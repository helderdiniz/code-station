import AppKit
import QuartzCore
import SwiftUI

struct CursorEffectOverlay: NSViewRepresentable {
    let settings: CursorEffectsSettings
    let activity: CursorEffectActivity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> CursorEffectLayerView {
        CursorEffectLayerView()
    }

    func updateNSView(_ view: CursorEffectLayerView, context: Context) {
        view.configure(settings: settings, activity: activity, reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ view: CursorEffectLayerView, coordinator: ()) {
        view.stop()
    }
}

// Pointer events only place layers. Core Animation owns their decay and every loop,
// so an idle pointer never asks SwiftUI to lay out the window again.
final class CursorEffectLayerView: LoopLayerView {
    static let particleLimit = 320
    private static let lifetime = Motion.popDuration * 3
    private static let orbitPeriod = Breath.period * 30

    private(set) var settings = CursorEffectsSettings()
    private(set) var activity = CursorEffectActivity.inactive
    private var reduced = false
    private var environmentReduced = false
    private var pointerInside = false
    private var point = CGPoint.zero
    private var previous: CGPoint?
    private var ribbonStart: CGPoint?
    private var lastEmission: CFTimeInterval = 0
    private var monitor: Any?
    private var tracking: NSTrackingArea?
    private var observing = false
    private var foreground = false
    private var lastSize = CGSize.zero
    private let ornament = CALayer()
    private var particles: [CAShapeLayer] = []
    private var nextParticle = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.masksToBounds = true
        layer?.addSublayer(ornament)
        setAccessibilityElement(false)
    }

    convenience init() { self.init(frame: .zero) }

    func configure(settings: CursorEffectsSettings, activity: CursorEffectActivity,
                   reduceMotion: Bool) {
        let appearanceChanged = self.settings != settings || environmentReduced != reduceMotion
        let changed = appearanceChanged || self.activity != activity
        let wasActive = self.activity == .running || self.activity == .waiting
        let preserveTrails = !appearanceChanged && wasActive && (activity == .running || activity == .waiting)
        let completed = wasActive && activity == .finished && self.settings.effect == settings.effect
        let presentedPoint = ornament.presentation()?.position ?? point
        self.settings = settings
        self.activity = activity
        environmentReduced = reduceMotion
        if changed {
            reduced = reduceMotion || settings.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            clear(preservingTrails: preserveTrails && !reduced)
            rebuild()
            if completed && foreground && !reduced && settings.effect != .none && pointerInside {
                ring(at: presentedPoint, finished: true)
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { stop(); return }
        if !observing {
            observing = true
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
                         NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                         NSView.boundsDidChangeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: name, object: nil)
            }
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionChanged),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        }
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged,
                .rightMouseDragged, .otherMouseDragged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated { self?.receive(event) }
                return event
            }
        }
        synchronize()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { stop() }
        super.viewWillMove(toWindow: newWindow)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        observing = false
        foreground = false
        pointerInside = false
        clear()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(tracking)
        self.tracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { receive(event) }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        clear(preservingTrails: true)
    }

    override func layoutLayers() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        if bounds.size != lastSize {
            lastSize = bounds.size
            previous = nil
            clear()
        }
        if !pointerInside { point = CGPoint(x: bounds.width * 0.6, y: bounds.height * 0.55) }
        synchronize()
    }

    override func restartLoops() { synchronize() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        clear()
        rebuild()
    }

    @objc private func visibilityChanged() { synchronize() }

    @objc private func motionChanged() {
        reduced = environmentReduced || settings.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        clear()
        rebuild()
    }

    private var isForegroundVisible: Bool {
        guard observing, let window else { return false }
        return NSApp.isActive && WindowKeyMonitor.frontmostWindow === window
            && window.isVisible && window.occlusionState.contains(.visible)
            && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
    }

    private func synchronize() {
        setForeground(isForegroundVisible)
    }

    func setForeground(_ visible: Bool) {
        if foreground != visible {
            foreground = visible
            previous = nil
            clear()
            if visible, let window {
                let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                pointerInside = visibleRect.contains(location)
                if pointerInside { point = location }
            }
        }
        if visible { rebuild() }
    }

    private func receive(_ event: NSEvent) {
        guard event.window === window, isForegroundVisible, settings.effect != .none else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard visibleRect.contains(location) else {
            if pointerInside { mouseExited(with: event) }
            return
        }
        movePointer(to: location)
        if event.type == .leftMouseDown || event.type == .rightMouseDown { click() }
    }

    func movePointer(to location: CGPoint, at time: CFTimeInterval = CACurrentMediaTime()) {
        guard foreground, location.x.isFinite, location.y.isFinite, bounds.contains(location),
              settings.effect != .none else { return }
        if !pointerInside {
            pointerInside = true
            previous = nil
            ribbonStart = nil
        }
        let from = previous ?? location
        point = location
        LayerLoop.still { ornament.position = location }
        rebuild()
        if activity == .running && !reduced {
            if hypot(location.x - from.x, location.y - from.y) > 2 && time - lastEmission > 1.0 / 90 {
                emit(from: from, to: location, elapsed: max(1.0 / 90, min(0.1, time - lastEmission)))
                lastEmission = time
                previous = location
            } else if previous == nil {
                previous = location
            }
        }
    }

    private func clear(preservingTrails: Bool = false) {
        previous = nil
        ribbonStart = nil
        LayerLoop.still {
            ornament.removeAllAnimations()
            ornament.sublayers?.forEach { $0.removeFromSuperlayer() }
            if !preservingTrails {
                for particle in particles {
                    particle.removeAllAnimations()
                    particle.opacity = 0
                }
            }
        }
    }

    private func rebuild() {
        guard foreground, settings.effect != .none,
              activity == .running || activity == .waiting,
              pointerInside else { return }
        guard ornament.sublayers?.isEmpty != false else { return }
        LayerLoop.still {
            ornament.position = point
            if activity == .waiting || reduced {
                let tint = activity == .waiting ? NSColor(Theme.attentionText) : NSColor(Theme.dotOnText)
                let halo = shape(path: CGPath(ellipseIn: CGRect(x: -8, y: -5, width: 30, height: 30), transform: nil),
                                 colour: tint.withAlphaComponent(0.6), width: 1.2)
                ornament.addSublayer(halo)
                let dot = shape(path: CGPath(ellipseIn: CGRect(x: 16.7, y: 18.7, width: 4.6, height: 4.6), transform: nil),
                                colour: tint, width: 0)
                dot.fillColor = tint.cgColor
                ornament.addSublayer(dot)
            } else if settings.effect == .orbit {
                addOrbits()
            } else {
                let radius = settings.effect == .ember ? 26 + settings.intensity * 13 : 22
                ornament.addSublayer(glow(at: CGPoint(x: 7, y: 10), radius: radius,
                                         colour: colour(settings.effect == .ember ? 0.4 : 1).withAlphaComponent(0.16)))
            }
        }
    }

    private func colour(_ fraction: Double) -> NSColor {
        let dark = Theme.isDark(effectiveAppearance)
        switch settings.effect {
        case .none: return Theme.accentNSColor
        case .ember: return NSColor(calibratedHue: 0.07 + fraction * 0.07, saturation: 0.85,
                                   brightness: dark ? 1 : 0.8, alpha: 1)
        case .aurora: return NSColor(calibratedHue: 0.47 + fraction * 0.28, saturation: 0.55,
                                    brightness: dark ? 1 : 0.7, alpha: 1)
        case .orbit: return NSColor(calibratedHue: 0.5 + fraction * 0.16, saturation: 0.35,
                                   brightness: dark ? 1 : 0.65, alpha: 1)
        }
    }

    private func shape(path: CGPath, colour: NSColor, width: CGFloat) -> CAShapeLayer {
        let result = CAShapeLayer()
        result.path = path
        result.fillColor = nil
        result.strokeColor = colour.cgColor
        result.lineWidth = width
        result.lineCap = .round
        result.lineJoin = .round
        result.contentsScale = window?.backingScaleFactor ?? 2
        return result
    }

    private func transient() -> CAShapeLayer {
        let particle: CAShapeLayer
        if particles.count < Self.particleLimit {
            particle = CAShapeLayer()
            particle.contentsScale = window?.backingScaleFactor ?? 2
            particles.append(particle)
            layer?.insertSublayer(particle, below: ornament)
        } else {
            particle = particles[nextParticle]
            nextParticle = (nextParticle + 1) % Self.particleLimit
        }
        particle.removeAllAnimations()
        particle.opacity = 0
        particle.position = .zero
        particle.fillColor = nil
        particle.lineCap = .round
        return particle
    }

    private func emit(from start: CGPoint, to end: CGPoint, elapsed: CFTimeInterval) {
        let velocity = CGVector(dx: (end.x - start.x) / elapsed, dy: (end.y - start.y) / elapsed)
        let speed = min(2500, hypot(velocity.dx, velocity.dy))
        let origin = CGPoint(x: end.x + 7, y: end.y + 10)
        LayerLoop.still {
            if settings.effect == .aurora {
                let control = CGPoint(x: start.x + 7, y: start.y + 10)
                let midpoint = CGPoint(x: (control.x + origin.x) / 2, y: (control.y + origin.y) / 2)
                let path = CGMutablePath()
                path.move(to: ribbonStart ?? control)
                path.addQuadCurve(to: midpoint, control: control)
                ribbonStart = midpoint
                for index in 0..<4 {
                    let ribbon = transient()
                    styleRibbon(ribbon, path: path, band: index)
                    let tint = CABasicAnimation(keyPath: "strokeColor")
                    tint.fromValue = colour(1).cgColor
                    tint.toValue = colour(0).cgColor
                    tint.duration = Self.lifetime
                    ribbon.add(tint, forKey: "ribbon-colour")
                    let taper = CABasicAnimation(keyPath: "lineWidth")
                    taper.fromValue = ribbon.lineWidth
                    taper.toValue = 0.1
                    taper.duration = Self.lifetime
                    ribbon.add(taper, forKey: "ribbon-taper")
                    let flow = CAKeyframeAnimation(keyPath: "position")
                    let now = CACurrentMediaTime()
                    flow.values = (0...24).map { frame in
                        let age = Double(frame) / 24
                        let wave = sin((1 - age) * 7 - (now + age * Self.lifetime) * 3 + Double(index) * 0.9)
                            * age * 13 * settings.intensity
                        return NSValue(point: CGPoint(x: 0, y: wave))
                    }
                    flow.duration = Self.lifetime
                    ribbon.add(flow, forKey: "ribbon-flow")
                    fade(ribbon, opacity: [0.05, 0.16, 0.65, 0.65][index])
                }
            } else {
                let count = settings.effect == .ember
                    ? min(11, Int(ceil(speed / 140 * (0.8 + settings.intensity * 2.8))))
                    : max(1, Int(settings.intensity * 3))
                for _ in 0..<count {
                    if settings.effect == .orbit {
                        let phase = CACurrentMediaTime().truncatingRemainder(dividingBy: Self.orbitPeriod) / Self.orbitPeriod
                        let offset = satellite(Int.random(in: 0..<4), phase: phase, radius: 24 + settings.intensity * 17)
                        spark(at: CGPoint(x: end.x + offset.x, y: end.y + offset.y), spread: 18, velocity: velocity)
                    } else {
                        spark(at: origin, spread: 9 + settings.intensity * 58, velocity: velocity)
                    }
                }
            }
        }
    }

    private func styleRibbon(_ ribbon: CAShapeLayer, path: CGPath, band: Int) {
        ribbon.name = "aurora-ribbon"
        ribbon.path = path
        ribbon.lineWidth = [30, 12, 3.7, 1.1][band] * settings.intensity
        ribbon.strokeColor = colour(1).cgColor
        ribbon.lineCap = .round
        ribbon.lineJoin = .round
    }

    private func spark(at origin: CGPoint, spread: Double, velocity: CGVector = .zero) {
        let particle = transient()
        particle.name = "cursor-spark"
        let angle = Double.random(in: 0...(2 * .pi))
        let speed = Double.random(in: spread * 0.2...spread)
        let dx = cos(angle) * speed - max(-2500, min(2500, velocity.dx)) * 0.13
        let dy = sin(angle) * speed - max(-2500, min(2500, velocity.dy)) * 0.13 - 20
        let duration = Self.lifetime * Double.random(in: 0.35...1)
        let gravity = settings.effect == .ember ? 65.0 : 5.0
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: -dx * 0.025, y: -dy * 0.025))
        if Double.random(in: 0...1) > 0.89 {
            path.move(to: CGPoint(x: -2.6, y: 0))
            path.addLine(to: CGPoint(x: 2.6, y: 0))
            path.move(to: CGPoint(x: 0, y: -2.6))
            path.addLine(to: CGPoint(x: 0, y: 2.6))
        }
        particle.path = path
        particle.lineWidth = Double.random(in: 0.5...1.75)
        particle.strokeColor = colour(1).cgColor
        let flight = CAKeyframeAnimation(keyPath: "position")
        flight.values = (0...12).map { frame in
            let time = duration * Double(frame) / 12
            return NSValue(point: CGPoint(x: origin.x + dx * (1 - exp(-0.9 * time)) / 0.9,
                                          y: origin.y + dy * time + gravity * time * time / 2))
        }
        flight.duration = duration
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.9
        opacity.toValue = 0
        opacity.duration = duration
        let cooling = CABasicAnimation(keyPath: "strokeColor")
        cooling.fromValue = particle.strokeColor
        cooling.toValue = colour(0).withAlphaComponent(0.2).cgColor
        cooling.duration = duration
        let thinning = CABasicAnimation(keyPath: "lineWidth")
        thinning.fromValue = particle.lineWidth
        thinning.toValue = 0.1
        thinning.duration = duration
        let group = CAAnimationGroup()
        group.animations = [flight, opacity, cooling, thinning]
        group.duration = duration
        particle.add(group, forKey: "decay")
    }

    private func glow(at point: CGPoint, radius: CGFloat, colour: NSColor) -> CAGradientLayer {
        let glow = CAGradientLayer()
        glow.name = "cursor-glow"
        glow.type = .radial
        glow.colors = [colour.cgColor, colour.cgColor, colour.withAlphaComponent(0).cgColor]
        glow.locations = [0, 0.22, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.frame = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        return glow
    }

    private func fade(_ layer: CALayer, opacity: Float) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity
        fade.toValue = 0
        fade.duration = Self.lifetime
        layer.add(fade, forKey: "decay")
    }

    private func click() {
        guard foreground, settings.effect != .none, activity == .running, !reduced else { return }
        LayerLoop.still {
            let origin = ornament.presentation()?.position ?? point
            for _ in 0..<Int(12 + settings.intensity * 20) { spark(at: CGPoint(x: origin.x + 7, y: origin.y + 10), spread: 175) }
            ring(at: origin, finished: false)
        }
    }

    private func ring(at origin: CGPoint, finished: Bool) {
        LayerLoop.still {
            let ring = transient()
            ring.position = CGPoint(x: origin.x + 7, y: origin.y + 10)
            ring.strokeColor = (finished ? NSColor(Theme.dotOnText) : colour(0.5)).cgColor
            ring.lineWidth = 1
            let opening = CGPath(ellipseIn: CGRect(x: -12, y: -12, width: 24, height: 24), transform: nil)
            let closing = CGPath(ellipseIn: CGRect(x: -77, y: -77, width: 154, height: 154), transform: nil)
            ring.path = closing
            let expand = CABasicAnimation(keyPath: "path")
            expand.fromValue = opening
            expand.toValue = closing
            expand.duration = Self.lifetime
            expand.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(expand, forKey: "ring")
            fade(ring, opacity: 0.6)
        }
    }

    private func addOrbits() {
        let radius = 24 + settings.intensity * 17
        let center = CGPoint(x: 8, y: 10)
        ornament.addSublayer(glow(at: center, radius: 18, colour: colour(0).withAlphaComponent(0.1)))
        for index in 0..<2 {
            var tilt = CGAffineTransform(rotationAngle: index == 0 ? -0.5 : 1.1)
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
            let rx = radius * (index == 0 ? 1 : 1.22)
            let ry = radius * (index == 0 ? 0.62 : 0.58)
            let ellipse = CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2), transform: &tilt)
            let orbit = shape(path: ellipse, colour: colour(Double(index)), width: 0.7)
            orbit.name = "orbit-track"
            orbit.opacity = index == 0 ? 0.35 : 0.25
            ornament.addSublayer(orbit)
        }
        let frames = Int(Self.orbitPeriod * 30)
        var positions: [[CGPoint]] = []
        for index in 0..<4 {
            let points = (0...frames).map { frame in
                satellite(index, phase: Double(frame) / Double(frames), radius: radius)
            }
            positions.append(points)
            let dotRadius = index == 0 ? 2.3 : 1.5
            let dot = shape(path: CGPath(ellipseIn: CGRect(x: -dotRadius, y: -dotRadius,
                                                          width: dotRadius * 2, height: dotRadius * 2), transform: nil),
                            colour: colour(Double(index % 2)), width: 0)
            dot.name = "orbit-satellite"
            dot.fillColor = colour(Double(index % 2)).cgColor
            dot.insertSublayer(glow(at: .zero, radius: 7, colour: colour(0).withAlphaComponent(0.3)), at: 0)
            let travel = CAKeyframeAnimation(keyPath: "position")
            travel.values = points.map { NSValue(point: $0) }
            travel.duration = Self.orbitPeriod
            dot.add(LayerLoop.repeating(travel, period: Self.orbitPeriod), forKey: "orbit")
            ornament.addSublayer(dot)
        }
        let paths = (0...frames).map { frame in
            let path = CGMutablePath()
            path.addLines(between: positions.map { $0[frame] })
            path.closeSubpath()
            return path
        }
        let constellation = shape(path: paths[0], colour: colour(0).withAlphaComponent(0.14), width: 0.55)
        let links = CAKeyframeAnimation(keyPath: "path")
        links.values = paths
        links.duration = Self.orbitPeriod
        constellation.add(LayerLoop.repeating(links, period: Self.orbitPeriod), forKey: "constellation")
        ornament.insertSublayer(constellation, at: 0)
    }

    private func satellite(_ index: Int, phase: Double, radius: Double) -> CGPoint {
        let reverse = index.isMultiple(of: 2) ? 1.0 : -1.0
        let angle = phase * .pi * 2 * Double(6 + index) * reverse + Double(index) * .pi / 2
        let rx = radius * (index.isMultiple(of: 2) ? 1 : 1.15)
        let ry = radius * 0.65
        let tilt = index.isMultiple(of: 2) ? -0.5 : 1.1
        return CGPoint(x: 8 + cos(angle) * rx * cos(tilt) - sin(angle) * ry * sin(tilt),
                       y: 10 + cos(angle) * rx * sin(tilt) + sin(angle) * ry * cos(tilt))
    }
}

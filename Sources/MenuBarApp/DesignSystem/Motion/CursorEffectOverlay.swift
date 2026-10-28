import AppKit
import QuartzCore
import SwiftUI

struct CursorEffectOverlay: NSViewRepresentable {
    let settings: CursorEffectsSettings
    let activity: CursorEffectActivity
    var preview = false
    var demo = false
    var flourish = 0
    var onPointerEntry: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> CursorEffectLayerView {
        CursorEffectLayerView()
    }

    func updateNSView(_ view: CursorEffectLayerView, context: Context) {
        view.onPointerEntry = onPointerEntry
        view.configure(settings: settings, activity: activity,
                       reduceMotion: reduceMotion, preview: preview, demo: demo, flourish: flourish)
    }

    static func dismantleNSView(_ view: CursorEffectLayerView, coordinator: ()) {
        view.stop()
    }
}

// Pointer events only place layers. Core Animation owns their decay and every loop,
// so an idle pointer never asks SwiftUI to lay out the window again.
final class CursorEffectLayerView: LoopLayerView {
    static let particleLimit = 96
    private static let lifetime = Motion.popDuration * 3
    private static let demoPeriod = Breath.period * 3

    private(set) var settings = CursorEffectsSettings()
    private(set) var activity = CursorEffectActivity.inactive
    private var reduced = false
    private var environmentReduced = false
    private var preview = false
    private var demo = false
    private var flourish = 0
    private var pointerInside = false
    private var point = CGPoint.zero
    private var previous: CGPoint?
    private var lastEmission: CFTimeInterval = 0
    private var monitor: Any?
    private var tracking: NSTrackingArea?
    private var observing = false
    private var foreground = false
    private var lastSize = CGSize.zero
    private let ornament = CALayer()
    private let demoLayers = CALayer()
    private var particles: [CAShapeLayer] = []
    private var nextParticle = 0
    var onPointerEntry: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.masksToBounds = true
        layer?.addSublayer(demoLayers)
        layer?.addSublayer(ornament)
        setAccessibilityElement(false)
    }

    convenience init() { self.init(frame: .zero) }

    func configure(settings: CursorEffectsSettings, activity: CursorEffectActivity,
                   reduceMotion: Bool, preview: Bool, demo: Bool, flourish: Int) {
        let changed = self.settings != settings || self.activity != activity
            || environmentReduced != reduceMotion || self.preview != preview || self.demo != demo
        let wasActive = self.activity == .running || self.activity == .waiting
        let completed = wasActive && activity == .finished && self.settings.effect == settings.effect
        let clicked = self.flourish != flourish
        let presentedPoint = ornament.presentation()?.position ?? point
        if self.demo && !demo && preview && !pointerInside { point = presentedPoint }
        self.settings = settings
        self.activity = activity
        environmentReduced = reduceMotion
        self.preview = preview
        self.demo = demo
        self.flourish = flourish
        if changed {
            reduced = reduceMotion || settings.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            clear()
            rebuild()
            if completed && foreground && !reduced && settings.effect != .none && (preview || pointerInside) {
                ring(at: presentedPoint, finished: true)
            }
        }
        if clicked { click() }
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
        previous = nil
        clear()
        rebuild()
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
            if visible && !preview, let window {
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
            clear()
            if preview { onPointerEntry() }
        }
        let from = previous ?? location
        point = location
        LayerLoop.still { ornament.position = location }
        rebuild()
        if activity == .running && !reduced {
            if hypot(location.x - from.x, location.y - from.y) > 2 && time - lastEmission > 1.0 / 90 {
                emit(from: from, to: location)
                lastEmission = time
                previous = location
            } else if previous == nil {
                previous = location
            }
        }
    }

    private func clear() {
        LayerLoop.still {
            ornament.removeAllAnimations()
            ornament.sublayers?.forEach { $0.removeFromSuperlayer() }
            demoLayers.sublayers?.forEach { $0.removeFromSuperlayer() }
            for particle in particles {
                particle.removeAllAnimations()
                particle.opacity = 0
            }
        }
    }

    private func rebuild() {
        guard foreground, settings.effect != .none,
              activity == .running || activity == .waiting,
              pointerInside || preview else { return }
        guard ornament.sublayers?.isEmpty != false else { return }
        LayerLoop.still {
            ornament.position = point
            if activity == .waiting || reduced {
                let halo = shape(path: CGPath(ellipseIn: CGRect(x: -15, y: -15, width: 30, height: 30), transform: nil),
                                 colour: activity == .waiting ? NSColor(Theme.attentionText) : NSColor(Theme.dotOnText), width: 1.2)
                ornament.addSublayer(halo)
            } else if settings.effect == .orbit {
                addOrbits()
            } else {
                let glow = shape(path: CGPath(ellipseIn: CGRect(x: -7, y: -7, width: 14, height: 14), transform: nil),
                                 colour: colour(0), width: 1)
                glow.opacity = 0.35
                ornament.addSublayer(glow)
            }
            if preview && !pointerInside {
                ornament.addSublayer(samplePointer())
                if demo && activity == .running && !reduced { animateDemo() }
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

    private func emit(from start: CGPoint, to end: CGPoint) {
        LayerLoop.still {
            if settings.effect == .aurora {
                for index in 0..<4 {
                    let ribbon = transient()
                    let offset = CGFloat(index - 2) * 2
                    let path = CGMutablePath()
                    path.move(to: CGPoint(x: start.x, y: start.y + offset))
                    path.addQuadCurve(to: CGPoint(x: end.x, y: end.y + offset),
                                      control: CGPoint(x: (start.x + end.x) / 2, y: start.y + offset))
                    ribbon.path = path
                    ribbon.lineWidth = [12, 6, 2, 1][index] * settings.intensity
                    ribbon.strokeColor = colour(Double(index) / 3).cgColor
                    fade(ribbon, opacity: index < 2 ? 0.18 : 0.75)
                }
            } else {
                for _ in 0..<Int(2 + settings.intensity * 6) {
                    spark(at: end, spread: 28 + settings.intensity * 25)
                }
            }
        }
    }

    private func spark(at origin: CGPoint, spread: Double) {
        let particle = transient()
        let radius = Double.random(in: 0.6...1.6)
        particle.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        particle.fillColor = colour(Double.random(in: 0...1)).cgColor
        particle.strokeColor = nil
        let dx = Double.random(in: -spread...spread)
        let dy = Double.random(in: -spread...spread)
        let flight = CAKeyframeAnimation(keyPath: "position")
        flight.values = [origin,
                         CGPoint(x: origin.x + dx * 0.6, y: origin.y + dy * 0.6 - 8),
                         CGPoint(x: origin.x + dx, y: origin.y + dy + (settings.effect == .ember ? 32 : 4))]
            .map { NSValue(point: $0) }
        flight.keyTimes = [0, 0.5, 1]
        flight.duration = Self.lifetime
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.9
        opacity.toValue = 0
        opacity.duration = Self.lifetime
        let cooling = CABasicAnimation(keyPath: "fillColor")
        cooling.fromValue = particle.fillColor
        cooling.toValue = colour(0).withAlphaComponent(0.2).cgColor
        cooling.duration = Self.lifetime
        let group = CAAnimationGroup()
        group.animations = [flight, opacity, cooling]
        group.duration = Self.lifetime
        particle.add(group, forKey: "decay")
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
            for _ in 0..<Int(12 + settings.intensity * 20) { spark(at: origin, spread: 70) }
            ring(at: origin, finished: false)
        }
    }

    private func ring(at origin: CGPoint, finished: Bool) {
        LayerLoop.still {
            let ring = transient()
            ring.position = origin
            ring.strokeColor = (finished ? NSColor(Theme.dotOnText) : colour(0.5)).cgColor
            ring.lineWidth = 1
            let opening = CGPath(ellipseIn: CGRect(x: -12, y: -12, width: 24, height: 24), transform: nil)
            let closing = CGPath(ellipseIn: CGRect(x: -48, y: -48, width: 96, height: 96), transform: nil)
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
        let radius = 22 + settings.intensity * 15
        for index in 0..<2 {
            var tilt = CGAffineTransform(rotationAngle: index == 0 ? -0.5 : 1.1)
            let ellipse = CGPath(ellipseIn: CGRect(x: -radius, y: -radius * 0.6,
                                                 width: radius * 2, height: radius * 1.2), transform: &tilt)
            let orbit = shape(path: ellipse, colour: colour(Double(index)), width: 0.7)
            orbit.opacity = 0.45
            ornament.addSublayer(orbit)
            for satellite in 0..<2 {
                let dot = shape(path: CGPath(ellipseIn: CGRect(x: -2, y: -2, width: 4, height: 4), transform: nil),
                                colour: colour(Double(index)), width: 1)
                dot.fillColor = colour(Double(index)).cgColor
                let travel = CAKeyframeAnimation(keyPath: "position")
                travel.path = ellipse
                travel.calculationMode = .paced
                travel.duration = Breath.period * Double(index + 2)
                let loop = LayerLoop.repeating(travel, period: travel.duration)
                loop.timeOffset += Double(satellite) * travel.duration / 2
                dot.add(loop, forKey: "orbit")
                ornament.addSublayer(dot)
            }
        }
    }

    private func samplePointer() -> CAShapeLayer {
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLines(between: [CGPoint(x: 14, y: 11), CGPoint(x: 8, y: 12), CGPoint(x: 5, y: 19), .zero])
        let cursor = shape(path: path, colour: .black, width: 1)
        cursor.fillColor = NSColor.white.cgColor
        return cursor
    }

    private func demoPoint(_ fraction: Double) -> CGPoint {
        let angle = fraction * .pi * 2
        return CGPoint(x: bounds.width * (0.57 + cos(angle) * 0.23),
                       y: bounds.height * (0.54 + sin(angle * 2) * 0.18))
    }

    private func animateDemo() {
        let points = (0...120).map { demoPoint(Double($0) / 120) }
        let travel = CAKeyframeAnimation(keyPath: "position")
        travel.values = points.map { NSValue(point: $0) }
        travel.duration = Self.demoPeriod
        ornament.add(LayerLoop.repeating(travel, period: Self.demoPeriod), forKey: "demo")

        // The demo is a precomputed journey. Each mark shares the cursor's clock, which
        // makes it a real moving sample without a timer or a display-link callback.
        let count = Int(16 + settings.intensity * 48)
        for index in 0..<count {
            let fraction = Double(index) / Double(count)
            let origin = demoPoint(fraction)
            let mark: CAShapeLayer
            if settings.effect == .aurora {
                let path = CGMutablePath()
                path.move(to: origin)
                path.addLine(to: demoPoint(fraction + 1.0 / Double(count)))
                mark = shape(path: path, colour: colour(fraction), width: 2 + 6 * settings.intensity)
            } else {
                mark = shape(path: CGPath(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2), transform: nil),
                             colour: colour(fraction), width: 1)
                mark.position = origin
                mark.fillColor = colour(fraction).cgColor
            }
            mark.opacity = 0
            demoLayers.addSublayer(mark)
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0.8, 0, 0]
            opacity.keyTimes = [0, NSNumber(value: Self.lifetime / Self.demoPeriod), 1]
            opacity.duration = Self.demoPeriod
            let loop = LayerLoop.repeating(opacity, period: Self.demoPeriod)
            loop.timeOffset = (loop.timeOffset + Self.demoPeriod * (1 - fraction)).truncatingRemainder(dividingBy: Self.demoPeriod)
            mark.add(loop, forKey: "demo-decay")
            if settings.effect != .aurora {
                let drift = CAKeyframeAnimation(keyPath: "position")
                let end = CGPoint(x: origin.x + Double.random(in: -18...18),
                                  y: origin.y + (settings.effect == .ember ? 28 : 8))
                drift.values = [NSValue(point: origin), NSValue(point: end), NSValue(point: end)]
                drift.keyTimes = opacity.keyTimes
                drift.duration = Self.demoPeriod
                let flight = LayerLoop.repeating(drift, period: Self.demoPeriod)
                flight.timeOffset = loop.timeOffset
                mark.add(flight, forKey: "demo-flight")
            }
        }
    }
}

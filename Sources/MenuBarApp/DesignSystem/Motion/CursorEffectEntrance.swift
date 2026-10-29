import AppKit
import QuartzCore

// Geometry is sampled once for Core Animation and evaluated directly for inspection.
// Pointer events only move the parent layer; they never drive a frame clock.
@MainActor
enum CursorEffectEntrance {
    static func make(effect: CursorEffect, intensity: Double, scale: CGFloat,
                     progress inspectionProgress: Double? = nil,
                     colour: (Double) -> NSColor,
                     satellite: (Int, Double) -> CGPoint) -> CALayer {
        let root = CALayer()
        root.name = "cursor-entrance"
        let duration = effect.entranceDuration
        guard duration > 0 else { return root }
        let extent = 0.55 + intensity * 0.82
        let brightness = 0.4 + intensity * 0.8
        let progress = (0...60).map { Double($0) / 60 }

        func animate(_ layer: CALayer, _ key: String, values: [Any]) {
            guard inspectionProgress == nil else { return }
            let animation = CAKeyframeAnimation(keyPath: key)
            animation.values = values
            animation.duration = duration
            animation.beginTime = .leastNonzeroMagnitude
            animation.fillMode = .both
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: "entrance-\(key)")
        }

        func mark(_ name: String, tint: NSColor, width: CGFloat = 0.8, filled: Bool = false, fillOpacity: CGFloat = 0.2,
                  frame: (Double) -> (CGPath, Double)) {
            let layer = CAShapeLayer()
            layer.name = name
            layer.contentsScale = scale
            layer.strokeColor = tint.cgColor
            layer.fillColor = filled ? tint.withAlphaComponent(fillOpacity).cgColor : nil
            layer.lineWidth = width
            layer.lineCap = .round
            layer.lineJoin = .round
            let selected = frame(inspectionProgress ?? 1)
            layer.path = selected.0
            layer.opacity = Float(max(0, min(1, selected.1 * brightness)))
            if inspectionProgress == nil {
                let frames = progress.map(frame)
                animate(layer, "path", values: frames.map { $0.0 })
                animate(layer, "opacity", values: frames.map { max(0, min(1, $0.1 * brightness)) })
            }
            root.addSublayer(layer)
        }

        func glow(radius: Double, tint: NSColor, opacity: @escaping (Double) -> Double) {
            let layer = CAGradientLayer()
            layer.name = "entrance-glow"
            layer.type = .radial
            layer.colors = [tint.cgColor, tint.withAlphaComponent(0.45).cgColor, tint.withAlphaComponent(0).cgColor]
            layer.locations = [0, 0.25, 1]
            layer.startPoint = CGPoint(x: 0.5, y: 0.5)
            layer.endPoint = CGPoint(x: 1, y: 1)
            let r = radius * extent
            layer.frame = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
            layer.opacity = Float(inspectionProgress.map { opacity($0) * brightness } ?? 0)
            animate(layer, "opacity", values: progress.map { opacity($0) * brightness })
            root.addSublayer(layer)
        }

        switch effect {
        case .none: break
        case .ember:
            glow(radius: 46, tint: colour(0.6)) { sin(.pi * $0) * 0.38 }
            for index in 0..<Int(14 + intensity * 36) {
                let angle = Double(index) * 2.39996
                mark("entrance-fleck", tint: colour(0.8), width: 0.7 + noise(index) * 0.8) { p in
                    let gather = 1 - ease(p / 0.42)
                    let release = ease((p - 0.31) / 0.69)
                    let radius = ((18 + noise(index) * 60) * gather
                        + (10 + noise(index + 20) * 62) * release) * extent
                    let point = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius * 0.75 - release * 14 * extent)
                    let path = CGMutablePath()
                    path.move(to: point)
                    path.addLine(to: CGPoint(x: point.x - cos(angle) * 3, y: point.y + 2 + release * 3))
                    let alpha = p < 0.36 ? smooth(p / 0.16) : 1 - smooth((p - 0.66) / 0.34)
                    return (path, alpha * (0.25 + noise(index + 100) * 0.7))
                }
            }
            mark("entrance-core", tint: colour(1), filled: true, fillOpacity: 1) { p in
                (ellipse(radius: (1.3 + sin(.pi * p) * 2) * extent),
                 smooth(p / 0.16) * (1 - smooth((p - 0.66) / 0.34)))
            }
        case .aurora:
            let release = Motion.popDuration * 2
            let gather = release - Motion.leaveDuration
            let fadeDuration = duration - release - Motion.revealDuration
            let center = CGPoint(x: 7, y: 10)

            func point(_ angle: Double, _ radius: Double, flat: Double = 1) -> CGPoint {
                CGPoint(x: center.x + cos(angle) * radius * extent,
                        y: center.y + sin(angle) * radius * flat * extent)
            }
            func burst(_ p: Double) -> (travel: Double, drift: Double, opacity: Double, flash: Double) {
                let time = p * duration - release
                let ignition = smooth(time / (Motion.controlDuration / 10))
                let fadeDelay = Motion.leaveDuration * 2 / 3
                let fade = 1 - smooth((time - fadeDelay) / (duration - release - fadeDelay))
                return (ease(time / Motion.revealDuration),
                        ease((time - Motion.revealDuration) / fadeDuration),
                        ignition * fade,
                        ignition * fade * exp(-pow((time - Motion.revealDuration / 5) / (Motion.revealDuration / 2), 2)))
            }
            func novaGlow(_ name: String, colours: [NSColor], stops: [NSNumber],
                          frame: (Double) -> (radius: Double, opacity: Double)) {
                let layer = CAGradientLayer()
                layer.name = name
                layer.contentsScale = scale
                layer.type = .radial
                layer.colors = colours.map(\.cgColor)
                layer.locations = stops
                layer.startPoint = CGPoint(x: 0.5, y: 0.5)
                layer.endPoint = CGPoint(x: 1, y: 1)
                layer.position = center
                func bounds(_ radius: Double) -> CGRect {
                    CGRect(x: 0, y: 0, width: radius * extent * 2, height: radius * extent * 2)
                }
                let selected = frame(inspectionProgress ?? 1)
                layer.bounds = bounds(selected.radius)
                layer.opacity = Float(clamp(selected.opacity * brightness))
                if inspectionProgress == nil {
                    let frames = progress.map(frame)
                    animate(layer, "bounds", values: frames.map { NSValue(rect: bounds($0.radius)) })
                    animate(layer, "opacity", values: frames.map { clamp($0.opacity * brightness) })
                }
                root.addSublayer(layer)
            }

            novaGlow("entrance-charge-glow", colours: [colour(0.75), colour(0.5).withAlphaComponent(0.32),
                     colour(0.3).withAlphaComponent(0)], stops: [0, 0.3, 1]) { p in
                (37, smooth(p * duration / (gather * 0.45))
                    * (1 - smooth((p * duration - release) / Motion.leaveDuration)) * 0.34)
            }
            let coreColours = [colour(0.2).blended(withFraction: 0.82, of: .white)!,
                               colour(0.2).withAlphaComponent(0.7), colour(0.5).withAlphaComponent(0.32),
                               colour(0.9).withAlphaComponent(0.1), colour(0.9).withAlphaComponent(0)]
            novaGlow("entrance-charge-core", colours: coreColours, stops: [0, 0.12, 0.36, 0.7, 1]) { p in
                (25, smooth((p * duration / gather - 0.65) / 0.35)
                    * (1 - smooth((p * duration - release) / Motion.leaveDuration)) * 0.5)
            }
            for index in 0..<12 {
                let angle = Double(index) * .pi * 2 / 12 + noise(index) * 0.24
                mark("entrance-charge-wisp", tint: colour(noise(index + 9)), width: 0.7) { p in
                    let charge = clamp(p * duration / gather)
                    let reach = 34 + (1 - ease(charge)) * (35 + noise(index + 4) * 25)
                    let path = CGMutablePath()
                    for step in 0...17 {
                        let t = Double(step) / 17
                        let location = point(angle + sin(t * .pi) * 0.18, reach + (11 - reach) * t)
                        if step == 0 { path.move(to: location) } else { path.addLine(to: location) }
                    }
                    return (path, smooth(charge / 0.45)
                            * (1 - smooth((p * duration - release) / Motion.leaveDuration)) * 0.44)
                }
            }
            novaGlow("entrance-burst-core", colours: coreColours, stops: [0, 0.12, 0.36, 0.7, 1]) { p in
                let frame = burst(p)
                return (58 + frame.travel * 62, frame.flash * 0.95 + frame.opacity * 0.12)
            }

            // Nearby hues share paths, keeping the full burst within the entrance layer budget.
            let hues = 8
            for hue in 0..<hues {
                let tint = colour(Double(hue) / Double(hues - 1))
                let streaks = (0..<54).filter { index in
                    let angle = Double(index) * 2.399963 + noise(index + 30) * 0.13
                    return Int((0.06 + 0.92 * (sin(angle) + 1) / 2) * Double(hues)) == hue
                }
                for (band, width, alpha) in [("glow", 7.5, 0.05), ("light", 2.3, 0.3), ("streak", 0.9, 0.72)] {
                    mark("entrance-burst-\(band)", tint: tint, width: width) { p in
                        let frame = burst(p)
                        let path = CGMutablePath()
                        for index in streaks {
                            let angle = Double(index) * 2.399963 + noise(index + 30) * 0.13
                            let reach = (65 + noise(index + 4) * 75) * frame.travel + frame.drift * 20
                            let tail = reach * (0.13 + noise(index + 14) * 0.44) + frame.drift * 30
                            let bend = (noise(index + 64) - 0.5) * 0.17
                            for step in 0...14 {
                                let t = Double(step) / 14
                                let location = point(angle + bend * t, tail + (reach - tail) * t, flat: 0.86)
                                if step == 0 { path.move(to: location) } else { path.addLine(to: location) }
                            }
                        }
                        return (path, frame.opacity * alpha)
                    }
                }
                let points = (0..<52).filter { Int(noise($0 + 9) * Double(hues)) == hue }
                mark("entrance-burst-point", tint: tint, width: 0, filled: true, fillOpacity: 1) { p in
                    let frame = burst(p)
                    let path = CGMutablePath()
                    for index in points {
                        let angle = Double(index) * 2.399963 + 0.64
                        let radius = (50 + noise(index + 8) * 105) * frame.travel + frame.drift * 25
                        let location = point(angle, radius, flat: 0.84)
                        let size = (0.35 + noise(index + 11) * 0.95) * extent
                        path.addEllipse(in: CGRect(x: location.x - size, y: location.y - size,
                                                   width: size * 2, height: size * 2))
                    }
                    return (path, frame.opacity * 0.65)
                }
            }
            mark("entrance-burst-wave", tint: colour(0.25), width: 0.7) { p in
                let frame = burst(p)
                let rx = (16 + frame.travel * 104) * extent
                let ry = (12 + frame.travel * 77) * extent
                let path = CGPath(ellipseIn: CGRect(x: center.x - rx, y: center.y - ry,
                                                   width: rx * 2, height: ry * 2), transform: nil)
                return (path, frame.opacity * (1 - smooth((p * duration - release) / Motion.revealDuration)) * 0.25)
            }
        case .orbit:
            for index in 0..<4 {
                let dot = CAShapeLayer()
                dot.name = "entrance-satellite"
                dot.contentsScale = scale
                dot.path = ellipse(radius: index == 0 ? 2.3 : 1.5)
                dot.fillColor = colour(Double(index % 2)).cgColor
                dot.shadowColor = dot.fillColor
                dot.shadowOpacity = Float(0.4 * brightness)
                dot.shadowRadius = 4 * extent
                dot.shadowOffset = .zero
                func position(_ p: Double) -> NSValue {
                    let join = ease((p - Double(index) * 0.08) / 0.62)
                    let target = satellite(index, p * duration)
                    let reach = 1 + (1 - join) * (1.5 + noise(index)) * extent
                    return NSValue(point: CGPoint(x: 8 + (target.x - 8) * reach,
                                                  y: 10 + (target.y - 10) * reach))
                }
                let points = progress.map(position)
                dot.position = inspectionProgress.map { position($0).pointValue } ?? points.last!.pointValue
                dot.opacity = Float(inspectionProgress.map {
                    min(1, smooth($0 / 0.18) * brightness) * (1 - smooth(($0 - 0.86) / 0.14))
                } ?? 0)
                animate(dot, "position", values: points)
                animate(dot, "opacity", values: progress.map {
                    min(1, smooth($0 / 0.18) * brightness) * (1 - smooth(($0 - 0.86) / 0.14))
                })
                root.addSublayer(dot)
            }
        case .ripple:
            glow(radius: 26, tint: colour(0.5)) { sin(.pi * $0) * 0.18 }
            mark("entrance-drop", tint: colour(0.5), filled: true, fillOpacity: 1) { p in
                (ellipse(radius: max(0.1, 3 * (1 - p / 0.3) + 0.7) * extent),
                 smooth(p / 0.12) * (1 - smooth((p - 0.2) / 0.1)))
            }
            mark("entrance-wave", tint: colour(0.5), width: 0.85) { p in
                let wave = clamp((p - 0.25) / 0.75)
                return (ellipse(radius: (8 + ease(wave) * 77) * extent, flat: 0.85), sin(.pi * wave) * 0.7)
            }
        case .prism:
            glow(radius: 38, tint: colour(0.5)) { sin(.pi * $0) * 0.12 }
            for index in 0..<6 {
                mark("entrance-facet", tint: colour(Double(index % 3) / 2), filled: true) { p in
                    let open = sin(p * .pi)
                    let settle = ease((p - 0.55) / 0.45)
                    let angle = Double(index) * .pi / 3 + p * 0.9
                    let radius = (15 + open * 29) * extent
                    let point = CGPoint(x: cos(angle) * radius * (1 - settle * 0.65) - settle * 15 * extent,
                                        y: sin(angle) * radius * (1 - settle * 0.65) + settle * 9 * extent)
                    let size = (10 + open * 9) * extent
                    let path = CGMutablePath()
                    path.addLines(between: [CGPoint(x: size, y: -size * 0.35),
                                           CGPoint(x: -size * 0.75, y: -size * 0.55),
                                           CGPoint(x: -size * 0.35, y: size * 0.7)])
                    path.closeSubpath()
                    var transform = CGAffineTransform(rotationAngle: angle + .pi / 2 + p * 0.6)
                        .concatenating(CGAffineTransform(translationX: point.x, y: point.y))
                    return (path.copy(using: &transform)!, open * 0.68)
                }
            }
        }
        return root
    }

    private static func ellipse(radius: Double, flat: Double = 1) -> CGPath {
        CGPath(ellipseIn: CGRect(x: -radius, y: -radius * flat, width: radius * 2, height: radius * 2 * flat), transform: nil)
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
    private static func ease(_ value: Double) -> Double { 1 - pow(1 - clamp(value), 3) }
    private static func smooth(_ value: Double) -> Double {
        let p = clamp(value)
        return p * p * (3 - 2 * p)
    }
    private static func noise(_ index: Int) -> Double {
        let value = sin(Double(index) * 127.1 + 311.7) * 43758.5453
        return value - floor(value)
    }
}

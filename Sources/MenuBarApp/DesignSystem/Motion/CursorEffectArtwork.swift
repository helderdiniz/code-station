import AppKit

// The still illustrations and live layers use the same glass, ring and colour geometry.
enum CursorEffectArtwork {
    static let ringStops: [CGFloat] = [0, 0.33, 0.64, 1]
    static let faceStops: [CGFloat] = [0, 0.52, 1]
    static let edgeStops: [CGFloat] = [0, 0.5, 1]

    static func ringColours(light: Bool) -> [CGColor] {
        let components: [(Double, Double, Double, Double)] = light
            ? [(32, 121, 126, 1), (26, 128, 148, 0.7), (70, 105, 132, 1), (77, 135, 110, 0.6)]
            : [(99, 178, 161, 0.7), (191, 233, 210, 1), (126, 193, 219, 0.8), (112, 152, 117, 0.4)]
        return components.map { NSColor(srgbRed: $0.0 / 255, green: $0.1 / 255, blue: $0.2 / 255, alpha: $0.3).cgColor }
    }

    static func faceColours(hue: Double, light: Bool) -> [CGColor] {
        [colour(hue, saturation: light ? 0.65 : 0.85, lightness: light ? 0.44 : 0.8, alpha: 0.2),
         colour(hue + 35, saturation: 0.85, lightness: light ? 0.47 : 0.76, alpha: 0.4),
         colour(hue - 25, saturation: 0.85, lightness: light ? 0.5 : 0.83, alpha: 0.08)]
    }

    static func edgeColours(hue: Double, light: Bool) -> [CGColor] {
        [colour(hue, saturation: 0.8, lightness: light ? 0.39 : 0.8, alpha: 0.18),
         colour(hue + 30, saturation: 0.9, lightness: light ? 0.48 : 0.89),
         colour(hue - 15, saturation: 0.9, lightness: light ? 0.44 : 0.7, alpha: 0.5)]
    }

    static func seamColour(hue: Double, light: Bool) -> CGColor {
        colour(hue + 15, saturation: 0.7, lightness: light ? 0.47 : 0.88, alpha: 0.2)
    }

    static func facetVertices(size: Double, stretch: Double = 1.3, center: CGPoint = .zero) -> [CGPoint] {
        [CGPoint(x: -0.85, y: 0.36), CGPoint(x: 0.72, y: -0.8), CGPoint(x: 0.3, y: 0.75)]
            .map { CGPoint(x: center.x + $0.x * size * stretch, y: center.y + $0.y * size) }
    }

    static func facetPath(vertices: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: vertices)
        path.closeSubpath()
        return path
    }

    static func seams(vertices: [CGPoint], center: CGPoint) -> CGPath {
        let path = CGMutablePath()
        for vertex in vertices {
            path.move(to: center)
            path.addLine(to: vertex)
        }
        return path
    }

    static func cursorPosition(effect: CursorEffect, size: CGSize, preview: Bool) -> CGPoint {
        let scale = illustrationScale(size: size, preview: preview)
        let center = illustrationCenter(size: size, preview: preview)
        let offset = effect == .prism ? CGPoint(x: 52, y: -35) : CGPoint(x: 8, y: -9)
        return CGPoint(x: center.x + offset.x * scale, y: center.y + offset.y * scale)
    }

    static func drawIllustration(_ effect: CursorEffect, in context: CGContext, size: CGSize, preview: Bool, light: Bool) {
        let center = illustrationCenter(size: size, preview: preview)
        let scale = illustrationScale(size: size, preview: preview)
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: scale, y: scale)
        switch effect {
        case .ripple:
            glow(in: context, center: .zero, radius: 190,
                 colour: NSColor(srgbRed: 0.34, green: 0.56, blue: 0.46, alpha: light ? 0.06 : 0.1).cgColor)
            for (index, radius) in [166.0, 137, 108, 79, 50, 24].enumerated() {
                let point = CGPoint(x: -Double(5 - index) * 8, y: Double(5 - index) * 4)
                let radius = radius * (preview ? 1 : 1.3)
                drawRing(in: context, center: point, radius: radius, opacity: 0.11 + Double(index) * 0.11,
                         width: index > 3 ? 1.1 : 0.8, light: light)
                drawRing(in: context, center: point, radius: radius + 2, opacity: 0.04, width: 3, light: light)
            }
            for (radius, opacity) in [(58.0, 0.1), (89.0, 0.07)] {
                drawRing(in: context, center: CGPoint(x: -111, y: 47), radius: radius, opacity: opacity, width: 0.7, light: light)
            }
            if preview {
                star(in: context, at: CGPoint(x: -65, y: -94), radius: 2.5, hue: 160, opacity: 0.6, light: light)
                star(in: context, at: CGPoint(x: 101, y: 46), radius: 2, hue: 175, opacity: 0.4, light: light)
            }
        case .prism:
            glow(in: context, center: CGPoint(x: -30, y: 0), radius: 180,
                 colour: NSColor(srgbRed: 0.41, green: 0.4, blue: 0.69, alpha: 0.07).cgColor)
            let facets: [(Double, Double, Double, Double, Double, Double)] = [
                (-167, 60, 21, -0.8, 174, 0.22), (-128, 47, 31, -0.65, 184, 0.32),
                (-100, 24, 39, -0.5, 203, 0.42), (-61, 13, 46, -0.35, 226, 0.52),
                (-21, -6, 53, -0.18, 255, 0.68), (27, -23, 59, 0.01, 284, 0.78),
                (64, -42, 28, 0.35, 326, 0.5)
            ]
            for (x, y, radius, angle, hue, opacity) in facets {
                drawFacet(in: context, center: CGPoint(x: x, y: y), size: radius * (preview ? 1 : 1.3),
                          angle: angle, hue: hue, opacity: opacity, stretch: 1.18, light: light)
            }
            let fragments: [(Double, Double, Double, Double)] = [(-122, 4, 13, 188), (-67, 73, 17, 225),
                                                               (24, 52, 18, 272), (78, -5, 10, 308)]
            for (index, fragment) in fragments.enumerated() {
                drawFacet(in: context, center: CGPoint(x: fragment.0, y: fragment.1), size: fragment.2,
                          angle: 0.3 + Double(index), hue: fragment.3, opacity: 0.32, stretch: 1, light: light)
            }
            star(in: context, at: CGPoint(x: 28, y: -64), radius: 5, hue: 285, opacity: 0.8, light: light)
            star(in: context, at: CGPoint(x: -102, y: 52), radius: 3, hue: 170, opacity: 0.6, light: light)
        default: break
        }
    }

    private static func illustrationScale(size: CGSize, preview: Bool) -> Double {
        preview ? min(size.width / 580, size.height / 360) : min(size.width / 410, size.height / 330)
    }

    private static func illustrationCenter(size: CGSize, preview: Bool) -> CGPoint {
        CGPoint(x: size.width * (preview ? 0.65 : 0.5), y: size.height * (preview ? 0.55 : 0.5))
    }

    private static func drawRing(in context: CGContext, center: CGPoint, radius: Double, opacity: Double,
                                 width: Double, light: Bool) {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: 1, y: 0.86)
        context.setAlpha(opacity)
        context.addEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
        context.setLineWidth(width)
        context.replacePathWithStrokedPath()
        context.clip()
        gradient(in: context, colours: ringColours(light: light), stops: ringStops,
                 start: CGPoint(x: -radius, y: -radius), end: CGPoint(x: radius, y: radius))
    }

    private static func drawFacet(in context: CGContext, center: CGPoint, size: Double, angle: Double,
                                  hue: Double, opacity: Double, stretch: Double, light: Bool) {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: angle)
        context.scaleBy(x: stretch, y: 1)
        context.setAlpha(opacity)
        let vertices = facetVertices(size: size, stretch: 1)
        let outline = facetPath(vertices: vertices)
        context.saveGState()
        context.addPath(outline)
        context.clip()
        gradient(in: context, colours: faceColours(hue: hue, light: light), stops: faceStops,
                 start: CGPoint(x: -size, y: -size), end: CGPoint(x: size, y: size))
        context.restoreGState()
        context.saveGState()
        context.addPath(outline)
        context.setLineWidth(0.8)
        context.replacePathWithStrokedPath()
        context.clip()
        gradient(in: context, colours: edgeColours(hue: hue, light: light), stops: edgeStops,
                 start: CGPoint(x: -size, y: 0), end: CGPoint(x: size, y: 0))
        context.restoreGState()
        context.addPath(seams(vertices: vertices, center: CGPoint(x: size * 0.02, y: size * 0.02)))
        context.setStrokeColor(seamColour(hue: hue, light: light))
        context.setLineWidth(0.5)
        context.strokePath()
    }

    private static func gradient(in context: CGContext, colours: [CGColor], stops: [CGFloat], start: CGPoint, end: CGPoint) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: colours as CFArray, locations: stops) else { return }
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func glow(in context: CGContext, center: CGPoint, radius: Double, colour: CGColor) {
        guard let clear = colour.copy(alpha: 0),
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [colour, clear] as CFArray, locations: [0, 1]) else { return }
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: radius, options: [])
    }

    private static func star(in context: CGContext, at point: CGPoint, radius: Double, hue: Double, opacity: Double, light: Bool) {
        context.setStrokeColor(colour(hue, saturation: 0.45, lightness: light ? 0.4 : 0.85, alpha: opacity))
        context.setLineWidth(0.8)
        context.move(to: CGPoint(x: point.x - radius, y: point.y))
        context.addLine(to: CGPoint(x: point.x + radius, y: point.y))
        context.move(to: CGPoint(x: point.x, y: point.y - radius))
        context.addLine(to: CGPoint(x: point.x, y: point.y + radius))
        context.strokePath()
    }

    private static func colour(_ hue: Double, saturation: Double, lightness: Double, alpha: Double = 1) -> CGColor {
        let hue = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let secondary = chroma * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
        let components: (Double, Double, Double) = switch hue {
        case ..<1: (chroma, secondary, 0)
        case ..<2: (secondary, chroma, 0)
        case ..<3: (0, chroma, secondary)
        case ..<4: (0, secondary, chroma)
        case ..<5: (secondary, 0, chroma)
        default: (chroma, 0, secondary)
        }
        let offset = lightness - chroma / 2
        return NSColor(srgbRed: components.0 + offset, green: components.1 + offset,
                       blue: components.2 + offset, alpha: alpha).cgColor
    }
}

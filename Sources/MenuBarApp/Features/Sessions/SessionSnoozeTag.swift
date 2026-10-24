import AppKit
import QuartzCore
import SwiftUI

struct SessionSnoozeTag: NSViewRepresentable {
    let snoozed: Bool

    func makeNSView(context: Context) -> SessionSnoozeTagView { SessionSnoozeTagView() }

    func updateNSView(_ view: SessionSnoozeTagView, context: Context) {
        view.update(snoozed: snoozed, reduceMotion: context.environment.accessibilityReduceMotion,
                    paper: Theme.snoozePaper.resolve(in: context.environment).cgColor,
                    ink: Theme.snoozeText.resolve(in: context.environment).cgColor,
                    edge: Theme.snoozeEdge.resolve(in: context.environment).cgColor,
                    hole: Theme.card.resolve(in: context.environment).cgColor)
    }
}

// Only the drawing turns. Transforming the hosting view would also transform the
// AppKit-backed tooltip on the card, which cannot be laid out under a rotation.
final class SessionSnoozeTagView: NSView {
    private let drawing = CALayer()
    private let paper = CAShapeLayer()
    private let cord = CAShapeLayer()
    private let pin = CAShapeLayer()
    private let hole = CAShapeLayer()
    private let word = CATextLayer()
    private let moon = CAShapeLayer()
    private let seam = CAShapeLayer()
    private var snoozed: Bool?
    private static let restingAngle = 7.0 * .pi / 180

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(false)
        layer?.addSublayer(drawing)
        drawing.bounds = CGRect(x: 0, y: 0, width: 39, height: 66)
        drawing.anchorPoint = CGPoint(x: 0.5, y: 3.0 / 66)
        drawing.position = CGPoint(x: 19.5, y: 3)
        for part in [cord, paper, pin, hole, word, moon, seam] {
            drawing.addSublayer(part)
            part.contentsScale = 2
        }
        paper.path = CGPath(roundedRect: CGRect(x: 4, y: 14, width: 31, height: 49),
                            cornerWidth: 7, cornerHeight: 7, transform: nil)
        paper.lineWidth = 0.6
        paper.shadowOffset = CGSize(width: 1, height: 2)
        paper.shadowRadius = 0
        paper.shadowOpacity = 0.15
        let string = CGMutablePath()
        string.move(to: CGPoint(x: 19.5, y: 3))
        string.addLine(to: CGPoint(x: 19.5, y: 23))
        cord.path = string
        cord.lineWidth = 1
        pin.path = CGPath(ellipseIn: CGRect(x: 17.5, y: 1, width: 4, height: 4), transform: nil)
        pin.lineWidth = 2
        hole.path = CGPath(ellipseIn: CGRect(x: 17, y: 19, width: 5, height: 5), transform: nil)
        hole.lineWidth = 0.8
        word.string = "shh."
        word.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        word.fontSize = 13
        word.alignmentMode = .center
        word.frame = CGRect(x: 4, y: 28, width: 31, height: 17)
        let crescent = CGMutablePath()
        crescent.move(to: CGPoint(x: 21, y: 46))
        crescent.addCurve(to: CGPoint(x: 24, y: 54), control1: CGPoint(x: 18, y: 51),
                          control2: CGPoint(x: 21, y: 54))
        crescent.addCurve(to: CGPoint(x: 21, y: 46), control1: CGPoint(x: 14, y: 58),
                          control2: CGPoint(x: 13, y: 47))
        crescent.closeSubpath()
        moon.path = crescent
        moon.fillColor = nil
        moon.lineWidth = 1
        let stitch = CGMutablePath()
        stitch.move(to: CGPoint(x: 12, y: 59))
        stitch.addLine(to: CGPoint(x: 28, y: 59))
        seam.path = stitch
        seam.lineDashPattern = [2, 2]
        seam.lineWidth = 0.6
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        drawing.sublayers?.forEach { $0.contentsScale = window?.backingScaleFactor ?? 2 }
    }

    func update(snoozed: Bool, reduceMotion: Bool, paper: CGColor, ink: CGColor,
                edge: CGColor, hole: CGColor) {
        let changed = self.snoozed != nil && self.snoozed != snoozed
        self.snoozed = snoozed
        LayerLoop.still {
            self.paper.fillColor = paper
            self.paper.strokeColor = edge
            self.paper.shadowColor = ink
            cord.strokeColor = edge
            pin.fillColor = ink
            pin.strokeColor = hole
            self.hole.fillColor = hole
            self.hole.strokeColor = edge
            word.foregroundColor = ink
            moon.strokeColor = ink
            seam.strokeColor = edge
            drawing.opacity = snoozed ? 1 : 0
            drawing.setAffineTransform(CGAffineTransform(rotationAngle: Self.restingAngle))
        }
        if reduceMotion { drawing.removeAllAnimations() }
        guard changed, window?.occlusionState.contains(.visible) == true else { return }
        drawing.removeAllAnimations()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = snoozed ? 0 : 1
        fade.toValue = snoozed ? 1 : 0
        fade.duration = snoozed ? Motion.revealDuration : Motion.leaveDuration
        fade.timingFunction = CAMediaTimingFunction(name: snoozed ? .easeOut : .easeIn)
        drawing.add(fade, forKey: "fade")
        guard !reduceMotion else { return }
        if snoozed {
            let swing = CASpringAnimation(keyPath: "transform.rotation.z")
            let frequency = 2 * Double.pi / Motion.popDuration
            swing.mass = 1
            swing.stiffness = frequency * frequency
            swing.damping = 2 * Motion.popDamping * frequency
            swing.fromValue = -13.0 * .pi / 180
            swing.toValue = Self.restingAngle
            swing.duration = Motion.popDuration + Motion.controlDuration
            drawing.add(swing, forKey: "swing")
        } else {
            let lift = CABasicAnimation(keyPath: "transform.translation.y")
            lift.fromValue = 0
            lift.toValue = -8
            lift.duration = Motion.leaveDuration
            lift.timingFunction = CAMediaTimingFunction(name: .easeIn)
            drawing.add(lift, forKey: "lift")
        }
    }
}

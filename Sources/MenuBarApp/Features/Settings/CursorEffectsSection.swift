import AppKit
import SwiftUI

struct CursorEffectsSection: View {
    @Environment(AppSettings.self) private var settings
    @State private var keys = WindowKeyHandler()

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cursor effects")
                        .font(.system(size: 13, weight: .semibold))
                    Text("A little extra life around the pointer while a session is running.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 8)], spacing: 8) {
                    ForEach(CursorEffect.allCases) { effect in
                        CursorEffectChoice(effect: effect, selected: settings.cursorEffects.effect == effect) {
                            settings.cursorEffects.effect = effect
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(WindowKeyAnchor(handler: keys))
        .onAppear {
            keys.start { event in
                guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      let key = event.characters, let index = Int(key),
                      (0...3).contains(index) else { return false }
                settings.cursorEffects.effect = CursorEffect.allCases[index]
                return true
            }
        }
        .onDisappear { keys.stop() }
        .onChange(of: settings.cursorEffects.effect) { _, effect in
            announce("\(effect.title) selected. Changes saved.")
        }
    }

    private func announce(_ text: String) {
        guard let window = keys.anchor?.window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

private struct CursorEffectChoice: View {
    let effect: CursorEffect
    let selected: Bool
    let choose: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 8) {
                CursorEffectThumbnail(effect: effect).frame(width: 45, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 3) {
                        Text(effect == .none ? "Default" : " ")
                            .font(.system(size: 8)).foregroundStyle(Theme.accent)
                        Spacer(minLength: 0)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11)).foregroundStyle(selected ? Theme.accent : Color.secondary)
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    }
                    Text(effect.title).font(.system(size: 12, weight: .semibold))
                    Text(effect.subtitle).font(.system(size: 9)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(9).frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
            .surface(selected ? Theme.accent.opacity(0.08) : Theme.field, cornerRadius: 9,
                     border: selected || focused ? Theme.accent : Theme.settingsBorder)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(focused ? Theme.accent : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverLift().focused($focused)
        .motion(Motion.control, value: selected)
        .accessibilityLabel("Cursor effect: \(effect.title)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct CursorEffectThumbnail: View {
    let effect: CursorEffect

    var body: some View {
        ZStack {
            (effect == .none ? Theme.card : Color(nsColor: Theme.canvasDarkNSColor))
            Canvas { context, size in
                let center = CGPoint(x: size.width * 0.56, y: size.height * 0.48)
                switch effect {
                case .none: break
                case .ember:
                    for index in 0..<32 {
                        let t = Double(index) / 32
                        let x = 5 + t * (size.width - 10)
                        let y = size.height * 0.55 - sin(t * .pi) * 17 + sin(Double(index) * 7) * 9
                        var spark = Path()
                        spark.move(to: CGPoint(x: x, y: y))
                        spark.addLine(to: CGPoint(x: x - 2, y: y + 3))
                        context.stroke(spark, with: .color(.orange.opacity(0.3 + t * 0.7)), lineWidth: 1)
                    }
                case .aurora:
                    var ribbon = Path()
                    ribbon.move(to: CGPoint(x: 3, y: size.height * 0.65))
                    ribbon.addCurve(to: CGPoint(x: size.width - 6, y: size.height * 0.4),
                                    control1: CGPoint(x: size.width * 0.45, y: size.height * 0.7),
                                    control2: CGPoint(x: size.width * 0.65, y: size.height * 0.1))
                    for width in [9.0, 4, 1.5] {
                        context.stroke(ribbon, with: .linearGradient(Gradient(colors: [.teal.opacity(0.2), .purple]),
                            startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)), lineWidth: width)
                    }
                case .orbit:
                    for index in 0..<2 {
                        let ellipse = Path(ellipseIn: CGRect(x: -20, y: -12, width: 40, height: 24))
                            .applying(CGAffineTransform(rotationAngle: index == 0 ? -0.6 : 1.1)
                                .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
                        context.stroke(ellipse, with: .color(.cyan.opacity(0.45)), lineWidth: 0.7)
                    }
                    for offset in [-1.0, 1] {
                        context.fill(Path(ellipseIn: CGRect(x: center.x + offset * 16 - 1.5,
                            y: center.y + offset * 8 - 1.5, width: 3, height: 3)), with: .color(.cyan))
                    }
                }
            }
            Image(systemName: "cursorarrow").font(.system(size: 14))
                .foregroundStyle(effect == .none ? Color.primary : .white)
                .offset(x: effect == .none ? 0 : 7, y: -1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

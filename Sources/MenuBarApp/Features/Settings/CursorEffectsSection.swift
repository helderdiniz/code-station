import AppKit
import SwiftUI

struct CursorEffectsSection: View {
    @Environment(AppSettings.self) private var settings
    @State private var keys = WindowKeyHandler()
    @State private var preview = CursorEffectsPreviewController()
    @State private var beforeReset: CursorEffectsSettings?
    @State private var availableWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var systemReduced

    private var reduced: Bool { systemReduced || settings.cursorEffects.reduceMotion }

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cursor effects")
                        .font(.system(size: 13, weight: .semibold))
                    Text("A little extra life around the pointer while a session is running.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                workbenchLayout {
                    gallery.frame(width: availableWidth >= 620 ? 260 : nil)
                    livePreview
                }
                SettingsRowDivider()
                controlsLayout {
                    intensity.frame(maxWidth: .infinity)
                    motionPreference.frame(maxWidth: .infinity)
                }
                Text("Effects settle when a session finishes. Your macOS Reduce Motion preference is always respected.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack { shortcuts; Spacer(); resetActions }
                    VStack(alignment: .leading, spacing: 10) { shortcuts; resetActions }
                }
            }
            .padding(14)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .transaction { if reduced { $0.animation = nil; $0.disablesAnimations = true } }
        .background(WindowKeyAnchor(handler: keys))
        .onAppear {
            keys.start { event in
                guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
                if event.keyCode == 53 && preview.playing {
                    preview.stop()
                    return true
                }
                guard let key = event.characters, let effect = CursorEffect.shortcut(key) else { return false }
                choose(effect)
                return true
            }
        }
        .onDisappear { keys.stop(); preview.stop() }
        .onChange(of: settings.cursorEffects.effect) { _, effect in
            announce("\(effect.title) selected. Changes saved.")
        }
        .onChange(of: reduced) { _, _ in preview.stop() }
    }

    private var workbenchLayout: AnyLayout {
        availableWidth >= 620 ? AnyLayout(HStackLayout(alignment: .top, spacing: 18))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
    }

    private var controlsLayout: AnyLayout {
        availableWidth >= 540 ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
    }

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                choice(.ripple, featured: true)
                choice(.prism, featured: true)
            }
            Text("The rest of your collection").font(.system(size: 10.5)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach([CursorEffect.none, .ember, .aurora, .orbit]) { choice($0) }
            }
            Label("Only in Code Station. Your pointer stays familiar everywhere else.", systemImage: "checkmark")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var livePreview: some View {
        CursorEffectsPreview(settings: settings.cursorEffects, reduced: reduced, controller: preview)
    }

    private func choice(_ effect: CursorEffect, featured: Bool = false) -> some View {
        CursorEffectChoice(effect: effect, selected: settings.cursorEffects.effect == effect,
                           featured: featured, localReduced: reduced) {
            choose(effect)
        }
    }

    private func choose(_ effect: CursorEffect) {
        settings.cursorEffects.effect = effect
        preview.play(settings: settings.cursorEffects, reduced: reduced)
    }

    private var intensity: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Intensity").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(settings.cursorEffects.intensityLabel)
                    .font(.system(size: 10.5)).foregroundStyle(Theme.accent)
                    .contentTransition(.opacity)
            }
            CursorEffectIntensity(value: Binding(get: { settings.cursorEffects.intensity },
                                                set: { settings.cursorEffects.intensity = $0 }),
                                  label: settings.cursorEffects.intensityLabel) {
                preview.play(settings: settings.cursorEffects, reduced: reduced)
            }
                .disabled(settings.cursorEffects.effect == .none || reduced)
            HStack {
                Text("Subtle")
                Spacer()
                Text("All out")
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private var motionPreference: some View {
        SettingsToggleRow("Reduce motion",
                          detail: systemReduced ? "Enabled by macOS. Your system preference takes priority."
                            : "Keep a still halo around your pointer, without the trail or click animation.",
                          isOn: Binding(get: { reduced }, set: { settings.cursorEffects.reduceMotion = $0 }))
            .disabled(systemReduced)
    }

    private var shortcuts: some View {
        Text("0 to 5 to switch effects").font(.system(size: 10)).foregroundStyle(.secondary)
    }

    private var resetActions: some View {
        HStack(spacing: 14) {
            InlineLink(title: "Reset cursor effects") {
                beforeReset = settings.cursorEffects
                settings.cursorEffects = CursorEffectsSettings()
                preview.stop()
                announce("Cursor effects reset to None. Changes saved.")
            }
            if let previous = beforeReset {
                InlineLink(title: "Undo reset") {
                    settings.cursorEffects = previous
                    beforeReset = nil
                    preview.stop()
                    announce("Your cursor effect has been restored. Changes saved.")
                }
                .transition(.fadeIn)
            }
        }
        .motion(Motion.reveal, value: beforeReset != nil)
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
    var featured = false
    var localReduced = false
    let choose: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 8) {
                if featured {
                    CursorEffectThumbnail(effect: effect).frame(height: 110).accessibilityHidden(true)
                    copy
                } else {
                    HStack(spacing: 7) {
                        CursorEffectThumbnail(effect: effect).frame(width: 30, height: 42).accessibilityHidden(true)
                        copy
                    }
                }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .surface(selected ? Theme.accent.opacity(0.08) : Theme.field, cornerRadius: 9,
                     border: selected || focused ? Theme.accent : Theme.settingsBorder)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(focused ? Theme.accent : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverLift(amount: localReduced ? 1 : Motion.lift).focused($focused)
        .motion(Motion.control, value: selected)
        .accessibilityLabel("Cursor effect: \(effect.title)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint(effect.detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Text(effect.title).font(.system(size: featured ? 13 : 11, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10)).foregroundStyle(selected ? Theme.accent : Color.secondary)
                    .contentTransition(reduceMotion || localReduced ? .identity : .symbolEffect(.replace))
            }
            Text(effect.subtitle).font(.system(size: 9)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CursorEffectThumbnail: View {
    let effect: CursorEffect
    var reduced = false
    var light = false
    var preview = false

    var body: some View {
        ZStack {
            (light ? Color(nsColor: Theme.canvasLightNSColor) : Color(nsColor: Theme.canvasDarkNSColor))
            Canvas { context, size in
                let center = CGPoint(x: size.width * (preview ? 0.65 : 0.56), y: size.height * (preview ? 0.6 : 0.48))
                if reduced && effect != .none {
                    context.stroke(Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 5, width: 30, height: 30)),
                                   with: .color(Theme.accent), lineWidth: 1.2)
                    context.fill(Path(ellipseIn: CGRect(x: center.x + 17, y: center.y + 19, width: 4.6, height: 4.6)),
                                 with: .color(Theme.accent))
                    return
                }
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
                case .ripple:
                    let scale = min(size.width, size.height) / (preview ? 2.6 : 2.1)
                    for index in 0..<6 {
                        let radius = scale * (0.18 + Double(index) * 0.19)
                        let rect = CGRect(x: center.x - radius - Double(index) * 2,
                                          y: center.y - radius * 0.86 + Double(index),
                                          width: radius * 2, height: radius * 1.72)
                        context.stroke(Path(ellipseIn: rect),
                                       with: .color((light ? Color.teal : Color(red: 0.65, green: 0.85, blue: 0.8))
                                        .opacity(0.65 - Double(index) * 0.095)), lineWidth: 0.8)
                    }
                case .prism:
                    let scale = min(size.width, size.height) / (preview ? 180 : 145)
                    for index in 0..<7 {
                        let t = Double(index) / 6
                        let x = center.x + (-62 + t * 95) * scale
                        let y = center.y + (27 - t * 48) * scale
                        let radius = (10 + t * 18) * scale
                        let vertices = [CGPoint(x: x + radius, y: y - radius),
                                        CGPoint(x: x - radius, y: y + radius * 0.7),
                                        CGPoint(x: x + radius * 0.5, y: y + radius)]
                        var face = Path()
                        face.addLines(vertices)
                        face.closeSubpath()
                        let colour = Color(hue: 0.49 + t * 0.4, saturation: light ? 0.65 : 0.4,
                                           brightness: light ? 0.65 : 0.95)
                        context.fill(face, with: .color(colour.opacity(0.1 + t * 0.17)))
                        context.stroke(face, with: .color(colour.opacity(0.25 + t * 0.4)), lineWidth: 0.8)
                    }
                }
            }
            GeometryReader { geometry in
                Image(systemName: "cursorarrow").font(.system(size: preview ? 19 : 14))
                    .foregroundStyle(light ? Color.black : .white)
                    .position(x: geometry.size.width * (preview ? 0.65 : 0.56),
                              y: geometry.size.height * (preview ? 0.6 : 0.48))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct CursorEffectIntensity: View {
    @Binding var value: Double
    let label: String
    let onCommit: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    private var fraction: Double { (value - 0.1) / 0.9 }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border).frame(height: 4)
                Capsule().fill(Theme.accent).frame(width: max(0, geometry.size.width * fraction), height: 4)
                Circle().fill(Theme.card).overlay(Circle().stroke(Theme.accent, lineWidth: 3))
                    .frame(width: 14, height: 14)
                    .offset(x: max(0, geometry.size.width - 14) * fraction)
            }
            .frame(height: 24).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard enabled else { return }
                value = 0.1 + min(1, max(0, drag.location.x / max(1, geometry.size.width))) * 0.9
            }.onEnded { _ in if enabled { onCommit() } })
        }
        .frame(height: 24)
        .opacity(enabled ? 1 : 0.4)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(focused ? Theme.accent : .clear, lineWidth: 2))
        .focusable(enabled).focusEffectDisabled().focused($focused)
        .hoverFill(cornerRadius: 5)
        .onMoveCommand { direction in
            if direction == .right || direction == .up { adjust(0.05) }
            if direction == .left || direction == .down { adjust(-0.05) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cursor effect intensity")
        .accessibilityValue("\(label), \(Int(value * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(0.05)
            case .decrement: adjust(-0.05)
            @unknown default: break
            }
        }
    }

    private func adjust(_ amount: Double) {
        guard enabled else { return }
        value = min(1, max(0.1, value + amount))
        onCommit()
    }
}

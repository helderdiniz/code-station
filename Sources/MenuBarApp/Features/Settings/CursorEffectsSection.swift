import AppKit
import SwiftUI

struct CursorEffectsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var activity = CursorEffectActivity.running
    @State private var demo = false
    @State private var flourish = 0
    @State private var keys = WindowKeyHandler()
    @FocusState private var previewFocused: Bool

    private var off: Bool { settings.cursorEffects.effect == .none }
    private var reduced: Bool { systemReduceMotion || settings.cursorEffects.reduceMotion }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Cursor effects").font(.system(size: 20, weight: .semibold))
                    Text("A little extra life while a session is running. Choose what feels like you.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Label("Off by default", systemImage: "cursorarrow")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .surface(Theme.card, cornerRadius: 14, border: Theme.settingsBorder)
            }
            SettingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 8)], spacing: 8) {
                        ForEach(CursorEffect.allCases) { effect in
                            CursorEffectChoice(effect: effect, selected: settings.cursorEffects.effect == effect) {
                                settings.cursorEffects.effect = effect
                            }
                        }
                    }
                    Rectangle().fill(Theme.settingsHairline).frame(height: 1)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            preview.frame(minWidth: 355)
                            inspector.frame(width: 190)
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            preview
                            inspector
                        }
                    }
                    Rectangle().fill(Theme.settingsHairline).frame(height: 1)
                    Label("Effects appear in the active session window. Waiting and finished sessions stay quiet.",
                          systemImage: "checkmark.shield")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
            }
        }
        .background(WindowKeyAnchor(handler: keys))
        .onAppear {
            demo = !off
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
            demo = effect != .none
            announce("\(effect.title) selected. Changes saved.")
        }
    }

    private var preview: some View {
        VStack(spacing: 9) {
            HStack(spacing: 6) {
                Label("Live preview", systemImage: "cursorarrow")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    ForEach([CursorEffectActivity.running, .waiting, .finished], id: \.self) { state in
                        ChoicePill(title: state.title, selected: activity == state) {
                            activity = state
                            announce("Preview \(state.title.lowercased())")
                        }
                        .accessibilityLabel("Preview state: \(state.title)")
                    }
                }
            }
            CursorWorkspaceSample(activity: activity, textScale: settings.textSize.scale)
                .frame(height: 273)
                .overlay {
                    if off {
                        Image(systemName: "cursorarrow")
                            .font(.system(size: 22)).offset(x: 36, y: 26)
                            .accessibilityHidden(true).allowsHitTesting(false)
                    } else {
                        CursorEffectOverlay(settings: settings.cursorEffects, activity: activity,
                                            preview: true, demo: demo, flourish: flourish,
                                            onPointerEntry: { demo = false })
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .stroke(previewFocused ? Theme.accent : Theme.settingsBorder, lineWidth: previewFocused ? 2 : 1))
                .contentShape(Rectangle())
                .onTapGesture { previewFocused = true }
                .focusable().focusEffectDisabled().focused($previewFocused)
                .onKeyPress(.return) { flourish += 1; return .handled }
                .onKeyPress(.space) { flourish += 1; return .handled }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Cursor effect preview: \(settings.cursorEffects.effect.title), \(activity.title)")
                .accessibilityHint("Move your pointer here to try the effect. Press Return or Space for a flourish.")
                .accessibilityAction(named: "Play flourish") { flourish += 1 }
            HStack(spacing: 5) {
                Text(off ? "Your familiar cursor. Nothing added." : "Move here to try it. Click for a flourish.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { demo.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: demo && !off ? "pause" : "play")
                            .contentTransition(systemReduceMotion ? .identity : .symbolEffect(.replace))
                        Text(demo && !off ? "Pause demo" : "Play demo")
                            .contentTransition(.interpolate)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.vertical, 5).contentShape(Rectangle())
                }
                .buttonStyle(.plain).hoverLift()
                .disabled(off || reduced || activity != .running)
                .opacity(off || reduced || activity != .running ? 0.4 : 1)
                .motion(Motion.control, value: demo)
            }
        }
    }

    private var inspector: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(settings.cursorEffects.effect.title).font(.logo(23))
                        .contentTransition(.interpolate)
                    if off {
                        Text("Default").font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.accent).padding(5)
                            .background(Theme.field, in: RoundedRectangle(cornerRadius: 5))
                            .transition(.opacity)
                    }
                }
                Text(settings.cursorEffects.effect.detail)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.interpolate)
            }
            .motion(Motion.reveal, value: settings.cursorEffects.effect)
            Rectangle().fill(Theme.settingsHairline).frame(height: 1)
            CursorIntensityControl(value: $settings.cursorEffects.intensity,
                                   label: settings.cursorEffects.intensityLabel)
                .disabled(off || reduced || activity != .running)
                .opacity(off || reduced || activity != .running ? 0.4 : 1)
            Text(stateHint).font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.interpolate).motion(Motion.control, value: activity)
            Toggle("Reduce motion", isOn: Binding(get: { reduced }, set: { settings.cursorEffects.reduceMotion = $0 }))
                .font(.system(size: 11)).toggleStyle(.appSwitch)
                .disabled(off || systemReduceMotion)
            Text(systemReduceMotion ? "Following your macOS Reduce Motion setting."
                 : reduced ? "A still halo replaces trails and bursts." : "Always respects your macOS setting.")
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 34)
    }

    private var stateHint: String {
        if off { return "Choose an effect to adjust its intensity." }
        if reduced { return "A still halo marks an active session." }
        switch activity {
        case .waiting: return "The trail settles. A still halo marks the pause."
        case .finished, .inactive: return "One soft closing ring. Then your familiar cursor."
        case .running: return "Move your pointer to explore the effect."
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

private struct CursorIntensityControl: View {
    @Binding var value: Double
    let label: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Intensity").fontWeight(.medium)
                Spacer()
                Text(label).foregroundStyle(.secondary).contentTransition(.interpolate)
            }
            .font(.system(size: 10))
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 14)
                let fraction = (value - 0.1) / 0.9
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.field).frame(height: 4)
                    Capsule().fill(Theme.accent.opacity(0.6)).frame(width: 7 + width * fraction, height: 4)
                    Circle().fill(Theme.card).overlay(Circle().stroke(Theme.accent, lineWidth: 3))
                        .frame(width: 14, height: 14).offset(x: width * fraction)
                }
                .frame(height: 26).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    value = 0.1 + min(1, max(0, (drag.location.x - 7) / width)) * 0.9
                })
            }
            .frame(height: 26)
            HStack {
                Text("Just a hint")
                Spacer()
                Text("Go all out")
            }
            .font(.system(size: 8)).foregroundStyle(.secondary)
        }
        .padding(3)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(focused ? Theme.accent : .clear, lineWidth: 2))
        .focusable().focusEffectDisabled().focused($focused)
        .hoverLift()
        .onMoveCommand { direction in
            if direction == .right || direction == .up { adjust(0.05) }
            if direction == .left || direction == .down { adjust(-0.05) }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Cursor effect intensity")
        .accessibilityValue("\(label), \(Int(value * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(0.05)
            case .decrement: adjust(-0.05)
            @unknown default: break
            }
        }
    }

    private func adjust(_ change: Double) { value = min(1, max(0.1, value + change)) }
}

private struct CursorWorkspaceSample: View {
    let activity: CursorEffectActivity
    let textScale: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach([Theme.deletion, Theme.attention, Theme.dotOn], id: \.self) { colour in
                    Circle().fill(colour.opacity(0.65)).frame(width: 5, height: 5)
                }
                Spacer()
                Text("Code Station")
                Spacer()
                Text("Preview").foregroundStyle(.tertiary)
            }
            .font(.system(size: 9)).padding(.horizontal, 10).frame(height: 26).background(Theme.sidebar)
            HStack(spacing: 7) {
                Text("cs").font(.mono(9)).foregroundStyle(Theme.accent)
                    .padding(5).background(Theme.field, in: RoundedRectangle(cornerRadius: 5))
                Text("code-station").fontWeight(.semibold)
                Spacer(minLength: 0)
                Text(activity.title)
                    .foregroundStyle(activity == .waiting ? Theme.attentionText : Theme.dotOnText)
                    .contentTransition(.interpolate)
            }
            .font(.system(size: 9)).padding(.horizontal, 10).frame(height: 34).background(Theme.card)
            HStack(spacing: 16) {
                Text("Conversation").foregroundStyle(.secondary)
                Text("Changes 3").foregroundStyle(Theme.accent)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.accent).frame(height: 2).offset(y: 7) }
                Text("Explorer").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .font(.system(size: 9)).padding(.horizontal, 10).frame(height: 28)
            HStack {
                Label("Sessions / TurnMotion.swift", systemImage: "doc.text")
                Spacer()
                Text("+24").foregroundStyle(Theme.addition)
                Text("-6").foregroundStyle(Theme.deletion)
            }
            .font(.system(size: 8)).padding(.horizontal, 10).frame(height: 26)
            VStack(alignment: .leading, spacing: 0) {
                code("14     enum TurnMotion {", added: false)
                code("15         static let orbitPeriod = 1.4", added: false)
                code("16", added: false)
                code("17  +      static let flight = Motion.reveal", added: true)
                code("18  +      static let settle = Motion.leave", added: true)
                code("19     }", added: false)
            }
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Circle().fill(activity == .waiting ? Theme.attention : Theme.dotOn).frame(width: 5, height: 5)
                Text(activity == .running ? "Refining the finishing touches…"
                     : activity == .waiting ? "Waiting for your approval…" : "Session finished. Ready for your review.")
                Spacer(minLength: 0)
            }
            .font(.system(size: 8)).foregroundStyle(.secondary).padding(.horizontal, 8)
            .frame(height: 26).background(Theme.card)
        }
        .background(Theme.background)
        .accessibilityHidden(true)
        .motion(Motion.control, value: activity)
    }

    private func code(_ text: String, added: Bool) -> some View {
        Text(text).font(.mono(8 * textScale))
            .foregroundStyle(added ? Theme.addition : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 2)
            .background(added ? Theme.addition.opacity(0.07) : .clear)
            .lineLimit(1)
    }
}

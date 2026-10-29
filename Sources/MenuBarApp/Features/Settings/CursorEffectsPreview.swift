import AppKit
import SwiftUI

@MainActor @Observable
final class CursorEffectsPreviewController {
    weak var view: CursorEffectsPreviewView?
    var playing = false

    func play(settings: CursorEffectsSettings, reduced: Bool) {
        view?.configure(settings: settings, reduced: reduced)
        view?.play()
    }

    func stop() {
        playing = false
        view?.reset()
    }
}

struct CursorEffectsPreview: View {
    let settings: CursorEffectsSettings
    let reduced: Bool
    let controller: CursorEffectsPreviewController
    @State private var dark = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                CursorEffectsPreviewSurface(settings: settings, reduced: reduced, controller: controller)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label(settings.effect == .none ? "No effect selected" :
                              reduced ? "Reduced motion preview" : "Running session preview",
                              systemImage: "circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        ForEach([false, true], id: \.self) { choice in
                            Button { dark = choice } label: {
                                Image(systemName: choice ? "moon" : "sun.max")
                                    .font(.system(size: 11))
                                    .actOut(choice ? "moon" : "sun.max", trigger: !reduced && dark == choice ? 1 : 0)
                                    .frame(width: 26, height: 26)
                                    .background(Circle().fill(dark == choice ? Theme.border : Theme.field))
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain).hoverLift(amount: reduced ? 1 : Motion.lift)
                            .accessibilityLabel(choice ? "Dark preview background" : "Light preview background")
                            .accessibilityValue(dark == choice ? "Selected" : "Not selected")
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(settings.effect == .none ? "Just your pointer." : settings.effect.title)
                            .font(.logo(26))
                        Text(settings.effect == .none ? "No extra motion while your session runs." :
                             reduced ? "A still halo. No trails or bursts." : settings.effect.subtitle)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .contentTransition(.opacity)
                    .allowsHitTesting(false)
                    Spacer()
                    HStack {
                        Text(reduced ? "A still halo follows your pointer." : "Move to explore. Click to try it.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                        Spacer(minLength: 8)
                        Button(action: togglePlayback) {
                            Label(controller.playing ? "Stop" : "Play preview",
                                  systemImage: controller.playing ? "stop" : "play")
                                .font(.system(size: 10.5, weight: .medium))
                                .contentTransition(.opacity)
                                .padding(.horizontal, 11).padding(.vertical, 8)
                                .surface(Theme.field, cornerRadius: 18, border: Theme.border)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain).hoverLift(amount: reduced ? 1 : Motion.lift)
                        .disabled(settings.effect == .none || reduced)
                    }
                }
                .padding(18)
            }
            .frame(minWidth: 0, maxWidth: .infinity).frame(height: 300)
            .background(Theme.background)
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(focused ? Theme.accent : Theme.border,
                                                             lineWidth: focused ? 2 : 1))
            .environment(\.colorScheme, dark ? .dark : .light)
            .focusable().focusEffectDisabled().focused($focused)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            .onKeyPress(.space) { togglePlayback(); return .handled }
            .onKeyPress(.return) { togglePlayback(); return .handled }
            .onKeyPress(.escape) { controller.stop(); return .handled }
            .accessibilityLabel("Interactive cursor effect preview")
            .accessibilityHint("Move or click to try the effect. Press Space or Return to play a sample. Escape stops it.")
            .motion(Motion.control, value: dark)
            .onChange(of: dark) { _, _ in controller.stop() }
            Text("\(settings.effect.title) selected")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accent)
                .contentTransition(.opacity)
            HStack(alignment: .top, spacing: 14) { descriptions }
        }
    }

    @ViewBuilder private var descriptions: some View {
        detail("On movement", icon: "point.topleft.down.to.point.bottomright.curvepath",
               text: reduced && settings.effect != .none ? "A still halo follows your pointer. No trails are emitted." : settings.effect.detail)
        detail("On click", icon: "cursorarrow.click",
               text: reduced ? "No burst or expanding animation." : settings.effect.clickDetail)
        detail("At rest", icon: "water.waves",
               text: reduced && settings.effect != .none ? "The halo stays still while the session is running." : settings.effect.restDetail)
    }

    private func detail(_ title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.system(size: 10.5, weight: .semibold))
            Text(text).font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
    }

    private func togglePlayback() {
        if controller.playing { controller.stop() }
        else { controller.play(settings: settings, reduced: reduced) }
    }
}

private struct CursorEffectsPreviewSurface: NSViewRepresentable {
    let settings: CursorEffectsSettings
    let reduced: Bool
    let controller: CursorEffectsPreviewController
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> CursorEffectsPreviewView {
        let view = CursorEffectsPreviewView()
        view.controller = controller
        controller.view = view
        return view
    }

    func updateNSView(_ view: CursorEffectsPreviewView, context: Context) {
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        view.configure(settings: settings, reduced: reduced)
    }

    static func dismantleNSView(_ view: CursorEffectsPreviewView, coordinator: ()) { view.stop() }
}

final class CursorEffectsPreviewView: NSView {
    weak var controller: CursorEffectsPreviewController?
    private let effects = CursorEffectLayerView()
    private let poster = NSHostingView(rootView: CursorEffectThumbnail(effect: .none))
    private var settings = CursorEffectsSettings()
    private var reduced = false
    private var environmentReduced = false
    private var monitor: Any?
    private var finish: DispatchWorkItem?
    private var sampleEnd: DispatchWorkItem?
    private var inside = false
    private var tracking: NSTrackingArea?
    private var lastSize = CGSize.zero

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        effects.tracksPointerEvents = false
        addSubview(poster)
        addSubview(effects)
        setAccessibilityElement(false)
    }

    convenience init() { self.init(frame: .zero) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        if lastSize != bounds.size {
            lastSize = bounds.size
            reset()
        }
        poster.frame = bounds
        effects.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking)
        self.tracking = tracking
    }

    override func mouseExited(with event: NSEvent) {
        guard inside else { return }
        inside = false
        effects.leavePointer()
        restorePoster(after: reduced ? 0 : 1.45)
    }

    func configure(settings: CursorEffectsSettings, reduced: Bool) {
        environmentReduced = reduced
        let reduced = reduced || settings.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if self.settings != settings || self.reduced != reduced {
            self.settings = settings
            self.reduced = reduced
            reset()
        }
        poster.rootView = CursorEffectThumbnail(effect: settings.effect, reduced: reduced,
                                               light: !Theme.isDark(effectiveAppearance), preview: true)
        effects.configure(settings: settings, activity: .running, reduceMotion: reduced)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { stop(); return }
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated { self?.receive(event) }
                return event
            }
            for name in [NSWindow.didResignKeyNotification, NSWindow.didChangeOcclusionStateNotification,
                         NSApplication.didResignActiveNotification, NSWindow.willCloseNotification,
                         NSWindow.willBeginSheetNotification, NSView.boundsDidChangeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: name, object: nil)
            }
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionChanged),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { stop() }
        super.viewWillMove(toWindow: newWindow)
    }

    private var visible: Bool {
        guard let window else { return false }
        return NSApp.isActive && WindowKeyMonitor.frontmostWindow === window && window.isVisible
            && window.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
    }

    @objc private func visibilityChanged() { if !visible { reset() } }
    @objc private func motionChanged() {
        reset()
        configure(settings: settings, reduced: environmentReduced)
    }

    func play() {
        guard visible, settings.effect != .none, !reduced else { return }
        reset()
        poster.isHidden = true
        effects.setForeground(true)
        effects.playPreviewSample()
        controller?.playing = true
        let end = DispatchWorkItem { [weak self] in self?.effects.leavePointer() }
        sampleEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6, execute: end)
        restorePoster(after: 5.05)
    }

    private func receive(_ event: NSEvent) {
        guard visible, event.window === window, settings.effect != .none else { return }
        let location = convert(event.locationInWindow, from: nil)
        // The preview's controls are outside the interactive illustration.
        let stage = bounds.insetBy(dx: 0, dy: 55)
        guard stage.contains(location), visibleRect.contains(location) else {
            if inside {
                inside = false
                effects.leavePointer()
                restorePoster(after: reduced ? 0 : 1.45)
            }
            return
        }
        if controller?.playing == true {
            controller?.playing = false
            reset()
        }
        finish?.cancel()
        inside = true
        poster.isHidden = true
        effects.setForeground(true)
        effects.movePointer(to: location)
        if event.type == .leftMouseDown || event.type == .rightMouseDown { effects.click() }
    }

    private func restorePoster(after delay: Double) {
        finish?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reset() }
        finish = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func reset() {
        finish?.cancel()
        sampleEnd?.cancel()
        finish = nil
        sampleEnd = nil
        inside = false
        effects.leavePointer()
        effects.setForeground(false)
        poster.isHidden = false
        if controller?.playing == true {
            DispatchQueue.main.async { [weak self] in
                guard let self, !poster.isHidden else { return }
                controller?.playing = false
            }
        }
    }

    func stop() {
        reset()
        effects.stop()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

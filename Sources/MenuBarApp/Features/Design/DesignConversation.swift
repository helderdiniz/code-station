import AppKit
import SwiftUI

enum DesignConversationLayout {
    static let minimizedSize = CGSize(width: 210, height: 56)
    static let minimizedMaxWidth: CGFloat = 320
    // The expand button sits in the top-right corner, this far in from both edges.
    static let cornerButtonSize: CGFloat = 28
    static let cornerButtonInset: CGFloat = 10

    static func inset(in workspace: CGSize) -> CGFloat {
        min(workspace.width < 720 ? 12 : 22, max(0, min(workspace.width, workspace.height) / 2))
    }

    // The folded panel follows the measured heights of the transcript and the composer, so a
    // short transcript does not leave a gap above it. A long transcript stops at the folded cap.
    // The small tab hugs its line of text, between its minimum and maximum widths.
    static func size(in workspace: CGSize, expanded: Bool, minimized: Bool = false,
                     composerHeight: CGFloat = 167, transcriptHeight: CGFloat = .infinity,
                     minimizedWidth: CGFloat = 0) -> CGSize {
        let margin = inset(in: workspace) * 2
        let available = CGSize(width: max(0, workspace.width - margin),
                               height: max(0, workspace.height - margin))
        if minimized {
            let width = min(max(minimizedSize.width, minimizedWidth), minimizedMaxWidth)
            return CGSize(width: min(width, available.width),
                          height: min(minimizedSize.height, available.height))
        }
        guard expanded else {
            let height = min(326, transcriptHeight + composerHeight)
            return CGSize(width: min(880, available.width), height: min(height, available.height))
        }
        return available
    }

    // The one line on the small tab. It names the state in words, so the state never rests
    // on the colour of the ring alone. A running turn shows the bot's current working word.
    static func minimizedLine(_ tone: SessionTone, word: String, waited: String?) -> String {
        switch tone {
        case .running: "\(word)…"
        case .waiting: waited.map { "Waiting… \($0)" } ?? "Waiting…"
        case .needsYou: "Needs you"
        case .idle: "Done. Hover to expand"
        }
    }

    // The corner button takes its own presses, so a press there must not also open the panel.
    static func isOnCornerButton(_ point: CGPoint, fromTop: CGFloat, width: CGFloat) -> Bool {
        let reach = cornerButtonInset * 2 + cornerButtonSize
        return fromTop < reach && point.x > width - reach
    }

    static func minimizedAccessibilityValue(_ tone: SessionTone) -> String {
        switch tone {
        case .running: "Minimized, working"
        case .waiting: "Minimized, waiting"
        case .needsYou: "Minimized, needs you"
        case .idle: "Minimized"
        }
    }
}

// Observe presses without taking them away from the canvas or composer: a press on the
// folded transcript opens it, and a press outside the panel shrinks it to a small tab.
struct DesignConversationDismissal: NSViewRepresentable {
    let expanded: Bool
    let minimized: Bool
    let footerHeight: CGFloat
    let enabled: Bool
    let collapse: (Bool) -> Void
    let expand: () -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.expanded = expanded
        view.minimized = minimized
        view.footerHeight = footerHeight
        view.enabled = enabled
        view.collapse = collapse
        view.expand = expand
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.stop() }

    final class ObserverView: NSView {
        var expanded = false
        var minimized = false
        var footerHeight: CGFloat = 0
        var enabled = true
        var collapse: ((Bool) -> Void)?
        var expand: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return stop() }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.handle(event, frontmost: NSApp.keyWindow) == nil
                }
                return consumed ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            collapse = nil
            expand = nil
        }

        func handle(_ event: NSEvent, frontmost: NSWindow?) -> NSEvent? {
            guard enabled, !minimized, !isHiddenOrHasHiddenAncestor, let window,
                  event.window === window, window.attachedSheet == nil else { return event }
            let point = convert(event.locationInWindow, from: nil)
            guard expanded else {
                // The corner has its own expand button, and a press in the composer is someone
                // about to type, so only a press on the rest of the transcript opens the panel.
                let fromTop = isFlipped ? point.y : bounds.maxY - point.y
                let transcript = fromTop < bounds.height - footerHeight
                    && !DesignConversationLayout.isOnCornerButton(point, fromTop: fromTop, width: bounds.width)
                if event.type == .leftMouseDown, bounds.contains(point), transcript {
                    expand?()
                } else if event.type != .keyDown, !bounds.contains(point) {
                    collapse?(false)
                }
                return event
            }
            if event.type == .keyDown {
                guard event.keyCode == 53,
                      WindowKeyMonitor.routes(to: window, frontmost: frontmost)
                else { return event }
                collapse?(true)
                return nil
            }
            if !bounds.contains(point) {
                collapse?(false)
            }
            return event
        }
    }
}

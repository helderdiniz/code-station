import AppKit
import SwiftUI
import WebKit

// A running app the conversation links to: its page and how the last load went. The
// session's pane keeps it, so a link clicked in the conversation over the app takes the
// page to the new address.
@MainActor
@Observable
final class LocalServerPreview {
    enum Phase: Equatable {
        case opening, showing, unreachable, failed(String), noPage, stopped, left(URL)
    }

    private(set) var address: URL
    private(set) var reloadGeneration = 0
    var phase = Phase.opening

    // Held here rather than in the view, so the page survives a switch to another tab.
    @ObservationIgnored let coordinator = LocalServerPreviewWebContent.Coordinator()
    @ObservationIgnored private var madeWebView: WKWebView?

    init(opening address: URL) {
        self.address = address
        reload()
    }

    var webView: WKWebView {
        if let madeWebView { return madeWebView }
        coordinator.onAddress = { [weak self] in self?.follow($0) }
        coordinator.onPhase = { [weak self] in self?.phase = $0 }
        coordinator.onLoaded = { [weak self] in self?.finishLoading(hasPage: $0) }
        let webView = LocalServerPreviewWebContent.makeWebView(coordinator: coordinator)
        madeWebView = webView
        return webView
    }

    func open(_ url: URL) {
        address = url
        reload()
    }

    func reload() {
        if phase != .showing { phase = .opening }
        reloadGeneration += 1
    }

    // A failed load sends the web view back to the page it had, but the address stays on
    // the one that failed, so Reload tries it again.
    func follow(_ url: URL) {
        switch phase {
        case .unreachable, .failed, .noPage: return
        case .opening, .showing, .stopped, .left: break
        }
        if url != address { address = url }
    }

    // Nothing arrives when a load only moves within the page that is there, so a load
    // that ends while the preview is still opening has left that page showing. When there
    // is no page, the server answered with something only a browser can take, such as a
    // download.
    func finishLoading(hasPage: Bool) {
        guard phase == .opening else { return }
        phase = hasPage ? .showing : .noPage
    }

    // Stopped at once, since letting a web view go can take a moment and its timers and
    // its dev server's reload socket run until then.
    func close() {
        guard let madeWebView else { return }
        LocalServerPreviewWebContent.close(madeWebView, coordinator: coordinator)
    }

    static func label(for url: URL) -> String {
        let path = Self.path(url)
        return path == "/" ? server(url) : server(url) + path
    }

    // Read from the address as written, since a parsed host can lose the brackets around
    // an IPv6 address and its port would then read as part of it.
    static func server(_ url: URL) -> String {
        let authority = url.absoluteString
            .drop(while: { $0 != "/" }).dropFirst(2)
            .prefix(while: { !"/?#".contains($0) })
        return String(authority.split(separator: "@").last ?? authority)
    }

    // Any query is left out, since it can carry tokens.
    static func path(_ url: URL) -> String {
        let path = url.path.isEmpty ? "/" : url.path
        guard let fragment = url.fragment, fragment.hasPrefix("/") else { return path }
        return path + "#" + fragment.prefix(while: { $0 != "?" })
    }
}

struct LocalServerPreviewPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let preview: LocalServerPreview
    let session: ChatSession
    let placeholder: String
    let openPreview: (URL) -> Bool
    var openChange: (String) -> Void = { _ in }
    var runInShell: (String) -> Void = { _ in }
    var showInExplorer: (URL) -> Bool = { _ in false }
    @Binding var pageFocused: Bool
    let onClose: () -> Void

    @State private var conversationMinimized = true
    @State private var conversationExpanded = false
    @State private var composerFocused = false

    var body: some View {
        VStack(spacing: 0) {
            bar
            GeometryReader { geometry in
                // An overlay would rebuild the composer when a message replaces the page.
                ZStack(alignment: .bottom) {
                    page(in: geometry.size)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    DesignConversation(session: session, size: geometry.size,
                                       conversationExpanded: $conversationExpanded,
                                       conversationMinimized: $conversationMinimized,
                                       composerFocused: $composerFocused,
                                       designEmpty: false, selectionEnabled: false,
                                       placeholder: placeholder,
                                       attachMessage: "Choose references for this change.",
                                       showsDesignAmbition: false,
                                       openPreview: openPreview,
                                       openChange: openChange,
                                       runInShell: runInShell,
                                       showInExplorer: showInExplorer,
                                       pagesTranscript: true)
                        .padding(DesignConversationLayout.inset(in: geometry.size))
                }
            }
        }
        .background(Theme.background)
        // A stale flag would keep Escape from stopping the turn, so it is cleared here.
        .onDisappear { pageFocused = false }
    }

    private func page(in size: CGSize) -> some View {
        let showing = preview.phase == .showing
        let room = messageRoom(in: size)
        return ZStack {
            LocalServerPreviewWebContent(preview: preview, address: preview.address,
                                         reloadGeneration: preview.reloadGeneration,
                                         showing: showing,
                                         isFocused: $pageFocused)
                .background(Color.white)
                // The page stays built under a message, so it and its sign-in
                // survive a failed reload.
                .opacity(showing ? 1 : 0)
                .allowsHitTesting(showing)
                .accessibilityHidden(!showing)
            if !showing {
                message
                    .padding(.bottom, room)
                    .clipped()
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: room)
                    .background(Theme.sunken)
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("PREVIEW")
                .font(.mono(10, .semibold))
                .kerning(1)
                .lineLimit(1)
            StatusDot()
            Text(LocalServerPreview.label(for: preview.address))
                .font(.mono(10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .appTooltip(preview.address.absoluteString)
            Spacer(minLength: 10)
            barButton("arrow.up.right", help: "Open in browser") { openInBrowser(preview.address) }
            barButton("xmark", help: "Close preview", action: onClose)
            barButton("arrow.clockwise", help: "Reload page") { preview.reload() }
        }
        .canvasBar()
    }

    private func barButton(_ icon: String, help: String,
                           action: @escaping () -> Void) -> some View {
        GlyphButton(icon: icon, side: 28, tint: Theme.accent, action: action)
            .appTooltip(help)
            .accessibilityLabel(help)
    }

    @ViewBuilder private var message: some View {
        let address = preview.address
        let server = LocalServerPreview.server(address)
        switch preview.phase {
        case .showing:
            EmptyView()
        case .opening:
            PaneMessage(icon: "globe", title: "Opening \(server)",
                        detail: "It appears here as soon as the server answers.")
        case .unreachable:
            PaneMessage(icon: "bolt.horizontal", title: "Nothing is running at \(server)",
                        detail: "Start the server, then reload.") { reloadButton }
        case .failed(let reason):
            PaneMessage(icon: "exclamationmark.triangle", title: "The page could not load",
                        detail: reason) { reloadButton }
        case .noPage:
            PaneMessage(icon: "doc",
                        title: "There is no page at \(LocalServerPreview.label(for: address))",
                        detail: "It leads to a file or another app rather than to a page.") {
                browserButton(address)
            }
        case .stopped:
            PaneMessage(icon: "exclamationmark.triangle", title: "The preview stopped",
                        detail: "Reload to try again.") { reloadButton }
        case .left(let url):
            PaneMessage(icon: "arrow.up.right.square",
                        title: "The app went to \(url.host ?? url.absoluteString)",
                        detail: "The preview only shows pages served from this machine.") {
                browserButton(url)
            }
        }
    }

    private func messageRoom(in size: CGSize) -> CGFloat {
        guard !conversationExpanded else { return 0 }
        let conversation = DesignConversationLayout.size(in: size, expanded: false,
                                                         minimized: conversationMinimized)
        return conversation.height + DesignConversationLayout.inset(in: size)
    }

    private var reloadButton: some View {
        ActionButton(title: "Reload", tone: .outlined, icon: "arrow.clockwise") {
            preview.reload()
        }
        .padding(.top, 4)
    }

    private func browserButton(_ url: URL) -> some View {
        ActionButton(title: "Open in browser", tone: .outlined, icon: "arrow.up.right") {
            openInBrowser(url)
        }
        .padding(.top, 4)
    }

    // The browser takes the app over, so the pane goes back to the conversation rather than
    // keep a second copy of the page running.
    private func openInBrowser(_ url: URL) {
        preview.coordinator.openInBrowser(url)
        onClose()
    }
}

// The page belongs to the preview, so mounting moves it into whichever container is shown.
struct LocalServerPreviewWebContent: NSViewRepresentable {
    let preview: LocalServerPreview
    let address: URL
    let reloadGeneration: Int
    let showing: Bool
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator { preview.coordinator }

    func makeNSView(context: Context) -> Container { Container() }

    func updateNSView(_ container: Container, context: Context) {
        if preview.webView.superview !== container { install(in: container) }
        container.onFocusChange = { focused in if isFocused != focused { isFocused = focused } }
        if !showing { container.letGoOfKeyboard() }
        guard context.coordinator.loadedGeneration != reloadGeneration else { return }
        context.coordinator.loadedGeneration = reloadGeneration
        preview.webView.load(URLRequest(url: address))
    }

    private func install(in container: NSView) {
        let webView = preview.webView
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }

    static func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.isInspectable = true
        coordinator.observations = [
            // The address can change during a SwiftUI update, so it is passed on later.
            webView.observe(\.url) { [weak coordinator] webView, _ in
                MainActor.assumeIsolated {
                    guard let url = webView.url, TranscriptLink.isLocalServer(url) else { return }
                    Task { @MainActor in coordinator?.onAddress(url) }
                }
            },
            // A link to an anchor on the same page ends its load without a commit.
            webView.observe(\.isLoading) { [weak coordinator] webView, _ in
                Task { @MainActor in
                    if !webView.isLoading { coordinator?.onLoaded(webView.url != nil) }
                }
            },
        ]
        return webView
    }

    // The navigation delegate stays until the page is gone: without one, WebKit hands
    // any link it cannot load to the system, clicked or not.
    static func close(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        coordinator.observations = []
    }

    final class Container: NSView {
        var onFocusChange: ((Bool) -> Void)?
        private var responderObservation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            responderObservation = window?.observe(\.firstResponder,
                                                   options: [.old, .new]) { [weak self] _, change in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let gained = self.holds(change.newValue ?? nil)
                    if gained || self.holds(change.oldValue ?? nil) { self.onFocusChange?(gained) }
                }
            }
        }

        // SwiftUI cannot take a focus change mid-update, so it waits and checks again.
        func letGoOfKeyboard() {
            guard holds(window?.firstResponder) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.holds(self.window?.firstResponder) else { return }
                self.window?.makeFirstResponder(nil)
            }
        }

        private func holds(_ responder: NSResponder?) -> Bool {
            (responder as? NSView)?.isDescendant(of: self) == true
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        // This is WebKitErrorFrameLoadInterruptedByPolicyChange, which WKError lacks.
        private static let interruptedByPolicy = 102

        var loadedGeneration = 0
        // A new click cancels the load first, so a page leaving mid-load is a redirect.
        var provisional = false
        var observations: [NSKeyValueObservation] = []
        var onAddress: (URL) -> Void = { _ in }
        var onPhase: (LocalServerPreview.Phase) -> Void = { _ in }
        var onLoaded: (Bool) -> Void = { _ in }
        var openInBrowser: (URL) -> Void = { NSWorkspace.shared.open($0) }

        // A page sent off the machine is stopped, since its session would not follow it.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable
                        (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else {
                decisionHandler(.cancel)
                return
            }
            let scheme = url.scheme?.lowercased() ?? ""
            let mainFrame = action.targetFrame?.isMainFrame == true
            if action.targetFrame != nil, !mainFrame {
                decisionHandler(["http", "https", "about", "data", "blob"].contains(scheme)
                                ? .allow : .cancel)
                return
            }
            if mainFrame, TranscriptLink.isLocalServer(url) || url.absoluteString == "about:blank" {
                decisionHandler(.allow)
                return
            }
            // A page's own click has no mouse button, so it cannot open the browser.
            if action.navigationType == .linkActivated, action.buttonNumber > 0,
               ["http", "https", "mailto"].contains(scheme), !mainFrame || !provisional {
                openInBrowser(url)
            } else if mainFrame, ["http", "https"].contains(scheme) {
                onPhase(.left(url))
            }
            decisionHandler(.cancel)
        }

        // Dev servers often serve HTTPS with a self-signed certificate. The connection
        // never leaves the machine, so the certificate is accepted as it is.
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping @MainActor @Sendable
                        (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let space = challenge.protectionSpace
            guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  TranscriptLink.localServerHosts.contains(space.host),
                  let trust = space.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            provisional = true
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            provisional = false
            onPhase(.showing)
            // After a failure the old page runs on, so the address is read on commit.
            if let url = webView.url, TranscriptLink.isLocalServer(url) { onAddress(url) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            provisional = false
            report(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onPhase(.stopped)
        }

        private func report(_ error: Error) {
            let error = error as NSError
            guard error.code != NSURLErrorCancelled,
                  error.domain != "WebKitErrorDomain" || error.code != Self.interruptedByPolicy
            else { return }
            onPhase(error.code == NSURLErrorCannotConnectToHost
                    ? .unreachable : .failed(error.localizedDescription))
        }
    }
}

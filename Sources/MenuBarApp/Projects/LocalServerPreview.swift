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

    // Nothing arrives when a load only moves within the page, so one that ends while
    // opening has left that page showing. No page means a download or another app's link.
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

    static func draft(_ text: String, adding selection: DesignElementSelection,
                      on address: URL) -> String {
        let place = "`\(selection.selector)` on `\(path(address))`"
        let reference = selection.reference(at: place)
        if text.isEmpty { return reference }
        return text.contains(place) ? text : text + "\n\n" + reference
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
    @Environment(SessionRunner.self) private var runner
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
    @State private var selectionEnabled = false

    private var picking: Bool { selectionEnabled && preview.phase == .showing }

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
                                       designEmpty: false, selectionEnabled: picking,
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
                                         selectionEnabled: picking,
                                         isFocused: $pageFocused,
                                         onPick: pick)
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
            if preview.phase == .showing {
                GlyphButton(icon: selectionEnabled ? "scope" : "cursorarrow", side: 28,
                            active: selectionEnabled, tint: Theme.accent) {
                    selectionEnabled.toggle()
                    if selectionEnabled { conversationMinimized = false }
                }
                .appTooltip(selectionEnabled
                    ? "Stop selecting page elements"
                    : "Select an element to refine")
                .accessibilityLabel("Select an element to refine")
            }
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

    // A pick writes into the composer and sends nothing, as one on a design does, so
    // several elements can be picked before the change is asked for.
    private func pick(_ selection: DesignElementSelection, page: URL, image: NSImage?) {
        runner.composer.editDraft(session.id) {
            $0.text = LocalServerPreview.draft($0.text, adding: selection, on: page)
        }
        if let image, let attachment = Attachments.fromImage(image, prefix: "selection") {
            runner.composer.attach([attachment], to: session.id)
        }
        conversationMinimized = false
        composerFocused = true
    }
}

// The page belongs to the preview, so mounting moves it into whichever container is shown.
struct LocalServerPreviewWebContent: NSViewRepresentable {
    let preview: LocalServerPreview
    let address: URL
    let reloadGeneration: Int
    let showing: Bool
    let selectionEnabled: Bool
    @Binding var isFocused: Bool
    let onPick: (DesignElementSelection, URL, NSImage?) -> Void

    func makeCoordinator() -> Coordinator { preview.coordinator }

    func makeNSView(context: Context) -> Container { Container() }

    func updateNSView(_ container: Container, context: Context) {
        if preview.webView.superview !== container { install(in: container) }
        container.onFocusChange = { focused in if isFocused != focused { isFocused = focused } }
        if !showing { container.letGoOfKeyboard() }
        context.coordinator.onPick = onPick
        context.coordinator.setSelection(selectionEnabled, in: preview.webView)
        guard context.coordinator.loadedGeneration != reloadGeneration else { return }
        context.coordinator.loadedGeneration = reloadGeneration
        context.coordinator.declinedAt = nil
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
        // The picker runs in a world the page's scripts cannot reach, and is added
        // before them so its press listeners run ahead of the app's.
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient,
                                                 name: DesignWebContent.Coordinator.messageName)
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.pickerScript, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: .defaultClient))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
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
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: DesignWebContent.Coordinator.messageName, contentWorld: .defaultClient)
        coordinator.observations = []
        // A pick goes back through the page that shows the preview, and that page holds the
        // preview, so it is let go here or the preview would outlive its pane.
        coordinator.onPick = { _, _, _ in }
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

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate,
                             WKScriptMessageHandler {
        // This is WebKitErrorFrameLoadInterruptedByPolicyChange, which WKError lacks.
        private static let interruptedByPolicy = 102

        var loadedGeneration = 0
        // A new click cancels the load first, so a page leaving mid-load is a redirect.
        var provisional = false
        var selectionEnabled = false
        var observations: [NSKeyValueObservation] = []
        var onAddress: (URL) -> Void = { _ in }
        var onPhase: (LocalServerPreview.Phase) -> Void = { _ in }
        var onLoaded: (Bool) -> Void = { _ in }
        var onPick: (DesignElementSelection, URL, NSImage?) -> Void = { _, _, _ in }
        var openInBrowser: (URL) -> Void = { NSWorkspace.shared.open($0) }
        var saveDownload: @MainActor (String) -> URL? = { name in
            FilePicker.saveFile(suggestedName: name, prompt: "Save",
                                message: "Choose where to save the file from the running app.")
        }
        // When the person last turned a save down. For a moment after, a file the page sends
        // by itself is not offered, so a page that keeps sending them cannot hold Code Station
        // behind save panels, and there is time to close it.
        var declinedAt: ContinuousClock.Instant?
        private var personsLoad = false
        private var asking = false

        private var resting: Bool {
            declinedAt.map { ContinuousClock.now - $0 < .seconds(2) } ?? false
        }

        func setSelection(_ enabled: Bool, in webView: WKWebView) {
            guard selectionEnabled != enabled else { return }
            selectionEnabled = enabled
            applySelection(in: webView)
        }

        private func applySelection(in webView: WKWebView) {
            webView.evaluateJavaScript("window.__codeStationSetSelection?.(\(selectionEnabled));",
                                       in: nil, in: .defaultClient)
        }

        // A pick during a load would carry the next page's address.
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == DesignWebContent.Coordinator.messageName,
                  message.frameInfo.isMainFrame, let webView = message.webView,
                  let body = message.body as? [String: Any] else { return }
            if body["kind"] as? String == "ready" {
                applySelection(in: webView)
                return
            }
            guard selectionEnabled, !provisional,
                  let selection = DesignElementSelection(message: body),
                  let page = webView.url else { return }
            let configuration = WKSnapshotConfiguration()
            let crop = selection.rect.insetBy(dx: -8, dy: -8).intersection(webView.bounds)
            if !crop.isNull, crop.width > 1, crop.height > 1 { configuration.rect = crop }
            webView.takeSnapshot(with: configuration) { [weak self] image, _ in
                self?.onPick(selection, page, image)
            }
        }

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
            // WebKit drops a link's `download` attribute unless this returns .download.
            if action.shouldPerformDownload,
               TranscriptLink.isLocalServer(url) || ["blob", "data"].contains(scheme) {
                decisionHandler(resting && action.buttonNumber == 0 ? .cancel : .download)
                return
            }
            if action.targetFrame != nil, !mainFrame {
                decisionHandler(["http", "https", "about", "data", "blob"].contains(scheme)
                                ? .allow : .cancel)
                return
            }
            if mainFrame, TranscriptLink.isLocalServer(url) || url.absoluteString == "about:blank" {
                personsLoad = action.buttonNumber > 0
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

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor @Sendable
                        (WKNavigationResponsePolicy) -> Void) {
            let disposition = (response.response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Disposition") ?? ""
            let file = disposition.lowercased().hasPrefix("attachment") || !response.canShowMIMEType
            let local = response.isForMainFrame
                || response.response.url.map(TranscriptLink.isLocalServer) == true
            guard file, local else {
                decisionHandler(.allow)
                return
            }
            let persons = response.isForMainFrame && personsLoad
            decisionHandler(resting && !persons ? .cancel : .download)
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

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                     didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                     didBecome download: WKDownload) {
            download.delegate = self
        }

        // The save panel runs modally, so another download can arrive while it is open.
        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String,
                      completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
            guard !asking else {
                completionHandler(nil)
                return
            }
            asking = true
            let destination = saveDownload(suggestedFilename)
            asking = false
            guard let destination else {
                declinedAt = .now
                completionHandler(nil)
                return
            }
            // The save panel has already asked before replacing a file, and a download
            // fails when its destination exists.
            try? FileManager.default.removeItem(at: destination)
            completionHandler(destination)
        }

        // Alerts are left to WebKit, since Code Station's dialog may already be in use.
        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
            let urls = parameters.allowsMultipleSelection
                ? FilePicker.chooseFiles(prompt: "Choose", message: "Choose files for the running app.")
                : FilePicker.chooseFile(prompt: "Choose", message: "Choose a file for the running app.")
                    .map { [$0] } ?? []
            completionHandler(urls.isEmpty ? nil : urls)
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

    private static let pickerScript = #"""
    (() => {
    \#(DesignWebContent.pickerHelpers)

      // The cursor goes in a sheet, not on the root element, which a server-rendered
      // app compares while it hydrates. The picker cannot reach into frames.
      const sheet = new CSSStyleSheet();
      sheet.replaceSync(":root { cursor: crosshair !important } "
        + "iframe, frame, object, embed { pointer-events: none !important }");
      // An app can replace adopted sheets, so this one is put back on pointer moves.
      const keepSheet = () => {
        if (!document.adoptedStyleSheets.includes(sheet)) {
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
        }
      };
      window.addEventListener("pointerover", () => { if (enabled) keepSheet(); }, true);
      window.__codeStationSetSelection = value => {
        enabled = Boolean(value);
        sheet.disabled = !enabled;
        if (enabled) keepSheet();
        else clearHighlight();
      };

      // Presses open menus and focus fields before the click that picks arrives.
      for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "dblclick",
                          "contextmenu", "auxclick"]) {
        window.addEventListener(type, event => {
          if (!enabled) return;
          event.preventDefault();
          event.stopImmediatePropagation();
        }, true);
      }
      window.addEventListener("click", event => {
        if (!enabled || event.isTrusted) return;
        event.preventDefault();
        event.stopImmediatePropagation();
      }, true);

    \#(DesignWebContent.pickerEvents)

      // A page from the back-forward cache keeps its old state, so it asks again.
      const askForState = () =>
        window.webkit.messageHandlers.codeStationDesignSelection.postMessage({kind: "ready"});
      window.addEventListener("pageshow", event => { if (event.persisted) askForState(); });
      askForState();
    })();
    """#
}

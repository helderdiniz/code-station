import AppKit
import Network
import SwiftUI
import Testing
import WebKit
@testable import MenuBarApp

private func url(_ text: String) -> URL { URL(string: text)! }

// Where a test clicks on a page: a box with its top left corner at x and y.
private func box(_ x: Int, _ y: Int) -> String {
    "style=\"position:absolute; left:\(x)px; top:\(y)px; width:200px; height:80px\""
}

// The bar, the message and Reload all go by what the preview holds, so after each load it
// has to hold the page a person expects: the one still on screen, or the one that did not
// load.
@MainActor
struct LocalServerPreviewTests {
    @Test func holdsThePageAPersonExpectsAfterEachLoad() {
        let preview = LocalServerPreview(opening: url("http://localhost:3000/#/billing"))
        #expect(preview.phase == .opening)
        preview.finishLoading(hasPage: true)
        #expect(preview.phase == .showing)
        preview.follow(url("http://localhost:3000/settings"))
        #expect(preview.address == url("http://localhost:3000/settings"))
        preview.reload()
        #expect(preview.phase == .showing)

        preview.open(url("http://localhost:5173/"))
        preview.phase = .unreachable
        preview.finishLoading(hasPage: true)
        preview.follow(url("http://localhost:3000/settings"))
        #expect(preview.phase == .unreachable)
        #expect(preview.address == url("http://localhost:5173/"))
        preview.reload()
        #expect(preview.phase == .opening)
        #expect(preview.reloadGeneration == 4)
        preview.finishLoading(hasPage: false)
        #expect(preview.phase == .noPage)
    }

    @Test func namesOnlyTheServerAndItsPage() {
        let addresses = ["http://localhost:3000/", "http://[::1]:5173/settings?token=abc",
                         "http://localhost:3000/#/billing?token=abc", "http://localhost:3000/docs#intro",
                         "http://ada:secret@localhost:8000/settings"]

        #expect(addresses.map { LocalServerPreview.label(for: url($0)) } == [
            "localhost:3000", "[::1]:5173/settings", "localhost:3000/#/billing", "localhost:3000/docs",
            "localhost:8000/settings",
        ])
    }
}

// An agent reads a pick, so it names the element and its page once, as a pick on Design does.
@MainActor
struct LocalServerPreviewDraftTests {
    @Test func writesAPickAsAReferenceToItsPageOncePerPage() {
        let save = DesignElementSelection(selector: "#save", tag: "button", text: "Save", rect: .zero)
        let image = DesignElementSelection(selector: "main > img", tag: "img", text: "", rect: .zero)
        let settings = url("http://localhost:5173/settings?token=abc#top")
        let first = LocalServerPreview.draft("Make these match.", adding: save, on: settings)

        #expect(LocalServerPreview.draft("", adding: save, on: settings)
                == "Refine \"Save\" at `#save` on `/settings`. ")
        #expect(LocalServerPreview.draft("", adding: image, on: url("http://localhost:5173"))
                == "Refine IMG at `main > img` on `/`. ")
        #expect(first == "Make these match.\n\nRefine \"Save\" at `#save` on `/settings`. ")
        #expect(LocalServerPreview.draft(first, adding: save, on: settings) == first)
        #expect(LocalServerPreview.draft(first, adding: save, on: url("http://localhost:5173/#/billing"))
                == first + "\n\nRefine \"Save\" at `#save` on `/#/billing`. ")
    }
}

// A running app is someone's real work, so the picker stays out of its way: the page cannot
// see or drive it, its crosshair lasts through the app's own documents and sheets without
// touching the page's styles, and with it off every gesture is the app's own.
@MainActor
@Suite(.serialized)
struct LocalServerPreviewWebTests {
    private let app = """
        <button id="save" \(box(100, 100))>Save</button>
        <button id="cancel" \(box(400, 100))>Cancel</button>
        <input id="agree" type="checkbox">
        <script>
        var presses = 0, clicks = 0, save = document.getElementById("save");
        var types = ["pointerdown", "mousedown", "pointerup", "mouseup", "dblclick", "contextmenu", "auxclick"];
        for (const type of types) save.addEventListener(type, () => presses++);
        document.addEventListener("click", () => clicks++, true);
        // Every press the picker stops, then a click, all made by the page's own script.
        var gestures = () => {
          for (const type of types) {
            const Event = type.startsWith("pointer") ? PointerEvent : MouseEvent;
            save.dispatchEvent(new Event(type, {bubbles: true, cancelable: true}));
          }
          save.click();
        };
        window.ready = true;
        </script>
        """

    @Test func picksWithoutGettingInTheAppsWay() async throws {
        let coordinator = LocalServerPreviewWebContent.Coordinator()
        let webView = LocalServerPreviewWebContent.makeWebView(coordinator: coordinator)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            LocalServerPreviewWebContent.close(webView, coordinator: coordinator)
            window.contentView = nil
        }
        webView.loadHTMLString(app, baseURL: url("http://localhost:3000/settings"))
        #expect(try await answer(to: "String(window.ready)", in: webView, awaiting: "true") == "true")
        var picks: [(selection: DesignElementSelection, page: URL, image: NSImage?)] = []
        coordinator.onPick = { picks.append(($0, $1, $2)) }
        let cursor = "getComputedStyle(document.documentElement).cursor"

        _ = try await webView.evaluateJavaScript("gestures()")
        coordinator.setSelection(true, in: webView)
        coordinator.setSelection(false, in: webView)
        _ = try await webView.evaluateJavaScript("gestures()")
        #expect(try await webView.evaluateJavaScript("[presses, clicks]") as? [Int] == [14, 2])
        coordinator.setSelection(true, in: webView)
        #expect(try await answer(to: cursor, in: webView, awaiting: "crosshair") == "crosshair")
        try click(CGPoint(x: 200, y: 140), in: webView)
        #expect(await waitUntil { picks.count == 1 })
        _ = try await webView.evaluateJavaScript("gestures()")
        _ = try await webView.evaluateJavaScript("document.getElementById('agree').click()")
        try click(CGPoint(x: 500, y: 140), in: webView)
        #expect(await waitUntil { picks.count == 2 })

        let pick = try #require(picks.first)
        #expect(pick.selection == DesignElementSelection(selector: "#save", tag: "button", text: "Save",
                                                         rect: CGRect(x: 100, y: 100, width: 200, height: 80)))
        #expect(pick.page.path == "/settings")
        #expect(pick.image?.size == CGSize(width: 216, height: 96))
        #expect(picks.map(\.selection.selector) == ["#save", "#cancel"])
        #expect(try await webView.evaluateJavaScript("[presses, clicks]") as? [Int] == [14, 2])
        #expect(try await webView.evaluateJavaScript("document.getElementById('agree').checked") as? Bool == false)
        #expect(try await webView.evaluateJavaScript("""
            [typeof window.webkit?.messageHandlers?.codeStationDesignSelection,
             typeof window.__codeStationSetSelection]
            """) as? [String] == ["undefined", "undefined"])
        #expect(!webView.configuration.websiteDataStore.isPersistent)

        webView.loadHTMLString(app, baseURL: url("http://localhost:3000/billing"))
        let state = "location.pathname + ' ' + \(cursor)"
        #expect(try await answer(to: state, in: webView, awaiting: "/billing crosshair") == "/billing crosshair")
        #expect(try await webView.evaluateJavaScript("document.documentElement.hasAttribute('style')") as? Bool == false)
        _ = try await webView.evaluateJavaScript("""
            document.adoptedStyleSheets = [new CSSStyleSheet()];
            document.body.dispatchEvent(new PointerEvent("pointerover"));
            """)
        #expect(try await webView.evaluateJavaScript(cursor) as? String == "crosshair")
    }

    // The page answers in its own time, so it is asked again until the answer arrives.
    private func answer(to script: String, in webView: WKWebView,
                        awaiting expected: String) async throws -> String? {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline,
              (try? await webView.evaluateJavaScript(script)) as? String != expected {
            try await Task.sleep(for: .milliseconds(30))
        }
        return (try? await webView.evaluateJavaScript(script)) as? String
    }

    // Through the window, as a person clicks, so the page sees the click as trusted.
    private func click(_ point: CGPoint, in webView: WKWebView) throws {
        let window = try #require(webView.window)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try #require(NSEvent.mouseEvent(
                with: type, location: webView.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
    }
}

// The app in the pane is someone's work in progress, so the pane keeps it as it was left.
@MainActor
@Suite(.serialized)
struct LocalServerPreviewPageTests {
    // A session's pane with a running app on its Chat tab. The app is handed to the page
    // directly, so no server has to be running for it.
    @MainActor
    private final class Pane {
        // The bar runs along the top 42 points of the window, with its controls this far across.
        enum Control: CGFloat {
            case picker = 858, openInBrowser = 896
        }

        let preview: LocalServerPreview
        // Borderless, as in the other web tests: a window that can become key takes the
        // first click on the page for itself, and the app never sees it.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        private(set) var pageFocused = false
        private(set) var closed = false
        private let hosting = NSHostingController(rootView: AnyView(EmptyView()))
        private let store: ProjectStore
        private let scratch: ScratchDirectory
        private let session: ChatSession
        private let runner = SessionRunner(paths: [.codex: "/usr/bin/true"])
        private let settings: AppSettings
        private let shortcuts: ShortcutStore
        private let palette = GlobalCommandPaletteController()

        init(app: String = "<p>Start</p>",
             at address: URL = URL(string: "http://localhost:3000/settings")!) async throws {
            (store, scratch) = TestStore.make()
            let project = try TestStore.project(in: store)
            session = store.newSession(in: project.id, seed: .init(agent: .codex))
            let preferences = try #require(UserDefaults(suiteName: "preview-page-\(UUID().uuidString)"))
            settings = AppSettings(agentAvatarURL: scratch.path("avatar.png"), preferences: preferences)
            shortcuts = ShortcutStore(storageURL: scratch.path("shortcuts.json"), siteDefaults: SiteDefaults())
            preview = LocalServerPreview(opening: address)
            preview.coordinator.loadedGeneration = preview.reloadGeneration
            preview.webView.loadHTMLString(app, baseURL: address)
            show(app: true)
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 1000, height: 800))
            window.center()
            window.orderFront(nil)
            #expect(await waitUntil { preview.phase == .showing && !preview.webView.isLoading })
            try await settle()
        }

        // The Chat tab with the app on it, or another tab with the app out of sight.
        func show(app: Bool) {
            hosting.rootView = AnyView(Group {
                if app {
                    LocalServerPreviewPage(preview: preview, session: session,
                                           placeholder: "Ask for a change",
                                           openPreview: { _ in false },
                                           pageFocused: focus,
                                           onClose: { [weak self] in self?.closed = true })
                }
            }
            .environment(store)
            .environment(runner)
            .environment(settings)
            .environment(shortcuts)
            .environment(palette)
            .background(Theme.background)
            .appOverlays())
        }

        // Held weakly, since the page it goes to is held by this pane.
        private var focus: Binding<Bool> {
            Binding(get: { [weak self] in self?.pageFocused == true },
                    set: { [weak self] in self?.pageFocused = $0 })
        }

        var conversation: DesignConversationDismissal.ObserverView? {
            func find(_ view: NSView) -> DesignConversationDismissal.ObserverView? {
                view as? DesignConversationDismissal.ObserverView ?? view.subviews.lazy.compactMap(find).first
            }
            return find(hosting.view)
        }

        var draft: SessionComposerStore.Draft { runner.composer.draft(session.id) }

        func click(_ point: CGPoint) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point,
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
        }

        func click(_ control: Control) throws { try click(CGPoint(x: control.rawValue, y: 779)) }

        func click(page point: CGPoint) throws { try click(preview.webView.convert(point, to: nil)) }

        func settle() async throws {
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(20))
                hosting.view.layoutSubtreeIfNeeded()
            }
        }

        func close() {
            window.orderOut(nil)
            window.contentViewController = nil
            preview.close()
            runner.stopAll()
        }
    }

    @Test func keepsTheAppUntilItIsClosed() async throws {
        weak var released: WKWebView?
        do {
            let pane = try await Pane(app: "<input id='name'>")
            let page = pane.preview.webView
            released = page
            let name = "document.getElementById('name').value"
            _ = try await page.evaluateJavaScript("\(name) = 'Ada'")
            #expect(pane.conversation?.minimized == true)
            pane.window.makeFirstResponder(page)
            #expect(pane.pageFocused)

            pane.show(app: false)
            try await pane.settle()
            #expect(page.window == nil)
            #expect(!pane.pageFocused)
            pane.show(app: true)
            try await pane.settle()
            #expect(page.window === pane.window)
            #expect(try await page.evaluateJavaScript(name) as? String == "Ada")
            #expect(pane.preview.phase == .showing)
            _ = try await page.evaluateJavaScript("history.pushState(null, '', '/billing')")
            #expect(await waitUntil { pane.preview.address.path == "/billing" })
            pane.window.makeFirstResponder(page)
            #expect(pane.pageFocused)
            pane.preview.phase = .unreachable
            try await pane.settle()
            #expect(pane.window.firstResponder !== page)
            #expect(!pane.pageFocused)

            pane.close()
            // A closed page keeps its policy until it is gone, or WebKit hands a link it
            // cannot load to the system.
            #expect(page.navigationDelegate === pane.preview.coordinator)
        }
        #expect(await waitUntil { released == nil })
    }

    @Test func onlyAPersonsClickOpensTheBrowser() async throws {
        let pane = try await Pane(app: """
            <a id="docs" href="https://example.com/docs" \(box(0, 0))>Docs</a>
            <a id="help" href="https://example.com/help" target="_blank" \(box(0, 100))>Help</a>
            """)
        defer { pane.close() }
        var opened: [URL] = []
        pane.preview.coordinator.openInBrowser = { opened.append($0) }
        let docs = url("https://example.com/docs"), help = url("https://example.com/help")

        try pane.click(page: CGPoint(x: 100, y: 40))
        try pane.click(page: CGPoint(x: 100, y: 140))
        #expect(await waitUntil { opened == [docs, help] })
        #expect(pane.preview.phase == .showing)
        _ = try await pane.preview.webView.evaluateJavaScript("""
            Object.assign(document.createElement("a"), {href: "mailto:someone@example.com"}).click();
            document.getElementById("help").click();
            document.getElementById("docs").click();
            """)
        #expect(await waitUntil { pane.preview.phase == .left(docs) })
        #expect(opened == [docs, help])
        try pane.click(.openInBrowser)
        #expect(await waitUntil { pane.closed })
        #expect(opened == [docs, help, url("http://localhost:3000/settings")])
    }

    // A page that keeps sending files must not hold Code Station behind save panels, so for a
    // moment after a save is turned down only a person's click or a conversation link asks again.
    @Test func savesWhatTheAppSends() async throws {
        let server = FileServer(serving: "week,picks\n42,7\n", as: "report.csv")
        let port = try await server.start()
        defer { server.stop() }
        let report = "http://127.0.0.1:\(port)/report.csv"
        let pane = try await Pane(app: """
            <input id="name">
            <a id="export" href="data:text/csv,name%2Cteam" download="people.csv" \(box(0, 0))>Export</a>
            <iframe srcdoc="<a href='data:text/csv,team' download='teams.csv'
              style='position:absolute; left:0; top:0; width:200px; height:80px'>Export</a>"
              style="position:absolute; left:0; top:100px; width:300px; height:120px; border:0"></iframe>
            <a href="\(report)" \(box(0, 240))>Report</a>
            """)
        defer { pane.close() }
        let scratch = ScratchDirectory()
        var asked: [String] = []
        pane.preview.coordinator.saveDownload = { asked.append($0); return scratch.path($0) }
        let saved = { (name: String) in try? String(contentsOf: scratch.path(name), encoding: .utf8) }
        let page = pane.preview.webView
        let name = "document.getElementById('name').value", export = "document.getElementById('export').click()"
        _ = try await page.evaluateJavaScript("\(name) = 'Ada'")
        try "an earlier export".write(to: scratch.path("people.csv"), atomically: true, encoding: .utf8)

        let files = [(40.0, "people.csv", "name,team"), (140, "teams.csv", "team"),
                     (280, "report.csv", "week,picks\n42,7\n")]
        for (y, file, contents) in files {
            try pane.click(page: CGPoint(x: 100, y: y))
            #expect(await waitUntil { saved(file) == contents })
        }
        #expect(asked == ["people.csv", "teams.csv", "report.csv"])
        #expect(pane.preview.phase == .showing)
        #expect(pane.preview.address.path == "/settings")
        #expect(try await page.evaluateJavaScript(name) as? String == "Ada")
        let frame = "document.querySelector('iframe').contentDocument.body.innerText"
        #expect(try await page.evaluateJavaScript(frame) as? String == "Export")

        pane.preview.coordinator.saveDownload = { asked.append($0); return nil }
        _ = try await page.evaluateJavaScript(export)
        #expect(await waitUntil { asked.count == 4 })
        _ = try await page.evaluateJavaScript("\(export); \(export)")
        _ = try await page.evaluateJavaScript("location.href = '\(report)'")
        try await pane.settle()
        #expect(asked.count == 4)
        try pane.click(page: CGPoint(x: 100, y: 40))
        #expect(await waitUntil { asked.count == 5 })
        try await pane.settle()
        #expect(asked.count == 5)
        #expect(pane.preview.phase == .showing)
        try pane.click(page: CGPoint(x: 100, y: 280))
        #expect(await waitUntil { asked.count == 6 })
        pane.preview.open(url(report))
        #expect(await waitUntil { asked.count == 7 })
        #expect(await waitUntil { pane.preview.address.path == "/settings" })
        pane.preview.coordinator.declinedAt = .now - .seconds(2)
        _ = try await page.evaluateJavaScript(export)
        #expect(await waitUntil { asked.count == 8 })
    }

    // A press while picking is a pick on its way to the composer, so it leaves the panel open.
    // The pane's clicks skip the monitor that watches for presses, so the panel is handed one.
    @Test func aPickOpensTheConversationWithTheElementInIt() async throws {
        let pane = try await Pane(app: "<button id='save' \(box(100, 100))>Save</button>")
        defer { pane.close() }
        let conversation = try #require(pane.conversation)
        let save = pane.preview.webView.convert(CGPoint(x: 200, y: 140), to: nil)
        let press = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: save,
            modifierFlags: [], timestamp: 0, windowNumber: pane.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))

        try pane.click(.picker)
        try await pane.settle()
        #expect(!conversation.minimized)
        #expect(conversation.handle(press, frontmost: pane.window) === press)
        try await pane.settle()
        #expect(!conversation.minimized)
        // A message over the page rests the picker, so the same press shrinks the panel, and
        // when the page comes back the pick has to bring the conversation back by itself.
        pane.preview.phase = .unreachable
        try await pane.settle()
        _ = conversation.handle(press, frontmost: pane.window)
        try await pane.settle()
        #expect(conversation.minimized)
        pane.preview.phase = .showing
        try await pane.settle()
        try pane.click(save)
        #expect(await waitUntil { !pane.draft.attachments.isEmpty })
        let crop = try #require(pane.draft.attachments.first)
        defer { try? FileManager.default.removeItem(at: crop.url) }
        try await pane.settle()

        #expect(crop.name.hasPrefix("selection-"))
        #expect(!conversation.minimized)
        let composer = try #require(pane.window.firstResponder as? NSTextView)
        #expect(composer.isEditable)
        #expect(composer.string == "Refine \"Save\" at `#save` on `/settings`. ")
    }
}

// A server on this machine that answers every request the same way: with one file, sent
// the way a dev server sends an export, or with one page.
private final class FileServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local-server-preview.file-server")
    private let listener = HTTPListener()
    private let reply: Data

    init(serving body: String, as file: String? = nil) {
        let type = file.map { "text/csv\r\nContent-Disposition: attachment; filename=\($0)" }
        reply = Data(("HTTP/1.1 200 OK\r\nContent-Type: \(type ?? "text/html; charset=utf-8")\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body).utf8)
    }

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let bound = try NWListener(using: parameters, on: .any)
        return try await withCheckedThrowingContinuation { ready in
            queue.async {
                self.listener.expect(ready)
                self.listener.start(bound, on: self.queue) { connection in
                    connection.start(queue: self.queue)
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                        connection.send(content: self.reply, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    }
                } failed: { error in
                    self.listener.answer(.failure(error))
                }
            }
        }
    }

    func stop() { queue.async { self.listener.cancel() } }
}

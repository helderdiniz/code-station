import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@Suite(.serialized)
struct DispatchWorkbenchLayoutTests {
    @Test(arguments: [CGFloat(640), CGFloat(1020)], [false, true])
    @MainActor func workbenchFitsItsSheet(width: CGFloat, dark: Bool) async throws {
        let scratch = ScratchDirectory(prefix: "dispatch-layout")
        let store = DispatchStore(storeURL: scratch.path("requests.json"), siteDefaults: SiteDefaults())
        let auth = DispatchAuthStore(storeURL: scratch.path("auth.json"),
                                     keychain: KeychainClient(read: { [:] }, write: { _ in }), siteDefaults: SiteDefaults())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkbenchPreviewProtocol.self]
        let runner = DispatchRunner(sessionConfiguration: configuration)
        let folder = store.addFolder(named: "Merchants")
        let request = store.add(SavedRequest(name: "List merchants", url: "https://example.test/merchants",
                                             headers: [HeaderField(key: "Accept", value: "application/json")],
                                             queryParams: [HeaderField(key: "status", value: "active"),
                                                           HeaderField(key: "limit", value: "20")], authMode: .none), to: folder.id)
        store.add(SavedRequest(name: "Create merchant", method: .post), to: folder.id)
        store.selectedID = request.id
        store.togglePin(request.id)
        await runner.send(request, environment: auth.active)

        let size = CGSize(width: width, height: 660)
        let host = NSHostingView(rootView: DispatchView(parentSize: CGSize(width: width + 48, height: 696))
            .environment(store).environment(auth).environment(runner)
            .environment(\.colorScheme, dark ? .dark : .light)
            .appOverlays())
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setContentSize(size)
        window.center()
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= width)
        #expect(host.fittingSize.height <= 660)

        for tab in DispatchWorkbenchState.ResponseTab.allCases {
            store.workbench.responseTab = tab
            store.workbench.responseExpanded = tab == .headers
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width <= width)
            #expect(host.fittingSize.height <= 660)
            if let directory = ProcessInfo.processInfo.environment["DISPATCH_SNAPSHOT_DIR"] {
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(350))
                host.layoutSubtreeIfNeeded()
                let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: image)
                let data = try #require(image.representation(using: .png, properties: [:]))
                let folder = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: folder.appendingPathComponent("dispatch-\(Int(width))-\(dark ? "dark" : "light")-\(tab.rawValue).png"))
            }
        }

    }
}

private final class WorkbenchPreviewProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json", "X-Request-ID": "preview"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":[{"id":"mrc_01842","name":"Northstar Coffee","country":"GB","status":"active"},{"id":"mrc_01843","name":"Casa do Pão","country":"PT","status":"active"}],"has_more":false,"total":2}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

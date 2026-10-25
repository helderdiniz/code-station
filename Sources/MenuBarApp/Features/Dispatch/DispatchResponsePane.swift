import SwiftUI

struct DispatchResponsePane: View {
    let result: HTTPResult?
    let running: Bool
    let environment: ApiEnvironment
    let cancel: () -> Void
    let retry: () -> Void

    @Environment(DispatchStore.self) private var store
    @Namespace private var tabPanels
    @State private var document = DispatchResponseDocument(body: "")
    @State private var collapsed = false
    @State private var highlighted = AttributedString("")
    private typealias Tab = DispatchWorkbenchState.ResponseTab

    private var tabs: [Tab] {
        guard let result, result.failure == nil else { return [.body] }
        return [.body] + (document.table == nil ? [] : [.table]) + (result.headers.isEmpty ? [] : [.headers])
    }

    private var shown: Tab { tabs.contains(store.workbench.responseTab) ? store.workbench.responseTab : .body }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            status
            if let result, !running {
                toolbar
                if result.isTruncated {
                    note("Response truncated at the download limit. Only the received portion is shown and copied.")
                } else if document.structuredLimitReached {
                    note("Large response shown as text. Structured views are available up to 1 MB.")
                }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(environment.label) response: \(tabLabel(shown))")
                .accessibilityLabeledPair(role: .content, id: shown, in: tabPanels)
        }
        .background(Theme.card)
        .onChange(of: result, initial: true) { _, result in
            document = DispatchResponseDocument(body: result?.body ?? "", truncated: result?.isTruncated ?? false)
            collapsed = false
            highlight()
        }
        .onChange(of: collapsed) { _, _ in highlight() }
        .motion(Motion.reveal, value: running)
        .motion(Motion.reveal, value: shown)
        .motion(Motion.reveal, value: environment)
    }

    private var status: some View {
        HStack(spacing: 10) {
            Text("Response").font(.system(size: 12, weight: .semibold))
            if running {
                Text("Waiting for \(environment.label)…").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let result {
                Text(result.statusText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(result.tint)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(result.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .transition(.fadeIn)
                ViewThatFits(in: .horizontal) {
                    Text("\(Int(result.duration * 1000)) ms · \(byteText(result.byteCount)) · \(environment.label)")
                    Text("\(Int(result.duration * 1000)) ms · \(environment.label)")
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text("Not sent in \(environment.label)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            GlyphButton(icon: store.workbench.responseExpanded ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right", side: 26) {
                store.workbench.responseExpanded.toggle()
            }
            .accessibilityLabel(store.workbench.responseExpanded ? "Restore request editor" : "Expand response")
            .appTooltip(store.workbench.responseExpanded ? "Restore request editor" : "Expand response")
        }
        .padding(.horizontal, 20).frame(height: 43)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            DispatchTabs(items: tabs,
                         selection: Binding(get: { shown }, set: { store.workbench.responseTab = $0 }),
                         namespace: tabPanels, label: tabLabel,
                         detail: { $0 == .headers ? "\(result?.headers.count ?? 0)" : nil })
                .accessibilityLabel("Response view tabs")
            Spacer(minLength: 0)
            if shown == .body, document.collapsedBody != nil {
                InlineLink(title: collapsed ? "Expand array" : "Collapse array", size: 11) { collapsed.toggle() }
            }
            if let text = copyable, !text.isEmpty {
                CopyButton("Copy", onCopy: { AccessibilityNotification.Announcement("Response copied").post() }) { text }
                    .accessibilityLabel(shown == .headers ? "Copy response headers" : "Copy response")
            }
        }
        .padding(.horizontal, 20)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }

    @ViewBuilder private var content: some View {
        if running {
            VStack(spacing: 10) {
                LoopSpinner(colour: Theme.accent, size: 22)
                Text("Sending to \(environment.label)").font(.serif(17))
                Text("Waiting for the response.").font(.system(size: 12)).foregroundStyle(.secondary)
                ActionButton(title: "Cancel request", tone: .outlined, action: cancel)
            }
        } else if let result {
            if let failure = result.failure {
                VStack(alignment: .leading, spacing: 12) {
                    Text(failure).font(.system(size: 12)).foregroundStyle(Theme.deletion).textSelection(.enabled)
                    ActionButton(title: "Retry request", tone: .outlined, icon: "arrow.clockwise", action: retry)
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(spacing: 0) {
                    if result.status >= 400 {
                        HStack {
                            Text("The server returned \(result.status). The response is shown below.")
                                .font(.system(size: 11)).foregroundStyle(Theme.deletion)
                            Spacer()
                            InlineLink(title: "Retry", size: 11, action: retry)
                        }.padding(.horizontal, 20).padding(.vertical, 8)
                    }
                    ZStack {
                        bodyView(result)
                            .opacity(shown == .body ? 1 : 0)
                            .allowsHitTesting(shown == .body).accessibilityHidden(shown != .body)
                        headersView(result)
                            .opacity(shown == .headers ? 1 : 0)
                            .allowsHitTesting(shown == .headers).accessibilityHidden(shown != .headers)
                        if let table = document.table {
                            tableView(table)
                                .opacity(shown == .table ? 1 : 0)
                                .allowsHitTesting(shown == .table).accessibilityHidden(shown != .table)
                        }
                    }
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "paperplane").font(.system(size: 25)).foregroundStyle(.secondary)
                Text("Your response will appear here").font(.serif(17))
                Text("Send this request to \(environment.label) to see the status, timing and body.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(20)
        }
    }

    private func bodyView(_ result: HTTPResult) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(result.body.isEmpty ? AttributedString("No body came back.") : highlighted)
                .font(.mono(11)).lineSpacing(4)
                .foregroundStyle(ResponseStyle.base)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
        .background(ResponseStyle.background)
    }

    private func headersView(_ result: HTTPResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(result.headers) { header in
                    HStack(alignment: .top, spacing: 12) {
                        Text(header.key).font(.mono(11, .semibold)).foregroundStyle(ResponseStyle.key)
                            .frame(minWidth: 100, idealWidth: 180, maxWidth: 220, alignment: .leading)
                        Text(header.value).font(.mono(11)).foregroundStyle(ResponseStyle.base)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.textSelection(.enabled).padding(20)
        }.background(ResponseStyle.background)
    }

    private func tableView(_ table: DispatchResponseDocument.Table) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if table.limited { note("Table preview limited to 500 rows, 30 columns and 500 characters per cell. JSON and Copy retain the full received body.") }
            if table.rows.isEmpty || table.columns.isEmpty {
                Text(table.rows.isEmpty ? "Empty array · 0 rows" : "This object has no fields.").font(.system(size: 12)).foregroundStyle(.secondary).padding(20)
                Spacer()
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        Section {
                            ForEach(table.rows.indices, id: \.self) { index in
                                HStack(alignment: .top, spacing: 0) {
                                    ForEach(table.columns.indices, id: \.self) { column in
                                        Text(table.rows[index][column]).font(.mono(11)).textSelection(.enabled)
                                            .frame(width: 170, alignment: .leading).padding(10)
                                            .accessibilityLabel("\(table.columns[column]): \(table.rows[index][column])")
                                    }
                                }.overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
                            }
                        } header: {
                            HStack(spacing: 0) {
                                ForEach(table.columns, id: \.self) { column in
                                    Text(column).font(.system(size: 11, weight: .semibold))
                                        .frame(width: 170, alignment: .leading).padding(10)
                                }
                            }.background(Theme.sidebar)
                        }
                    }
                }
                Text(counted(table.totalRows, "row")).font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.vertical, 6)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Theme.attentionText)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 7)
            .background(Theme.attention.opacity(0.08))
    }

    private func tabLabel(_ tab: Tab) -> String { tab == .body && document.isJSON ? "JSON" : tab.rawValue }

    private var copyable: String? {
        guard let result else { return nil }
        if let failure = result.failure { return failure }
        return shown == .headers ? result.headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n") : result.body
    }

    private func highlight() {
        let body = collapsed ? document.collapsedBody ?? "" : result?.body ?? ""
        highlighted = document.structuredLimitReached ? AttributedString(body) : ResponseStyle.highlight(body)
    }

    private func byteText(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        if count < 1024 * 1024 { return String(format: "%.1f kB", Double(count) / 1024) }
        return String(format: "%.1f MB", Double(count) / Double(1024 * 1024))
    }
}

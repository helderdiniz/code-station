import Foundation

// One MCP preset while it is being edited. The file keeps only what a preset becomes, so
// the editor holds a little more: both the command and the address, so switching the
// transport and back loses neither, whether the name is still made from the label, and
// whether an empty value is a deliberate prompt or one not filled in yet.
struct MCPPresetDraft: Identifiable, Equatable {
    enum Transport: Equatable { case local, remote }

    struct Entry: Identifiable, Equatable {
        let id: UUID
        var key: String
        var value: String
        var asks: Bool

        init(id: UUID = UUID(), key: String = "", value: String = "", asks: Bool = false) {
            self.id = id
            self.key = key
            self.value = value
            self.asks = asks
        }
    }

    // What is wrong with a preset, one message for each field that shows it.
    struct Problems: Equatable {
        var title: String?
        var name: String?
        var command: String?
        var url: String?
        var values: String?

        var isEmpty: Bool { self == Problems() }
    }

    let id: UUID
    var title: String
    var serverType: String
    // Empty means any environment.
    var environment: String
    var usesAutoName: Bool
    var customName: String
    var transport: Transport
    var command: String
    var arguments: String
    var url: String
    var type: String
    var env: [Entry]
    var headers: [Entry]

    init(id: UUID = UUID(),
         title: String = "",
         serverType: String = "",
         environment: String = "",
         usesAutoName: Bool = true,
         customName: String = "",
         transport: Transport = .local,
         command: String = "",
         arguments: String = "",
         url: String = "",
         type: String = "http",
         env: [Entry] = [],
         headers: [Entry] = []) {
        self.id = id
        self.title = title
        self.serverType = serverType
        self.environment = environment
        self.usesAutoName = usesAutoName
        self.customName = customName
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.url = url
        self.type = type
        self.env = env
        self.headers = headers
    }

    // A preset without a label falls back to its name, so it starts with one here too.
    init(_ preset: SiteDefaults.MCP.Preset) {
        let title = preset.title ?? preset.name
        let serverType = preset.serverType ?? ""
        let entries: ([SiteDefaults.MCP.Value]?) -> [Entry] = { values in
            (values ?? []).map { Entry(key: $0.key, value: $0.value, asks: $0.value.isEmpty) }
        }
        self.init(title: title,
                  serverType: serverType,
                  environment: preset.environment ?? "",
                  usesAutoName: preset.name == Self.autoName(serverType: serverType, title: title),
                  customName: preset.name,
                  transport: preset.isRemote ? .remote : .local,
                  command: preset.command ?? "",
                  arguments: (preset.args ?? []).joined(separator: "\n"),
                  url: preset.url ?? "",
                  type: preset.type ?? "http",
                  env: entries(preset.env),
                  headers: entries(preset.headers))
    }

    var name: String {
        usesAutoName ? Self.autoName(serverType: serverType, title: title) : customName
    }

    // The values the active transport uses. A local command takes environment variables
    // and a remote server takes headers, never both.
    var entries: [Entry] {
        get { transport == .local ? env : headers }
        set { if transport == .local { env = newValue } else { headers = newValue } }
    }

    var askedCount: Int {
        entries.filter { $0.asks && !$0.key.trimmed.isEmpty }.count
    }

    var argumentList: [String] {
        arguments.components(separatedBy: .newlines).map(\.trimmed).filter { !$0.isEmpty }
    }

    // What goes in the file. Only the active transport is written, and a value set to ask
    // is written empty, which is how the file says to ask for it.
    var preset: SiteDefaults.MCP.Preset {
        let values: ([Entry]) -> [SiteDefaults.MCP.Value]? = { entries in
            entries.isEmpty ? nil : entries.map { .init(key: $0.key, value: $0.asks ? "" : $0.value) }
        }
        let local = transport == .local
        let arguments = argumentList
        return SiteDefaults.MCP.Preset(
            name: name,
            title: title,
            serverType: serverType,
            environment: environment,
            command: local ? command : nil,
            args: local && !arguments.isEmpty ? arguments : nil,
            url: local ? nil : url,
            type: local ? nil : type,
            env: local ? values(env) : nil,
            headers: local ? nil : values(headers))
    }

    // The name a preset gets from its type and label. A label that already starts with
    // the type does not repeat it, so "Grafana platform dev" under Grafana becomes
    // grafana-platform-dev rather than grafana-grafana-platform-dev.
    static func autoName(serverType: String, title: String) -> String {
        let type = serverType.trimmed
        var label = title.trimmed
        if !type.isEmpty, label.lowercased().hasPrefix(type.lowercased()) {
            label = String(label.dropFirst(type.count)).trimmed
        }
        return [slug(type), slug(label)].filter { !$0.isEmpty }.joined(separator: "-")
    }

    private static func slug(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
            .joined(separator: "-")
    }

    func problems(among drafts: [MCPPresetDraft]) -> Problems {
        var problems = Problems()
        if title.trimmed.isEmpty {
            problems.title = "Add a label. It is what people pick from the menu."
        }
        let name = name.trimmed
        if name.isEmpty {
            problems.name = "Give the preset a name. It is the key in the configuration file."
        } else if drafts.filter({ $0.name.trimmed == name }).count > 1 {
            problems.name = "Another preset is already called \(name). Names must be unique."
        }
        switch transport {
        case .local:
            if command.trimmed.isEmpty {
                problems.command = "Enter the command that starts the server."
            }
        case .remote:
            let address = url.trimmed.lowercased()
            if !address.hasPrefix("http://") && !address.hasPrefix("https://") {
                problems.url = "Enter a full address, starting with https://"
            }
        }
        let keys = entries.map(\.key.trimmed)
        if keys.contains(where: \.isEmpty) {
            problems.values = "Every \(entryNoun) needs a name."
        } else if Set(keys).count != keys.count {
            problems.values = "Two \(entryNoun)s have the same name."
        } else if entries.contains(where: { !$0.asks && $0.value.trimmed.isEmpty }) {
            problems.values = "Give every \(entryNoun) a value, or set it to ask when added."
        }
        return problems
    }

    var entryNoun: String { transport == .local ? "variable" : "header" }

    // What the preset runs or reaches, a line for each part, so the dark panel at the top
    // of the editor reads the way it would in a terminal.
    var runsAs: [RunsAsLine] {
        switch transport {
        case .local:
            let variables = env.filter { !$0.key.trimmed.isEmpty }.map { entry in
                RunsAsLine(parts: [.plain("\(entry.key.trimmed)="), value(of: entry), .plain(" \\")])
            }
            var last: [RunsAsLine.Part] = [command.trimmed.isEmpty ? .dim("command") : .plain(command.trimmed)]
            if !argumentList.isEmpty { last.append(.plain(" " + argumentList.joined(separator: " "))) }
            return variables + [RunsAsLine(parts: last)]
        case .remote:
            let address: RunsAsLine.Part = url.trimmed.isEmpty ? .dim("address") : .plain(url.trimmed)
            let headers = headers.filter { !$0.key.trimmed.isEmpty }.map { entry in
                RunsAsLine(parts: [.dim("\(entry.key.trimmed): "), value(of: entry)])
            }
            return [RunsAsLine(parts: [.plain(type.uppercased() + " "), address])] + headers
        }
    }

    private func value(of entry: Entry) -> RunsAsLine.Part {
        if entry.asks { return .asked }
        return entry.value.isEmpty ? .plain("''") : .plain(entry.value)
    }

    struct RunsAsLine: Equatable {
        enum Part: Equatable {
            case plain(String)
            case dim(String)
            case asked
        }

        let parts: [Part]
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmed.lowercased()
        guard !query.isEmpty else { return true }
        return [title, name, serverType, environment].joined(separator: " ").lowercased().contains(query)
    }

    // The same grouping the add menu uses, so each group here is one menu there.
    static func groups(_ drafts: [MCPPresetDraft]) -> [(serverType: String?, drafts: [MCPPresetDraft])] {
        drafts.reduce(into: []) { groups, draft in
            let trimmed = draft.serverType.trimmed
            let serverType = trimmed.isEmpty ? nil : trimmed
            if let index = groups.firstIndex(where: { $0.serverType == serverType }) {
                groups[index].drafts.append(draft)
            } else {
                groups.append((serverType, [draft]))
            }
        }
    }
}

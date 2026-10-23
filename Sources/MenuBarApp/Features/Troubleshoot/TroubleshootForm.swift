import SwiftUI

// The parts a diagnosis is written on, shared by the sheet that starts one from scratch
// and by the tab inside a session. Both ask the same four things - the problem, the
// deployment, whether MCP servers are in play, and which skills to load - so they are
// built once here and the two screens only differ in what they already know and in how
// they lay the parts out.

// MARK: - Skills

@MainActor
enum TroubleshootSkills {
    static func host(for agent: AgentKind) -> SkillHost {
        switch agent {
        case .claudeCode: .claude
        case .codex: .codex
        case .copilot: .copilot
        }
    }

    static func available(_ manager: SkillsManager,
                          for agent: AgentKind) -> [SkillMarketplace.Plugin] {
        var names = Set<String>()
        return manager.plugins.filter {
            manager.installation(of: $0, on: host(for: agent))?.enabled == true
                && names.insert($0.name).inserted
        }
    }

    // A skill picked for one agent stays picked while the other is selected, so switching
    // agents and back keeps the choice. Only what this agent can load is sent to it.
    static func chosen(_ manager: SkillsManager, for agent: AgentKind,
                       selected: Set<String>) -> [String] {
        available(manager, for: agent).map(\.name).filter { selected.contains($0) }
    }

    // The menu that picks skills, one checked row per skill the agent has installed. A
    // long list gets a filter field. The same menu hangs off the sheet's bar and the tab's
    // pill, so the two screens offer the same choice.
    static func menu(_ manager: SkillsManager, for agent: AgentKind,
                     selected: Binding<Set<String>>,
                     manage: @escaping () -> Void) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        let items = available(manager, for: agent).map { plugin in
            MenuItem(label: plugin.name,
                     checked: selected.wrappedValue.contains(plugin.name),
                     subtitle: plugin.description,
                     handler: {
                         if selected.wrappedValue.contains(plugin.name) {
                             selected.wrappedValue.remove(plugin.name)
                         } else {
                             selected.wrappedValue.insert(plugin.name)
                         }
                     })
        }
        if items.count > 6 {
            entries.append(.searchable(items,
                                       prompt: "Filter skills by name",
                                       noResults: "No skill matches this filter."))
        } else {
            entries.append(contentsOf: items.map { MenuEntry.item($0) })
        }
        if !entries.isEmpty { entries.append(.separator) }
        entries.append(.item("Manage skills…", icon: "sparkles", action: manage))
        return entries
    }
}

// The skills the diagnosis is told to use, as a row of pills. The + adds one from what
// the chosen agent has installed, and a right-click on a pill takes it off. With nothing
// picked the bar turns amber, since an agent left to guess at Grafana or Postgres is
// rarely what was wanted.
struct TroubleshootSkillsBar: View {
    let skills: SkillsManager
    let agent: AgentKind
    @Binding var selected: Set<String>
    @Binding var showingSkills: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: needsSkill ? "exclamationmark.triangle.fill" : "sparkles")
                .font(.system(size: needsSkill ? 11 : 10.5, weight: .semibold))
                .foregroundStyle(needsSkill ? AnyShapeStyle(Theme.attentionText)
                                            : AnyShapeStyle(.tertiary))
                .accessibilityLabel("Skills")

            if chosenSkills.isEmpty {
                Text(emptySkillsMessage)
                    .font(.system(size: 11.5, weight: needsSkill ? .medium : .regular))
                    .foregroundStyle(needsSkill ? AnyShapeStyle(Theme.attentionText)
                                                : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                addSkillButton
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(chosenSkills, id: \.self) { name in
                            skillPill(name)
                        }
                        addSkillButton
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .surface(needsSkill ? Theme.attention.opacity(0.10) : Theme.field, cornerRadius: 10,
                 border: needsSkill ? Theme.attention.opacity(0.45) : Theme.border)
    }

    private func skillPill(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .cardSurface(cornerRadius: 7)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .appContextMenu {
                [
                    .item("Remove", kind: .destructive) { selected.remove(name) },
                    .separator,
                    .item("Manage skills…") { showingSkills = true },
                ]
            }
            .appTooltip { Tooltip(title: name, subtitle: description(of: name)) }
    }

    // Dashed rather than filled, so the control that adds a skill does not read as a
    // skill of its own. The whole pill opens the menu, not just the sign.
    private var addSkillButton: some View {
        HStack(spacing: 5) {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
            Text("Add")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .appMenu {
            TroubleshootSkills.menu(skills, for: agent, selected: $selected) {
                showingSkills = true
            }
        }
        .appTooltip("Add a skill to the diagnosis")
        .accessibilityLabel("Add skill")
    }

    // Amber is for something to put right: no skill is installed, or none of the ones
    // that are has been picked. While the installed set is still being read there is
    // nothing to put right yet.
    private var needsSkill: Bool {
        chosenSkills.isEmpty && skills.hasLoaded && !skills.isRefreshing
    }

    private var emptySkillsMessage: String {
        guard skills.hasLoaded, !skills.isRefreshing else {
            return "Reading the skills \(agent.title) has installed…"
        }
        if skills.hostFailure(TroubleshootSkills.host(for: agent)) != nil {
            return "The \(agent.title) plugin status could not be read, so no skill can be offered."
        }
        if availableSkills.isEmpty {
            return "No skill is installed for \(agent.title). The diagnosis runs without one."
        }
        return "No skill picked. The agent diagnoses without any of them."
    }

    private var availableSkills: [SkillMarketplace.Plugin] {
        TroubleshootSkills.available(skills, for: agent)
    }

    private var chosenSkills: [String] {
        TroubleshootSkills.chosen(skills, for: agent, selected: selected)
    }

    private func description(of skill: String) -> String? {
        availableSkills.first { $0.name == skill }?.description
    }
}

// MARK: - Problem and evidence

// What is failing, in the person's own words, with whatever they can already show for it
// docked underneath. Files arrive by drag, by paste or from the file chooser, and the
// three land in the same place. Under the words, the details the agent will start from
// are read back as they are typed, so a pasted id is seen to land. A screen that wants
// its controls on the card's bottom edge hands them in as the footer.
struct TroubleshootProblemEditor: View {
    @Environment(Dictation.self) private var dictation: Dictation?
    @Environment(MenuPresenter.self) private var menus: MenuPresenter?
    @Environment(\.isEnabled) private var isEnabled

    @Binding var problem: String
    @Binding var attachments: [Attachment]
    @Binding var focused: Bool
    var isBrief = false
    var dictationID: UUID? = nil
    var dictationDraft: Binding<SessionComposerStore.Draft>? = nil
    var roots: [String] = []
    var vocabulary: [String] = []
    // The projects the diagnosis covers, so a brief that names one shows it recognised.
    var projects: [String] = []
    var footer: AnyView? = nil

    @State private var dropTargeted = false
    @State private var fieldLink = ComposerFieldLink()
    @State private var dictateShortcut = WindowKeyMonitor([.command, .shift], "d")
    @State private var dictationKeys = DictationKeys()

    private var listening: Bool {
        dictationID.map { dictation?.isListening($0) == true } ?? false
    }

    private var feedback: DictationFeedback? {
        guard let dictation, let dictationID, let dictationDraft else { return nil }
        return DictationFeedback(dictation: dictation, sessionID: dictationID,
                                 draft: dictationDraft, notice: dictation.notice(for: dictationID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            feedback
            editor
        }
        .background {
            if feedback != nil {
                WindowAnchor(monitor: dictateShortcut)
                DictationKeysAnchor(keys: dictationKeys)
            }
        }
        .onChange(of: isEnabled, initial: true) {
            guard feedback != nil else { return }
            dictateShortcut.start {
                guard isEnabled else { return false }
                toggleDictation()
                return true
            }
        }
        .onChange(of: listening, initial: true) { _, live in
            guard let dictation, live else {
                dictationKeys.stop()
                return
            }
            dictationKeys.start(stop: { dictation.stop() }, throwAway: { dictation.throwAway() })
        }
        .onDisappear {
            dictateShortcut.stop()
            dictationKeys.stop()
            if let dictationID { dictation?.leave(dictationID) }
        }
        .onChange(of: problem) { _, text in
            if let dictationID { dictation?.draftEdited(dictationID, text: text) }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextArea(text: $problem,
                         isFocused: $focused,
                         isEnabled: isEnabled,
                         font: .systemFont(ofSize: 13),
                         onSubmit: {},
                         onOversizedPaste: { text in
                             if let attachment = Attachments.fromPastedText(text) { attach([attachment]) }
                         },
                         onRecallUp: nil, onRecallDown: nil,
                         highlightsKeyword: false,
                         onSuggestionKey: nil, onCommandKey: nil,
                         onDropFiles: { attach(Attachments.fromDrop($0)) },
                         onFileDragTargeted: { dropTargeted = $0 },
                         readOnly: listening,
                         marks: marks,
                         onMarkClick: showWordMenu,
                         link: fieldLink,
                         submitsOnReturn: false,
                         accessibilityLabel: "Problem description",
                         animatesKeyword: false,
                         onHeightChange: { _ in })
                    .padding(.horizontal, 5)
                    .padding(10)
                    .frame(height: isBrief ? 174 : 120)
                if problem.isEmpty {
                    Text("Describe what is failing, what you expected, and anything you already checked. Paste a traceId or a Grafana trace link and the agent starts from that trace.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }

            recognisedRow

            Divider().overlay(Theme.hairline)

            HStack(spacing: 10) {
                if attachments.isEmpty {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(dropTargeted ? "Drop files here" : "Drag or paste files here, or add them from Finder")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(attachments) { attachment in
                                AttachmentChip(url: attachment.url) {
                                    attachments.removeAll { $0.id == attachment.id }
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
                Spacer(minLength: 8)
                if let dictation, let dictationID, dictationDraft != nil {
                    DictationMicButton(live: listening,
                                       preparing: dictation.isPreparing(dictationID),
                                       blocked: dictation.notice(for: dictationID).isMicrophoneBlocked,
                                       level: dictation.level,
                                       startedAt: dictation.startedAt,
                                       download: dictation.notice(for: dictationID).downloadFraction,
                                       action: toggleDictation)
                }
                Button(action: chooseFiles) {
                    HStack(spacing: 5) {
                        Image(systemName: "paperclip")
                        Text(isBrief ? "Add evidence" : "Add files")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .fieldSurface(cornerRadius: 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverLift()
            }
            .padding(10)

            if let footer {
                Divider().overlay(Theme.hairline)
                footer
                    .background(UnevenRoundedRectangle(bottomLeadingRadius: 11,
                                                       bottomTrailingRadius: 11)
                        .fill(Theme.sunken))
            }
        }
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .stroke(listening ? Theme.listenEdge : dropTargeted || focused ? Theme.accent : Theme.border,
                    lineWidth: dropTargeted ? 2 : 1))
        .dropDestination(for: URL.self) { urls, _ in
            attach(Attachments.fromDrop(urls))
            return true
        } isTargeted: { dropTargeted = $0 }
        // Only while the description has the cursor: a screen that also holds a plain
        // text field would otherwise steal a path pasted into it as a file.
        .pasteAttachments(enabled: focused) { attach($0) }
        .onChange(of: attachments) { old, new in
            guard let window = NSApp?.keyWindow else { return }
            let added = new.filter { item in !old.contains { $0.id == item.id } }
            let removed = old.filter { item in !new.contains { $0.id == item.id } }
            let message = [
                added.isEmpty ? nil : "Evidence added: " + added.map { $0.url.lastPathComponent }.joined(separator: ", "),
                removed.isEmpty ? nil : "Evidence removed: " + removed.map { $0.url.lastPathComponent }.joined(separator: ", ")
            ].compactMap { $0 }.joined(separator: ". ")
            NSAccessibility.post(element: window, notification: .announcementRequested,
                                 userInfo: [.announcement: message,
                                            .priority: NSAccessibilityPriorityLevel.low.rawValue])
        }
    }

    // What the agent will start from, as chips, or a hint at what would show here. Read
    // off the text on every keystroke, so a pasted trace id lands as a chip at once.
    private var recognisedRow: some View {
        let details = TroubleshootRecognised.details(in: problem, projects: projects)
        return HStack(spacing: 6) {
            if details.isEmpty {
                Text("Paste a trace id, a Grafana link or a time and it shows up here.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            } else {
                Text("The agent starts from")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(details) { detail in
                            HStack(spacing: 5) {
                                Image(systemName: detail.icon)
                                    .font(.system(size: 9.5, weight: .semibold))
                                Text(detail.label)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .surface(Theme.accent.opacity(0.09), cornerRadius: 7,
                                     border: Theme.accent.opacity(0.22))
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 24)
        .padding(.horizontal, 15)
        .padding(.bottom, 10)
        .motion(Motion.reveal, value: details)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(details.isEmpty
                            ? "No trace id, link or time recognised yet"
                            : "The agent starts from " + details.map(\.label).joined(separator: ", "))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var marks: ComposerMarks {
        guard let dictation, let dictationID else { return ComposerMarks() }
        return listening
            ? ComposerMarks(tentative: dictation.tentative)
            : ComposerMarks(unsure: dictation.review(dictationID)?.unsure.map(\.range) ?? [])
    }

    private func toggleDictation() {
        guard isEnabled, let dictation, let dictationID, let dictationDraft else { return }
        let link = fieldLink
        dictation.toggle(DictationRequest(
            sessionID: dictationID, draft: dictationDraft,
            caret: link.caret ?? (problem as NSString).length,
            roots: roots, vocabulary: vocabulary,
            placeCaret: { location in
                focused = true
                link.placeCaret(location)
            }))
    }

    private func showWordMenu(_ index: Int, at frame: CGRect) {
        guard let dictationID, let words = dictation?.review(dictationID)?.unsure,
              words.indices.contains(index), let feedback else { return }
        menus?.show(feedback.wordMenu(words[index]),
                    at: CGPoint(x: frame.minX, y: frame.minY - 4),
                    verticalAttachment: .control(edge: .top, oppositeY: frame.maxY + 4))
    }

    private func chooseFiles() {
        let urls = FilePicker.chooseFiles(prompt: "Attach",
                                          message: "Choose files that help explain the problem.")
        attach(urls.map(Attachment.init(url:)))
    }

    private func attach(_ found: [Attachment]) {
        for item in found where !attachments.contains(where: { $0.url == item.url }) {
            attachments.append(item)
        }
        focused = true
    }
}

// MARK: - Environment

// The deployments the site file names. A dangerous one leads with an amber dot, so the
// consequence is on the option rather than only in the notice it brings with it.
struct TroubleshootEnvironmentPills: View {
    @Binding var environment: TroubleshootEnvironment

    var body: some View {
        HStack(spacing: 6) {
            ForEach(TroubleshootEnvironment.all()) { option in
                ChoicePill(title: option.title,
                           selected: environment == option,
                           dot: option.isDangerous ? Theme.attention : nil) {
                    environment = option
                }
                .accessibilityHint(option.isDangerous
                                   ? "Live deployment. The diagnosis stays read-only."
                                   : "")
            }
        }
    }
}

// MARK: - MCP servers

enum TroubleshootMCPState: Equatable {
    case ready
    case checking
    case unavailable(TroubleshootMCPConfiguration)

    // Whether the servers the diagnosis promises are really registered with the agent it
    // will run on. Until the check has been asked for it counts as still running, so a
    // start cannot slip through the gap before the first answer.
    static func resolve(enabled: Bool, servers: [Server], hasStartedCheck: Bool,
                        isRefreshing: Bool, registeredNames: Set<String>,
                        disabledNames: Set<String>) -> Self {
        guard enabled, !servers.isEmpty else { return .ready }
        guard hasStartedCheck, !isRefreshing else { return .checking }

        let configuration = TroubleshootMCPConfiguration(
            requiredNames: servers.map(\.name),
            registeredNames: registeredNames,
            disabledNames: disabledNames)
        return configuration.isAvailable ? .ready : .unavailable(configuration)
    }

    // The same question asked of a live agent. Codex and Copilot can have a server
    // registered but switched off, and both read their registry in the background.
    @MainActor
    static func resolve(agent: AgentKind, enabled: Bool, servers: [Server],
                        hasStartedCheck: Bool,
                        claude: ClaudeCodeManager, codex: CodexCodeManager,
                        copilot: CopilotCodeManager) -> Self {
        switch agent {
        case .claudeCode:
            resolve(enabled: enabled, servers: servers, hasStartedCheck: hasStartedCheck,
                    isRefreshing: false,
                    registeredNames: Set(claude.entries.keys), disabledNames: [])
        case .copilot:
            resolve(enabled: enabled, servers: servers, hasStartedCheck: hasStartedCheck,
                    isRefreshing: copilot.isRefreshing,
                    registeredNames: Set(copilot.entries.keys),
                    disabledNames: Set(copilot.entries.compactMap {
                        $0.value.enabled ? nil : $0.key
                    }))
        case .codex:
            resolve(enabled: enabled, servers: servers, hasStartedCheck: hasStartedCheck,
                    isRefreshing: codex.isRefreshing,
                    registeredNames: Set(codex.entries.keys),
                    disabledNames: Set(codex.entries.compactMap {
                        $0.value.enabled ? nil : $0.key
                    }))
        }
    }

    func configurationLabel(for name: String) -> String {
        switch self {
        case .checking: return "Checking"
        case .ready: return "Configured"
        case .unavailable(let configuration):
            if configuration.missing.contains(name) { return "Not configured" }
            if configuration.disabled.contains(name) { return "Disabled" }
            return "Configured"
        }
    }

    func message(for agent: AgentKind) -> String? {
        guard case .unavailable(let configuration) = self else { return nil }
        var messages: [String] = []
        if !configuration.missing.isEmpty {
            messages.append("Not configured for \(agent.title): \(configuration.missing.joined(separator: ", ")).")
        }
        if !configuration.disabled.isEmpty {
            messages.append("Disabled in \(agent.title): \(configuration.disabled.joined(separator: ", ")).")
        }
        messages.append("Sync the listed servers in MCP Servers before diagnosing.")
        return messages.joined(separator: " ")
    }
}

// Client registration describes configuration, not live connectivity. Only servers
// included in the chosen environment are offered here.
struct TroubleshootMCPOptions: View {
    let agent: AgentKind
    let environment: TroubleshootEnvironment
    let managedServers: [Server]
    let environmentServers: [Server]
    let state: TroubleshootMCPState
    @Binding var enabled: Bool

    private var helper: String {
        if !enabled { return "Use project files and attached evidence." }
        if managedServers.isEmpty { return "Use any servers configured for the selected agent." }
        return "\(counted(environmentServers.count, "managed server")) available for \(environment.title)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MCP servers").font(.system(size: 13, weight: .semibold))
            Toggle(isOn: $enabled) {
                Text(enabled ? "Enabled for this diagnosis" : "Disabled for this diagnosis")
                    .font(.system(size: 13))
            }
            .toggleStyle(.appSwitch)
            .frame(height: 39, alignment: .leading)
            .accessibilityLabel("Enable MCP servers")
            .accessibilityHint(helper)
            Text(helper)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch state {
            case .ready:
                EmptyView()
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking \(agent.title) MCP configuration...")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            case .unavailable:
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .padding(.top, 1)
                    Text(state.message(for: agent) ?? "")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.deletion)
            }
        }
        .onChange(of: state) { _, state in
            guard let message = state.message(for: agent),
                  let window = NSApp?.keyWindow else { return }
            NSAccessibility.post(element: window, notification: .announcementRequested,
                                 userInfo: [.announcement: message,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
}

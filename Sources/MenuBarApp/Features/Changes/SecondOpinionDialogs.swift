import AppKit
import SwiftUI

// The second opinion lives in three dialogs: asking, opened from the session header, and
// watching the reviewers work and going through what they found, opened from the same
// control in the header once it has been asked. The review bar only says what will be sent.

// What a second opinion is asked to read.
enum SecondOpinionScopeChoice: Hashable {
    case all, file, sinceReview
}

// Where the second opinion stands, which is what the header's control says and opens.
enum SecondOpinionStatus: Equatable {
    case ask
    case reviewing(agents: [AgentKind], started: Date, pending: Int)
    case failed(AgentKind)
    case ready(agents: [AgentKind], pending: Int)
    case settled(kept: Int, dismissed: Int)

    @MainActor
    init(reviews: ReviewCommentStore, sessionID: UUID) {
        self.init(runs: reviews.runs(sessionID),
                  findings: reviews.comments(sessionID).filter { $0.reviewer != nil },
                  dismissed: reviews.dismissedFindings(sessionID).count)
    }

    init(runs: [SecondOpinionRun], findings: [ReviewComment], dismissed: Int) {
        let pending = findings.filter(\.isPending)
        let running = runs.filter(\.isRunning)
        if !running.isEmpty {
            self = .reviewing(agents: unique(running.map(\.agent)), started: running.map(\.started).min() ?? Date(),
                              pending: pending.count)
        } else if let failed = runs.first(where: { if case .failed = $0.state { true } else { false } }),
                  pending.isEmpty {
            self = .failed(failed.agent)
        } else if !pending.isEmpty {
            let voices = Set(pending.flatMap(\.reviewers))
            self = .ready(agents: AgentKind.allCases.filter(voices.contains), pending: pending.count)
        } else if !runs.isEmpty {
            self = .settled(kept: findings.count { !$0.isPending }, dismissed: dismissed)
        } else {
            self = .ask
        }
    }
}

enum SecondOpinionFindings {
    // Findings by file, the file with the most serious one first, and inside a file the
    // most serious first, then by line.
    static func ordered(_ findings: [ReviewComment]) -> [ReviewComment] {
        func rank(_ comment: ReviewComment) -> Int {
            comment.severity.flatMap { ReviewComment.Severity.allCases.firstIndex(of: $0) }
                ?? ReviewComment.Severity.allCases.count
        }
        var files: [String] = []
        var byFile: [String: [ReviewComment]] = [:]
        for finding in findings {
            let key = ReviewRound.fileKey(root: finding.root, path: finding.path)
            if byFile[key] == nil { files.append(key) }
            byFile[key, default: []].append(finding)
        }
        let sortedFiles = files.enumerated().sorted { a, b in
            let left = byFile[a.element]!.map(rank).min()!
            let right = byFile[b.element]!.map(rank).min()!
            return left == right ? a.offset < b.offset : left < right
        }.map(\.element)
        return sortedFiles.flatMap { key in
            byFile[key]!.sorted { rank($0) == rank($1) ? $0.line < $1.line : rank($0) < rank($1) }
        }
    }

    // The next finding still to decide after the given one, going round to the start.
    static func next(after id: UUID?, in list: [ReviewComment], undecided: (ReviewComment) -> Bool) -> UUID? {
        let start = list.firstIndex { $0.id == id } ?? -1
        let rotated = list[(start + 1)...] + list[..<max(0, start + 1)]
        return rotated.first(where: undecided)?.id
    }
}

// Each agent once, in the order given. Two seats can run the same agent on two models.
private func unique(_ agents: [AgentKind]) -> [AgentKind] {
    var seen = Set<AgentKind>()
    return agents.filter { seen.insert($0).inserted }
}

private func names(_ agents: [AgentKind]) -> String {
    let titles = agents.map(\.title)
    guard titles.count > 1 else { return titles.first ?? "" }
    return titles.dropLast().joined(separator: ", ") + " and " + titles.last!
}

@MainActor
private func announce(_ text: String) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                         userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
}

func clock(from start: Date, to end: Date) -> String {
    let seconds = max(0, Int(end.timeIntervalSince(start)))
    return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
}

// A small turning arc, the sign a reviewer is still at work. Drawn rather than an
// NSProgressIndicator so it can sit on an avatar at any size. Still for reduced motion.
private struct ReviewerSpinner: View {
    var size: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                Image(systemName: "clock").font(.system(size: size * 0.7, weight: .bold))
                    .foregroundStyle(Theme.accent)
            } else {
                LoopSpinner(colour: Theme.accent, size: size * 0.76)
            }
        }
        .frame(width: size, height: size)
        .background(Circle().fill(Theme.card))
        .accessibilityHidden(true)
    }
}

private struct BadgedAvatar: View {
    let agent: AgentKind
    var size: CGFloat = 20
    var badge: Badge?

    enum Badge { case working, done }

    var body: some View {
        ReviewAvatar(agent: agent, size: size)
            .overlay(alignment: .bottomTrailing) {
                switch badge {
                case .working:
                    ReviewerSpinner(size: max(9, size * 0.45)).offset(x: size * 0.15, y: size * 0.15)
                case .done:
                    Image(systemName: "checkmark").font(.system(size: size * 0.24, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: size * 0.44, height: size * 0.44)
                        .background(Circle().fill(Theme.dotOn))
                        .overlay(Circle().stroke(Theme.card, lineWidth: 2))
                        .offset(x: size * 0.15, y: size * 0.15)
                        .accessibilityHidden(true)
                case nil:
                    EmptyView()
                }
            }
    }
}

// MARK: - Shared frame

// The header, body and footer every second opinion dialog is drawn in.
private struct DialogFrame<Trailing: View, Content: View, Footer: View>: View {
    let title: String
    let message: String
    // Escape closes the dialog unless something inside it, such as an edit, wants the key.
    var escapeCloses = true
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    @Environment(DialogPresenter.self) private var dialogs

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.serif(20, .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(message).font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                trailing()
            }
            .padding(.horizontal, 22).padding(.top, 20)
            content()
            HStack(spacing: 8) { footer() }
                .padding(.leading, 22).padding(.trailing, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.field)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .background(Theme.card)
        // No dialog draws a close button, so Escape is the way out that every one of
        // them shares, held by a button nobody sees.
        .background {
            Button { dialogs.dismiss() } label: { EmptyView() }
                .buttonStyle(.plain)
                .keyboardShortcut(escapeCloses ? .cancelAction : nil)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}

private struct SectionTitle: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 12.5, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - 1. Ask

// The ask dialog, the same for changes, a plan, an answer or a design. It holds a lineup
// of up to four seats, each an agent on its own model and effort, which a menu cannot.
// Every seat says how independent it is of the agent that wrote the work, in a meter and
// in words; that is advice, never a rule, so a seat on the author's own model is allowed
// and only flagged. What differs between subjects is the wording and what a reviewer
// looks for and reads, which the caller passes in.
struct SecondOpinionAskView<Choices: View>: View {
    let message: String
    let safety: String
    let author: SecondOpinion.Reviewer
    // What the author did, after its name in the lineup's top row.
    var authorDid = "wrote these changes"
    let installed: [AgentKind]
    var running: Set<SecondOpinion.Reviewer> = []
    @Binding var lineup: [SecondOpinion.Reviewer]
    // Nothing is ticked to look for, so there is nothing to ask for yet.
    var needsFocus = false
    @ViewBuilder let choices: Choices
    let ask: () -> Void

    @Environment(DialogPresenter.self) private var dialogs
    @Environment(SessionRunner.self) private var runner
    @State private var usual = Preferences.secondOpinionLineup()

    private var chosen: [SecondOpinion.Reviewer] {
        var seen = Set<SecondOpinion.Reviewer>()
        return lineup.filter { !running.contains($0) && seen.insert($0).inserted }
    }

    var body: some View {
        DialogFrame(title: "Ask for a second opinion", message: message) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionTitle(title: "Reviewers")
                        Spacer(minLength: 0)
                        if !lineup.isEmpty && lineup == usual {
                            Label("Your usual reviewers", systemImage: "checkmark")
                                .font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
                        } else if !lineup.isEmpty {
                            InlineLink(title: "Make this my usual", size: 11.5) {
                                Preferences.setSecondOpinionLineup(lineup)
                                usual = lineup
                            }
                            .appTooltip("Open with these reviewers, models and effort next time")
                        }
                    }
                    reviewers
                }
                choices
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.shield").font(.system(size: 12)).foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    Text(safety)
                        .font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 18)
        } footer: {
            footer
        }
        .onAppear {
            // Another agent than the author's own, on its usual model, is the most
            // independent first seat there is.
            if lineup.isEmpty, let agent = installed.first(where: { $0 != author.agent }) ?? installed.first {
                add(agent)
            }
        }
        .task { for agent in installed { await runner.discoverModels(for: agent) } }
    }

    // MARK: Pieces

    // The author on top, then each seat, then the way to add one, all in one box split
    // by hairlines, so each seat reads against the author it is measured from.
    private var reviewers: some View {
        VStack(spacing: 0) {
            authorRow
            ForEach(Array(lineup.enumerated()), id: \.offset) { index, seat in
                hairline
                seatRow(seat, at: index)
            }
            hairline
            if installed.isEmpty {
                (Text("No agent is installed to ask. ").fontWeight(.semibold).foregroundColor(.primary)
                 + Text("Install \(otherAgents), then open this again."))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 14)
            } else {
                addReviewer
            }
        }
        .background(Theme.field.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }

    private var hairline: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    private var otherAgents: String {
        let others = AgentKind.allCases.filter { $0 != author.agent }.map(\.title)
        guard others.count > 1 else { return others.first ?? "an agent" }
        return others.dropLast().joined(separator: ", ") + " or " + others.last!
    }

    private var authorRow: some View {
        HStack(spacing: 10) {
            ReviewAvatar(agent: author.agent, size: 22).opacity(0.8)
                .frame(width: 26)
            (Text(author.agent.title).fontWeight(.semibold).foregroundColor(.primary) + Text(" " + authorDid))
                .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(authorSetting).font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
        .padding(.horizontal, 12).frame(height: 42)
        .background(Theme.sunken)
        .accessibilityElement(children: .combine)
        .appTooltip("Each reviewer's independence is measured against this")
    }

    private var authorSetting: String {
        let model = author.model.map { runner.modelTitle($0) } ?? "Its usual model"
        guard let effort = author.effort else { return model }
        return model + ", " + runner.effortTitle(effort, for: author.agent, model: author.model).lowercased() + " effort"
    }

    private func seatRow(_ seat: SecondOpinion.Reviewer, at index: Int) -> some View {
        let independence = SecondOpinion.independence(of: seat, from: author)
        let busy = running.contains(seat)
        let flagged = independence == .sameModel
        return HStack(spacing: 10) {
            ReviewAvatar(agent: seat.agent, size: 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(seat.agent.title).font(.system(size: 12.5, weight: .semibold))
                    if seat.agent == author.agent {
                        Text("fresh start, without this conversation")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondaryText)
                            .truncationMode(.tail)
                    }
                }
                .lineLimit(1)
                HStack(spacing: 7) {
                    IndependenceMeter(independence: independence)
                    Text(independence.line)
                        .font(.system(size: 11))
                        .foregroundStyle(flagged ? Theme.attentionText : Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 6)
            if busy {
                Text("Reviewing now").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 6) {
                    modelMenu(seat, at: index)
                    effortMenu(seat, at: index)
                    GlyphButton(icon: "xmark", side: 22) { lineup.remove(at: index) }
                        .appTooltip("Remove")
                        .accessibilityLabel("Remove \(seat.label(modelTitle: runner.modelTitle))")
                }
            }
        }
        .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 10)
        .background(flagged ? Theme.attention.opacity(0.08) : .clear)
        .opacity(busy ? 0.6 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(seat.label(modelTitle: runner.modelTitle) + (busy ? ", reviewing now" : ""))
    }

    private func modelMenu(_ seat: SecondOpinion.Reviewer, at index: Int) -> some View {
        let title = seat.model.map { runner.modelTitle($0) } ?? "Default"
        return SeatPill { Text(title) }
            .appMenu {
                runner.modelOptions(for: seat.agent).map { option in
                    var changed = seat
                    changed.model = option.id
                    let words = SecondOpinion.independence(of: changed, from: author)
                    return MenuEntry.item(option.title, checked: seat.model == option.id,
                                          subtitle: option.detail,
                                          detail: words == .sameModel ? "Author's model" : nil,
                                          detailColour: Theme.attentionText) {
                        changed.effort = runner.validEffort(seat.effort, for: seat.agent, model: option.id)
                        lineup[index] = changed
                    }
                }
            }
            .appTooltip("The model \(seat.agent.title) reviews on")
            .accessibilityLabel("Model: \(title)")
    }

    private func effortMenu(_ seat: SecondOpinion.Reviewer, at index: Int) -> some View {
        let levels = runner.effortOptions(for: seat.agent, model: seat.model).compactMap(\.id)
        let title = seat.effort.map { runner.effortTitle($0, for: seat.agent, model: seat.model) } ?? "Default"
        return SeatPill {
            EffortMeter(lit: EffortMeter.lit(for: seat.effort, among: levels), height: 11)
            Text(title)
        }
        .appMenu {
            [MenuEntry.item("Default", meter: 0, checked: seat.effort == nil,
                            subtitle: "Whatever \(seat.agent.title) is set to use",
                            detail: "about \(SecondOpinion.minutes(for: nil)) min") {
                lineup[index].effort = nil
            }, .separator] + levels.map { level in
                MenuEntry.item(runner.effortTitle(level, for: seat.agent, model: seat.model),
                               meter: EffortMeter.lit(for: level, among: levels),
                               checked: seat.effort == level,
                               detail: "about \(SecondOpinion.minutes(for: level)) min") {
                    lineup[index].effort = level
                }
            }
        }
        .appTooltip("How long it thinks. More effort uses more of your plan.")
        .accessibilityLabel("Effort: \(title)")
    }

    // The last row of the box. `appMenu` brings the button itself, so the row is only
    // its label.
    private var addReviewer: some View {
        let full = lineup.count >= SecondOpinion.Reviewer.maxSeats
        return HStack(spacing: 10) {
            Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                .frame(width: 26)
            Text(full ? "Four reviewers at most" : "Add a reviewer").font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 8)
            if !full {
                Text(lineup.count > 1 ? "They read side by side, so more costs no extra time" : "Up to four")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(full ? Color.secondary.opacity(0.7) : Theme.accent)
        .padding(.horizontal, 12).frame(height: 38)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .hoverFill(cornerRadius: 0)
        .appMenu {
            installed.map { agent in
                MenuEntry.item(agent == author.agent ? agent.title + " fresh start" : agent.title,
                               image: nil, subtitle: agent == author.agent
                                ? "The author's agent without this conversation" : agent.vendor) {
                    add(agent)
                }
            }
        }
        .disabled(full)
        .appTooltip(full ? "Four reviewers at most" : "Add another agent, or the same one on another model")
        .accessibilityLabel(full ? "Four reviewers at most" : "Add a reviewer")
        .accessibilityAddTraits(.isButton)
    }

    // A new seat starts on the agent's own defaults, or on another of its models when
    // that seat is already taken, so two seats are never the same run.
    private func add(_ agent: AgentKind) {
        let defaults = runner.defaults(for: agent)
        let model = runner.validModel(defaults.model, for: agent)
        var seat = SecondOpinion.Reviewer(agent: agent, model: model,
                                          effort: runner.validEffort(defaults.effort, for: agent, model: model))
        if lineup.contains(seat),
           let free = runner.modelOptions(for: agent).first(where: { option in
               !lineup.contains { $0.agent == agent && $0.model == option.id }
           }) {
            seat.model = free.id
            seat.effort = runner.validEffort(seat.effort, for: agent, model: free.id)
        }
        lineup.append(seat)
    }

    @ViewBuilder private var footer: some View {
        let minutes = chosen.map { SecondOpinion.minutes(for: $0.effort) }.max() ?? 0
        Text(installed.isEmpty ? "Install an agent to ask for a review."
             : minutes > 0 ? "About \(minutes) min. You can keep working." : "You can keep working while they read.")
            .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
        Spacer(minLength: 0)
        ActionButton(title: "Cancel", tone: .sunken, height: 32, size: 12.5) { dialogs.dismiss() }
        ActionButton(title: needsFocus ? "Pick what to look for" : askTitle, tone: .green, height: 32, size: 12.5,
                     shortcut: "↩", keyboardShortcut: .defaultAction, action: ask)
            .disabled(chosen.isEmpty || needsFocus)
    }

    private var askTitle: String {
        let agents = Array(NSOrderedSet(array: chosen.map(\.agent.title))) as? [String] ?? []
        if chosen.isEmpty { return "Pick a reviewer" }
        if chosen.count == agents.count && agents.count <= 2 { return "Ask " + agents.joined(separator: " and ") }
        return "Ask \(chosen.count) reviewers"
    }
}

// A titled run of choices in the ask dialog, the way each of its sections reads.
struct SecondOpinionSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: title)
            content
        }
    }
}

// The ask dialog as it opens on a session's changes. It keeps its own choices while it
// is open and hands them over when the person asks.
struct ChangesOpinionAsk: View {
    let author: SecondOpinion.Reviewer
    let installed: [AgentKind]
    let running: Set<SecondOpinion.Reviewer>
    let fileCount: Int
    let fileName: String?
    let canReadSince: Bool
    let ask: ([SecondOpinion.Reviewer], Set<SecondOpinion.Focus>, SecondOpinionScopeChoice) -> Void

    @State private var lineup: [SecondOpinion.Reviewer]
    @State private var focus: Set<SecondOpinion.Focus>
    @State private var scope: SecondOpinionScopeChoice
    @Namespace private var track

    init(author: SecondOpinion.Reviewer, installed: [AgentKind], running: Set<SecondOpinion.Reviewer>,
         lineup: [SecondOpinion.Reviewer], focus: Set<SecondOpinion.Focus>, scope: SecondOpinionScopeChoice,
         fileCount: Int, fileName: String?, canReadSince: Bool,
         ask: @escaping ([SecondOpinion.Reviewer], Set<SecondOpinion.Focus>, SecondOpinionScopeChoice) -> Void) {
        self.author = author
        self.installed = installed
        self.running = running
        self.fileCount = fileCount
        self.fileName = fileName
        self.canReadSince = canReadSince
        self.ask = ask
        _lineup = State(initialValue: lineup)
        _focus = State(initialValue: focus)
        _scope = State(initialValue: scope)
    }

    var body: some View {
        SecondOpinionAskView(
            message: "Agents that did not write these changes read them on their own and leave findings. You decide which ones reach \(author.agent.title).",
            safety: "Reviewers can read files but not change them, and run without your MCP servers. They see the diff, not this conversation.",
            author: author, installed: installed, running: running, lineup: $lineup, needsFocus: focus.isEmpty,
            choices: {
                // Several can be ticked at once, so these are checkboxes; filled pills
                // would read as a choice of one.
                SecondOpinionSection(title: "What to look for") {
                    Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 9) {
                        ForEach(Array(stride(from: 0, to: SecondOpinion.Focus.allCases.count, by: 3)), id: \.self) { start in
                            GridRow {
                                ForEach(SecondOpinion.Focus.allCases.dropFirst(start).prefix(3), id: \.self) { item in
                                    Toggle(isOn: Binding(get: { focus.contains(item) },
                                                         set: { on in if on { focus.insert(item) } else { focus.remove(item) } })) {
                                        Text(item.title).font(.system(size: 12.5))
                                    }
                                    .toggleStyle(.appCheckbox)
                                }
                            }
                        }
                    }
                }
                SecondOpinionSection(title: "Which changes") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 2) {
                            scopePill("All \(counted(fileCount, "file"))", .all)
                            if let fileName { scopePill(fileName, .file) }
                            scopePill("Since your last review", .sinceReview, enabled: canReadSince)
                                .appTooltip(canReadSince ? "Only what changed after the last review was sent"
                                            : "Once you have sent a review, a reviewer can read only what changed after it")
                        }
                        .padding(2)
                        .fieldSurface(cornerRadius: 10)
                        .fixedSize()
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Which changes")
                        if !canReadSince {
                            Text("Since your last review opens up once you send one.")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            },
            ask: { ask(lineup, focus, scope) })
    }

    private func scopePill(_ title: String, _ choice: SecondOpinionScopeChoice, enabled: Bool = true) -> some View {
        ChoicePill(title: title, selected: scope == choice, enabled: enabled, thumb: track) {
            withAnimation(Motion.control) { scope = choice }
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(scope == choice ? .isSelected : [])
    }
}

// MARK: - 2. Progress

struct SecondOpinionProgressView: View {
    let review: ReviewTarget
    let stop: (SecondOpinion.Reviewer) -> Void
    let stopAll: () -> Void
    let lookAt: (SecondOpinion.Reviewer?) -> Void

    @Environment(DialogPresenter.self) private var dialogs

    var body: some View {
        let runs = review.reviews.runs(review.sessionID)
        let running = runs.filter(\.isRunning)
        let findings = review.reviews.findings(review.sessionID)
        let pending = review.reviews.pending(review.sessionID).count { $0.reviewer != nil }
        DialogFrame(title: running.isEmpty ? "Second opinion finished" : "Second opinion in progress",
                    message: !running.isEmpty ? "Findings wait for you as each reviewer finishes."
                        : pending > 0 ? "\(counted(pending, "finding")) came back. Look at them before anything reaches \(review.agent.title)."
                        : "Nothing is waiting to be looked at.") {
            EmptyView()
        } content: {
            VStack(spacing: 8) {
                if runs.isEmpty {
                    Text("No reviewer is at work.").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                }
                ForEach(runs) { run in lane(run, findings: findings) }
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
        } footer: {
            if running.count > 1 {
                InlineLink(title: "Stop all", tint: Color.secondary, action: stopAll)
            }
            Spacer(minLength: 0)
            if !running.isEmpty {
                Text("The review bar keeps count while you work.").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                ActionButton(title: "Keep working", tone: .outlined, height: 32, size: 12.5,
                             keyboardShortcut: .defaultAction) { dialogs.dismiss() }
            } else if pending > 0 {
                ActionButton(title: "Look at \(counted(pending, "finding"))", tone: .green, height: 32, size: 12.5,
                             keyboardShortcut: .defaultAction) { lookAt(nil) }
            } else {
                ActionButton(title: "Close", tone: .outlined, height: 32, size: 12.5,
                             keyboardShortcut: .defaultAction) { dialogs.dismiss() }
            }
        }
    }

    @ViewBuilder private func lane(_ run: SecondOpinionRun, findings: [ReviewComment]) -> some View {
        let name = run.reviewer.label()
        switch run.state {
        case .running:
            laneCard(fill: Theme.card, border: Theme.border) {
                BadgedAvatar(agent: run.agent, size: 36, badge: .working)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(name).font(.system(size: 13, weight: .semibold))
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(clock(from: run.started, to: context.date)).font(.mono(11)).foregroundStyle(.tertiary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(run.recent.enumerated()), id: \.offset) { index, line in
                            Text(line).font(.mono(11.5))
                                .foregroundStyle(index == run.recent.count - 1 ? Color.primary : Color.secondary)
                                .opacity(index == run.recent.count - 1 ? 1 : 0.55)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                Spacer(minLength: 0)
                ActionButton(title: "Stop", tone: .sunken, height: 26, size: 11.5, icon: "stop.fill") { stop(run.reviewer) }
                    .accessibilityLabel("Stop \(name)")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(name) is reviewing. \(run.activity)")
        case .finished(let found):
            let mine = findings.filter { $0.raised(by: run.reviewer) }
            laneCard(fill: Theme.dotOn.opacity(0.05), border: Theme.dotOn.opacity(0.25)) {
                BadgedAvatar(agent: run.agent, size: 36, badge: .done)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(name).font(.system(size: 13, weight: .semibold))
                        Text("took " + clock(from: run.started, to: run.ended ?? Date()))
                            .font(.mono(11)).foregroundStyle(.tertiary)
                    }
                    Group {
                        if found > 0 { Text("Found ") + Text("\(found)").fontWeight(.semibold).foregroundColor(.primary) + Text(" worth raising") }
                        else { Text("Nothing worth raising") }
                    }
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    let tally = ReviewComment.Severity.allCases.map { severity in (severity, mine.count { $0.severity == severity }) }
                        .filter { $0.1 > 0 }
                    if !tally.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(tally, id: \.0) { severity, count in SeverityChip(severity: severity, count: count) }
                        }
                        .padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
                if found > 0 {
                    ActionButton(title: "Look at them", tone: .outlined, height: 26, size: 11.5) { lookAt(run.reviewer) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(name) finished with \(counted(found, "finding"))")
        case .failed(let message):
            laneCard(fill: Theme.warningBackground, border: Theme.warningText.opacity(0.25)) {
                ReviewAvatar(agent: run.agent, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(name) could not finish").font(.system(size: 13, weight: .semibold))
                    Text(message).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.warningText)
                Spacer(minLength: 0)
                ActionButton(title: "Try again", tone: .outlined, height: 26, size: 11.5, icon: "arrow.clockwise") {
                    review.reviews.retrySecondOpinion(review.sessionID, reviewer: run.reviewer)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(name) could not finish. \(message)")
        }
    }

    private func laneCard<Content: View>(fill: Color, border: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(fill, cornerRadius: 12, border: border)
    }
}

// MARK: - 3. Findings

struct SecondOpinionFindingsView: View {
    let review: ReviewTarget

    @Environment(DialogPresenter.self) private var dialogs
    @State private var selected: UUID?
    @State private var editing = false
    @State private var draft = ""
    @State private var keys = WindowKeyHandler()
    @FocusState private var editorFocused: Bool

    init(review: ReviewTarget, selected: UUID?) {
        self.review = review
        _selected = State(initialValue: selected)
    }

    private enum Decision { case kept, dismissed }

    private var store: ReviewCommentStore { review.reviews }
    private var list: [ReviewComment] { SecondOpinionFindings.ordered(store.findings(review.sessionID)) }
    private var dismissedIDs: Set<UUID> { Set(store.dismissedFindings(review.sessionID).map(\.id)) }

    private func decision(_ finding: ReviewComment, dismissed: Set<UUID>) -> Decision? {
        dismissed.contains(finding.id) ? .dismissed : finding.isPending ? nil : .kept
    }

    var body: some View {
        let list = list
        let dismissed = dismissedIDs
        let kept = list.count { decision($0, dismissed: dismissed) == .kept }
        let gone = dismissed.count { id in list.contains { $0.id == id } }
        let left = list.count - kept - gone
        let voices = Set(list.flatMap(\.reviewers))
        let running = unique(store.runs(review.sessionID).filter(\.isRunning).map(\.agent))
        DialogFrame(title: voices.isEmpty ? "Findings" : "Findings from " + names(AgentKind.allCases.filter(voices.contains)),
                    message: "Keep what you agree with. Kept findings join your review, and nothing reaches \(review.agent.title) until you send it.",
                    escapeCloses: false) {
            if !list.isEmpty { progress(list, dismissed: dismissed, decided: kept + gone) }
        } content: {
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if !running.isEmpty { waitingNote(running) }
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, finding in
                                if index == 0 || ReviewRound.fileKey(root: list[index - 1].root, path: list[index - 1].path)
                                    != ReviewRound.fileKey(root: finding.root, path: finding.path) {
                                    groupHeader(finding)
                                }
                                row(finding, decision: decision(finding, dismissed: dismissed))
                                    .id(finding.id)
                            }
                        }
                        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 14)
                    }
                    .onChange(of: selected) { _, id in
                        if let id { withAnimation(Motion.reveal) { proxy.scrollTo(id) } }
                    }
                }
                .frame(width: 318)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Findings")
                Rectangle().fill(Theme.hairline).frame(width: 1)
                detail(list, dismissed: dismissed, running: running)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 470)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            .padding(.top, 16)
        } footer: {
            Text(left > 0 ? "\(kept) kept, \(gone) dismissed, \(left) left. Anything left stays here for later."
                 : "\(kept) kept and added to your review. \(gone) dismissed.")
                .font(.system(size: 11.5)).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            ActionButton(title: left > 0 ? "Finish later" : "Done", tone: left > 0 ? .outlined : .green,
                         height: 32, size: 12.5) { dialogs.dismiss() }
        }
        .background(WindowKeyAnchor(handler: keys))
        .onAppear {
            if selected == nil || !list.contains(where: { $0.id == selected }) {
                selected = SecondOpinionFindings.next(after: nil, in: list) { decision($0, dismissed: dismissed) == nil }
                    ?? list.first?.id
            }
            keys.start { handleKey($0) }
        }
        .onDisappear { keys.stop() }
        .onChange(of: list.map(\.id)) { _, ids in
            // A reviewer still at work can bring the first findings in while this is open.
            if selected == nil || !ids.contains(selected!) {
                selected = SecondOpinionFindings.next(after: nil, in: self.list) { decision($0, dismissed: dismissedIDs) == nil }
            }
        }
    }

    private func progress(_ list: [ReviewComment], dismissed: Set<UUID>, decided: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(decided) of \(list.count) looked at").font(.system(size: 12)).foregroundStyle(.secondary)
            if list.count <= 12 {
                HStack(spacing: 3) {
                    ForEach(list) { finding in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(segmentColour(decision(finding, dismissed: dismissed)))
                            .frame(width: 18, height: 5)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .padding(.top, 6)
        .fixedSize()
    }

    private func segmentColour(_ decision: Decision?) -> Color {
        switch decision {
        case .kept: Theme.dotOn
        case .dismissed: Color.secondary.opacity(0.5)
        case nil: Theme.field
        }
    }

    private func waitingNote(_ running: [AgentKind]) -> some View {
        HStack(spacing: 8) {
            ReviewerSpinner(size: 11)
            Text(running.count == 1 ? "\(running[0].title) is still reading. Its findings will show up here."
                 : "\(names(running)) are still reading. Their findings will show up here.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11.5)).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.sunken))
        .padding(.horizontal, 4).padding(.top, 4).padding(.bottom, 8)
    }

    private func groupHeader(_ finding: ReviewComment) -> some View {
        let folder = (finding.path as NSString).deletingLastPathComponent
        return HStack(spacing: 6) {
            Text((finding.path as NSString).lastPathComponent).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if !folder.isEmpty {
                Text(folder).font(.mono(10.5)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
        }
        .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ finding: ReviewComment, decision: Decision?) -> some View {
        let isSelected = finding.id == selected
        return Button {
            selected = finding.id
            editing = false
        } label: {
            HStack(alignment: .top, spacing: 8) {
                severityIcon(finding.severity).frame(width: 16).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.body.replacingOccurrences(of: "`", with: ""))
                        .font(.system(size: 12)).lineLimit(2)
                        .strikethrough(decision == .dismissed, color: Color.secondary.opacity(0.5))
                        .foregroundStyle(decision == .dismissed ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(finding.onFile ? "whole file" : "line \(finding.line)").font(.mono(10.5)).foregroundStyle(.tertiary)
                }
                Text(decision == .kept ? "Kept" : decision == .dismissed ? "Dismissed" : "")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(decision == .kept ? Theme.dotOn : Color.secondary)
                    .padding(.top, 1)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Theme.accent.opacity(0.09) : .clear))
            .overlay(alignment: .leading) {
                if isSelected { Rectangle().fill(Theme.accent).frame(width: 2).padding(.vertical, 2) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: 8)
        .accessibilityLabel(finding.spokenName + ". " + finding.body
                            + (decision == .kept ? ". Kept" : decision == .dismissed ? ". Dismissed" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private func severityIcon(_ severity: ReviewComment.Severity?) -> some View {
        switch severity {
        case .must: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Theme.warningText)
        case .should: Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(Theme.attention)
        case .look: Image(systemName: "eye").font(.system(size: 10)).foregroundStyle(.tertiary)
        case nil: Image(systemName: "text.bubble").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private func detail(_ list: [ReviewComment], dismissed: Set<UUID>, running: [AgentKind]) -> some View {
        if let finding = list.first(where: { $0.id == selected }) {
            let decided = decision(finding, dismissed: dismissed)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        ReviewAvatars(comment: finding, size: 24)
                        Text(finding.voices.first?.name ?? "").font(.system(size: 13, weight: .semibold))
                        if let other = finding.also.first {
                            Text("and \(other.name) raised this").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if let severity = finding.severity { SeverityChip(severity: severity) }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                        Text(finding.path)
                        Text(finding.onFile ? "whole file" : "line \(finding.line)").foregroundStyle(.tertiary)
                    }
                    .font(.mono(11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    codeExcerpt(finding)
                    if editing {
                        TextField("What should change", text: $draft, axis: .vertical)
                            .lineLimit(4...10)
                            .appTextField(size: 14)
                            .focused($editorFocused)
                            .onExitCommand { editing = false }
                            .accessibilityLabel("Edit the finding")
                    } else {
                        ReviewText(text: finding.body, size: 15)
                            .textSelection(.enabled)
                    }
                    ForEach(Array(finding.also.enumerated()), id: \.offset) { _, voice in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                ReviewAvatar(agent: voice.agent, size: 16)
                                Text(voice.name).fontWeight(.semibold).foregroundStyle(.primary)
                                Text("on the same lines")
                            }
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            ReviewText(text: voice.body, size: 12.5).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 2) }
                    }
                    actions(finding, decision: decided, list: list)
                }
                .padding(.horizontal, 24).padding(.vertical, 20)
            }
        } else {
            VStack(spacing: 6) {
                if list.isEmpty && !running.isEmpty {
                    ReviewerSpinner(size: 22)
                    Text("Waiting for the first findings").font(.serif(17, .semibold))
                    Text("They show up here as soon as a reviewer finishes.")
                } else {
                    Image(systemName: "checkmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.dotOn)
                        .frame(width: 44, height: 44).background(Circle().fill(Theme.dotOn.opacity(0.12)))
                    Text("Nothing left to look at").font(.serif(17, .semibold)).foregroundStyle(.primary).padding(.top, 4)
                    Text("Kept findings are in your review, next to your own comments.")
                }
            }
            .font(.system(size: 12.5)).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
        }
    }

    @ViewBuilder private func actions(_ finding: ReviewComment, decision: Decision?, list: [ReviewComment]) -> some View {
        HStack(spacing: 8) {
            if let decision {
                Label(decision == .kept ? "Kept. It is in your review." : "Dismissed. It will not be sent.",
                      systemImage: decision == .kept ? "checkmark" : "xmark")
                    .font(.system(size: 12.5))
                Spacer(minLength: 0)
                InlineLink(title: "Undo", tint: decision == .kept ? Theme.dotOn : Color.secondary) { undo(finding, decision) }
            } else if editing {
                ActionButton(title: "Keep my version", tone: .green, height: 30, size: 12, icon: "checkmark",
                             shortcut: "⌘↩", keyboardShortcut: KeyboardShortcut(.return, modifiers: .command)) {
                    saveEdit(finding)
                }
                .disabled(draft.isBlank)
                InlineLink(title: "Cancel", tint: Color.secondary) { editing = false }
            } else {
                ActionButton(title: "Keep", tone: .green, height: 30, size: 12, icon: "checkmark", shortcut: "K") { keep(finding) }
                ActionButton(title: "Edit and keep", tone: .outlined, height: 30, size: 12, shortcut: "E") { startEdit(finding) }
                ActionButton(title: "Dismiss", tone: .sunken, height: 30, size: 12, shortcut: "D") { dismiss(finding) }
                Spacer(minLength: 0)
                GlyphButton(icon: "chevron.up", side: 26) { move(-1, in: list) }
                    .appTooltip("Previous finding  ↑")
                    .accessibilityLabel("Previous finding")
                GlyphButton(icon: "chevron.down", side: 26) { move(1, in: list) }
                    .appTooltip("Next finding  ↓")
                    .accessibilityLabel("Next finding")
            }
        }
        .padding(decision == nil ? 0 : 10)
        .foregroundStyle(decision == .kept ? Theme.dotOn : Color.secondary)
        .background(RoundedRectangle(cornerRadius: 9).fill(decision == .kept ? Theme.dotOn.opacity(0.08)
                                                             : decision == .dismissed ? Theme.field : .clear))
        .padding(.top, 4)
    }

    // A few lines around the finding, read from the file, with its own line marked.
    private func codeExcerpt(_ finding: ReviewComment) -> some View {
        let lines = Self.context(for: finding, readFile: store.readFile)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(lines, id: \.number) { line in
                HStack(spacing: 0) {
                    Text("\(line.number)").foregroundStyle(.tertiary)
                        .frame(width: 44, alignment: .trailing).padding(.trailing, 12)
                    Text(line.text.isEmpty ? " " : line.text).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .font(.mono(11.5))
                .frame(height: 19)
                .background(line.number == finding.line ? Theme.attention.opacity(0.16) : .clear)
                .overlay(alignment: .leading) {
                    if line.number == finding.line { Rectangle().fill(Theme.attention).frame(width: 3) }
                }
            }
        }
        .padding(.vertical, 6)
        .surface(Theme.field, cornerRadius: 10)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Code at line \(finding.line): \(finding.excerpt)")
    }

    static func context(for finding: ReviewComment,
                        readFile: (String) -> String?) -> [(number: Int, text: String)] {
        let fallback = [(number: finding.line, text: finding.excerpt)]
        guard finding.side == .new, !finding.onFile,
              let text = readFile((finding.root as NSString).appendingPathComponent(finding.path)) else { return fallback }
        let all = text.components(separatedBy: "\n")
        guard finding.line >= 1, finding.line <= all.count else { return fallback }
        let first = max(1, finding.line - 2)
        let last = min(all.count, first + 3)
        return (first...last).map { (number: $0, text: all[$0 - 1]) }
    }

    // MARK: Deciding

    private func advance(from id: UUID) {
        selected = SecondOpinionFindings.next(after: id, in: list) { decision($0, dismissed: dismissedIDs) == nil }
    }

    private func keep(_ finding: ReviewComment) {
        store.keep(finding.id, in: review.sessionID)
        announce("Kept. It is in your review.")
        advance(from: finding.id)
    }

    private func dismiss(_ finding: ReviewComment) {
        store.dismiss(finding.id, from: review.sessionID)
        announce("Dismissed. It will not be sent.")
        advance(from: finding.id)
    }

    private func startEdit(_ finding: ReviewComment) {
        draft = finding.body
        editing = true
        editorFocused = true
    }

    private func saveEdit(_ finding: ReviewComment) {
        guard !draft.isBlank else { return }
        store.update(finding.id, body: draft.trimmed, in: review.sessionID)
        editing = false
        announce("Kept with your edits")
        advance(from: finding.id)
    }

    private func undo(_ finding: ReviewComment, _ decision: Decision) {
        switch decision {
        case .kept: store.reopen(finding.id, in: review.sessionID)
        case .dismissed: store.restore(finding, to: review.sessionID)
        }
        selected = finding.id
        announce("Back among the findings to look at")
    }

    private func move(_ step: Int, in list: [ReviewComment]) {
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == selected } ?? (step > 0 ? -1 : 0)
        selected = list[(index + step + list.count) % list.count].id
        editing = false
    }

    // K, E and D decide, the arrows move and Escape closes. A key typed into the editor
    // is left to it.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.isEmpty else { return false }
        switch event.keyCode {
        case 53:
            if editing { editing = false } else { dialogs.dismiss() }
            return true
        case 125: move(1, in: list); return true
        case 126: move(-1, in: list); return true
        default: break
        }
        guard !editing, let finding = list.first(where: { $0.id == selected }),
              decision(finding, dismissed: dismissedIDs) == nil else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "k": keep(finding)
        case "e": startEdit(finding)
        case "d": dismiss(finding)
        default: return false
        }
        return true
    }
}

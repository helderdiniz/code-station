import SwiftUI

// One project the whole change spans, with how much of the change is in it.
struct WholeChangeAskScope: Identifiable {
    let name: String
    let files: Int
    let added: Int
    let removed: Int
    var id: String { name }
    var lines: Int { added + removed }
}

// Questions about the whole change, in a card that hangs under the header button that
// asks them. It hangs over the diff rather than sitting in the file list, so the answer
// shows where the click was and the code it points at stays in view beside it.
struct WholeChangeAskCard<Thread: View>: View {
    let navigation: ChangesNavigationMemory
    let open: [ReviewQuestion]
    let resolved: [ReviewQuestion]
    let scope: [WholeChangeAskScope]
    let agentTitle: String
    // A fork of the conversation has read the chat; any other agent answers from the diff.
    let forksConversation: Bool
    // The tallest the card may be, so it never runs off the bottom of the window.
    let maxHeight: CGFloat
    let ask: (String) -> Void
    // Esc stops an answer under way before it puts the card away.
    let escape: () -> Void
    let close: () -> Void
    // Draws one thread, open or folded to a line.
    @ViewBuilder let thread: (ReviewQuestion, Bool) -> Thread

    static var width: CGFloat { 452 }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var fieldFocused: Bool
    @State private var frame: CGRect = .zero
    @State private var mapDrawn = false

    private var expanded: UUID? { WholeChangeThreads.expanded(navigation.askExpanded, in: open) }
    private var following: ReviewQuestion? {
        navigation.askFollowing.flatMap { id in (open + resolved).first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !scope.isEmpty { changeMap }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            threads
            composer
        }
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border))
        .overlay(alignment: .topLeading) { notch }
        .shadow(color: .black.opacity(0.16), radius: 24, y: 9)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ask about the whole change")
        .accessibilityAddTraits(.isModal)
        // The card is offered the whole height it may take but only draws what it holds,
        // from the top, so a short conversation leaves no empty card under it.
        .frame(height: maxHeight, alignment: .top)
        .onAppear {
            mapDrawn = true
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onChange(of: navigation.askFollowing) { _, id in
            if id != nil { fieldFocused = true }
        }
    }

    // Points back at the button the card came from.
    @ViewBuilder private var notch: some View {
        if let origin = navigation.askOrigin, frame.width > 0 {
            let x = min(max(origin.x - frame.minX, 24), Self.width - 24)
            RoundedRectangle(cornerRadius: 3)
                .fill(Theme.card)
                .overlay(alignment: .topLeading) {
                    // Only the two outer edges carry the border, so the notch joins the card.
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 14))
                        path.addLine(to: CGPoint(x: 0, y: 3))
                        path.addQuadCurve(to: CGPoint(x: 3, y: 0), control: .zero)
                        path.addLine(to: CGPoint(x: 14, y: 0))
                    }
                    .stroke(Theme.border, lineWidth: 1)
                }
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(45))
                .offset(x: x - 7, y: -7)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "questionmark.bubble")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.plan)
                .frame(width: 32, height: 32)
                .surface(Theme.plan.opacity(0.12), cornerRadius: 10, border: Theme.plan.opacity(0.25))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ask about the whole change")
                    .font(.serif(17, .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(forksConversation
                     ? "A side copy of \(agentTitle) answers. It has read the chat, can't edit files, and nothing it says goes back to the chat."
                     : "A read-only run of \(agentTitle) answers from the diff and the recent chat. It can't edit files, and nothing it says goes to the chat.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            GlyphButton(icon: "xmark", side: 26, action: close)
                .appTooltip("Put away  esc")
                .accessibilityLabel("Put away")
        }
        .padding(.leading, 16).padding(.trailing, 14).padding(.top, 16).padding(.bottom, 12)
    }

    // Where the change is: one bar split by how many lines each project changed, then a
    // row for each project with its files and lines.
    private var changeMap: some View {
        let total = max(scope.reduce(0) { $0 + $1.lines }, 1)
        return VStack(alignment: .leading, spacing: 9) {
            GeometryReader { proxy in
                let gaps = CGFloat(max(scope.count - 1, 0)) * 3
                HStack(spacing: 3) {
                    ForEach(scope) { project in
                        Capsule()
                            .fill(Theme.projectTint(for: project.name).colour)
                            .frame(width: mapDrawn || reduceMotion
                                   ? max((proxy.size.width - gaps) * CGFloat(project.lines) / CGFloat(total), 3) : 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .motion(Motion.draw, value: mapDrawn)
            }
            .frame(height: 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(mapSummary(total: total))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                ForEach(scope) { project in
                    GridRow {
                        HStack(spacing: 7) {
                            ProjectDot(tint: Theme.projectTint(for: project.name), size: 8)
                            Text(project.name).font(.system(size: 12, weight: .medium))
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(counted(project.files, "file"))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        HStack(spacing: 5) {
                            Text("+\(project.added)").foregroundStyle(Theme.addition)
                            Text("\u{2212}\(project.removed)").foregroundStyle(Theme.deletion)
                                .opacity(project.removed == 0 ? 0.4 : 1)
                        }
                        .font(.mono(11)).fixedSize()
                        .gridColumnAlignment(.trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(project.name), \(counted(project.files, "file")), "
                                        + "\(project.added) lines added, \(project.removed) removed")
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sunken))
        .padding(.horizontal, 14).padding(.bottom, 12)
    }

    private func mapSummary(total: Int) -> String {
        guard let largest = scope.max(by: { $0.lines < $1.lines }) else { return "" }
        guard scope.count > 1 else { return "\(largest.name) holds the whole change" }
        let percent = Int((Double(largest.lines) / Double(total) * 100).rounded())
        return "\(largest.name) holds \(percent) percent of the changed lines"
    }

    // The threads scroll inside the card once they outgrow it. The card is as tall as
    // what it holds, so a short conversation does not leave a tall empty card.
    private var threads: some View {
        ScrollViewReader { proxy in
            HuggingHeight {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if !resolved.isEmpty {
                            resolvedToggle.frame(maxWidth: .infinity)
                        }
                        if navigation.askShowsResolved {
                            ForEach(resolved) { question in
                                thread(question, true).id(question.id).transition(.fadeIn)
                            }
                        }
                        if open.isEmpty && !(navigation.askShowsResolved && !resolved.isEmpty) {
                            empty.transition(.fadeIn)
                        }
                        ForEach(open) { question in
                            thread(question, question.id == expanded).id(question.id).transition(.fadeIn)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 8)
                    .motion(Motion.reveal, value: expanded)
                    .motion(Motion.reveal, value: open.map(\.id))
                    .motion(Motion.reveal, value: navigation.askShowsResolved)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Questions")
            .onAppear {
                if let expanded { proxy.scrollTo(expanded, anchor: .bottom) }
            }
            .onChange(of: open.last?.id) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : Motion.reveal) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .layoutPriority(-1)
    }

    private var resolvedToggle: some View {
        let count = resolved.count == 1 ? "1 resolved question" : "\(resolved.count) resolved questions"
        return InlineLink(title: (navigation.askShowsResolved ? "Hide " : "Show ") + count,
                          size: 11.5, tint: Color.secondary) {
            navigation.askShowsResolved.toggle()
        }
        .padding(.vertical, 4)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "questionmark.bubble")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.plan)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.plan.opacity(0.08)))
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text("Ask how this change fits together").font(.serif(15, .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Good for the big picture: why it was built this way, what to read first, what it could break. To ask about a few lines, select them in the diff.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 330)
            VStack(spacing: 4) {
                ForEach(WholeChangeThreads.starters(projects: scope.count), id: \.self) { starter in
                    WholeChangeStarter(text: starter) { ask(starter) }
                }
            }
            .padding(.top, 10)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Questions to start with")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 10)
    }

    // One box: the field, then where the answer stays and the button that asks.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let following {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.plan)
                    (Text("Following up on ").foregroundStyle(.secondary)
                     + Text(following.text).fontWeight(.semibold).foregroundStyle(Color.primary))
                        .font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    GlyphButton(icon: "xmark", side: 20) { navigation.askFollowing = nil }
                        .appTooltip("Ask a new question instead")
                        .accessibilityLabel("Ask a new question instead")
                }
                .padding(.leading, 9).padding(.trailing, 4).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.plan.opacity(0.08)))
                .transition(.fadeIn)
            }
            VStack(alignment: .leading, spacing: 6) {
                TextField(following == nil ? "Ask \(agentTitle) about the whole change" : "Ask a follow-up",
                          text: Binding(get: { navigation.askDraft }, set: { navigation.askDraft = $0 }),
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .focused($fieldFocused)
                    .onSubmit(send)
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.shift) else { return .ignored }
                        navigation.askDraft += "\n"
                        return .handled
                    }
                    .onExitCommand(perform: escape)
                    .accessibilityLabel(following == nil ? "Question about the whole change" : "Follow-up question")
                    .accessibilityHint("Return asks. Shift-Return adds a line.")
                HStack(spacing: 8) {
                    Label("Stays in this review", systemImage: "lock")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .labelStyle(.titleAndIcon)
                    Spacer(minLength: 8)
                    WholeChangeAskButton(title: following == nil ? "Ask" : "Ask follow-up",
                                         ready: !navigation.askDraft.isBlank, action: send)
                }
            }
            .padding(.leading, 12).padding(.trailing, 7).padding(.top, 10).padding(.bottom, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(fieldFocused ? Theme.plan.opacity(0.5) : Theme.border))
            .motion(Motion.hover, value: fieldFocused)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture { fieldFocused = true }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .motion(Motion.reveal, value: navigation.askFollowing)
    }

    private func send() {
        guard !navigation.askDraft.isBlank else { return }
        ask(navigation.askDraft.trimmed)
        fieldFocused = true
    }

    private func counted(_ count: Int, _ noun: String) -> String {
        count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }
}

// A question to start with. It is a whole question, so a click asks it at once.
private struct WholeChangeStarter: View {
    let text: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.plan)
                Text(text).font(.system(size: 12.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.plan)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 11).frame(height: 32)
            .surface(hovering ? Theme.plan.opacity(0.06) : Theme.card, cornerRadius: 8,
                     border: hovering ? Theme.plan.opacity(0.35) : Theme.border)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .hoverLift(hovering, amount: Motion.smallLift)
        .motion(Motion.hover, value: hovering)
        .onPointerHover { hovering = $0 }
        .accessibilityLabel(text)
        .accessibilityHint("Asks it now")
    }
}

// The card's Ask button. With nothing typed it waits in the field's own grey rather than
// fading out, so it reads as not yet rather than broken.
private struct WholeChangeAskButton: View {
    let title: String
    let ready: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11.5, weight: .semibold)).fixedSize()
                Image(systemName: "return")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(ready ? Theme.card.opacity(0.5) : Theme.border))
            }
            .foregroundStyle(ready ? Theme.card : Color.secondary)
            .padding(.horizontal, 10).frame(height: 28)
            .surface(ready ? (hovering ? Theme.plan.opacity(0.86) : Theme.plan) : Theme.sunken,
                     cornerRadius: 7, border: ready ? .clear : Theme.border)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .hoverLift(hovering && ready)
        .motion(Motion.control, value: ready)
        .onPointerHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(ready ? "" : "Type a question first")
    }
}

// A thread folded to one line: the question, where it stands and when it was asked.
struct WholeChangeFoldedThread<Badge: View>: View {
    let question: ReviewQuestion
    let open: () -> Void
    @ViewBuilder let badge: () -> Badge

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Text(question.text)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                badge()
                Text(question.created.formatted(date: .omitted, time: .shortened))
                    .font(.mono(10.5)).foregroundStyle(.tertiary).fixedSize()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: 11)
        .accessibilityLabel(question.spokenName)
        .accessibilityHint("Opens the thread")
    }
}

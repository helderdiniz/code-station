import SwiftUI

// One project the whole change spans, as the card's scope names it.
struct WholeChangeAskScope: Identifiable {
    let name: String
    let files: Int
    var id: String { name }
}

// Questions about the whole change, in a card that grows out of the header button that
// asks them. It hangs over the diff rather than sitting in the file list, so the answer
// shows where the click was and the code it points at stays in view beside it.
struct WholeChangeAskCard<Thread: View>: View {
    let navigation: ChangesNavigationMemory
    let open: [ReviewQuestion]
    let resolved: [ReviewQuestion]
    let scope: [WholeChangeAskScope]
    let added: Int
    let removed: Int
    let agentTitle: String
    // The tallest the card may be, so it never runs off the bottom of the window.
    let maxHeight: CGFloat
    let ask: (String) -> Void
    let close: () -> Void
    // Draws one thread, open or folded to a line.
    @ViewBuilder let thread: (ReviewQuestion, Bool) -> Thread

    static var width: CGFloat { 452 }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var fieldFocused: Bool
    @State private var threadsHeight: CGFloat = 0
    @State private var frame: CGRect = .zero

    private var expanded: UUID? { WholeChangeThreads.expanded(navigation.askExpanded, in: open) }
    private var following: ReviewQuestion? {
        navigation.askFollowing.flatMap { id in (open + resolved).first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            scopeRow
            Rectangle().fill(Theme.hairline).frame(height: 1)
            threads
            composer
        }
        .frame(width: Self.width)
        .frame(maxHeight: maxHeight)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border))
        .overlay(alignment: .topLeading) { notch }
        .shadow(color: .black.opacity(0.16), radius: 24, y: 9)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ask about the whole change")
        .accessibilityAddTraits(.isModal)
        .onAppear {
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
                Text("A side copy of this session answers. Nothing reaches the chat.")
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

    private var scopeRow: some View {
        HStack(spacing: 6) {
            ForEach(scope) { project in
                HStack(spacing: 5) {
                    Text(project.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    Text(counted(project.files, "file")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize()
                }
                .padding(.horizontal, 9).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.sunken))
            }
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                Text("+\(added)").foregroundStyle(Theme.addition)
                Text("\u{2212}\(removed)").foregroundStyle(Theme.deletion)
            }
            .font(.mono(11)).fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(added) lines added, \(removed) removed")
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    // The threads scroll inside the card once they outgrow it. The card is as tall as
    // what it holds, so a short conversation does not leave a tall empty card.
    private var threads: some View {
        ScrollViewReader { proxy in
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
                        empty
                    }
                    ForEach(open) { question in
                        thread(question, question.id == expanded).id(question.id).transition(.fadeIn)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { threadsHeight = $0 }
                .motion(Motion.reveal, value: expanded)
                .motion(Motion.reveal, value: open.map(\.id))
                .motion(Motion.reveal, value: navigation.askShowsResolved)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: threadsHeight)
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
            Text("Nothing asked about the whole change yet").font(.serif(15, .semibold))
            Text("Ask how the parts fit together, or why it was done this way. Questions about a few lines are asked from the diff.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20).padding(.vertical, 22)
        .accessibilityElement(children: .combine)
    }

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
            HStack(alignment: .bottom, spacing: 8) {
                TextField(following == nil ? "Ask \(agentTitle) about the whole change" : "Ask a follow-up",
                          text: Binding(get: { navigation.askDraft }, set: { navigation.askDraft = $0 }),
                          axis: .vertical)
                    .lineLimit(1...5)
                    .appTextField(size: 12.5)
                    .focused($fieldFocused)
                    .onSubmit(send)
                    .onExitCommand(perform: close)
                    .accessibilityLabel(following == nil ? "Question about the whole change" : "Follow-up question")
                ActionButton(title: following == nil ? "Ask" : "Ask follow-up", tone: .plan,
                             height: 30, size: 11.5, icon: "questionmark", action: send)
                    .disabled(navigation.askDraft.isBlank)
            }
            Text("Return asks. Esc puts the card away.")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
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

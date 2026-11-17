import SwiftUI
import SwiftData

struct ChatView: View {
    @Bindable var conversation: Conversation
    /// Called with a newly created conversation so the app can switch to it
    /// when the user branches the transcript at some message.
    var onCreateBranch: ((Conversation) -> Void)? = nil
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = ChatViewModel()
    @State private var draft = ""
    @State private var isAtBottom = true
    /// True while the transcript should follow the bottom edge as tokens
    /// stream in. Cleared only when the user *drags* away from the bottom;
    /// restored whenever the view reaches the bottom again. Unlike `isAtBottom`
    /// this survives the transient "content grew, offset hasn't caught up"
    /// states that would otherwise stop the follow-scroll.
    @State private var autoFollow = true
    /// When set, the transcript pins this user message to the top of the view
    /// while the answer streams in below it, instead of following the bottom.
    @State private var pinnedMessageID: UUID?
    /// The user request whose turn gets a viewport-tall block, so it can be
    /// scrolled to the top of the transcript. Set on send, cleared when the
    /// conversation changes.
    @State private var reservedTurnID: UUID?
    /// Scroll offset captured right after the pin animation, used to detect
    /// the user scrolling away from the pinned position.
    @State private var pinnedOffsetY: CGFloat?
    @State private var currentOffsetY: CGFloat = 0
    /// Height of the newest bubble and of the viewport, used to detect when
    /// the streaming answer outgrows the screen and we must follow the bottom.
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = .infinity
    /// True while the user is actively dragging the transcript.
    @State private var isDragging = false
    /// True for a few seconds after streaming ends, while the answer is
    /// revealed in chunks (see `MarkdownView.revealInChunks`).
    @State private var isRevealing = false
    @State private var showFileImporter = false
    @State private var showFolderImporter = false
    @FocusState private var inputFocused: Bool

    /// Horizontal inset for the transcript and input bar; tighter on iPhone
    /// where screen width is at a premium.
    private var horizontalPadding: CGFloat {
        #if os(macOS)
        42
        #else
        UIDevice.current.userInterfaceIdiom == .phone ? 12 : 42
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            if viewModel.isStreaming || viewModel.isCompacting {
                HStack(spacing: 16) {
                    if viewModel.isCompacting {
                        ProgressView().controlSize(.small)
                        Text("Compacting context…")
                    }
                    if viewModel.isStreaming {
                        if !viewModel.activeSubagentTasks.isEmpty {
                            ProgressView().controlSize(.small)
                            Text(viewModel.activeSubagentTasks.count == 1
                                 ? "Sub-agent running…"
                                 : "\(viewModel.activeSubagentTasks.count) sub-agents running…")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 20)
                .padding(.bottom, 6)
            }
            inputBar
                .overlay(alignment: .topLeading) {
                    if !matchingCommands.isEmpty {
                        // Float just above the composer without resizing the transcript.
                        commandPicker
                            .alignmentGuide(.top) { $0[.bottom] + 8 }
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, 4)
            // Metrics shown below the input. The slot is always reserved, so the
            // input doesn't jump up when the first reply adds the tok/s line.
            // The rate is displayed only once generation is done — the final
            // value is the exact one from the usage chunk.
            HStack(spacing: 16) {
                if !viewModel.isStreaming && viewModel.tokensPerSecond > 0 {
                    MetricChip(symbol: "bolt.fill",
                               label: String(format: "%.1f tok/s", viewModel.tokensPerSecond))
                }
                if let context = viewModel.contextUsedRatio {
                    RingMetric(value: context, label: "\(Int((context * 100).rounded()))%",
                               help: "Context window used", showsHelp: false,
                               labelBesideRing: true)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: 20)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        .background(Color.appGroupedBackground)
        // Links to files the assistant saved open in an in-app preview (the file
        // sits in the app's sandbox, out of reach of the default browser).
        .opensSavedFilesInPreview()
        .navigationTitle($conversation.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ModelPicker(viewModel: viewModel)
            }
        }
        .onAppear {
            viewModel.configure(from: conversation, in: modelContext)
        }
        // Reload the model list on appear and whenever the active endpoint
        // changes. URL/key edits don't trigger it (no requests while typing);
        // use "Refresh models" or Settings' "Test Connection" after editing.
        // Errors stay silent so an alert can't dismiss the Settings sheet.
        .task(id: AppSettings.shared.activeEndpointID) {
            await viewModel.loadModels(reportErrors: false)
        }
        .onChange(of: conversation.id) { _, _ in
            reservedTurnID = nil
            viewModel.configure(from: conversation, in: modelContext)
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.lastError != nil },
            set: { if !$0 { viewModel.lastError = nil } }
        )) {
            Button("OK") { viewModel.lastError = nil }
        } message: {
            Text(viewModel.lastError ?? "")
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: true) { result in
            attach(urls: result, isFolder: false)
        }
        .fileImporter(isPresented: $showFolderImporter,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: true) { result in
            attach(urls: result, isFolder: true)
        }
    }

    /// Stores security-scoped bookmarks for the picked URLs and registers
    /// them as resources on the current conversation.
    private func attach(urls: Result<[URL], Error>, isFolder: Bool) {
        guard case .success(let picked) = urls else { return }
        for url in picked {
            // The picked URL is security-scoped; access must be active to
            // create a bookmark that carries the scope.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            #if os(macOS)
            guard let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                       includingResourceValuesForKeys: nil,
                                                       relativeTo: nil) else { continue }
            #else
            guard let bookmark = try? url.bookmarkData(options: [],
                                                       includingResourceValuesForKeys: nil,
                                                       relativeTo: nil) else { continue }
            #endif
            let resource = SessionResource(name: url.lastPathComponent,
                                           isFolder: isFolder,
                                           bookmarkData: bookmark)
            modelContext.insert(resource)
            conversation.resources.append(resource)
        }
        saveChanges()
    }

    /// Forks the transcript into a new conversation containing everything
    /// up to and including `messageID`, then switches the app to it.
    private func branch(at messageID: UUID) {
        guard !viewModel.isStreaming,
              viewModel.messages.contains(where: { $0.id == messageID }) else { return }
        let source = conversation.sortedMessages
        guard let cutIndex = source.firstIndex(where: { $0.id == messageID }) else { return }

        let fork = Conversation(title: "\(conversation.title) (branch)",
                                modelID: conversation.modelID,
                                systemPrompt: conversation.systemPrompt)
        modelContext.insert(fork)

        for (index, message) in source.prefix(cutIndex + 1).enumerated() {
            let copy = ChatMessage(role: message.role,
                                   content: message.content,
                                   toolCallsJSON: message.toolCallsJSON,
                                   toolCallId: message.toolCallId,
                                   workedSeconds: message.workedSeconds,
                                   stepsJSON: message.stepsJSON,
                                   order: index)
            copy.conversation = fork
            modelContext.insert(copy)
        }
        // Carry the attached resources over so the branch keeps its context.
        for resource in conversation.resources {
            let clone = SessionResource(name: resource.name,
                                        isFolder: resource.isFolder,
                                        bookmarkData: resource.bookmarkData)
            clone.conversation = fork
            modelContext.insert(clone)
        }

        do {
            try modelContext.save()
        } catch {
            viewModel.lastError = "Unable to save conversation: \(error.localizedDescription)"
            return
        }
        onCreateBranch?(fork)
    }

    private func transcriptRow(_ message: ChatMessage) -> some View {
        let isLive = viewModel.isStreaming && message.id == viewModel.messages.last?.id && message.role == .assistant
        return MessageBubble(message: message,
                             streaming: isLive,
                             reasoning: isLive ? viewModel.reasoningLine : "",
                             liveSteps: isLive ? viewModel.liveSteps : [],
                             onBranch: message.role == .assistant ? { branch(at: message.id) } : nil)
            .id(message.id)
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") {
                    Clipboard.string = message.content
                }
            }
    }

    /// While a tool runs the last message is a (hidden) tool result, so show
    /// the status here instead of in a bubble.
    @ViewBuilder
    private var toolStatusRow: some View {
        if viewModel.isStreaming, viewModel.activeToolName != nil {
            VStack(alignment: .leading, spacing: 6) {
                ActivityStepsView(steps: viewModel.liveSteps)
                ThinkingIndicator(label: "Working…")
                    .padding(.vertical, 10)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Tool results and the intermediate assistant steps that
                    // issue tool calls are hidden; only final answers show.
                    let visible = viewModel.messages.filter { $0.role != .tool && $0.toolCallsJSON == nil }
                    // The earlier rows always live in this one ForEach, whether
                    // or not a turn is reserved. Moving them between branches
                    // would recreate every row on send, and in a long chat the
                    // lazy stack would fall back to estimated heights and the
                    // scroll-to-top would land on the wrong offset.
                    let reservedStart = reservedTurnID.flatMap { id in
                        visible.firstIndex(where: { $0.id == id })
                    }
                    ForEach(visible[..<(reservedStart ?? visible.count)]) { transcriptRow($0) }
                    if let start = reservedStart {
                        // The newest request and its answer sit in a block at
                        // least one viewport tall, so the request can scroll
                        // all the way to the top even while the answer is
                        // still short.
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(visible[start...]) { transcriptRow($0) }
                            toolStatusRow
                        }
                        .frame(minHeight: viewportHeight.isFinite ? max(0, viewportHeight - 16) : 0,
                               alignment: .top)
                    } else {
                        toolStatusRow
                    }
                    // Zero-height anchor at the very end of the transcript.
                    // Scrolling to it pins the bottom edge exactly, even when
                    // the last bubble is shorter than the viewport.
                    Color.clear
                        .frame(height: 1)
                        .id("bottom-anchor")
                }
                .scrollTargetLayout()
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 16)
            }
            .scrollBounceBehavior(.basedOnSize)

            // Track the scroll position: whether the transcript is pinned to
            // the bottom, and whether the user has scrolled away from a pinned
            // user message.
            .onScrollGeometryChange(for: ScrollState.self) { geometry in
                let distance = geometry.contentSize.height - geometry.containerSize.height
                return ScrollState(atBottom: geometry.contentOffset.y >= distance - 8,
                                   offsetY: geometry.contentOffset.y,
                                   contentHeight: geometry.contentSize.height,
                                   viewportHeight: geometry.containerSize.height)
            } action: { _, state in
                currentOffsetY = state.offsetY
                contentHeight = state.contentHeight
                viewportHeight = state.viewportHeight
                isAtBottom = state.atBottom
                // Sticky follow intent: reaching the bottom re-arms it, and
                // only a *user drag* away from the bottom disarms it. (A plain
                // `atBottom` check can't drive the follow-scroll: when the
                // streaming content grows, the offset momentarily lags the
                // new bottom edge and reads as "not at bottom" for a frame.)
                if state.atBottom {
                    autoFollow = true
                } else if isDragging {
                    autoFollow = false
                }
                // If the user dragged away from the pinned position, stop
                // pinning. Only dragging counts — programmatic scrolls during
                // the pin animation must not release the pin.
                if isDragging,
                   let pinned = pinnedOffsetY,
                   pinnedMessageID != nil,
                   abs(state.offsetY - pinned) > 40 {
                    pinnedMessageID = nil
                    pinnedOffsetY = nil
                }
            }
            .onScrollPhaseChange { _, phase in
                isDragging = (phase == .interacting)
            }
            .overlay(alignment: .bottom) {
                if !isAtBottom && pinnedMessageID == nil {
                    JumpToLatestButton {
                        pinnedMessageID = nil
                        pinnedOffsetY = nil
                        autoFollow = true
                        withAnimation { proxy.scrollTo("bottom-anchor", anchor: .bottom) }
                        isAtBottom = true
                    }
                    .padding(.bottom, 12)
                }
            }
            // Follow the output as it streams. While a user message is pinned
            // to the top, leave the view alone until the streaming answer
            // grows past the bottom of the viewport; then release the pin and
            // follow the bottom edge. No animation — animated scrolls would
            // fight each other at token cadence.
            .onChange(of: viewModel.streamingText) { _, _ in
                followStream(proxy)
            }
            // The "Thinking…" bubble and tool-run pauses grow the content
            // without any streamed text, so follow content growth as well.
            .onChange(of: contentHeight) { _, _ in
                if viewModel.isStreaming { followStream(proxy) }
            }
            .onChange(of: viewModel.isStreaming) { _, streaming in
                guard !streaming else { return }
                // No scrolling when the answer lands; the guard below also
                // stops the reset of `streamingText` from following the bottom.
                isRevealing = true
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    isRevealing = false
                }
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if viewModel.isStreaming { followStream(proxy) }
            }
            // When a new user message is sent, bring it to the top of the
            // view so the answer streams in below it. Retry a few times: the
            // new bubble may not be laid out yet when the count changes, and
            // the first scrollTo would then land on a stale position.
            .onChange(of: viewModel.messages.last(where: { $0.role == .user })?.id) { _, newID in
                // Fires only when a *new* user message arrives. The assistant
                // placeholder may already be appended by the time this runs,
                // so we can't rely on messages.count or messages.last.
                // Only a request sent from this view (not a conversation
                // switch loading its history) pins to the top.
                guard let newID, newID != pinnedMessageID, newID == reservedTurnID else { return }
                guard let last = viewModel.messages.first(where: { $0.id == newID }) else { return }
                pinnedMessageID = last.id
                pinnedOffsetY = nil
                for delay in [0.0, 0.05, 0.15, 0.3] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        guard pinnedMessageID == last.id else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .top)
                        }
                    }
                }
                // Capture the settled offset so user-initiated scrolling can
                // be distinguished from the pin animation itself.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    if pinnedMessageID == last.id {
                        pinnedOffsetY = currentOffsetY
                    }
                }
            }
            .onAppear {
                proxy.scrollTo("bottom-anchor", anchor: .bottom)
            }
        }
    }

    /// Keeps the newest content visible while a response is in flight.
    private func followStream(_ proxy: ScrollViewProxy) {
        // While the finished answer is being revealed the bubble already has
        // its full height; jumping to the bottom would skip past the lines
        // not yet shown, so the reveal scrolls itself line by line instead.
        guard !isRevealing else { return }
        if pinnedMessageID != nil {
            // The request stays at the top for the whole response; the
            // viewport-tall turn block means content height can't tell us
            // when the answer outgrows the screen, and the user scrolls
            // down themselves (a drag releases the pin).
            return
        } else if autoFollow {
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    }

    /// Horizontal strip of attached resources with remove buttons.
    private var resourceStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(conversation.resources) { resource in
                    HStack(spacing: 6) {
                        Image(systemName: resource.isFolder ? "folder.fill" : "doc.text.fill")
                            .font(.caption)
                            .foregroundStyle(resource.isFolder ? Color.yellow : Color.accentColor)
                        Text(resource.name)
                            .font(.caption)
                            .lineLimit(1)
                        Button {
                            modelContext.delete(resource)
                            conversation.resources.removeAll { $0.id == resource.id }
                            saveChanges()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.appSecondaryBackground, in: Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    /// iOS 26 "Liquid Glass" composer: a glass capsule holding the field and
    /// glass button styles for send/stop.
    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Attached files/folders live inside the composer, above the field.
            if !conversation.resources.isEmpty {
                resourceStrip
            }
            inputRow
        }
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
    }

    private var inputRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Menu {
                Button("Add File…", systemImage: "doc.badge.plus") {
                    showFileImporter = true
                }
                Button("Add Folder…", systemImage: "folder.badge.plus") {
                    showFolderImporter = true
                }
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.medium))
            }
            .menuIndicator(.hidden)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Add resources")

            TextField("Message…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(.horizontal, 5)
                .padding(.vertical, 8)
                .focused($inputFocused)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .onSubmit(send)

            if viewModel.isStreaming {
                Button {
                    viewModel.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.body.weight(.medium))
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(.red)
                .accessibilityLabel("Stop generating")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send message")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Slash commands whose name starts with what's typed. Only offered while
    /// the draft is a single "/word", so normal messages and paths never match.
    private var matchingCommands: [SlashCommand] {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard typed.hasPrefix("/"), !typed.contains(where: \.isWhitespace) else { return [] }
        return SlashCommand.allCases.filter { $0.name.hasPrefix(typed) }
    }

    private func run(_ command: SlashCommand) {
        draft = ""
        inputFocused = false
        switch command {
        case .compact:
            Task { await viewModel.compact(conversation: conversation) }
        }
    }

    /// Popover listing the commands that match the draft, shown above the composer.
    private var commandPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matchingCommands) { command in
                Button { run(command) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: command.symbol)
                            .frame(width: 22)
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(command.name).font(.body.weight(.medium))
                            Text(command.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func send() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !viewModel.isStreaming, !viewModel.isCompacting else { return }
        // A slash command (or the first match of a partial one) runs instead
        // of sending a message.
        if let command = matchingCommands.first {
            run(command)
            return
        }
        // Auto-title new conversations from the first user message.
        if conversation.title == "New Chat" {
            conversation.title = String(draft.prefix(40))
        }
        viewModel.send(draft, conversation: conversation)
        reservedTurnID = viewModel.messages.last(where: { $0.role == .user })?.id
        saveChanges()
        draft = ""
        isAtBottom = true
        autoFollow = true
        inputFocused = false
    }

    private func saveChanges() {
        do {
            try modelContext.save()
        } catch {
            viewModel.lastError = "Unable to save conversation: \(error.localizedDescription)"
        }
    }
}

/// Commands typed into the composer with a leading "/".
private enum SlashCommand: String, CaseIterable, Identifiable {
    case compact

    var id: String { rawValue }
    var name: String { "/" + rawValue }

    var symbol: String {
        switch self {
        case .compact: "arrow.down.right.and.arrow.up.left"
        }
    }

    var summary: String {
        switch self {
        case .compact: "Summarize older messages to free up context"
        }
    }
}

/// Snapshot of the transcript's scroll position.
private struct ScrollState: Equatable {
    var atBottom: Bool
    var offsetY: CGFloat
    var contentHeight: CGFloat
    var viewportHeight: CGFloat
}

/// Icon + value stat shown in the status row.
private struct MetricChip: View {
    let symbol: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption2)
            Text(label)
                .monospacedDigit()
        }
    }
}

/// Circular progress ring with a percentage in the middle.
private struct RingMetric: View {
    let value: Double   // 0...1
    let label: String
    var help: String
    /// When false only the ring is shown; `help` stays as the accessibility label.
    var showsHelp = true
    /// When true the ring is left empty and `label` is shown next to it.
    var labelBesideRing = false

    private var strokeWidth: CGFloat { labelBesideRing ? 1.5 : 2 }

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: strokeWidth)
                Circle()
                    .trim(from: 0, to: min(max(value, 0), 1))
                    .stroke(value > 0.85 ? Color.orange : Color.accentColor,
                            style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: value)
                // Inset so the digits sit inside the ring, centred, and
                // shrink rather than truncate ("10…") at three digits.
                if !labelBesideRing {
                    Text(label)
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(3)
                }
            }
            // Shrink to roughly the caption text height when the label sits beside it.
            .frame(width: labelBesideRing ? 14 : 24, height: labelBesideRing ? 14 : 24)
            if labelBesideRing {
                Text(label)
                    .monospacedDigit()
            } else if showsHelp {
                Text(help)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(help): \(label)")
    }
}

/// Floating glass button that returns the transcript to the newest message.
private struct JumpToLatestButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.callout.weight(.semibold))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Jump to latest message")
    }
}

import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    var streaming: Bool = false
    /// Latest line of the model's reasoning, shown while it is thinking.
    var reasoning: String = ""
    /// Steps taken so far this turn, listed above the indicator while live.
    var liveSteps: [ActivityStep] = []
    /// Forks the conversation into a new branch ending at this message.
    var onBranch: (() -> Void)? = nil
    @State private var copied = false
    /// True once this bubble has streamed live, so the finished answer is
    /// revealed in chunks (messages loaded from history appear instantly).
    @State private var sawStreaming = false
    @State private var backgroundOn = true

    /// Only the final answer that just finished streaming is revealed, once.
    /// Intermediate tool-call messages and anything shown again later (older
    /// results, recycled rows, other conversations) appear instantly. The
    /// action buttons keep their space but stay hidden while this is true.
    private var revealing: Bool {
        sawStreaming && message.toolCallsJSON == nil
    }

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            // Breathing room above the bubble, visible when a new request is
            // scrolled to the top of the transcript.
            .padding(.top, 20)
        case .assistant:
            // An assistant message that carries tool calls is an intermediate
            // step ("pulling the full document…"); never show it, only the
            // final answer. (It stays in the history sent to the model.)
            if message.toolCallsJSON != nil {
                EmptyView()
            } else {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    // Tool calls themselves are not shown; just a compact note
                    // that the assistant spent time working before answering.
                    let steps = ActivityStep.decode(message.stepsJSON)
                    if !streaming, !steps.isEmpty {
                        ActivitySummaryView(steps: steps, seconds: message.workedSeconds)
                    } else if let seconds = message.workedSeconds {
                        Label(workedText(seconds), systemImage: "hammer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if streaming, !liveSteps.isEmpty {
                        ActivityStepsView(steps: liveSteps)
                            .padding(.top, 6)
                    }
                    // While waiting for the first token (or after a tool run),
                    // the bubble is empty — show a "thinking" indicator instead.
                    // The answer is shown only once it has been fully received;
                    // until then the indicator stays ("Working…" once text
                    // has started arriving).
                    if streaming {
                        ThinkingIndicator(label: message.content.isEmpty ? "Thinking…" : "Working…",
                                          detail: message.content.isEmpty ? reasoning : "")
                            .padding(.vertical, 10)
                            .padding(.horizontal, 4)
                    } else {
                        // Markdown renders live during streaming too; the parser
                        // tolerates unterminated constructs (open fences, partial
                        // emphasis) by rendering them as plain text until closed.
                        // No cross-fade with the indicator (two overlapping
                        // layers read as a ghost); the swap is instant and the
                        // bubble background fades in as the reveal begins.
                        MarkdownView(text: message.content, streaming: streaming,
                                     revealInChunks: revealing,
                                     onRevealFinished: { sawStreaming = false })
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background {
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color.appSecondaryBackground)
                                    .opacity(backgroundOn ? 1 : 0)
                                    .animation(.easeOut(duration: 0.4), value: backgroundOn)
                            }
                            .onAppear { backgroundOn = true }
                    }
                }
                .onChange(of: streaming, initial: true) { _, isStreaming in
                    if isStreaming {
                        sawStreaming = true
                        backgroundOn = false
                    }
                }
                // No trailing spacer: the answer bubble runs to the same
                // right edge as the user's bubble.
            }
            // Quick actions for finished answers, left-aligned under the bubble.
            if !streaming, !message.content.isEmpty {
                HStack(spacing: 0) {
                    Button {
                        Clipboard.string = message.content
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 36, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy response")

                    ShareLink(item: message.content) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 36, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share response")

                    if let onBranch {
                        Button(action: onBranch) {
                            Image(systemName: "arrow.trianglehead.branch")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 36, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Branch from here")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(revealing ? 0 : 1)
                .animation(.easeOut(duration: 0.3), value: revealing)
                .allowsHitTesting(!revealing)
            }
            }
        case .tool:
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Tool result", systemImage: "wrench.and.screwdriver")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(message.content)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.appTertiaryBackground, in: RoundedRectangle(cornerRadius: 10))
                }
                Spacer(minLength: 60)
            }
        case .system:
            // A system message in the transcript is a compaction summary: the
            // model sees it in place of everything above this point.
            DisclosureGroup {
                Text(message.content)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                Label("Earlier context compacted", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.appTertiaryBackground, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func workedText(_ seconds: Double) -> String {
        if seconds < 60 {
            return "Worked for \(max(1, Int(seconds.rounded()))) second\(Int(max(1, seconds.rounded())) == 1 ? "" : "s")"
        }
        let minutes = Int(seconds) / 60
        let rest = Int(seconds) % 60
        return "Worked for \(minutes)m \(rest)s"
    }
}

/// Shown while the request is in flight but no tokens have arrived yet
/// (server latency, or the pause between a tool result and the next reply).
struct ThinkingIndicator: View {
    /// Status wording: "Thinking…" while waiting on the model, "Working…"
    /// while tools or sub-agents run.
    var label: LocalizedStringKey = "Thinking…"
    /// Live reasoning line; replaces `label` (single line, truncated) when set.
    var detail: String = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        HStack(spacing: 8) {
            if reduceMotion {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: 4) {
                    ForEach(0..<3) { index in
                        Circle()
                            .fill(.secondary)
                            .frame(width: 6, height: 6)
                            .scaleEffect(phase && index == 1 ? 1.3 : 0.8)
                            .opacity(phase ? 1 : 0.4)
                            .animation(.easeInOut(duration: 0.5)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.15), value: phase)
                    }
                }
            }
            Group {
                if detail.isEmpty {
                    Text(label)
                } else {
                    Text(verbatim: detail)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onAppear { phase = true }
    }
}

import Foundation
import FoundationModels

/// Runs one chat turn through a `LanguageModelSession` backed by `DGXLanguageModel`.
/// The session runs the tool-call loop itself, so the caller only sees text
/// deltas and a callback per tool call.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
enum DGXSessionRunner {
    /// `history` holds the prior user/assistant turns as plain text; tool
    /// rounds from earlier turns aren't replayed. `onText` receives the full
    /// text of the current segment each time, not just the new part.
    static func stream(model: DGXLanguageModel,
                       instructions: String,
                       history: [(role: String, text: String)],
                       prompt: String,
                       temperature: Double,
                       maxTokens: Int?,
                       tools offered: [any DGXChat.Tool],
                       onText: @escaping @MainActor (String) -> Void,
                       onToolCall: @escaping @Sendable @MainActor (_ name: String, _ arguments: String) -> Void,
                       onToolFinish: @escaping @Sendable @MainActor (_ name: String, _ arguments: String) -> Void,
                       onUsage: @escaping @MainActor (_ input: Int, _ cached: Int, _ output: Int) -> Void,
                       onReasoning: @escaping @Sendable (String) -> Void) async throws {
        var model = model
        model.onReasoning = onReasoning
        let bridged: [any FoundationModels.Tool] = offered.guarded(by: ToolCallGuard()).compactMap {
            BridgedTool(wrapping: $0, onCall: onToolCall, onFinish: onToolFinish)
        }

        var entries: [Transcript.Entry] = []
        if !instructions.isEmpty {
            entries.append(.instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: instructions))],
                toolDefinitions: [])))
        }
        for turn in history {
            let segments: [Transcript.Segment] = [.text(Transcript.TextSegment(content: turn.text))]
            switch turn.role {
            case "user":
                entries.append(.prompt(Transcript.Prompt(segments: segments)))
            case "assistant":
                entries.append(.response(Transcript.Response(metadata: [:], segments: segments)))
            default:
                continue
            }
        }

        let session = LanguageModelSession(model: model, tools: bridged, transcript: Transcript(entries: entries))
        let options = GenerationOptions(temperature: temperature, maximumResponseTokens: maxTokens)

        // Each snapshot holds the whole text of the current segment. After a
        // tool round the session starts a new segment, so the text restarts;
        // forwarding the full text lets the caller replace the earlier
        // narration instead of gluing segments together.
        var lastUsage: [Int] = []
        for try await snapshot in session.streamResponse(to: prompt, options: options) {
            await onText(snapshot.content)
            // A snapshot's usage covers the current request only. The server's
            // exact figures come with a non-zero input count; before that the
            // session just sums per-chunk estimates.
            let usage = snapshot.usage
            guard usage.input.totalTokenCount > 0 else { continue }
            let current = [usage.input.totalTokenCount, usage.input.cachedTokenCount, usage.output.totalTokenCount]
            if current != lastUsage {
                lastUsage = current
                await onUsage(current[0], current[1], current[2])
            }
        }
    }
}

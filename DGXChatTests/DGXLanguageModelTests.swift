import Foundation
import FoundationModels
import Testing

/// Live tests: they talk to the real DGX server, so they fail when it's off or unreachable.
@Suite("DGXLanguageModel (live server)", .serialized)
struct DGXLanguageModelTests {
    static let baseURL = URL(string: "http://192.168.1.192:8000")!
    static let modelName = "qwen3.8-flash-next"

    private var model: DGXLanguageModel {
        DGXLanguageModel(baseURL: Self.baseURL, modelName: Self.modelName)
    }

    @Test(.timeLimit(.minutes(2)))
    func streamsPlainResponse() async throws {
        let session = LanguageModelSession(model: model, instructions: "Answer in one short sentence.")
        var snapshots = 0
        var final = ""
        for try await snapshot in session.streamResponse(to: "What is the capital of France?") {
            snapshots += 1
            final = snapshot.content
        }
        #expect(snapshots > 1, "Expected the text to stream in more than one piece.")
        #expect(final.localizedCaseInsensitiveContains("Paris"))
    }

    /// Probe: how usage reaches the app across a tool round (printed to the test log).
    @Test(.timeLimit(.minutes(2)))
    func reportsUsageAcrossToolRound() async throws {
        let recorder = CallRecorder()
        let session = LanguageModelSession(
            model: model,
            tools: [LookupCodeTool(recorder: recorder)],
            instructions: "You can't know access codes yourself. Always use the lookup_code tool for them.")
        var seen: [String] = []
        var lastLength = 0
        for try await snapshot in session.streamResponse(to: "What is the access code for the vault? Reply with the code only.") {
            let usage = snapshot.usage
            // What the snapshot's entries hold: kind and text length per entry.
            let entries = snapshot.transcriptEntries.map { entry -> String in
                func length(_ segments: [Transcript.Segment]) -> Int {
                    segments.reduce(0) { total, segment in
                        if case .text(let text) = segment { return total + text.content.count }
                        return total
                    }
                }
                switch entry {
                case .reasoning(let reasoning): return "reasoning(\(length(reasoning.segments)))"
                case .response(let response): return "response(\(length(response.segments)))"
                case .toolCalls: return "toolCalls"
                case .toolOutput: return "toolOutput"
                case .prompt: return "prompt"
                case .instructions: return "instructions"
                default: return "other"
                }
            }.joined(separator: ",")
            let line = "in=\(usage.input.totalTokenCount) out=\(usage.output.totalTokenCount) textLen=\(snapshot.content.count) entries=[\(entries)]"
            if seen.last != line || snapshot.content.count < lastLength { seen.append(line) }
            lastLength = snapshot.content.count
        }
        let final = session.usage
        print("USAGE-PROBE snapshots(changes only):\n" + seen.joined(separator: "\n"))
        print("USAGE-PROBE session.usage: in=\(final.input.totalTokenCount) cached=\(final.input.cachedTokenCount) out=\(final.output.totalTokenCount) reasoning=\(final.output.reasoningTokenCount)")
        #expect(final.output.totalTokenCount > 0)
    }

    @Test(.timeLimit(.minutes(2)))
    func callsToolAndUsesItsOutput() async throws {
        let recorder = CallRecorder()
        let session = LanguageModelSession(
            model: model,
            tools: [LookupCodeTool(recorder: recorder)],
            instructions: "You can't know access codes yourself. Always use the lookup_code tool for them.")

        let response = try await session.respond(to: "What is the access code for the vault? Reply with the code only.")

        // The code only exists inside the tool, so seeing it proves the full
        // round trip: tool call out, tool output back in, final answer.
        #expect(await recorder.names == ["vault"])
        #expect(response.content.contains(LookupCodeTool.vaultCode))
    }
}

// MARK: - Test tool

private actor CallRecorder {
    private(set) var names: [String] = []
    func record(_ name: String) { names.append(name) }
}

private struct LookupCodeTool: FoundationModels.Tool {
    static let vaultCode = "ZEBRA-7421"

    let recorder: CallRecorder

    let name = "lookup_code"
    let description = "Looks up the access code for a named place."

    @Generable
    struct Arguments {
        @Guide(description: "The place to look up, for example 'vault'.")
        var place: String
    }

    func call(arguments: Arguments) async throws -> String {
        await recorder.record(arguments.place.lowercased())
        return arguments.place.lowercased() == "vault" ? Self.vaultCode : "unknown place"
    }
}

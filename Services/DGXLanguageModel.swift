import Foundation
import FoundationModels

// MARK: - Model

/// A `LanguageModel` backed by an OpenAI-compatible chat-completions server
/// (the DGX box, vLLM, llama.cpp server, Ollama, LM Studio, …).
///
/// Use it like any other model:
/// `LanguageModelSession(model: DGXLanguageModel(baseURL: url, modelName: "qwen3"))`.
/// The type stays light; the executor does the work.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
struct DGXLanguageModel: LanguageModel {
    typealias Executor = DGXLanguageModelExecutor

    var baseURL: URL
    var modelName: String
    var apiKey: String?
    /// How much the model may think; sent with every request to the server.
    var thinkingEffort: ThinkingEffort = .serverDefault
    /// Called with each piece of reasoning text as it streams in, so an app can
    /// show live progress without waiting for the session's transcript.
    var onReasoning: (@Sendable (String) -> Void)?
    /// Most tool-call rounds one turn may take (the app's "Max tool rounds" setting).
    var maxToolRounds: Int = 8

    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.toolCalling, .reasoning])
    }

    /// The server is the lookup key, not the model name: switching models on
    /// the same server reuses one executor.
    var executorConfiguration: DGXLanguageModelExecutor.Configuration {
        .init(baseURL: baseURL, apiKey: apiKey)
    }
}

enum DGXModelError: LocalizedError {
    case tooManyToolRounds(Int)

    var errorDescription: String? {
        switch self {
        case .tooManyToolRounds(let limit):
            return "Stopped after \(limit) rounds of tool calls without a final answer. "
                + "The model may be retrying a call that keeps failing."
        }
    }
}

// MARK: - Executor

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
struct DGXLanguageModelExecutor: LanguageModelExecutor {
    typealias Model = DGXLanguageModel

    struct Configuration: Hashable, Sendable {
        var baseURL: URL
        var apiKey: String?
    }

    private let configuration: Configuration

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// One piece of server output, bridged from `LLMClient`'s callbacks.
    private enum Chunk: Sendable {
        case text(String)
        case reasoning(String)
        case toolCalls([APIToolCall])
        case usage(Usage)
    }

    func respond(to request: LanguageModelExecutorGenerationRequest,
                 model: DGXLanguageModel,
                 streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        // The session keeps calling tools until the model answers. A model that
        // retries the same failing call would never finish, so stop after the
        // same number of rounds the app's own loop allows.
        let toolRounds = request.transcript.reduce(0) { count, entry in
            if case .toolCalls = entry { return count + 1 }
            return count
        }
        if toolRounds >= model.maxToolRounds {
            throw DGXModelError.tooManyToolRounds(model.maxToolRounds)
        }

        var chat = ChatRequest(
            model: model.modelName,
            messages: try Self.messages(from: request.transcript),
            temperature: request.generationOptions.temperature,
            maxTokens: request.generationOptions.maximumResponseTokens,
            tools: try Self.tools(from: request.enabledToolDefinitions))
        model.thinkingEffort.apply(to: &chat)

        // `LLMClient` reports through synchronous callbacks, but sending on the
        // channel is async, so hop through a stream.
        let configuration = configuration
        let (chunks, continuation) = AsyncThrowingStream<Chunk, Error>.makeStream()
        let producer = Task {
            let client = LLMClient(baseURL: configuration.baseURL, apiKey: configuration.apiKey)
            do {
                try await client.streamChat(
                    chat,
                    onText: { continuation.yield(.text($0)) },
                    onToolCalls: { continuation.yield(.toolCalls($0)) },
                    onReasoning: { continuation.yield(.reasoning($0)) },
                    onUsage: { continuation.yield(.usage($0)) })
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in producer.cancel() }

        for try await chunk in chunks {
            switch chunk {
            case .text(let text):
                // The server doesn't report per-delta counts; a stream chunk is about one token.
                await channel.send(.response(action: .appendText(text, segmentID: nil, tokenCount: 1)))
            case .reasoning(let text):
                model.onReasoning?(text)
                await channel.send(.reasoning(action: .appendText(text, segmentID: nil, tokenCount: 1)))
            case .toolCalls(let calls):
                for call in calls {
                    await channel.send(.toolCalls(action: .toolCall(
                        id: call.id,
                        name: call.function.name,
                        action: .appendArguments(call.function.arguments, tokenCount: 0))))
                }
            case .usage(let usage):
                // Usage updates are cumulative, so the final chunk replaces any earlier one.
                await channel.send(.response(action: .updateUsage(
                    input: .init(totalTokenCount: usage.promptTokens,
                                 cachedTokenCount: usage.promptTokensDetails?.cachedTokens ?? 0),
                    output: .init(totalTokenCount: usage.completionTokens, reasoningTokenCount: 0))))
            }
        }
    }

    // MARK: Transcript → OpenAI messages

    /// Maps each transcript entry onto the chat roles the server understands.
    /// Reasoning and data entries are dropped: OpenAI-style servers don't accept them back.
    private static func messages(from transcript: Transcript) throws -> [APIMessage] {
        var messages: [APIMessage] = []
        for entry in transcript {
            switch entry {
            case .instructions(let instructions):
                messages.append(APIMessage(role: "system", content: text(of: instructions.segments)))
            case .prompt(let prompt):
                messages.append(APIMessage(role: "user", content: text(of: prompt.segments)))
            case .response(let response):
                messages.append(APIMessage(role: "assistant", content: text(of: response.segments)))
            case .reasoning, .data:
                continue
            case .toolCalls(let toolCalls):
                let calls = toolCalls.map {
                    APIToolCall(id: $0.id,
                                function: APIFunctionCall(name: $0.toolName,
                                                          arguments: $0.arguments.jsonString))
                }
                messages.append(APIMessage(role: "assistant", content: nil, toolCalls: calls))
            case .toolOutput(let output):
                messages.append(APIMessage(role: "tool", content: text(of: output.segments),
                                           toolCallId: output.id))
            @unknown default:
                continue // entry kinds added by newer SDKs have no chat-role equivalent
            }
        }
        return messages
    }

    private static func text(of segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            switch segment {
            case .text(let text): return text.content
            case .structure(let structured): return structured.content.jsonString
            default: return nil // attachments need `.vision`, which this model doesn't declare
            }
        }.joined(separator: "\n")
    }

    // MARK: Tool definitions → OpenAI tools

    /// `GenerationSchema` encodes as JSON Schema, which is what the server wants.
    private static func tools(from definitions: [Transcript.ToolDefinition]) throws -> [APITool]? {
        guard !definitions.isEmpty else { return nil }
        return try definitions.map { definition in
            let data = try JSONEncoder().encode(definition.parameters)
            let json = try JSONSerialization.jsonObject(with: data)
            guard case .object(let parameters) = AnyCodableValue(json: json) else {
                throw LLMError.decoding("Schema for tool \(definition.name) is not an object.")
            }
            return APITool(function: APIFunctionSpec(name: definition.name,
                                                    description: definition.description,
                                                    parameters: parameters))
        }
    }
}

private extension AnyCodableValue {
    /// Converts `JSONSerialization` output into the app's JSON value type.
    init(json: Any) {
        switch json {
        case let dict as [String: Any]:
            self = .object(dict.mapValues { AnyCodableValue(json: $0) })
        case let array as [Any]:
            self = .array(array.map { AnyCodableValue(json: $0) })
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if number.doubleValue == Double(number.intValue) {
                self = .int(number.intValue)
            } else {
                self = .double(number.doubleValue)
            }
        default:
            self = .string("")
        }
    }
}

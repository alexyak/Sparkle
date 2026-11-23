import Foundation

// MARK: - OpenAI-compatible chat completion API types

struct ChatRequest: Encodable {
    var model: String
    var messages: [APIMessage]
    var stream: Bool = true
    var temperature: Double?
    var maxTokens: Int?
    var tools: [APITool]?
    /// Ask the server to include a token-usage chunk at the end of the stream.
    var streamOptions: StreamOptions?
    /// Reasoning controls for vLLM-style servers; nil leaves the server default.
    var reasoningEffort: String?
    var chatTemplateKwargs: [String: Bool]?

    struct StreamOptions: Encodable {
        var includeUsage: Bool

        enum CodingKeys: String, CodingKey {
            case includeUsage = "include_usage"
        }
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, tools
        case maxTokens = "max_tokens"
        case streamOptions = "stream_options"
        case reasoningEffort = "reasoning_effort"
        case chatTemplateKwargs = "chat_template_kwargs"
    }
}

/// How much the model may think before answering. "Server default" sends
/// nothing; the others use the fields vLLM-style servers accept
/// (`chat_template_kwargs.enable_thinking` and `reasoning_effort`).
enum ThinkingEffort: String, CaseIterable, Identifiable {
    case serverDefault = "default"
    case off, low, medium, high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .serverDefault: return "Server default"
        case .off: return "Off"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    func apply(to request: inout ChatRequest) {
        switch self {
        case .serverDefault:
            break
        case .off:
            request.chatTemplateKwargs = ["enable_thinking": false]
        case .low, .medium, .high:
            request.reasoningEffort = rawValue
        }
    }
}

/// Token accounting reported by the server (final stream chunk or response body).
struct Usage: Decodable {
    var promptTokens: Int
    var completionTokens: Int
    var totalTokens: Int?
    var promptTokensDetails: PromptTokensDetails?

    struct PromptTokensDetails: Decodable {
        var cachedTokens: Int?

        enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
        }
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptTokensDetails = "prompt_tokens_details"
    }
}

struct APIMessage: Encodable {
    var role: String
    var content: String?
    var toolCalls: [APIToolCall]?
    var toolCallId: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }
}

struct APITool: Encodable {
    var type: String = "function"
    var function: APIFunctionSpec
}

struct APIFunctionSpec: Encodable {
    var name: String
    var description: String
    var parameters: [String: AnyCodableValue]
}

struct APIToolCall: Codable {
    var id: String
    var type: String = "function"
    var function: APIFunctionCall
}

struct APIFunctionCall: Codable {
    var name: String
    var arguments: String
}

// MARK: - Streaming response chunks

struct ChatStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            var role: String?
            var content: String?
            /// Reasoning tokens; servers name the field `reasoning` or
            /// `reasoning_content`.
            var reasoning: String?
            var reasoningContent: String?
            var toolCalls: [ToolCallDelta]?

            enum CodingKeys: String, CodingKey {
                case role, content, reasoning
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
            }
        }

        struct ToolCallDelta: Decodable {
            var index: Int?
            var id: String?
            var type: String?
            var function: FunctionDelta?

            struct FunctionDelta: Decodable {
                var name: String?
                var arguments: String?
            }
        }

        var index: Int?
        var delta: Delta?
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, delta
            case finishReason = "finish_reason"
        }
    }

    var id: String?
    var choices: [Choice]
    var usage: Usage?
}

// MARK: - Non-streaming response

struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            var role: String?
            var content: String?
            var toolCalls: [APIToolCall]?

            enum CodingKeys: String, CodingKey {
                case role, content
                case toolCalls = "tool_calls"
            }
        }
        var index: Int?
        var message: Message?
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, message
            case finishReason = "finish_reason"
        }
    }
    var id: String?
    var choices: [Choice]
    var usage: Usage?
}

// MARK: - Responses API

/// Which OpenAI-compatible API an endpoint is called with.
enum APIMode: String, CaseIterable, Identifiable, Codable {
    /// `POST /v1/chat/completions`.
    case chatCompletions
    /// `POST /v1/responses`, streamed on the request's own connection.
    case responses
    /// `POST /v1/responses` with `background: true`: the server keeps
    /// generating if the connection drops, and the client resumes the stream.
    case responsesBackground

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chatCompletions: return "Chat Completions"
        case .responses: return "Responses"
        case .responsesBackground: return "Responses (background)"
        }
    }

    var usesResponses: Bool { self != .chatCompletions }
    var isBackground: Bool { self == .responsesBackground }
}

/// Request body for `POST /v1/responses`, built from the same `ChatRequest`
/// the rest of the app produces.
struct ResponsesRequest: Encodable {
    var model: String
    var input: [Item]
    var stream: Bool
    /// Background runs must be stored server-side so they can be resumed.
    var background: Bool?
    var store: Bool?
    var temperature: Double?
    var maxOutputTokens: Int?
    var tools: [Tool]?
    var reasoning: Reasoning?

    enum Item: Encodable {
        case message(role: String, content: String)
        case functionCall(callID: String, name: String, arguments: String)
        case functionCallOutput(callID: String, output: String)

        private enum CodingKeys: String, CodingKey {
            case type, role, content, name, arguments, output
            case callID = "call_id"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .message(let role, let content):
                try c.encode("message", forKey: .type)
                try c.encode(role, forKey: .role)
                try c.encode(content, forKey: .content)
            case .functionCall(let callID, let name, let arguments):
                try c.encode("function_call", forKey: .type)
                try c.encode(callID, forKey: .callID)
                try c.encode(name, forKey: .name)
                try c.encode(arguments, forKey: .arguments)
            case .functionCallOutput(let callID, let output):
                try c.encode("function_call_output", forKey: .type)
                try c.encode(callID, forKey: .callID)
                try c.encode(output, forKey: .output)
            }
        }
    }

    /// Unlike chat completions, the function spec sits at the top level.
    struct Tool: Encodable {
        var type = "function"
        var name: String
        var description: String
        var parameters: [String: AnyCodableValue]
    }

    struct Reasoning: Encodable {
        var effort: String
    }

    enum CodingKeys: String, CodingKey {
        case model, input, stream, background, store, temperature, tools, reasoning
        case maxOutputTokens = "max_output_tokens"
    }

    init(_ chat: ChatRequest, stream: Bool, background: Bool) {
        model = chat.model
        self.stream = stream
        self.background = background ? true : nil
        store = background ? true : nil
        temperature = chat.temperature
        maxOutputTokens = chat.maxTokens
        tools = chat.tools?.map {
            Tool(name: $0.function.name, description: $0.function.description,
                 parameters: $0.function.parameters)
        }
        reasoning = chat.reasoningEffort.map(Reasoning.init(effort:))
        input = chat.messages.flatMap { message -> [Item] in
            switch message.role {
            case "tool":
                return [.functionCallOutput(callID: message.toolCallId ?? "",
                                            output: message.content ?? "")]
            case "assistant":
                var items: [Item] = []
                if let content = message.content, !content.isEmpty {
                    items.append(.message(role: "assistant", content: content))
                }
                for call in message.toolCalls ?? [] {
                    items.append(.functionCall(callID: call.id, name: call.function.name,
                                               arguments: call.function.arguments))
                }
                return items
            default:
                return [.message(role: message.role, content: message.content ?? "")]
            }
        }
    }
}

/// A response object, as returned by `GET /v1/responses/{id}`, a
/// non-streaming `POST`, or nested in stream events. Decoded with
/// `.convertFromSnakeCase`.
struct ResponsesObject: Decodable {
    var id: String?
    var status: String?
    var output: [OutputItem]?
    var usage: ResponsesUsage?
    var error: ResponsesError?
    var incompleteDetails: IncompleteDetails?

    struct OutputItem: Decodable {
        var type: String
        var id: String?
        var callId: String?
        var name: String?
        var arguments: String?
        var content: [ContentPart]?

        struct ContentPart: Decodable {
            var type: String
            var text: String?
        }

        /// Concatenated `output_text` parts of a message item.
        var text: String {
            (content ?? []).filter { $0.type == "output_text" }.compactMap(\.text).joined()
        }
    }

    struct ResponsesError: Decodable {
        var message: String?
    }

    struct IncompleteDetails: Decodable {
        var reason: String?
    }

    var isTerminal: Bool {
        ["completed", "failed", "cancelled", "incomplete"].contains(status ?? "")
    }
}

struct ResponsesUsage: Decodable {
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
    var inputTokensDetails: Details?

    struct Details: Decodable {
        var cachedTokens: Int?
    }

    /// The same accounting the chat-completions path reports.
    var asUsage: Usage {
        Usage(promptTokens: inputTokens ?? 0,
              completionTokens: outputTokens ?? 0,
              totalTokens: totalTokens,
              promptTokensDetails: Usage.PromptTokensDetails(cachedTokens: inputTokensDetails?.cachedTokens))
    }
}

/// One server-sent event of a streamed response. Only the fields the client
/// reads are decoded; `type` selects which of them are present.
struct ResponsesStreamEvent: Decodable {
    var type: String
    var sequenceNumber: Int?
    var delta: String?
    var outputIndex: Int?
    var arguments: String?
    var item: ResponsesObject.OutputItem?
    var response: ResponsesObject?
    /// Set on `error` events.
    var message: String?
}

// MARK: - Models list

struct ModelList: Decodable {
    struct Model: Decodable, Identifiable {
        var id: String
        var object: String?
        var ownedBy: String?

        enum CodingKeys: String, CodingKey {
            case id, object
            case ownedBy = "owned_by"
        }
    }
    var data: [Model]
}

/// Minimal JSON value used to encode tool parameter schemas without pulling in a JSON library.
enum AnyCodableValue: Encodable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: AnyCodableValue])
    case array([AnyCodableValue])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        }
    }
}

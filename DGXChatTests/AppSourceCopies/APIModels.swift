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

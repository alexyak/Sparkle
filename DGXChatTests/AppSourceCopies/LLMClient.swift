import Foundation

/// Errors surfaced by the LLM client.
enum LLMError: LocalizedError {
    case invalidURL
    case http(Int, String)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The server URL is not valid."
        case .http(let code, let body):
            return "Server returned \(code): \(body.prefix(300))"
        case .decoding(let detail):
            return "Could not parse the server response: \(detail)"
        case .transport(let detail):
            return "Network error: \(detail)"
        }
    }
}

/// Thin client for an OpenAI-compatible server (vLLM, llama.cpp server, Ollama in
/// OpenAI mode, LM Studio, …). Works over plain HTTP on the LAN.
final class LLMClient {
    var baseURL: URL
    var apiKey: String?

    init(baseURL: URL, apiKey: String? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    private var apiBase: URL {
        // Accept both "http://host:port" and "http://host:port/v1"
        if baseURL.path.hasSuffix("/v1") {
            return baseURL
        }
        return baseURL.appendingPathComponent("v1")
    }

    private func makeRequest(path: String, method: String = "POST", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: apiBase.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        request.timeoutInterval = 600
        return request
    }

    // MARK: - Models

    func fetchModels() async throws -> [ModelList.Model] {
        var request = makeRequest(path: "models", method: "GET")
        request.httpBody = nil
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.transport("Unexpected response (not HTTP).")
        }
        guard http.statusCode == 200 else {
            throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(ModelList.self, from: data).data
        } catch {
            throw LLMError.decoding(error.localizedDescription)
        }
    }

    // MARK: - Streaming chat

    /// Streams a chat completion. Emits assistant text deltas as they arrive.
    /// Tool-call deltas are accumulated and returned via `onToolCalls` when the
    /// stream finishes with `finish_reason == "tool_calls"`.
    func streamChat(_ request: ChatRequest,
                    onText: @escaping (String) -> Void,
                    onToolCalls: @escaping ([APIToolCall]) -> Void,
                    onReasoning: @escaping (String) -> Void = { _ in },
                    onUsage: @escaping (Usage) -> Void = { _ in }) async throws {
        // Ask for a final usage chunk so the UI can show cache hits and
        // context usage. Servers that reject unknown fields can opt out.
        var request = request
        if request.streamOptions == nil {
            request.streamOptions = ChatRequest.StreamOptions(includeUsage: true)
        }
        guard var body = try? JSONEncoder().encode(request) else {
            throw LLMError.decoding("Failed to encode request.")
        }
        var urlRequest = makeRequest(path: "chat/completions", body: body)
        var (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        guard var http = response as? HTTPURLResponse else {
            throw LLMError.transport("Unexpected response (not HTTP).")
        }
        if http.statusCode != 200 {
            var bodyText = ""
            for try await line in bytes.lines {
                bodyText += line
                if bodyText.count > 4000 { break }
            }
            // Some servers reject stream_options outright — retry once without it.
            if http.statusCode == 400, request.streamOptions != nil {
                request.streamOptions = nil
                guard let retryBody = try? JSONEncoder().encode(request) else {
                    throw LLMError.http(http.statusCode, bodyText)
                }
                body = retryBody
                urlRequest = makeRequest(path: "chat/completions", body: body)
                (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                guard let retryHTTP = response as? HTTPURLResponse else {
                    throw LLMError.transport("Unexpected response (not HTTP).")
                }
                http = retryHTTP
            }
            guard http.statusCode == 200 else {
                throw LLMError.http(http.statusCode, bodyText)
            }
        }

        var toolAccumulator: [Int: APIToolCall] = [:]
        let decoder = JSONDecoder()

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }
            let chunk: ChatStreamChunk
            do {
                chunk = try decoder.decode(ChatStreamChunk.self, from: data)
            } catch {
                continue // skip keep-alives / malformed lines
            }
            // The usage chunk typically has no choices — emit it before the
            // choices guard so it isn't skipped.
            if let usage = chunk.usage {
                onUsage(usage)
            }
            guard let choice = chunk.choices.first else { continue }

            if let reasoning = choice.delta?.reasoningContent ?? choice.delta?.reasoning,
               !reasoning.isEmpty {
                onReasoning(reasoning)
            }
            if let content = choice.delta?.content, !content.isEmpty {
                onText(content)
            }
            if let deltas = choice.delta?.toolCalls {
                for delta in deltas {
                    let index = delta.index ?? 0
                    var existing = toolAccumulator[index] ?? APIToolCall(id: "", function: APIFunctionCall(name: "", arguments: ""))
                    if let id = delta.id, !id.isEmpty { existing.id = id }
                    if let name = delta.function?.name { existing.function.name += name }
                    if let args = delta.function?.arguments { existing.function.arguments += args }
                    toolAccumulator[index] = existing
                }
            }
            if let reason = choice.finishReason, reason == "tool_calls" {
                let calls = toolAccumulator.keys.sorted().map { toolAccumulator[$0]! }
                if !calls.isEmpty {
                    onToolCalls(calls)
                }
            }
        }
    }

    // MARK: - Non-streaming chat (used for tool-call rounds if needed)

    func chat(_ request: ChatRequest) async throws -> ChatResponse {
        var req = request
        req.stream = false
        guard let body = try? JSONEncoder().encode(req) else {
            throw LLMError.decoding("Failed to encode request.")
        }
        let (data, response) = try await URLSession.shared.data(for: makeRequest(path: "chat/completions", body: body))
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.transport("Unexpected response (not HTTP).")
        }
        guard http.statusCode == 200 else {
            throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw LLMError.decoding(error.localizedDescription)
        }
    }
}

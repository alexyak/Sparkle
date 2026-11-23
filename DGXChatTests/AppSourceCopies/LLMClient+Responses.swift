import Foundation

// MARK: - Responses API

extension LLMClient {
    /// Most consecutive failed attempts to resume a background stream before
    /// falling back to polling the stored response.
    private static let maxResumeAttempts = 5

    /// Streams a response from `POST /v1/responses`, reporting through the same
    /// callbacks as the chat-completions path.
    ///
    /// With `background`, the server keeps generating if the connection drops
    /// (app suspended, network change). The client then resumes the event
    /// stream from the last sequence number it saw, or polls the stored
    /// response if the stream can't be resumed. Cancelling the task cancels
    /// the run on the server.
    func streamResponses(_ chat: ChatRequest,
                         background: Bool,
                         onText: @escaping (String) -> Void,
                         onToolCalls: @escaping ([APIToolCall]) -> Void,
                         onReasoning: @escaping (String) -> Void,
                         onUsage: @escaping (Usage) -> Void) async throws {
        let payload = ResponsesRequest(chat, stream: true, background: background)
        guard let body = try? JSONEncoder().encode(payload) else {
            throw LLMError.decoding("Failed to encode request.")
        }
        let processor = ResponsesStreamProcessor(onText: onText, onToolCalls: onToolCalls,
                                                 onReasoning: onReasoning, onUsage: onUsage)
        var urlRequest = makeRequest(path: "responses", body: body)
        var failedAttempts = 0

        while true {
            let sequenceBefore = processor.lastSequence
            do {
                try await consumeResponsesStream(urlRequest, into: processor)
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    if background { cancelRun(processor.responseID) }
                    throw error
                }
                // Only a background run with a known id can be picked up again.
                guard background, processor.responseID != nil, !processor.isFinished else {
                    throw error
                }
                // An HTTP error on resume means the stream can't be replayed.
                if case LLMError.http = error {
                    failedAttempts = Self.maxResumeAttempts
                }
            }
            if processor.isFinished || !background { break }

            // The stream ended or dropped before a terminal event.
            if processor.lastSequence != sequenceBefore { failedAttempts = 0 }
            failedAttempts += 1
            if failedAttempts > Self.maxResumeAttempts {
                try await pollResponse(processor)
                break
            }
            try await Task.sleep(for: .seconds(1))
            guard let id = processor.responseID else { break }
            urlRequest = resumeRequest(id: id, after: processor.lastSequence)
        }
        try processor.complete()
    }

    /// Non-streaming Responses call, mapped onto `ChatResponse`.
    func chatResponses(_ chat: ChatRequest) async throws -> ChatResponse {
        let payload = ResponsesRequest(chat, stream: false, background: false)
        guard let body = try? JSONEncoder().encode(payload) else {
            throw LLMError.decoding("Failed to encode request.")
        }
        let (data, response) = try await URLSession.shared.data(for: makeRequest(path: "responses", body: body))
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.transport("Unexpected response (not HTTP).")
        }
        guard http.statusCode == 200 else {
            throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let object: ResponsesObject
        do {
            object = try Self.responsesDecoder.decode(ResponsesObject.self, from: data)
        } catch {
            throw LLMError.decoding(error.localizedDescription)
        }
        if object.status == "failed" {
            throw LLMError.response(object.error?.message ?? "The response failed.")
        }
        let items = object.output ?? []
        let text = items.filter { $0.type == "message" }.map(\.text).joined()
        let calls = items.filter { $0.type == "function_call" }.map {
            APIToolCall(id: $0.callId ?? $0.id ?? "",
                        function: APIFunctionCall(name: $0.name ?? "", arguments: $0.arguments ?? ""))
        }
        let message = ChatResponse.Choice.Message(role: "assistant",
                                                  content: text.isEmpty ? nil : text,
                                                  toolCalls: calls.isEmpty ? nil : calls)
        let reason = calls.isEmpty ? (object.status == "incomplete" ? "length" : "stop") : "tool_calls"
        return ChatResponse(id: object.id,
                            choices: [ChatResponse.Choice(index: 0, message: message, finishReason: reason)],
                            usage: object.usage?.asUsage)
    }

    // MARK: - Plumbing

    fileprivate static let responsesDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// Opens `urlRequest` and feeds its server-sent events to `processor`
    /// until the stream ends or the response reaches a terminal state.
    private func consumeResponsesStream(_ urlRequest: URLRequest,
                                        into processor: ResponsesStreamProcessor) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.transport("Unexpected response (not HTTP).")
        }
        guard http.statusCode == 200 else {
            var bodyText = ""
            for try await line in bytes.lines {
                bodyText += line
                if bodyText.count > 4000 { break }
            }
            throw LLMError.http(http.statusCode, bodyText)
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let text = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if text == "[DONE]" { break }
            guard let data = text.data(using: .utf8),
                  let event = try? Self.responsesDecoder.decode(ResponsesStreamEvent.self, from: data)
            else { continue } // keep-alives / unknown events
            processor.handle(event)
            if processor.isFinished { break }
        }
    }

    /// `GET /v1/responses/{id}?stream=true&starting_after=n` replays a stored
    /// background run's events after sequence number `n`.
    private func resumeRequest(id: String, after sequence: Int?) -> URLRequest {
        var request = makeRequest(path: "responses/\(id)", method: "GET")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var items = [URLQueryItem(name: "stream", value: "true")]
        if let sequence {
            items.append(URLQueryItem(name: "starting_after", value: String(sequence)))
        }
        if let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = items
            request.url = components.url
        }
        return request
    }

    /// Last resort for a background run whose stream can't be resumed: poll
    /// the stored response until it finishes, then hand over what is missing.
    private func pollResponse(_ processor: ResponsesStreamProcessor) async throws {
        guard let id = processor.responseID else { return }
        while true {
            try await Task.sleep(for: .seconds(2))
            let (data, response) = try await URLSession.shared.data(for: makeRequest(path: "responses/\(id)", method: "GET"))
            guard let http = response as? HTTPURLResponse else {
                throw LLMError.transport("Unexpected response (not HTTP).")
            }
            guard http.statusCode == 200 else {
                throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            let object: ResponsesObject
            do {
                object = try Self.responsesDecoder.decode(ResponsesObject.self, from: data)
            } catch {
                throw LLMError.decoding(error.localizedDescription)
            }
            if object.isTerminal {
                processor.apply(finalResponse: object)
                return
            }
        }
    }

    /// Asks the server to stop a background run nobody is listening to anymore.
    private func cancelRun(_ id: String?) {
        guard let id else { return }
        let request = makeRequest(path: "responses/\(id)/cancel")
        Task.detached { _ = try? await URLSession.shared.data(for: request) }
    }
}

// MARK: - Event processing

/// Turns Responses API stream events into the client's callbacks. Lives
/// across resume attempts so a resumed stream continues where it stopped.
final class ResponsesStreamProcessor {
    private let onText: (String) -> Void
    private let onToolCalls: ([APIToolCall]) -> Void
    private let onReasoning: (String) -> Void
    private let onUsage: (Usage) -> Void

    private(set) var responseID: String?
    private(set) var lastSequence: Int?
    private(set) var isFinished = false

    /// Tool calls keyed by the output index they arrive at.
    private var calls: [Int: APIToolCall] = [:]
    private var emittedText = ""
    private var failure: LLMError?
    private var incompleteReason: String?
    // Reasoning alone doesn't count as output: a run that stops at the token
    // limit with only reasoning is a failure worth reporting.
    private var producedOutput = false

    init(onText: @escaping (String) -> Void,
         onToolCalls: @escaping ([APIToolCall]) -> Void,
         onReasoning: @escaping (String) -> Void,
         onUsage: @escaping (Usage) -> Void) {
        self.onText = onText
        self.onToolCalls = onToolCalls
        self.onReasoning = onReasoning
        self.onUsage = onUsage
    }

    func handle(_ event: ResponsesStreamEvent) {
        if let sequence = event.sequenceNumber { lastSequence = sequence }
        if responseID == nil, let id = event.response?.id { responseID = id }
        let index = event.outputIndex ?? 0

        switch event.type {
        case "response.output_text.delta":
            if let delta = event.delta, !delta.isEmpty {
                producedOutput = true
                emittedText += delta
                onText(delta)
            }
        case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
            if let delta = event.delta, !delta.isEmpty { onReasoning(delta) }
        case "response.output_item.added":
            if let item = event.item, item.type == "function_call" {
                producedOutput = true
                calls[index] = Self.call(from: item)
            }
        case "response.function_call_arguments.delta":
            if let delta = event.delta { calls[index]?.function.arguments += delta }
        case "response.function_call_arguments.done":
            if let arguments = event.arguments { calls[index]?.function.arguments = arguments }
        case "response.output_item.done":
            if let item = event.item, item.type == "function_call" {
                calls[index] = Self.call(from: item)
            }
        case "response.completed":
            finish(with: event.response)
        case "response.incomplete":
            incompleteReason = event.response?.incompleteDetails?.reason
            finish(with: event.response)
        case "response.failed":
            failure = .response(event.response?.error?.message ?? "The response failed.")
            isFinished = true
        case "response.cancelled":
            failure = .response("The run was cancelled on the server.")
            isFinished = true
        case "error":
            failure = .response(event.message ?? "Unknown error.")
            isFinished = true
        default:
            break
        }
    }

    /// Takes the final state of a run that was polled instead of streamed,
    /// delivering whatever text and tool calls the stream never got to.
    func apply(finalResponse response: ResponsesObject) {
        let items = response.output ?? []
        let text = items.filter { $0.type == "message" }.map(\.text).joined()
        if text.hasPrefix(emittedText), text.count > emittedText.count {
            let rest = String(text.dropFirst(emittedText.count))
            producedOutput = true
            emittedText = text
            onText(rest)
        }
        for (offset, item) in items.enumerated() where item.type == "function_call" {
            producedOutput = true
            calls[offset] = Self.call(from: item)
        }
        switch response.status {
        case "failed":
            failure = .response(response.error?.message ?? "The response failed.")
        case "cancelled":
            failure = .response("The run was cancelled on the server.")
        case "incomplete":
            incompleteReason = response.incompleteDetails?.reason
        default:
            break
        }
        finish(with: response)
    }

    /// Flushes pending tool calls and reports a failed or truncated run.
    func complete() throws {
        if let failure { throw failure }
        let pending = calls.keys.sorted().compactMap { calls[$0] }
        if pending.contains(where: { !$0.function.name.isEmpty }) {
            onToolCalls(pending)
            calls = [:]
        }
        if incompleteReason == "max_output_tokens", !producedOutput { throw LLMError.truncated }
    }

    private func finish(with response: ResponsesObject?) {
        if let usage = response?.usage { onUsage(usage.asUsage) }
        isFinished = true
    }

    private static func call(from item: ResponsesObject.OutputItem) -> APIToolCall {
        APIToolCall(id: item.callId ?? item.id ?? "",
                    function: APIFunctionCall(name: item.name ?? "", arguments: item.arguments ?? ""))
    }
}

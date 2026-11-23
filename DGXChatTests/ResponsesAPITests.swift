import Foundation
import Testing

// MARK: - Helpers

/// Collects what `LLMClient` / `ResponsesStreamProcessor` report.
private final class Recorder {
    var text = ""
    var reasoning = ""
    var toolCalls: [[APIToolCall]] = []
    var usage: [Usage] = []
}

private func makeProcessor(_ recorder: Recorder) -> ResponsesStreamProcessor {
    ResponsesStreamProcessor(
        onText: { recorder.text += $0 },
        onToolCalls: { recorder.toolCalls.append($0) },
        onReasoning: { recorder.reasoning += $0 },
        onUsage: { recorder.usage.append($0) })
}

private func event(_ json: String) throws -> ResponsesStreamEvent {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(ResponsesStreamEvent.self, from: Data(json.utf8))
}

private func jsonObject(_ request: ResponsesRequest) throws -> [String: Any] {
    let data = try JSONEncoder().encode(request)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func sampleChat() -> ChatRequest {
    var chat = ChatRequest(
        model: "qwen",
        messages: [
            APIMessage(role: "system", content: "Be brief."),
            APIMessage(role: "user", content: "Weather in Paris?"),
            APIMessage(role: "assistant", content: nil,
                       toolCalls: [APIToolCall(id: "call_1",
                                               function: APIFunctionCall(name: "weather",
                                                                         arguments: "{\"city\":\"Paris\"}"))]),
            APIMessage(role: "tool", content: "Sunny", toolCallId: "call_1")
        ],
        temperature: 0.5,
        maxTokens: 256,
        tools: [APITool(function: APIFunctionSpec(
            name: "weather", description: "Look up weather",
            parameters: ["type": .string("object")]))])
    chat.reasoningEffort = "high"
    return chat
}

// MARK: - Request conversion

@Suite("Responses request")
struct ResponsesRequestTests {
    @Test func convertsMessagesToInputItems() throws {
        let json = try jsonObject(ResponsesRequest(sampleChat(), stream: true, background: false))
        let input = try #require(json["input"] as? [[String: Any]])

        #expect(input.count == 4)
        #expect(input[0]["role"] as? String == "system")
        #expect(input[0]["content"] as? String == "Be brief.")
        #expect(input[1]["role"] as? String == "user")
        // An assistant message with only tool calls becomes just the function_call item.
        #expect(input[2]["type"] as? String == "function_call")
        #expect(input[2]["call_id"] as? String == "call_1")
        #expect(input[2]["name"] as? String == "weather")
        #expect(input[2]["arguments"] as? String == "{\"city\":\"Paris\"}")
        #expect(input[3]["type"] as? String == "function_call_output")
        #expect(input[3]["call_id"] as? String == "call_1")
        #expect(input[3]["output"] as? String == "Sunny")
    }

    @Test func assistantTextAndToolCallsBothSurvive() throws {
        let chat = ChatRequest(model: "m", messages: [
            APIMessage(role: "assistant", content: "Checking.",
                       toolCalls: [APIToolCall(id: "c", function: APIFunctionCall(name: "t", arguments: "{}"))])
        ])
        let json = try jsonObject(ResponsesRequest(chat, stream: true, background: false))
        let input = try #require(json["input"] as? [[String: Any]])
        #expect(input.map { $0["type"] as? String } == ["message", "function_call"])
    }

    @Test func flattensToolsAndMapsLimits() throws {
        let json = try jsonObject(ResponsesRequest(sampleChat(), stream: true, background: false))
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "function")
        #expect(tools[0]["name"] as? String == "weather")
        #expect(tools[0]["description"] as? String == "Look up weather")
        #expect(tools[0]["function"] == nil, "Responses tools carry no nested function object.")

        #expect(json["max_output_tokens"] as? Int == 256)
        #expect(json["max_tokens"] == nil)
        #expect(json["temperature"] as? Double == 0.5)
        #expect((json["reasoning"] as? [String: Any])?["effort"] as? String == "high")
        #expect(json["stream"] as? Bool == true)
        #expect(json["messages"] == nil)
    }

    @Test func backgroundRunsAreStored() throws {
        let background = try jsonObject(ResponsesRequest(sampleChat(), stream: true, background: true))
        #expect(background["background"] as? Bool == true)
        #expect(background["store"] as? Bool == true)

        let plain = try jsonObject(ResponsesRequest(sampleChat(), stream: true, background: false))
        #expect(plain["background"] == nil)
        #expect(plain["store"] == nil)
    }

    @Test func apiModeFlags() {
        #expect(!APIMode.chatCompletions.usesResponses)
        #expect(APIMode.responses.usesResponses)
        #expect(!APIMode.responses.isBackground)
        #expect(APIMode.responsesBackground.usesResponses)
        #expect(APIMode.responsesBackground.isBackground)
    }
}

// MARK: - Event processing

@Suite("Responses stream processor")
struct ResponsesStreamProcessorTests {
    @Test func streamsTextReasoningAndUsage() throws {
        let recorder = Recorder()
        let processor = makeProcessor(recorder)
        processor.handle(try event(#"{"type":"response.created","sequence_number":0,"response":{"id":"resp_1","status":"in_progress"}}"#))
        processor.handle(try event(#"{"type":"response.reasoning_text.delta","sequence_number":1,"delta":"hmm "}"#))
        processor.handle(try event(#"{"type":"response.output_text.delta","sequence_number":2,"delta":"Hel"}"#))
        processor.handle(try event(#"{"type":"response.output_text.delta","sequence_number":3,"delta":"lo"}"#))
        #expect(!processor.isFinished)
        processor.handle(try event(#"{"type":"response.completed","sequence_number":4,"response":{"id":"resp_1","status":"completed","usage":{"input_tokens":10,"output_tokens":4,"total_tokens":14,"input_tokens_details":{"cached_tokens":6}}}}"#))

        #expect(processor.isFinished)
        #expect(processor.responseID == "resp_1")
        #expect(processor.lastSequence == 4)
        #expect(recorder.text == "Hello")
        #expect(recorder.reasoning == "hmm ")
        let usage = try #require(recorder.usage.first)
        #expect(usage.promptTokens == 10)
        #expect(usage.completionTokens == 4)
        #expect(usage.totalTokens == 14)
        #expect(usage.promptTokensDetails?.cachedTokens == 6)
        try processor.complete()
        #expect(recorder.toolCalls.isEmpty)
    }

    @Test func accumulatesFunctionCallArguments() throws {
        let recorder = Recorder()
        let processor = makeProcessor(recorder)
        processor.handle(try event(#"{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_9","name":"weather","arguments":""}}"#))
        processor.handle(try event(#"{"type":"response.function_call_arguments.delta","output_index":1,"delta":"{\"city\":"}"#))
        processor.handle(try event(#"{"type":"response.function_call_arguments.delta","output_index":1,"delta":"\"Paris\"}"}"#))
        processor.handle(try event(#"{"type":"response.completed","response":{"status":"completed"}}"#))
        try processor.complete()

        let calls = try #require(recorder.toolCalls.first)
        #expect(recorder.toolCalls.count == 1)
        #expect(calls.count == 1)
        #expect(calls[0].id == "call_9", "The model's call_id, not the item id, answers the tool result.")
        #expect(calls[0].function.name == "weather")
        #expect(calls[0].function.arguments == #"{"city":"Paris"}"#)

        // Completing again must not report the same calls twice.
        try processor.complete()
        #expect(recorder.toolCalls.count == 1)
    }

    @Test func itemDoneOverridesAccumulatedArguments() throws {
        let recorder = Recorder()
        let processor = makeProcessor(recorder)
        processor.handle(try event(#"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"c","name":"t","arguments":""}}"#))
        processor.handle(try event(#"{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","call_id":"c","name":"t","arguments":"{\"a\":1}"}}"#))
        processor.handle(try event(#"{"type":"response.completed","response":{"status":"completed"}}"#))
        try processor.complete()
        #expect(recorder.toolCalls.first?.first?.function.arguments == #"{"a":1}"#)
    }

    @Test func multipleToolCallsKeepOutputOrder() throws {
        let recorder = Recorder()
        let processor = makeProcessor(recorder)
        processor.handle(try event(#"{"type":"response.output_item.done","output_index":2,"item":{"type":"function_call","call_id":"b","name":"second","arguments":"{}"}}"#))
        processor.handle(try event(#"{"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","call_id":"a","name":"first","arguments":"{}"}}"#))
        processor.handle(try event(#"{"type":"response.completed","response":{"status":"completed"}}"#))
        try processor.complete()
        #expect(recorder.toolCalls.first?.map(\.function.name) == ["first", "second"])
    }

    @Test func failedResponseThrows() throws {
        let processor = makeProcessor(Recorder())
        processor.handle(try event(#"{"type":"response.failed","response":{"status":"failed","error":{"message":"out of memory"}}}"#))
        #expect(processor.isFinished)
        #expect(throws: LLMError.self) { try processor.complete() }
        do {
            try processor.complete()
        } catch let error as LLMError {
            #expect(error.errorDescription?.contains("out of memory") == true)
        }
    }

    @Test func errorEventThrows() throws {
        let processor = makeProcessor(Recorder())
        processor.handle(try event(#"{"type":"error","message":"bad request"}"#))
        #expect(processor.isFinished)
        #expect(throws: LLMError.self) { try processor.complete() }
    }

    @Test func truncatedWithOnlyReasoningThrows() throws {
        let processor = makeProcessor(Recorder())
        processor.handle(try event(#"{"type":"response.reasoning_text.delta","delta":"thinking…"}"#))
        processor.handle(try event(#"{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}"#))
        do {
            try processor.complete()
            Issue.record("Expected a truncation error.")
        } catch LLMError.truncated {
            // expected
        }
    }

    @Test func truncatedAfterOutputIsNotAnError() throws {
        let recorder = Recorder()
        let processor = makeProcessor(recorder)
        processor.handle(try event(#"{"type":"response.output_text.delta","delta":"Partial answer"}"#))
        processor.handle(try event(#"{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}"#))
        try processor.complete()
        #expect(recorder.text == "Partial answer")
    }

    @Test func unknownEventsAreIgnored() throws {
        let recorder = Recorder()
        let processor = makeProcessor(recorder)
        processor.handle(try event(#"{"type":"response.content_part.added","sequence_number":3}"#))
        #expect(!processor.isFinished)
        #expect(processor.lastSequence == 3)
        #expect(recorder.text.isEmpty)
    }

    @Test func pollingDeliversOnlyTheMissingText() throws {
        let recorder = Recorder()
        let processor = makeProcessor(recorder)
        processor.handle(try event(#"{"type":"response.created","sequence_number":0,"response":{"id":"resp_2"}}"#))
        processor.handle(try event(#"{"type":"response.output_text.delta","sequence_number":1,"delta":"Hello "}"#))

        let final = """
        {"id":"resp_2","status":"completed","output":[
          {"type":"reasoning","id":"rs_1"},
          {"type":"message","content":[{"type":"output_text","text":"Hello world"}]},
          {"type":"function_call","id":"fc","call_id":"call_x","name":"t","arguments":"{}"}
        ],"usage":{"input_tokens":3,"output_tokens":2}}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        processor.apply(finalResponse: try decoder.decode(ResponsesObject.self, from: Data(final.utf8)))
        try processor.complete()

        #expect(processor.isFinished)
        #expect(recorder.text == "Hello world")
        #expect(recorder.toolCalls.first?.first?.id == "call_x")
        #expect(recorder.usage.first?.promptTokens == 3)
    }

    @Test func pollingFailureThrows() throws {
        let processor = makeProcessor(Recorder())
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let final = #"{"id":"r","status":"failed","error":{"message":"boom"}}"#
        processor.apply(finalResponse: try decoder.decode(ResponsesObject.self, from: Data(final.utf8)))
        #expect(throws: LLMError.self) { try processor.complete() }
    }
}

// MARK: - Client against a stubbed server

/// Answers every request from `handler`, so the client runs end to end
/// without a network. Registered globally; suites using it run serialized.
private final class StubURLProtocol: URLProtocol {
    typealias Handler = (URLRequest, Data) -> (status: Int, body: String)
    nonisolated(unsafe) static var handler: Handler?
    nonisolated(unsafe) static var requests: [(request: URLRequest, body: Data)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        Self.requests.append((request, body))
        let result = Self.handler?(request, body) ?? (status: 500, body: "no handler")
        let response = HTTPURLResponse(url: request.url!, statusCode: result.status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Server-sent events for the given JSON payloads.
private func sse(_ payloads: [String]) -> String {
    payloads.map { "data: \($0)\n\n" }.joined()
}

@Suite("LLMClient Responses API (stubbed server)", .serialized)
struct LLMClientResponsesTests {
    private let baseURL = URL(string: "http://stub.test:8000")!

    private func prepare(_ handler: @escaping StubURLProtocol.Handler) {
        StubURLProtocol.requests = []
        StubURLProtocol.handler = handler
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    private func finish() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        StubURLProtocol.handler = nil
    }

    private func chat() -> ChatRequest {
        ChatRequest(model: "qwen", messages: [APIMessage(role: "user", content: "Hi")])
    }

    @Test func plainResponsesStreamsText() async throws {
        prepare { _, _ in
            (200, sse([
                #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_1"}}"#,
                #"{"type":"response.output_text.delta","sequence_number":1,"delta":"Hi "}"#,
                #"{"type":"response.output_text.delta","sequence_number":2,"delta":"there"}"#,
                #"{"type":"response.completed","sequence_number":3,"response":{"id":"resp_1","status":"completed","usage":{"input_tokens":5,"output_tokens":2}}}"#
            ]))
        }
        defer { finish() }

        let recorder = Recorder()
        let client = LLMClient(baseURL: baseURL, apiMode: .responses)
        try await client.streamChat(chat(), onText: { recorder.text += $0 },
                                    onToolCalls: { recorder.toolCalls.append($0) },
                                    onUsage: { recorder.usage.append($0) })

        #expect(recorder.text == "Hi there")
        #expect(recorder.usage.first?.promptTokens == 5)
        #expect(StubURLProtocol.requests.count == 1)
        let sent = try #require(StubURLProtocol.requests.first)
        #expect(sent.request.url?.path == "/v1/responses")
        #expect(sent.request.httpMethod == "POST")
        let body = try #require(try JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        #expect(body["stream"] as? Bool == true)
        #expect(body["background"] == nil)
    }

    @Test func chatCompletionsModeStillUsesChatCompletions() async throws {
        prepare { _, _ in
            (200, sse([
                #"{"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#,
                "[DONE]"
            ]))
        }
        defer { finish() }

        let recorder = Recorder()
        let client = LLMClient(baseURL: baseURL)
        try await client.streamChat(chat(), onText: { recorder.text += $0 }, onToolCalls: { _ in })
        #expect(recorder.text == "ok")
        #expect(StubURLProtocol.requests.first?.request.url?.path == "/v1/chat/completions")
    }

    @Test func toolCallsAreReported() async throws {
        prepare { _, _ in
            (200, sse([
                #"{"type":"response.created","sequence_number":0,"response":{"id":"r"}}"#,
                #"{"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"type":"function_call","id":"fc","call_id":"call_1","name":"weather","arguments":""}}"#,
                #"{"type":"response.function_call_arguments.delta","sequence_number":2,"output_index":0,"delta":"{\"city\":\"Rome\"}"}"#,
                #"{"type":"response.completed","sequence_number":3,"response":{"id":"r","status":"completed"}}"#
            ]))
        }
        defer { finish() }

        let recorder = Recorder()
        let client = LLMClient(baseURL: baseURL, apiMode: .responses)
        try await client.streamChat(chat(), onText: { recorder.text += $0 },
                                    onToolCalls: { recorder.toolCalls.append($0) })
        #expect(recorder.toolCalls.count == 1)
        #expect(recorder.toolCalls.first?.first?.function.name == "weather")
        #expect(recorder.toolCalls.first?.first?.function.arguments == #"{"city":"Rome"}"#)
    }

    @Test func httpErrorSurfaces() async throws {
        prepare { _, _ in (404, #"{"error":"no such endpoint"}"#) }
        defer { finish() }

        let client = LLMClient(baseURL: baseURL, apiMode: .responses)
        do {
            try await client.streamChat(chat(), onText: { _ in }, onToolCalls: { _ in })
            Issue.record("Expected an HTTP error.")
        } catch LLMError.http(let code, _) {
            #expect(code == 404)
        }
    }

    @Test func backgroundRunSendsBackgroundFlags() async throws {
        prepare { _, _ in
            (200, sse([
                #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_bg"}}"#,
                #"{"type":"response.output_text.delta","sequence_number":1,"delta":"done"}"#,
                #"{"type":"response.completed","sequence_number":2,"response":{"id":"resp_bg","status":"completed"}}"#
            ]))
        }
        defer { finish() }

        let recorder = Recorder()
        let client = LLMClient(baseURL: baseURL, apiMode: .responsesBackground)
        try await client.streamChat(chat(), onText: { recorder.text += $0 }, onToolCalls: { _ in })

        #expect(recorder.text == "done")
        #expect(StubURLProtocol.requests.count == 1, "A run that finishes needs no resume.")
        let sent = try #require(StubURLProtocol.requests.first)
        let body = try #require(try JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        #expect(body["background"] as? Bool == true)
        #expect(body["store"] as? Bool == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func backgroundRunResumesAfterDroppedStream() async throws {
        prepare { request, _ in
            if request.httpMethod == "GET" {
                // The resume: events after sequence 2, then completion.
                return (200, sse([
                    #"{"type":"response.output_text.delta","sequence_number":3,"delta":"lo "}"#,
                    #"{"type":"response.output_text.delta","sequence_number":4,"delta":"world"}"#,
                    #"{"type":"response.completed","sequence_number":5,"response":{"id":"resp_bg","status":"completed","usage":{"input_tokens":7,"output_tokens":3}}}"#
                ]))
            }
            // The first connection ends early, with no terminal event.
            return (200, sse([
                #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_bg"}}"#,
                #"{"type":"response.output_text.delta","sequence_number":1,"delta":"Hel"}"#,
                #"{"type":"response.output_text.delta","sequence_number":2,"delta":""}"#
            ]))
        }
        defer { finish() }

        let recorder = Recorder()
        let client = LLMClient(baseURL: baseURL, apiMode: .responsesBackground)
        try await client.streamChat(chat(), onText: { recorder.text += $0 },
                                    onToolCalls: { _ in },
                                    onUsage: { recorder.usage.append($0) })

        #expect(recorder.text == "Hello world")
        #expect(recorder.usage.first?.promptTokens == 7)
        #expect(StubURLProtocol.requests.count == 2)
        let resume = try #require(StubURLProtocol.requests.last).request
        #expect(resume.httpMethod == "GET")
        #expect(resume.url?.path == "/v1/responses/resp_bg")
        let query = URLComponents(url: try #require(resume.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "stream", value: "true")))
        #expect(query.contains(URLQueryItem(name: "starting_after", value: "2")))
    }

    @Test(.timeLimit(.minutes(1)))
    func plainResponsesDoesNotResumeADroppedStream() async throws {
        prepare { _, _ in
            (200, sse([
                #"{"type":"response.created","sequence_number":0,"response":{"id":"r"}}"#,
                #"{"type":"response.output_text.delta","sequence_number":1,"delta":"partial"}"#
            ]))
        }
        defer { finish() }

        let recorder = Recorder()
        let client = LLMClient(baseURL: baseURL, apiMode: .responses)
        try await client.streamChat(chat(), onText: { recorder.text += $0 }, onToolCalls: { _ in })
        #expect(recorder.text == "partial")
        #expect(StubURLProtocol.requests.count == 1)
    }

    @Test func nonStreamingChatMapsOntoChatResponse() async throws {
        prepare { _, _ in
            (200, """
            {"id":"resp_n","status":"completed","output":[
              {"type":"message","content":[{"type":"output_text","text":"Paris"}]},
              {"type":"function_call","id":"fc","call_id":"call_2","name":"lookup","arguments":"{}"}
            ],"usage":{"input_tokens":4,"output_tokens":1,"total_tokens":5}}
            """)
        }
        defer { finish() }

        let client = LLMClient(baseURL: baseURL, apiMode: .responses)
        let response = try await client.chat(chat())

        let choice = try #require(response.choices.first)
        #expect(choice.message?.content == "Paris")
        #expect(choice.message?.toolCalls?.first?.id == "call_2")
        #expect(choice.finishReason == "tool_calls")
        #expect(response.usage?.totalTokens == 5)
        let sent = try #require(StubURLProtocol.requests.first)
        let body = try #require(try JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        #expect(body["stream"] as? Bool == false)
        #expect(sent.request.url?.path == "/v1/responses")
    }

    @Test func nonStreamingFailureThrows() async throws {
        prepare { _, _ in
            (200, #"{"id":"r","status":"failed","error":{"message":"nope"}}"#)
        }
        defer { finish() }

        let client = LLMClient(baseURL: baseURL, apiMode: .responses)
        await #expect(throws: LLMError.self) { try await client.chat(chat()) }
    }
}

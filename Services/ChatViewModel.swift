import Foundation
import Observation
import SwiftData
#if !os(macOS)
import UIKit
#endif

/// Drives one chat turn: streams tokens into the live assistant message and
/// runs the tool-call loop (assistant -> tool result -> assistant …).
@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var isStreaming = false
    /// True while a compaction summary is being generated.
    private(set) var isCompacting = false
    var streamingText = ""
    /// Latest non-empty line of the model's reasoning for the current
    /// attempt, shown in the "thinking" indicator. Empty when none arrived.
    private(set) var reasoningLine = ""
    private var reasoningBuffer = ""
    /// Untrimmed reasoning text of the message being generated, saved with it.
    private var reasoningFull = ""
    /// When the first reasoning delta of the current stream attempt arrived.
    private var reasoningStart: Date?
    /// When the latest reasoning delta arrived (session path), to time the thinking step.
    private var reasoningLastDelta: Date?
    /// Steps (reasoning, tool calls) taken so far in the current turn.
    private(set) var liveSteps: [ActivityStep] = []
    /// Approximate generation speed (tokens/sec) of the current stream.
    /// Uses a ~4 chars/token heuristic since vLLM-style streams don't
    /// report token counts until the final usage chunk.
    private(set) var tokensPerSecond: Double = 0
    private var streamStart = Date()
    private var streamChars = 0
    /// When the first text delta of the current stream attempt arrived.
    /// Generation time is measured from here (excludes prompt processing).
    private var firstTokenAt: Date?
    /// True once the server's usage chunk has set the exact rate for the
    /// current stream attempt, so later heuristic updates don't clobber it.
    private var exactRateSet = false

    /// Token accounting from the server's usage chunk (nil until it arrives).
    private(set) var lastUsage: Usage?
    /// Cache hit rate 0...1 from the usage chunk, nil if not reported.
    var cacheHitRatio: Double? {
        guard let cached = lastUsage?.promptTokensDetails?.cachedTokens,
              let prompt = lastUsage?.promptTokens, prompt > 0 else { return nil }
        return Double(cached) / Double(prompt)
    }
    /// Context window usage 0...1 for the last request, nil if unknown.
    var contextUsedRatio: Double? {
        guard let prompt = lastUsage?.promptTokens, settings.contextWindow > 0 else { return nil }
        return Double(prompt) / Double(settings.contextWindow)
    }
    var lastError: String?
    var activeToolName: String?
    /// Sub-agents currently running (empty when idle).
    var activeSubagentTasks: [String] { SubagentRunner.shared.activeTasks }
    var models: [ModelList.Model] = []
    var isLoadingModels = false

    private let settings = AppSettings.shared
    private var streamTask: Task<Void, Never>?
    private var modelContext: ModelContext?
    private var orderCounter = 0
    #if os(macOS)
    /// Held while a turn runs so App Nap doesn't throttle a reply streaming in the background.
    private var activityToken: NSObjectProtocol?
    #else
    private var backgroundTaskID = UIBackgroundTaskIdentifier.invalid
    #endif

    var client: LLMClient? {
        guard let url = settings.serverURL else { return nil }
        return LLMClient(baseURL: url, apiKey: settings.apiKey.isEmpty ? nil : settings.apiKey)
    }

    // MARK: - Loading

    /// `reportErrors: false` is for automatic reloads (e.g. while a URL is being
    /// edited in Settings): a failure there must not raise the chat's error
    /// alert, which would dismiss the Settings sheet mid-typing.
    func loadModels(reportErrors: Bool = true) async {
        if settings.isOnDevice {
            models = OnDeviceModels.available()
            if !models.contains(where: { $0.id == settings.modelID }) {
                settings.modelID = models.first?.id ?? ""
            }
            if models.isEmpty {
                lastError = OnDeviceModels.appleUnavailableReason ?? "No on-device models available."
            }
            return
        }
        // Never leave the previous server's models showing for this one.
        guard let client else { models = []; return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let fetched = try await client.fetchModels()
            guard !Task.isCancelled else { return }
            models = fetched
            if !models.contains(where: { $0.id == settings.modelID }) {
                if let first = models.first { settings.modelID = first.id }
            }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else { return }
            models = []
            if reportErrors { lastError = error.localizedDescription }
        }
    }

    func configure(from conversation: Conversation, in modelContext: ModelContext) {
        self.modelContext = modelContext
        messages = conversation.sortedMessages
        orderCounter = (messages.map(\.order).max() ?? -1) + 1
    }

    // MARK: - Sending

    func send(_ text: String, conversation: Conversation?) {
        guard !isStreaming else { return }
        let client = self.client
        guard client != nil || settings.isOnDevice else {
            lastError = "Set the server URL in Settings first."
            return
        }
        lastError = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let userMessage = ChatMessage(role: .user, content: trimmed, order: nextOrder())
        messages.append(userMessage)
        persist([userMessage], in: conversation)

        // Ask for notification permission without making the turn wait on the
        // system prompt: on first launch the reply would stall behind it.
        Task { await NotificationService.requestAuthorizationIfNeeded() }
        streamTask = Task { await runTurn(client: client, conversation: conversation) }
    }

    // MARK: - Compaction

    /// Messages that would be folded into a summary: everything before the
    /// newest user request. Empty when there is nothing worth compacting.
    private var compactableRange: Range<Int>? {
        let start = (messages.lastIndex(where: { $0.role == .system }) ?? -1) + 1
        guard let cutoff = messages.lastIndex(where: { $0.role == .user }),
              cutoff - start >= 2 else { return nil }
        return start..<cutoff
    }

    /// Replaces the model's view of the older transcript with a generated
    /// summary. The messages stay visible in the UI; a summary message is
    /// inserted after them and `buildAPIMessages` ignores everything before it.
    func compact(conversation: Conversation?) async {
        guard !isStreaming, !isCompacting else { return }
        guard let range = compactableRange else {
            lastError = "Nothing to compact yet."
            return
        }
        guard let client else {
            lastError = settings.isOnDevice
                ? "Compaction isn't available for on-device models yet."
                : "Set the server URL in Settings first."
            return
        }
        isCompacting = true
        defer { isCompacting = false }

        var transcript = ""
        for message in messages[range] {
            switch message.role {
            case .system:
                transcript += "[Previous summary]\n\(message.content)\n\n"
            case .user:
                transcript += "User: \(message.content)\n\n"
            case .assistant:
                guard !message.content.isEmpty else { continue }
                transcript += "Assistant: \(message.content)\n\n"
            case .tool:
                // Tool output can be huge; the assistant's reply already
                // digests it, so keep only a short excerpt.
                transcript += "[Tool result] \(message.content.prefix(1500))\n\n"
            }
        }

        let instruction = """
            You compact conversations. Write a concise but complete summary of the \
            conversation below so the assistant can continue it without the original \
            messages. Preserve the user's goals, decisions, facts, names, file paths, \
            code identifiers, open questions and any pending work. Output only the summary.
            """
        let request = ChatRequest(model: settings.modelID,
                                  messages: [APIMessage(role: "system", content: instruction),
                                             APIMessage(role: "user", content: transcript)],
                                  stream: false,
                                  temperature: 0.2,
                                  maxTokens: settings.requestMaxTokens)
        do {
            let response = try await client.chat(request)
            let summary = response.choices.first?.message?.content?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !summary.isEmpty else {
                lastError = "The model returned an empty summary."
                return
            }
            // Slot the summary right before the kept messages; ties on `order`
            // fall back to creation time, which puts it after the older ones.
            let keptOrder = messages[range.upperBound].order
            let summaryMessage = ChatMessage(role: .system, content: summary, order: keptOrder - 1)
            // The new message sorts after the compacted messages and before the kept ones.
            messages.insert(summaryMessage, at: range.upperBound)
            persist([summaryMessage], in: conversation)
            // The last usage figure described the uncompacted prompt.
            lastUsage = nil
        } catch {
            lastError = "Compaction failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }

    // MARK: - Turn loop

    private func nextOrder() -> Int {
        defer { orderCounter += 1 }
        return orderCounter
    }

    /// Asks iOS for extra execution time so a turn in flight keeps running
    /// after the app moves to the background (granted for a limited window).
    private func beginBackgroundExecution() {
        #if os(macOS)
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated, reason: "DGXChat.chatTurn")
        #else
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "DGXChat.chatTurn") { [weak self] in
            // The expiration handler runs on the main thread and must end the
            // task before returning, or the system terminates the app.
            MainActor.assumeIsolated {
                // The app is about to be suspended mid-reply; let the user know.
                NotificationService.notifyIfBackgrounded(
                    title: "Reply interrupted",
                    body: "Background time ran out. Open DGXChat to continue.")
                self?.endBackgroundExecution()
            }
        }
        #endif
    }

    private func endBackgroundExecution() {
        #if os(macOS)
        guard let token = activityToken else { return }
        ProcessInfo.processInfo.endActivity(token)
        activityToken = nil
        #else
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
        #endif
    }

    private func runTurn(client: LLMClient?, conversation: Conversation?) async {
        guard let client else {
            await runOnDeviceTurn(conversation: conversation)
            return
        }
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *),
           settings.useFoundationSession, let url = settings.serverURL {
            await runSessionTurn(url: url, conversation: conversation)
            return
        }
        isStreaming = true
        liveSteps = []
        beginBackgroundExecution()
        defer {
            isStreaming = false
            activeToolName = nil
            liveSteps = []
            endBackgroundExecution()
        }
        // Give the resource_browse tool access to this conversation's resources.
        ResourceBrowseTool.resources = conversation?.resources ?? []

        // Wall-clock time of the whole turn, surfaced on the final answer as
        // "Worked for N s" when tools ran during it.
        let turnStart = Date()
        var didRunTools = false

        // Max tool rounds guards against runaway loops. Once the budget is
        // spent (or the model repeats an identical round of calls), one last
        // round runs without tools so the model must answer from what it has.
        let maxToolRounds = settings.maxToolRounds
        var forceWrapUp = false
        var lastCallSignature: String?
        let callGuard = ToolCallGuard()
        var stepIDs: [String: UUID] = [:]
        for round in 0...maxToolRounds {
            guard !Task.isCancelled else { break }
            let wrapUp = forceWrapUp || round == maxToolRounds
            let apiMessages = buildAPIMessages(conversation: conversation)
            var request = ChatRequest(model: settings.modelID,
                                      messages: apiMessages,
                                      stream: true,
                                      temperature: settings.temperature,
                                      maxTokens: settings.requestMaxTokens)
            if settings.toolsEnabled, !wrapUp {
                request.tools = ToolRegistry.specs
            }
            settings.thinkingEffort.apply(to: &request)

            streamingText = ""
            reasoningBuffer = ""
            reasoningFull = ""
            reasoningLine = ""
            reasoningStart = nil
            streamStart = Date()
            streamChars = 0
            tokensPerSecond = 0
            firstTokenAt = nil
            exactRateSet = false
            var collectedToolCalls: [APIToolCall] = []
            let assistantMessage = ChatMessage(role: .assistant, content: "", order: nextOrder())
            messages.append(assistantMessage)

            do {
                try await client.streamChat(
                    request,
                    onText: { [weak self] delta in
                        Task { @MainActor in
                            guard let self else { return }
                            self.streamingText += delta
                            assistantMessage.content = self.streamingText
                            if self.firstTokenAt == nil {
                                self.firstTokenAt = Date()
                            }
                            // Live estimate until the usage chunk arrives with
                            // the exact token count; then the exact value wins.
                            guard !self.exactRateSet else { return }
                            self.streamChars += delta.count
                            let elapsed = Date().timeIntervalSince(self.streamStart)
                            if elapsed > 0.3 {
                                self.tokensPerSecond = Double(self.streamChars / 4) / elapsed
                            }
                        }
                    },
                    onToolCalls: { calls in collectedToolCalls = calls },
                    onReasoning: { [weak self] delta in
                        Task { @MainActor in
                            guard let self else { return }
                            if self.reasoningStart == nil { self.reasoningStart = Date() }
                            self.reasoningFull += delta
                            self.reasoningBuffer += delta
                            // Keep only the newest non-empty line for display.
                            let line = self.reasoningBuffer
                                .split(whereSeparator: \.isNewline)
                                .last
                                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                            if !line.isEmpty { self.reasoningLine = line }
                            // Bound memory on very long reasoning.
                            if self.reasoningBuffer.count > 4000 {
                                self.reasoningBuffer = String(self.reasoningBuffer.suffix(1000))
                            }
                        }
                    },
                    onUsage: { [weak self] usage in
                        Task { @MainActor in
                            guard let self else { return }
                            self.lastUsage = usage
                            // Exact rate: completion tokens over generation
                            // time (first token → now), excluding prompt
                            // processing and network latency.
                            if let first = self.firstTokenAt {
                                let gen = Date().timeIntervalSince(first)
                                if gen > 0.1, usage.completionTokens > 0 {
                                    self.tokensPerSecond = Double(usage.completionTokens) / gen
                                    self.exactRateSet = true
                                }
                            }
                        }
                    }
                )
            } catch {
                lastError = error.localizedDescription
                if assistantMessage.content.isEmpty {
                    assistantMessage.content = "⚠️ \(error.localizedDescription)"
                }
                persist([assistantMessage], in: conversation)
                NotificationService.notifyIfBackgrounded(title: "Reply failed",
                                                         body: error.localizedDescription)
                break
            }

            assistantMessage.content = streamingText
            // No tools were offered in the wrap-up round; ignore any stray calls.
            if wrapUp { collectedToolCalls = [] }
            assistantMessage.reasoningText = reasoningFull.isEmpty ? nil : reasoningFull
            // A turn that ends with no text and no tool calls would otherwise
            // vanish silently; say so instead.
            if assistantMessage.content.isEmpty, collectedToolCalls.isEmpty, !Task.isCancelled {
                assistantMessage.content = "⚠️ The model returned an empty response."
                lastError = "The model returned an empty response."
            }
            // Log the reasoning phase (first reasoning token → first answer
            // token, or end of stream if the model only reasoned).
            if let start = reasoningStart {
                let end = firstTokenAt ?? Date()
                liveSteps.append(.thinking(seconds: end.timeIntervalSince(start)))
            }
            if collectedToolCalls.isEmpty {
                if didRunTools || !liveSteps.isEmpty {
                    assistantMessage.workedSeconds = Date().timeIntervalSince(turnStart)
                    assistantMessage.stepsJSON = ActivityStep.encode(liveSteps)
                }
                persist([assistantMessage], in: conversation)
                if !Task.isCancelled {
                    NotificationService.notifyIfBackgrounded(
                        title: conversation?.title ?? "Reply ready",
                        body: assistantMessage.content)
                }
                break
            }

            // Persist the assistant message with its tool calls, then run each tool.
            assistantMessage.toolCallsJSON = String(data: (try? JSONEncoder().encode(collectedToolCalls)) ?? Data(), encoding: .utf8)
            persist([assistantMessage], in: conversation)

            // An identical round of calls means the model is looping.
            let signature = collectedToolCalls
                .map { "\($0.function.name)(\($0.function.arguments))" }
                .joined(separator: "|")
            if signature == lastCallSignature { forceWrapUp = true }
            lastCallSignature = signature

            // A round made only of read-only tools runs concurrently; anything
            // else runs one call at a time, in order. Results are always
            // recorded in call order.
            let runParallel = collectedToolCalls.count > 1 && collectedToolCalls.allSatisfy {
                ToolRegistry.tool(named: $0.function.name)?.isParallelSafe == true
            }
            func begin(_ call: APIToolCall) {
                let step = ActivityStep.tool(name: call.function.name, arguments: call.function.arguments)
                liveSteps.append(step)
                stepIDs[call.id] = step.id
            }
            func run(_ call: APIToolCall) async -> String {
                if let blocked = callGuard.check(name: call.function.name, arguments: call.function.arguments) {
                    return blocked
                }
                guard let tool = ToolRegistry.tool(named: call.function.name) else {
                    return "Error: unknown tool '\(call.function.name)'"
                }
                return await tool.execute(arguments: call.function.arguments)
            }
            func record(_ call: APIToolCall, result: String) {
                if let id = stepIDs[call.id], let index = liveSteps.firstIndex(where: { $0.id == id }) {
                    liveSteps[index].isRunning = false
                }
                let toolMessage = ChatMessage(role: .tool,
                                              content: result,
                                              toolCallId: call.id,
                                              order: nextOrder())
                messages.append(toolMessage)
                persist([toolMessage], in: conversation)
            }

            if runParallel {
                activeToolName = collectedToolCalls.map(\.function.name).joined(separator: ", ")
                collectedToolCalls.forEach(begin)
                var results = [String?](repeating: nil, count: collectedToolCalls.count)
                await withTaskGroup(of: (Int, String).self) { group in
                    for (index, call) in collectedToolCalls.enumerated() {
                        group.addTask { (index, await run(call)) }
                    }
                    for await (index, result) in group { results[index] = result }
                }
                for (index, call) in collectedToolCalls.enumerated() {
                    record(call, result: results[index] ?? "Error: tool did not run")
                }
            } else {
                for call in collectedToolCalls {
                    guard !Task.isCancelled else { break }
                    activeToolName = call.function.name
                    begin(call)
                    record(call, result: await run(call))
                }
            }
            didRunTools = true
            activeToolName = nil
            // Loop continues: send tool results back to the model.
        }
        streamingText = ""
    }

    /// Logs the reasoning gathered so far as a "Finished thinking" step and
    /// resets the reasoning state. Session path only: the old loop does this
    /// itself at the end of each request.
    private func finishThinkingStep() {
        guard let start = reasoningStart else { return }
        let end = reasoningLastDelta ?? Date()
        liveSteps.append(.thinking(seconds: end.timeIntervalSince(start)))
        reasoningStart = nil
        reasoningLastDelta = nil
        reasoningBuffer = ""
        reasoningLine = ""
    }

    /// One turn on the server through a FoundationModels session
    /// (`DGXLanguageModel`). The session runs the tool loop itself; tool calls
    /// are logged as activity steps. Reasoning and exact usage aren't surfaced
    /// on this path yet, and tool rounds aren't persisted (as with on-device).
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
    private func runSessionTurn(url: URL, conversation: Conversation?) async {
        isStreaming = true
        liveSteps = []
        beginBackgroundExecution()
        defer {
            isStreaming = false
            activeToolName = nil
            liveSteps = []
            endBackgroundExecution()
        }
        ResourceBrowseTool.resources = conversation?.resources ?? []
        reasoningLine = ""
        reasoningBuffer = ""
        reasoningFull = ""
        reasoningStart = nil
        reasoningLastDelta = nil
        defer { reasoningLine = "" }
        let turnStart = Date()

        let apiMessages = buildAPIMessages(conversation: conversation)
        let instructions = apiMessages.first(where: { $0.role == "system" })?.content ?? ""
        var turns: [(role: String, text: String)] = []
        for message in apiMessages where message.role == "user" || message.role == "assistant" {
            guard let text = message.content, !text.isEmpty else { continue }
            turns.append((message.role, text))
        }
        guard let lastUser = turns.lastIndex(where: { $0.role == "user" }) else { return }
        let prompt = turns.remove(at: lastUser).text

        streamingText = ""
        tokensPerSecond = 0
        streamStart = Date()
        streamChars = 0
        firstTokenAt = nil
        exactRateSet = false
        let assistantMessage = ChatMessage(role: .assistant, content: "", order: nextOrder())
        messages.append(assistantMessage)

        let model = DGXLanguageModel(baseURL: url,
                                     modelName: settings.modelID,
                                     apiKey: settings.apiKey.isEmpty ? nil : settings.apiKey,
                                     thinkingEffort: settings.thinkingEffort,
                                     maxToolRounds: settings.maxToolRounds)
        do {
            try await DGXSessionRunner.stream(
                model: model,
                instructions: instructions,
                history: turns,
                prompt: prompt,
                temperature: settings.temperature,
                maxTokens: settings.requestMaxTokens,
                tools: settings.toolsEnabled ? ToolRegistry.all : [],
                onText: { [weak self] text in
                    guard let self else { return }
                    // Full text of the current segment; a restart (new segment
                    // after a tool round) replaces what was shown before.
                    let grew = text.hasPrefix(self.streamingText)
                    if !grew {
                        // A new segment after a tool round: time its generation on
                        // its own, so searches and fetches don't drag the rate down.
                        self.streamStart = Date()
                        self.streamChars = 0
                        self.firstTokenAt = nil
                        self.exactRateSet = false
                    }
                    let newChars = grew ? text.count - self.streamingText.count : text.count
                    self.streamingText = text
                    assistantMessage.content = text
                    if self.firstTokenAt == nil {
                        self.firstTokenAt = Date()
                        // Text has started, so the reasoning before it is done.
                        self.finishThinkingStep()
                    }
                    self.streamChars += newChars
                    // The server's exact figure wins once it has arrived.
                    guard !self.exactRateSet else { return }
                    let elapsed = Date().timeIntervalSince(self.streamStart)
                    if elapsed > 0.3 {
                        self.tokensPerSecond = Double(self.streamChars / 4) / elapsed
                    }
                },
                // `activeToolName` stays nil here: it makes `ChatView.toolStatusRow`
                // draw the steps again, and the live assistant bubble already shows them.
                onToolCall: { [weak self] name, arguments in
                    guard let self else { return }
                    // A tool call ends the round's reasoning; log it before the tool step.
                    self.finishThinkingStep()
                    self.liveSteps.append(.tool(name: name, arguments: arguments))
                },
                onToolFinish: { [weak self] name, arguments in
                    guard let self else { return }
                    // Stop the spinner on the matching step (same verb and detail).
                    let probe = ActivityStep.tool(name: name, arguments: arguments)
                    if let index = self.liveSteps.firstIndex(where: {
                        $0.isRunning && $0.verb == probe.verb && $0.detail == probe.detail
                    }) {
                        self.liveSteps[index].isRunning = false
                    }
                },
                onUsage: { [weak self] input, cached, output in
                    guard let self else { return }
                    // Same bookkeeping as the server path's usage chunk: feeds
                    // the cache-hit and context-usage readouts, and gives the
                    // exact rate (tokens over first-text-to-now).
                    self.lastUsage = Usage(promptTokens: input,
                                           completionTokens: output,
                                           totalTokens: input + output,
                                           promptTokensDetails: .init(cachedTokens: cached))
                    if let first = self.firstTokenAt {
                        let gen = Date().timeIntervalSince(first)
                        if gen > 0.1, output > 0 {
                            self.tokensPerSecond = Double(output) / gen
                            self.exactRateSet = true
                        }
                    }
                },
                onReasoning: { [weak self] delta in
                    Task { @MainActor in
                        guard let self else { return }
                        let now = Date()
                        if self.reasoningStart == nil { self.reasoningStart = now }
                        self.reasoningLastDelta = now
                        self.reasoningBuffer += delta
                        // Keep only the newest non-empty line for display.
                        let line = self.reasoningBuffer
                            .split(whereSeparator: \.isNewline)
                            .last
                            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                        if !line.isEmpty { self.reasoningLine = line }
                        // Bound memory on very long reasoning.
                        if self.reasoningBuffer.count > 4000 {
                            self.reasoningBuffer = String(self.reasoningBuffer.suffix(1000))
                        }
                    }
                }
            )
            // A final round that only reasoned still gets its thinking step.
            finishThinkingStep()
        } catch {
            lastError = error.localizedDescription
            if assistantMessage.content.isEmpty {
                assistantMessage.content = "⚠️ \(error.localizedDescription)"
            }
            persist([assistantMessage], in: conversation)
            streamingText = ""
            return
        }

        assistantMessage.content = streamingText
        assistantMessage.reasoningText = reasoningFull.isEmpty ? nil : reasoningFull
        reasoningFull = ""
        if assistantMessage.content.isEmpty, !Task.isCancelled {
            assistantMessage.content = "⚠️ The model returned an empty response."
            lastError = "The model returned an empty response."
        }
        for index in liveSteps.indices { liveSteps[index].isRunning = false }
        if !liveSteps.isEmpty {
            assistantMessage.workedSeconds = Date().timeIntervalSince(turnStart)
            assistantMessage.stepsJSON = ActivityStep.encode(liveSteps)
        }
        persist([assistantMessage], in: conversation)
        if !Task.isCancelled {
            NotificationService.notifyIfBackgrounded(
                title: conversation?.title ?? "Reply ready",
                body: assistantMessage.content)
        }
        streamingText = ""
    }

    /// One turn on the on-device model. The FoundationModels session runs the
    /// tool loop itself; tool calls are logged as activity steps.
    private func runOnDeviceTurn(conversation: Conversation?) async {
        isStreaming = true
        liveSteps = []
        beginBackgroundExecution()
        defer {
            isStreaming = false
            activeToolName = nil
            liveSteps = []
            reasoningLine = ""
            endBackgroundExecution()
        }
        ResourceBrowseTool.resources = conversation?.resources ?? []
        reasoningLine = ""
        let turnStart = Date()

        // Reuse the server path's prompt assembly: system text + prior turns.
        let apiMessages = buildAPIMessages(conversation: conversation, onDevice: true)
        let instructions = apiMessages.first(where: { $0.role == "system" })?.content ?? ""
        var turns: [(role: String, text: String)] = []
        for message in apiMessages where message.role != "system" {
            guard let text = message.content, !text.isEmpty else { continue }
            switch message.role {
            case "user": turns.append(("User", text))
            case "assistant": turns.append(("Assistant", text))
            default: turns.append(("Tool result", String(text.prefix(1500))))
            }
        }
        guard let lastUser = turns.lastIndex(where: { $0.role == "User" }) else { return }
        let prompt = turns.remove(at: lastUser).text

        streamingText = ""
        tokensPerSecond = 0
        streamStart = Date()
        streamChars = 0
        firstTokenAt = nil
        exactRateSet = false
        let assistantMessage = ChatMessage(role: .assistant, content: "", order: nextOrder())
        messages.append(assistantMessage)

        do {
            try await OnDeviceRunner.stream(
                instructions: instructions,
                history: turns,
                prompt: prompt,
                temperature: settings.temperature,
                maxTokens: settings.maxTokens,
                tools: settings.toolsEnabled
                    ? OnDeviceRunner.tools(hasResources: !(conversation?.resources.isEmpty ?? true))
                    : [],
                onStatus: { [weak self] status in
                    // The live bubble shows this line in its thinking indicator.
                    self?.reasoningLine = status
                },
                onText: { [weak self] delta in
                    guard let self else { return }
                    self.streamingText += delta
                    assistantMessage.content = self.streamingText
                    if self.firstTokenAt == nil {
                        self.firstTokenAt = Date()
                        self.reasoningLine = ""
                    }
                    self.streamChars += delta.count
                    let elapsed = Date().timeIntervalSince(self.streamStart)
                    if elapsed > 0.3 {
                        self.tokensPerSecond = Double(self.streamChars / 4) / elapsed
                    }
                },
                onToolCall: { [weak self] name, arguments in
                    guard let self else { return }
                    self.activeToolName = name
                    self.liveSteps.append(.tool(name: name, arguments: arguments))
                }
            )
        } catch {
            lastError = error.localizedDescription
            if assistantMessage.content.isEmpty {
                assistantMessage.content = "⚠️ \(error.localizedDescription)"
            }
            persist([assistantMessage], in: conversation)
            streamingText = ""
            return
        }

        assistantMessage.content = streamingText
        assistantMessage.reasoningText = reasoningFull.isEmpty ? nil : reasoningFull
        reasoningFull = ""
        if assistantMessage.content.isEmpty, !Task.isCancelled {
            assistantMessage.content = "⚠️ The model returned an empty response."
            lastError = "The model returned an empty response."
        }
        for index in liveSteps.indices { liveSteps[index].isRunning = false }
        if !liveSteps.isEmpty {
            assistantMessage.workedSeconds = Date().timeIntervalSince(turnStart)
            assistantMessage.stepsJSON = ActivityStep.encode(liveSteps)
        }
        persist([assistantMessage], in: conversation)
        if !Task.isCancelled {
            NotificationService.notifyIfBackgrounded(
                title: conversation?.title ?? "Reply ready",
                body: assistantMessage.content)
        }
        streamingText = ""
    }

    /// Tells the model this chat renders markdown images, so it uses them
    /// instead of saying it can't show pictures.
    private static let imageDisplayNote = """
        Image display: this chat renders markdown images. To show a picture, put \
        ![short description](address) on a line of its own. The address can be an \
        http(s) image URL (a direct link to a .jpg, .png, .gif, .webp or similar file, taken \
        from your search or fetch results — never invented) or the path of an image file you \
        saved in the app's Documents folder. Images appear as small thumbnails that the \
        user can tap to enlarge. SVG files cannot be rendered. Don't say you can't display images.
        """

    /// `onDevice` keeps the prompt small for the on-device model's short context
    /// window: attached resources aren't inlined (the model reads them through
    /// `resource_browse`) and the skills catalog is left out.
    private func buildAPIMessages(conversation: Conversation?, onDevice: Bool = false) -> [APIMessage] {
        var result: [APIMessage] = []
        var systemPrompt = conversation?.systemPrompt ?? settings.systemPrompt
        // The default prompt names the DGX Spark, which isn't what runs on-device.
        if onDevice, systemPrompt == AppSettings.defaultSystemPrompt {
            systemPrompt = "You are a helpful assistant."
        }
        // Attach resources (files/folders) into the single system message —
        // chat servers accept at most one system message, at the beginning.
        if onDevice, let conversation, !conversation.resources.isEmpty {
            let note = OnDeviceRunner.resourceNote(for: conversation.resources)
            systemPrompt = systemPrompt.isEmpty ? note : systemPrompt + "\n\n" + note
        } else if let conversation, !conversation.resources.isEmpty {
            var context = "Attached resources for this conversation:\n\n"
            for resource in conversation.resources.sorted(by: { $0.addedAt < $1.addedAt }) {
                context += "## \(resource.isFolder ? "Folder" : "File"): \(resource.name)\n"
                context += resource.readContext()
                context += "\n"
            }
            systemPrompt = systemPrompt.isEmpty ? context : systemPrompt + "\n\n" + context
        }
        if !onDevice, settings.toolsEnabled, let catalog = SkillStore.catalogPrompt() {
            systemPrompt = systemPrompt.isEmpty ? catalog : systemPrompt + "\n\n" + catalog
        }
        if !onDevice {
            let note = Self.imageDisplayNote
            systemPrompt = systemPrompt.isEmpty ? note : systemPrompt + "\n\n" + note
        }
        if !systemPrompt.isEmpty {
            result.append(APIMessage(role: "system", content: systemPrompt))
        }
        // Only the newest compaction summary counts: it stands in for every
        // message before it (including older summaries).
        let summaryIndex = messages.lastIndex(where: { $0.role == .system })
        if let summaryIndex {
            let summary = "Summary of the earlier conversation (older messages were compacted):\n\n"
                + messages[summaryIndex].content
            // Chat servers accept one system message, so fold it into that.
            if result.isEmpty {
                result.append(APIMessage(role: "system", content: summary))
            } else {
                result[0].content = (result[0].content ?? "") + "\n\n" + summary
            }
        }
        let live = summaryIndex.map { messages[($0 + 1)...] } ?? messages[...]
        for message in live {
            switch message.role {
            case .system:
                continue
            case .user:
                result.append(APIMessage(role: "user", content: message.content))
            case .assistant:
                if let json = message.toolCallsJSON,
                   let data = json.data(using: .utf8),
                   let calls = try? JSONDecoder().decode([APIToolCall].self, from: data), !calls.isEmpty {
                    result.append(APIMessage(role: "assistant",
                                             content: message.content.isEmpty ? nil : message.content,
                                             toolCalls: calls))
                } else if !message.content.isEmpty {
                    result.append(APIMessage(role: "assistant", content: message.content))
                }
            case .tool:
                result.append(APIMessage(role: "tool", content: message.content, toolCallId: message.toolCallId))
            }
        }
        return result
    }

    private func persist(_ newMessages: [ChatMessage], in conversation: Conversation?) {
        guard let conversation else { return }
        for message in newMessages {
            modelContext?.insert(message)
            message.conversation = conversation
        }
        conversation.updatedAt = .now
        do {
            try modelContext?.save()
        } catch {
            lastError = "Unable to save conversation: \(error.localizedDescription)"
        }
        SessionLog.write(conversation, fallbackModel: settings.modelID)
    }
}

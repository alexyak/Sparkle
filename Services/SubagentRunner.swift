import Foundation
import Observation

/// A named role a sub-agent can take, with its own system prompt and tool set.
struct SubagentPreset: Sendable {
    let id: String
    let description: String
    let systemPrompt: String
    /// Names of tools the preset may call (looked up in ToolRegistry).
    /// `nil` means every tool except `spawn_subagent`, resolved lazily.
    let explicitTools: [String]?

    init(id: String, description: String, systemPrompt: String, allowedTools: [String]?) {
        self.id = id
        self.description = description
        self.systemPrompt = systemPrompt
        self.explicitTools = allowedTools
    }

    /// Resolved on access (not at preset construction) because ToolRegistry.all
    /// builds SpawnSubagentTool, which reads SubagentPresets.all — resolving
    /// eagerly would recurse into the static initializer.
    var allowedTools: [String] {
        explicitTools ?? ToolRegistry.all.map(\.name).filter { $0 != "spawn_subagent" }
    }
}

enum SubagentPresets {
    static let all: [SubagentPreset] = [
        SubagentPreset(
            id: "research",
            description: "Gathers facts from the web, knowledge base, and conversation resources, then reports findings with sources.",
            systemPrompt: """
            You are a research sub-agent. Work only on the assigned task. \
            Use web_search/web_fetch, knowledge_search and resource_browse to \
            gather evidence. Prefer primary sources. Return a concise report \
            with bullet-point findings and source URLs/paths. Do not ask \
            questions; make reasonable assumptions and state them.
            """,
            allowedTools: ["web_search", "web_fetch", "knowledge_search", "resource_browse"]
        ),
        SubagentPreset(
            id: "summarizer",
            description: "Reads long material (resources, knowledge base, provided text) and returns a tight summary.",
            systemPrompt: """
            You are a summarization sub-agent. Produce a faithful, condensed \
            summary of the material requested in the task. Preserve numbers, \
            names, and key claims. No commentary of your own.
            """,
            allowedTools: ["resource_browse", "knowledge_search", "device_files"]
        ),
        SubagentPreset(
            id: "general",
            description: "General-purpose worker with access to all tools except spawning more sub-agents.",
            systemPrompt: """
            You are a sub-agent working on a delegated task. Complete it \
            autonomously using the tools available, then return the final \
            answer only — your output is read by the delegating assistant, \
            not the user.
            """,
            allowedTools: nil
        )
    ]

    static func preset(id: String) -> SubagentPreset? {
        all.first { $0.id == id }
    }
}

/// Immutable snapshot of the endpoint/model a sub-agent run should use, so
/// the background loop never touches shared settings off the main actor.
struct SubagentEndpoint: Sendable {
    var baseURL: URL
    var apiKey: String?
    var model: String
    var temperature: Double
    var apiMode: APIMode = .chatCompletions
    /// Nil leaves the reply length uncapped (Auto max tokens).
    var maxTokens: Int?
}

/// Per-task bounds on a sub-agent run, set by the delegating assistant.
struct SubagentLimits: Sendable {
    static let defaultMaxToolCalls = 8
    static let defaultTimeout: TimeInterval = 180

    /// Total tool calls the agent may make before it must answer.
    var maxToolCalls = SubagentLimits.defaultMaxToolCalls
    /// Wall-clock budget, checked between model requests and tool calls.
    var timeout = SubagentLimits.defaultTimeout
    /// Overrides the per-response token cap from settings.
    var maxTokens: Int?
    /// Narrows the preset's tool set; can never widen it.
    var allowedTools: [String]?
    /// When the budget runs out, ask the agent for a best-effort answer from
    /// what it gathered instead of discarding the work.
    var returnPartial = true
}

/// Runs sub-agent conversations: self-contained tool loops against an
/// OpenAI-compatible endpoint, returning only the final assistant text.
/// Transcripts live in memory for the duration of the run (nothing persisted).
///
/// The request loop runs off the main actor so multiple sub-agents execute
/// in parallel; only tool execution hops back to the main actor.
@MainActor
@Observable
final class SubagentRunner {
    /// Shared instance used by the spawn_subagent tool.
    static let shared = SubagentRunner()

    /// Live descriptions of currently running sub-agents, for the UI.
    private(set) var activeTasks: [String] = []

    /// Max nesting depth: 1 means the main assistant can spawn sub-agents,
    /// but sub-agents cannot spawn their own.
    static let maxDepth = 1

    /// Runs one sub-agent task. `depth` guards against recursive spawning.
    func run(task: String,
             presetID: String,
             modelOverride: String? = nil,
             baseURLOverride: String? = nil,
             limits: SubagentLimits = SubagentLimits(),
             depth: Int = 1) async -> String {
        guard depth <= Self.maxDepth else {
            return "Error: sub-agent depth limit reached; no further delegation is allowed."
        }
        guard let preset = SubagentPresets.preset(id: presetID) else {
            return "Error: unknown agent type '\(presetID)'. Available: \(SubagentPresets.all.map(\.id).joined(separator: ", "))."
        }
        let settings = AppSettings.shared
        // Resolve model/endpoint: explicit override > sub-agent settings > main settings.
        let model = Self.firstNonEmpty(modelOverride,
                                       settings.subagentModelID,
                                       settings.modelID)
        guard !model.isEmpty else {
            return "Error: no model configured. Set the main model in Settings."
        }
        let endpointBase = Self.firstNonEmpty(baseURLOverride, settings.subagentBaseURL)
        let url: URL?
        if endpointBase.isEmpty {
            url = settings.serverURL
        } else {
            url = URL(string: endpointBase)
        }
        guard let url else {
            return "Error: no server URL configured in Settings."
        }
        let endpoint = SubagentEndpoint(baseURL: url,
                                       apiKey: settings.apiKey.isEmpty ? nil : settings.apiKey,
                                       model: model,
                                       temperature: settings.temperature,
                                       apiMode: Self.subagentAPIMode(for: settings.apiMode,
                                                                     usesMainServer: endpointBase.isEmpty),
                                       maxTokens: limits.maxTokens ?? settings.requestMaxTokens)

        let label = "\(presetID): \(task.prefix(60))"
        activeTasks.append(label)
        defer { activeTasks.removeAll { $0 == label } }

        // The caller may only narrow the preset's tools, never widen them.
        var toolNames = Set(preset.allowedTools)
        if let requested = limits.allowedTools {
            let unknown = requested.filter { !toolNames.contains($0) }
            if !unknown.isEmpty {
                return "Error: tool(s) not available to '\(presetID)' agents: \(unknown.joined(separator: ", ")). Available: \(preset.allowedTools.sorted().joined(separator: ", "))."
            }
            toolNames = Set(requested)
        }
        let toolSpecs = ToolRegistry.specs
            .filter { toolNames.contains($0.function.name) }

        return await Self.execute(task: task,
                                  systemPrompt: preset.systemPrompt,
                                  endpoint: endpoint,
                                  toolSpecs: toolSpecs,
                                  allowedToolNames: toolNames,
                                  limits: limits)
    }

    /// Runs several tasks concurrently via TaskGroup. Returns results in the
    /// same order as the input tasks.
    func runParallel(tasks: [(task: String, presetID: String, limits: SubagentLimits)],
                     modelOverride: String? = nil,
                     baseURLOverride: String? = nil,
                     depth: Int = 1) async -> [String] {
        await withTaskGroup(of: (index: Int, result: String).self) { group in
            for (index, item) in tasks.enumerated() {
                group.addTask {
                    let result = await self.run(task: item.task,
                                                presetID: item.presetID,
                                                modelOverride: modelOverride,
                                                baseURLOverride: baseURLOverride,
                                                limits: item.limits,
                                                depth: depth)
                    return (index, result)
                }
            }
            // TaskGroup yields results in completion order; re-sort by index
            // so the output matches the input task order.
            var results = Array(repeating: String?.none, count: tasks.count)
            for await item in group {
                results[item.index] = item.result
            }
            return results.map { $0 ?? "Error: missing result." }
        }
    }

    /// The request loop itself. Non-isolated so parallel runs don't serialize
    /// on the main actor; only tool execution hops back.
    private nonisolated static func execute(task: String,
                                            systemPrompt: String,
                                            endpoint: SubagentEndpoint,
                                            toolSpecs: [APITool],
                                            allowedToolNames: Set<String>,
                                            limits: SubagentLimits) async -> String {
        let client = LLMClient(baseURL: endpoint.baseURL, apiKey: endpoint.apiKey,
                               apiMode: endpoint.apiMode)
        var apiMessages: [APIMessage] = [
            APIMessage(role: "system", content: systemPrompt),
            APIMessage(role: "user", content: task)
        ]
        let maxToolCalls = min(max(limits.maxToolCalls, 0), 30)
        let deadline = Date().addingTimeInterval(min(max(limits.timeout, 10), 900))
        var toolCallsUsed = 0
        var finalText = ""
        var stopReason: String?
        // Raw tool outputs, kept so a capped run can still hand back its work
        // if the wrap-up request fails.
        var gathered: [String] = []

        // Each round either makes tool calls or ends the run, so the tool-call
        // budget bounds the rounds; the extra round lets the agent answer.
        while stopReason == nil {
            guard !Task.isCancelled else { return "Error: sub-agent was cancelled." }
            if Date() >= deadline {
                stopReason = "timed out after \(Int(limits.timeout))s"
                break
            }
            var request = ChatRequest(model: endpoint.model,
                                      messages: apiMessages,
                                      stream: false,
                                      temperature: endpoint.temperature,
                                      maxTokens: endpoint.maxTokens)
            // Withhold tools once the budget is spent so the agent has to answer.
            if !toolSpecs.isEmpty, toolCallsUsed < maxToolCalls {
                request.tools = toolSpecs
            }
            do {
                let response = try await client.chat(request)
                guard let message = response.choices.first?.message else {
                    return "Error: server returned no choices."
                }
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    apiMessages.append(APIMessage(role: "assistant",
                                                  content: message.content,
                                                  toolCalls: toolCalls))
                    for call in toolCalls {
                        guard !Task.isCancelled else { return "Error: sub-agent was cancelled." }
                        let result: String
                        if !allowedToolNames.contains(call.function.name) {
                            result = "Error: tool '\(call.function.name)' is not allowed for this agent."
                        } else if toolCallsUsed >= maxToolCalls {
                            result = "Error: tool-call budget (\(maxToolCalls)) exhausted. Answer now from what you have."
                        } else if Date() >= deadline {
                            result = "Error: time budget exhausted. Answer now from what you have."
                        } else {
                            toolCallsUsed += 1
                            result = await SubagentRunner.runTool(named: call.function.name,
                                                                  arguments: call.function.arguments)
                            gathered.append("[\(call.function.name) \(call.function.arguments.prefix(200))]\n\(result.prefix(2_000))")
                        }
                        apiMessages.append(APIMessage(role: "tool",
                                                      content: result,
                                                      toolCallId: call.id))
                    }
                    // A model that keeps calling tools after the budget is gone
                    // is not going to converge; cut it off.
                    if toolCallsUsed >= maxToolCalls {
                        let overrun = apiMessages.suffix(toolCalls.count)
                            .filter { ($0.content ?? "").hasPrefix("Error: tool-call budget") }
                        if !overrun.isEmpty { stopReason = "tool-call budget (\(maxToolCalls)) exhausted" }
                    }
                    continue
                }
                finalText = message.content ?? ""
                break
            } catch {
                if limits.returnPartial, toolCallsUsed > 0 {
                    stopReason = "request failed: \(error.localizedDescription)"
                    break
                }
                return "Error: sub-agent request failed: \(error.localizedDescription)"
            }
        }

        if let stopReason {
            guard limits.returnPartial, toolCallsUsed > 0 else {
                return "status: failed (\(stopReason); \(toolCallsUsed) tool calls used)\n\nError: sub-agent stopped with no answer."
            }
            // Salvage the gathered work: one tool-less request for a best answer.
            apiMessages.append(APIMessage(role: "user", content: "You have run out of budget (\(stopReason)). Using only what you have already gathered, give your best answer now. State clearly what is incomplete or unverified. Do not call tools."))
            var wrapUp = ChatRequest(model: endpoint.model,
                                     messages: apiMessages,
                                     stream: false,
                                     temperature: endpoint.temperature,
                                     maxTokens: endpoint.maxTokens)
            wrapUp.tools = nil
            if let response = try? await client.chat(wrapUp),
               let text = response.choices.first?.message?.content,
               !text.isEmpty {
                return "status: capped (\(stopReason); \(toolCallsUsed) tool calls used)\n\n\(text)"
            }
            // Wrap-up failed too: return the raw evidence rather than nothing.
            return "status: capped (\(stopReason); \(toolCallsUsed) tool calls used; no summary could be produced — raw tool output follows)\n\n\(gathered.joined(separator: "\n\n"))"
        }
        if finalText.isEmpty {
            return "status: failed (\(toolCallsUsed) tool calls used)\n\nError: sub-agent produced no answer."
        }
        return "status: complete (\(toolCallsUsed) tool calls used)\n\n\(finalText)"
    }

    /// Executes a registry tool on the main actor (tools touch UI/files) and
    /// awaits its async result.
    @MainActor
    private static func runTool(named name: String, arguments: String) async -> String {
        guard let tool = ToolRegistry.tool(named: name) else {
            return "Error: unknown tool '\(name)'"
        }
        return await tool.execute(arguments: arguments)
    }

    /// Sub-agents never run in background mode (they're short, in-memory loops).
    /// A separate sub-agent server may not support Responses, so it keeps chat completions.
    private static func subagentAPIMode(for mode: APIMode, usesMainServer: Bool) -> APIMode {
        guard usesMainServer else { return .chatCompletions }
        return mode == .responsesBackground ? .responses : mode
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            if let value, !value.isEmpty { return value }
        }
        return ""
    }
}

import Foundation

/// Delegates tasks to sub-agents that run their own conversation with the
/// model (optionally on a cheaper model / different endpoint) and return only
/// the final result. Multiple tasks run in parallel.
struct SpawnSubagentTool: Tool {
    var name = "spawn_subagent"
    var description = """
    Delegate one or more self-contained tasks to sub-agents. Each sub-agent \
    runs its own conversation with the model and its own tool loop, then \
    returns only its final answer — use this to keep research, summarization, \
    or multi-step work out of this conversation. Give each task COMPLETE \
    instructions: sub-agents cannot see this conversation, so include all \
    context they need. Multiple tasks run in parallel. Agent types: \
    'research' (web + knowledge base gathering), 'summarizer' (condense long \
    material), 'general' (any tool). Optionally override the model or server \
    endpoint per call for cheaper/faster execution.
    """
    var parameters: [String: AnyCodableValue] = [
        "type": .string("object"),
        "properties": .object([
            "tasks": .object([
                "type": .string("array"),
                "description": .string("One or more tasks to run in parallel"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "task": .object([
                            "type": .string("string"),
                            "description": .string("Complete instructions for the sub-agent")
                        ]),
                        "agent_type": .object([
                            "type": .string("string"),
                            "enum": .array(SubagentPresets.all.map { .string($0.id) }),
                            "description": .string("Sub-agent role preset")
                        ]),
                        "max_tool_calls": .object([
                            "type": .string("integer"),
                            "description": .string("Hard cap on tool calls for this sub-agent (default \(SubagentLimits.defaultMaxToolCalls), max 30). Tools are withheld once spent.")
                        ]),
                        "timeout_seconds": .object([
                            "type": .string("integer"),
                            "description": .string("Wall-clock budget in seconds (default \(Int(SubagentLimits.defaultTimeout)), 10–900), checked between steps")
                        ]),
                        "max_tokens": .object([
                            "type": .string("integer"),
                            "description": .string("Optional cap on tokens per sub-agent response")
                        ]),
                        "allowed_tools": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Restrict the sub-agent to these tools (e.g. [\"web_search\"] for search without fetching). Must be a subset of the agent type's tools.")
                        ]),
                        "return_partial": .object([
                            "type": .string("boolean"),
                            "description": .string("Default true: if a budget runs out, return a best-effort answer from the work done with status 'capped' (raw tool output if no summary is possible). False returns status 'failed' instead. Every result starts with a status line: complete, capped or failed.")
                        ])
                    ]),
                    "required": .array([.string("task")])
                ])
            ]),
            "model": .object([
                "type": .string("string"),
                "description": .string("Optional model override for all sub-agents in this call")
            ]),
            "base_url": .object([
                "type": .string("string"),
                "description": .string("Optional server endpoint override (e.g. a cheaper server)")
            ])
        ]),
        "required": .array([.string("tasks")])
    ]

    /// Depth of the current call. The main assistant runs at depth 1; the
    /// runner rejects deeper nesting.
    nonisolated(unsafe) static var depth: Int = 1

    func execute(arguments: String) async -> String {
        struct TaskSpec: Decodable {
            let task: String
            let agent_type: String?
            let max_tool_calls: Int?
            let timeout_seconds: Int?
            let max_tokens: Int?
            let allowed_tools: [String]?
            let return_partial: Bool?
        }
        struct Args: Decodable {
            let tasks: [TaskSpec]
            let model: String?
            let base_url: String?
        }
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data),
              !args.tasks.isEmpty else {
            return "Error: invalid arguments — provide a non-empty 'tasks' array."
        }
        guard args.tasks.count <= 4 else {
            return "Error: too many tasks in one call (max 4). Split into multiple calls."
        }

        let specs = args.tasks.map { spec -> (task: String, presetID: String, limits: SubagentLimits) in
            var limits = SubagentLimits()
            if let value = spec.max_tool_calls { limits.maxToolCalls = value }
            if let value = spec.timeout_seconds { limits.timeout = TimeInterval(value) }
            limits.maxTokens = spec.max_tokens
            limits.allowedTools = spec.allowed_tools
            if let value = spec.return_partial { limits.returnPartial = value }
            return (task: spec.task, presetID: spec.agent_type ?? "general", limits: limits)
        }
        let results = await SubagentRunner.shared.runParallel(
            tasks: specs,
            modelOverride: args.model,
            baseURLOverride: args.base_url,
            depth: Self.depth
        )

        // Return results labeled by task so the parent can map them.
        var output = ""
        for (spec, result) in zip(specs, results) {
            output += "## Sub-agent result (\(spec.presetID))\n"
            output += "Task: \(spec.task.prefix(200))\n"
            // Early failures (bad agent type, no model) skip the runner's
            // status line; add one so every result carries a status.
            if !result.hasPrefix("status:") { output += "status: failed\n" }
            output += "\n" + result.trimmingCharacters(in: .whitespacesAndNewlines)
            output += "\n\n"
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

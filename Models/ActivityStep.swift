import Foundation

/// One entry in the activity log of a turn: a stretch of reasoning or a tool
/// call. Shown live while the assistant works, then collapsed into a
/// "Completed N steps" summary on the final answer.
struct ActivityStep: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Bold lead-in, e.g. "Searched" or "Finished".
    var verb: String
    /// Dimmed remainder, e.g. the query or "thinking after 3s".
    var detail: String
    var symbol: String
    /// True while the step is still executing (shows a spinner).
    var isRunning = false

    static func thinking(seconds: Double) -> ActivityStep {
        let rounded = max(1, Int(seconds.rounded()))
        return ActivityStep(verb: "Finished", detail: "thinking after \(rounded)s", symbol: "brain")
    }

    /// Describes a tool call from its name and raw JSON arguments.
    static func tool(name: String, arguments: String) -> ActivityStep {
        let args = (arguments.data(using: .utf8))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func value(_ keys: String...) -> String {
            for key in keys {
                if let text = args[key] as? String, !text.isEmpty { return text }
            }
            return ""
        }
        switch name {
        case "web_search", "knowledge_search":
            return ActivityStep(verb: "Searched for", detail: value("query", "q"), symbol: "magnifyingglass", isRunning: true)
        case "web_fetch":
            return ActivityStep(verb: "Fetched", detail: value("url"), symbol: "globe", isRunning: true)
        case "resource_browse", "device_files", "knowledge_index":
            return ActivityStep(verb: "Read", detail: value("name", "path", "file", "action"), symbol: "book", isRunning: true)
        case "spawn_subagent":
            return ActivityStep(verb: "Delegated", detail: value("task", "prompt"), symbol: "person.2", isRunning: true)
        case "load_skill", "create_skill":
            return ActivityStep(verb: "Used skill", detail: value("name"), symbol: "sparkles", isRunning: true)
        default:
            return ActivityStep(verb: "Ran", detail: value("expression", "text", "name").isEmpty ? name : value("expression", "text", "name"),
                                symbol: "wrench.and.screwdriver", isRunning: true)
        }
    }

    static func encode(_ steps: [ActivityStep]) -> String? {
        guard !steps.isEmpty, let data = try? JSONEncoder().encode(steps) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String?) -> [ActivityStep] {
        guard let data = json?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ActivityStep].self, from: data)) ?? []
    }
}

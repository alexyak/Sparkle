import Foundation

/// A local tool the assistant can invoke via OpenAI-style function calling.
protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    /// JSON-Schema-ish parameter spec encoded as a dictionary.
    var parameters: [String: AnyCodableValue] { get }

    /// Execute the tool. `arguments` is the raw JSON string from the model.
    func execute(arguments: String) async -> String

    /// True when the tool is read-only and independent of other calls, so a
    /// round of such calls may run concurrently. Defaults to false.
    var isParallelSafe: Bool { get }
}

extension Tool {
    var isParallelSafe: Bool { false }
}

/// Registry of tools exposed to the model.
enum ToolRegistry {
    static var all: [any Tool] {
        [CalculatorTool(), CurrentTimeTool(), EchoTool(), WebSearchTool(), WebFetchTool(),
         ResourceBrowseTool(), KnowledgeSearchTool(), KnowledgeIndexTool(),
         DeviceFilesTool(), ClipboardTool(), SpeakTool(),
         LoadSkillTool(), CreateSkillTool(), SpawnSubagentTool()]
    }

    static var specs: [APITool] {
        all.map { tool in
            APITool(function: APIFunctionSpec(name: tool.name,
                                              description: tool.description,
                                              parameters: tool.parameters))
        }
    }

    static func tool(named name: String) -> (any Tool)? {
        all.first { $0.name == name }
    }
}

// MARK: - Repeat guard

/// Pre-execution check that blocks a tool call identical (same name and
/// arguments) to one already made this turn. A model that retries the same
/// call gets an error result pointing it at the earlier answer instead of
/// running the tool again.
final class ToolCallGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: Set<String> = []

    /// Records the call and returns nil, or returns an error result when an
    /// identical call was already made.
    func check(name: String, arguments: String) -> String? {
        let key = "\(name)(\(Self.normalized(arguments)))"
        lock.lock()
        defer { lock.unlock() }
        if seen.insert(key).inserted { return nil }
        return "Error: blocked a repeated call to '\(name)' with identical arguments. "
            + "Use the result from the earlier call, or change the arguments."
    }

    /// Canonical JSON (sorted keys, no extra whitespace) so key order and
    /// spacing don't hide a repeat. Falls back to the raw string.
    private static func normalized(_ arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: canonical, encoding: .utf8) else {
            return arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}

/// Wraps a tool so every `execute` first passes through a `ToolCallGuard`.
struct GuardedTool: Tool {
    let wrapped: any Tool
    let callGuard: ToolCallGuard

    var name: String { wrapped.name }
    var description: String { wrapped.description }
    var parameters: [String: AnyCodableValue] { wrapped.parameters }
    var isParallelSafe: Bool { wrapped.isParallelSafe }

    func execute(arguments: String) async -> String {
        if let blocked = callGuard.check(name: wrapped.name, arguments: arguments) {
            return blocked
        }
        return await wrapped.execute(arguments: arguments)
    }
}

extension Array where Element == any Tool {
    /// The same tools, each guarded by one shared repeat check.
    func guarded(by callGuard: ToolCallGuard) -> [any Tool] {
        map { GuardedTool(wrapped: $0, callGuard: callGuard) }
    }
}

// MARK: - Example tools

/// Evaluates simple arithmetic expressions (no external deps).
struct CalculatorTool: Tool {
    var name = "calculator"
    var isParallelSafe: Bool { true }
    var description = "Evaluate a basic arithmetic expression. Supports +, -, *, / and parentheses. Example: '(2+3)*4'."
    var parameters: [String: AnyCodableValue] = [
        "type": .string("object"),
        "properties": .object([
            "expression": .object([
                "type": .string("string"),
                "description": .string("Arithmetic expression to evaluate")
            ])
        ]),
        "required": .array([.string("expression")])
    ]

    func execute(arguments: String) async -> String {
        struct Args: Decodable { let expression: String }
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return "Error: invalid arguments"
        }
        let value = ArithmeticEvaluator.evaluate(args.expression)
        return value.map { String($0) } ?? "Error: could not evaluate '\(args.expression)'"
    }
}

struct CurrentTimeTool: Tool {
    var name = "current_time"
    var isParallelSafe: Bool { true }
    var description = "Get the current date and time on this device."
    var parameters: [String: AnyCodableValue] = [
        "type": .string("object"),
        "properties": .object([:])
    ]

    func execute(arguments: String) async -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: .now)
    }
}

struct EchoTool: Tool {
    var name = "echo"
    var isParallelSafe: Bool { true }
    var description = "Return the given text back unchanged. Useful for testing."
    var parameters: [String: AnyCodableValue] = [
        "type": .string("object"),
        "properties": .object([
            "text": .object([
                "type": .string("string"),
                "description": .string("Text to echo")
            ])
        ]),
        "required": .array([.string("text")])
    ]

    func execute(arguments: String) async -> String {
        struct Args: Decodable { let text: String }
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return "Error: invalid arguments"
        }
        return args.text
    }
}

// MARK: - Tiny recursive-descent arithmetic evaluator

enum ArithmeticEvaluator {
    static func evaluate(_ input: String) -> Double? {
        var parser = Parser(Array(input.replacingOccurrences(of: " ", with: "")))
        guard let value = parser.expression(), parser.done() else { return nil }
        return value
    }

    private struct Parser {
        let chars: [Character]
        var pos = 0

        init(_ chars: [Character]) { self.chars = chars }

        mutating func done() -> Bool { pos >= chars.count }
        private mutating func peek() -> Character? { pos < chars.count ? chars[pos] : nil }
        private mutating func advance() { pos += 1 }

        // expression := term (('+'|'-') term)*
        mutating func expression() -> Double? {
            guard var left = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                advance()
                guard let right = term() else { return nil }
                left = c == "+" ? left + right : left - right
            }
            return left
        }

        // term := factor (('*'|'/') factor)*
        private mutating func term() -> Double? {
            guard var left = factor() else { return nil }
            while let c = peek(), c == "*" || c == "/" {
                advance()
                guard let right = factor() else { return nil }
                if c == "*" { left *= right }
                else {
                    if right == 0 { return nil }
                    left /= right
                }
            }
            return left
        }

        // factor := ('+'|'-') factor | '(' expression ')' | number
        private mutating func factor() -> Double? {
            guard let c = peek() else { return nil }
            if c == "-" { advance(); guard let v = factor() else { return nil }; return -v }
            if c == "+" { advance(); return factor() }
            if c == "(" {
                advance()
                guard let v = expression(), peek() == ")" else { return nil }
                advance()
                return v
            }
            return number()
        }

        private mutating func number() -> Double? {
            let start = pos
            while let c = peek(), c.isNumber || c == "." || c == "e" || c == "E" || ((c == "+" || c == "-") && (chars[pos - 1] == "e" || chars[pos - 1] == "E")) {
                advance()
            }
            guard pos > start else { return nil }
            let text = String(chars[start..<pos])
            return Double(text)
        }
    }
}

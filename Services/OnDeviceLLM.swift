import Foundation
import FoundationModels

// MARK: - Model catalog

/// The Apple Intelligence model that runs on this device.
enum OnDeviceModels {
    static let appleID = "apple"

    static let displayName = "Apple Intelligence"

    /// Human-readable reason the Apple model can't be used, nil when it can.
    static var appleUnavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This device doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off in Settings."
        case .unavailable(.modelNotReady):
            return "The Apple model is still downloading."
        case .unavailable:
            return "The Apple model is unavailable."
        }
    }

    static func available() -> [ModelList.Model] {
        guard appleUnavailableReason == nil else { return [] }
        return [ModelList.Model(id: appleID, object: "model", ownedBy: "apple")]
    }
}

enum OnDeviceError: LocalizedError {
    case appleUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .appleUnavailable(let reason): return reason
        }
    }
}

// MARK: - Running a turn

enum OnDeviceRunner {
    /// The model's context window is small (the docs say 4,096 tokens; 8,192
    /// was measured on macOS 27) and every tool definition counts against it.
    /// All 14 tools cost about 2,350 tokens, so only a core set is offered.
    static let coreToolNames: Set<String> = ["calculator", "current_time", "web_search", "web_fetch"]

    /// Output share of the window; the rest is left for instructions, history and tools.
    static let maxResponseTokens = 1000

    /// History replayed in the prompt is capped by characters (about 3-4 per
    /// token): the newest turns that fit, each shortened to `turnCharLimit`.
    /// This leaves room for the tools, instructions and a reply even on a
    /// 4,096-token window, and keeps replies fast as a chat grows.
    static let historyCharBudget = 5000
    static let turnCharLimit = 1200

    /// Added to the instructions when tools are offered. A generic "only use
    /// tools when needed" didn't help: the model still ran the calculator for
    /// a story after a math turn and searched the web for a whale fact. Naming
    /// when each tool applies cut those unneeded calls from 4 of 6 to 0 of 6.
    static let toolGuidance = "Tool rules: calculator only for arithmetic the user asks you to compute; "
        + "current_time only when asked for the time or date; "
        + "web_search and web_fetch only when the user asks for recent news or to look something up online; "
        + "resource_browse only for the user's attached files. "
        + "For everything else answer from memory and call no tools."

    static func trimmedHistory(_ history: [(role: String, text: String)]) -> [(role: String, text: String)] {
        var kept: [(role: String, text: String)] = []
        var used = 0
        for turn in history.reversed() {
            var text = turn.text
            if text.count > turnCharLimit { text = String(text.prefix(turnCharLimit)) + "…" }
            guard used + text.count <= historyCharBudget else { break }
            used += text.count
            kept.append((turn.role, text))
        }
        return kept.reversed()
    }

    /// The tools to offer: the core set, plus `resource_browse` when the
    /// conversation has attached resources (they aren't inlined on-device).
    static func tools(hasResources: Bool) -> [any DGXChat.Tool] {
        ToolRegistry.all.filter {
            coreToolNames.contains($0.name) || (hasResources && $0.name == "resource_browse")
        }
    }

    /// System-prompt text about attached resources. Resources aren't inlined
    /// (the window is too small), so this tells the model what exists and that
    /// it must call `resource_browse` itself.
    static func resourceNote(for resources: [SessionResource]) -> String {
        """
        The user attached these resources:
        \(ResourceBrowseTool.promptListing(of: resources))
        To answer questions about them, call the resource_browse tool yourself: use action "read" with a path \
        from the list above (action "list" shows every file), then answer from what you read. \
        Never tell the user to use the tool.
        """
    }

    /// Streams one response. `history` is the prior conversation as plain
    /// text turns; the session runs any tool-call loop itself.
    static func stream(instructions: String,
                       history: [(role: String, text: String)],
                       prompt: String,
                       temperature: Double,
                       maxTokens: Int,
                       tools offered: [any DGXChat.Tool],
                       onStatus: @escaping @MainActor (String) -> Void,
                       onText: @escaping @MainActor (String) -> Void,
                       onToolCall: @escaping @Sendable @MainActor (_ name: String, _ arguments: String) -> Void) async throws {
        if let reason = OnDeviceModels.appleUnavailableReason {
            throw OnDeviceError.appleUnavailable(reason)
        }
        await onStatus("Reading the prompt…")

        let history = trimmedHistory(history)
        let bridged: [any FoundationModels.Tool] = offered.compactMap {
            BridgedTool(wrapping: $0, onCall: onToolCall)
        }
        let options = GenerationOptions(temperature: temperature,
                                        maximumResponseTokens: min(maxTokens, maxResponseTokens))

        // Each attempt gives up something to fit: first the earlier turns,
        // then the tools. An oversized prompt that includes tools fails with a
        // misleading "Model Catalog" error rather than a context-size error, so
        // any failure before output starts moves on to the next attempt.
        var attempts: [(history: [(role: String, text: String)], tools: [any FoundationModels.Tool], note: String?)] = [
            (history, bridged, nil)
        ]
        if !history.isEmpty { attempts.append(([], bridged, "That didn't fit the on-device model, so earlier turns were dropped…")) }
        if !bridged.isEmpty { attempts.append(([], [], "Still no luck, so answering without tools…")) }

        var emitted = ""
        var lastError: Error?
        for attempt in attempts {
            if let note = attempt.note { await onStatus(note) }
            let session = LanguageModelSession(
                model: .default, tools: attempt.tools,
                instructions: attempt.tools.isEmpty ? instructions : instructions + "\n\n" + toolGuidance)
            do {
                try await emit(session.streamResponse(to: fullPrompt(history: attempt.history, prompt: prompt),
                                                      options: options),
                               emitted: &emitted, onText: onText)
                return
            } catch {
                // Retry only when nothing was shown yet.
                guard emitted.isEmpty, !(error is CancellationError) else { throw error }
                lastError = error
            }
        }
        throw lastError ?? OnDeviceError.appleUnavailable("The on-device model didn't respond.")
    }

    /// Replays earlier turns inside the prompt; simple and robust.
    private static func fullPrompt(history: [(role: String, text: String)], prompt: String) -> String {
        guard !history.isEmpty else { return prompt }
        var text = "Conversation so far:\n"
        for turn in history { text += "\(turn.role): \(turn.text)\n" }
        return text + "\nRespond to the latest user message:\n" + prompt
    }

    /// Snapshots hold the whole text so far; forwards only the new part.
    private static func emit(_ stream: LanguageModelSession.ResponseStream<String>,
                             emitted: inout String,
                             onText: @MainActor (String) -> Void) async throws {
        for try await snapshot in stream {
            let text = snapshot.content
            guard text.count > emitted.count, text.hasPrefix(emitted) else {
                emitted = text
                continue
            }
            let delta = String(text.dropFirst(emitted.count))
            emitted = text
            await onText(delta)
        }
    }
}

// MARK: - Tool bridge

/// Exposes one of the app's tools to a FoundationModels session.
struct BridgedTool: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let wrapped: any DGXChat.Tool
    let parameters: GenerationSchema
    let onCall: @Sendable @MainActor (String, String) -> Void
    /// Called with the same name and arguments once the tool has returned.
    let onFinish: (@Sendable @MainActor (String, String) -> Void)?

    var name: String { wrapped.name }
    var description: String { wrapped.description }

    /// Nil when the tool's JSON schema can't be converted.
    init?(wrapping tool: any DGXChat.Tool,
          onCall: @escaping @Sendable @MainActor (String, String) -> Void,
          onFinish: (@Sendable @MainActor (String, String) -> Void)? = nil) {
        guard let schema = try? JSONSchemaConverter.schema(from: tool.parameters, name: tool.name) else {
            return nil
        }
        self.wrapped = tool
        self.parameters = schema
        self.onCall = onCall
        self.onFinish = onFinish
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let json = arguments.jsonString
        await onCall(wrapped.name, json)
        let result = await wrapped.execute(arguments: json)
        await onFinish?(wrapped.name, json)
        return result
    }
}

/// Converts the app's JSON-Schema-style tool parameters to a `GenerationSchema`.
enum JSONSchemaConverter {
    struct Unsupported: Error { let detail: String }

    static func schema(from parameters: [String: AnyCodableValue], name: String) throws -> GenerationSchema {
        let root = try dynamic(from: .object(parameters), name: name, description: nil)
        return try GenerationSchema(root: root, dependencies: [])
    }

    private static func dynamic(from value: AnyCodableValue, name: String,
                                description: String?) throws -> DynamicGenerationSchema {
        guard case .object(let dict) = value else { throw Unsupported(detail: "\(name) is not an object") }
        let description: String? = {
            if case .string(let d)? = dict["description"] { return d }
            return description
        }()

        if case .array(let choices)? = dict["enum"] {
            let strings = choices.compactMap { choice -> String? in
                if case .string(let s) = choice { return s }
                return nil
            }
            if !strings.isEmpty {
                return DynamicGenerationSchema(name: name, description: description, anyOf: strings)
            }
        }

        guard case .string(let type)? = dict["type"] else { throw Unsupported(detail: "\(name) has no type") }
        switch type {
        case "string": return DynamicGenerationSchema(type: String.self)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        case "array":
            guard let items = dict["items"] else { throw Unsupported(detail: "\(name) array has no items") }
            let element = try dynamic(from: items, name: name + "Item", description: nil)
            return DynamicGenerationSchema(arrayOf: element)
        case "object":
            var required = Set<String>()
            if case .array(let names)? = dict["required"] {
                for case .string(let n) in names { required.insert(n) }
            }
            var properties: [DynamicGenerationSchema.Property] = []
            if case .object(let props)? = dict["properties"] {
                for key in props.keys.sorted() {
                    var propDescription: String?
                    if case .object(let p)? = props[key], case .string(let d)? = p["description"] {
                        propDescription = d
                    }
                    let child = try dynamic(from: props[key] ?? .object([:]), name: name + "_" + key,
                                            description: propDescription)
                    properties.append(.init(name: key, description: propDescription,
                                            schema: child, isOptional: !required.contains(key)))
                }
            }
            return DynamicGenerationSchema(name: name, description: description, properties: properties)
        default:
            throw Unsupported(detail: "\(name) has unsupported type \(type)")
        }
    }
}

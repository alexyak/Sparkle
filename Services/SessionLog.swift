import Foundation

/// Writes each conversation to a JSONL transcript in the same shape Claude
/// Code uses for its session files: one JSON object per line, `user` /
/// `assistant` entries chained by `parentUuid`, and message content as typed
/// blocks (`text`, `thinking`, `tool_use`, `tool_result`).
///
/// The file is rewritten from the SwiftData store after every save, so it
/// always mirrors the conversation and can't drift or duplicate entries.
enum SessionLog {
    private static let appVersion = "DGXChat 1.0"

    /// `Documents/Sessions`, created on demand. Documents is exposed in the
    /// Files app (file sharing is enabled in Info.plist), so transcripts can
    /// be browsed and copied off the device.
    static var directory: URL? {
        guard let base = try? FileManager.default.url(for: .documentDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: true) else { return nil }
        let dir = base.appendingPathComponent("Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileURL(for id: UUID) -> URL? {
        directory?.appendingPathComponent("\(id.uuidString.lowercased()).jsonl")
    }

    /// The transcript to share for a conversation, or nil if none exists yet.
    static func exportURL(for id: UUID) -> URL? {
        guard let url = fileURL(for: id),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// One-time housekeeping at launch: moves transcripts from the earlier
    /// Application Support location into Documents, then writes a transcript
    /// for any conversation that doesn't have one yet (chats saved before
    /// transcripts existed).
    static func prepare(_ conversations: [Conversation]) {
        let fileManager = FileManager.default
        if let base = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                           appropriateFor: nil, create: false),
           let target = directory {
            let legacy = base.appendingPathComponent("DGXChat/Sessions", isDirectory: true)
            if let files = try? fileManager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) {
                for file in files {
                    let destination = target.appendingPathComponent(file.lastPathComponent)
                    if fileManager.fileExists(atPath: destination.path) {
                        try? fileManager.removeItem(at: file)
                    } else {
                        try? fileManager.moveItem(at: file, to: destination)
                    }
                }
                try? fileManager.removeItem(at: legacy)
            }
        }
        for conversation in conversations where exportURL(for: conversation.id) == nil {
            write(conversation, fallbackModel: "")
        }
    }

    static func delete(conversationID: UUID) {
        guard let url = fileURL(for: conversationID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func write(_ conversation: Conversation, fallbackModel: String) {
        guard let url = fileURL(for: conversation.id) else { return }
        let sessionID = conversation.id.uuidString.lowercased()
        let model = conversation.modelID ?? fallbackModel
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var entries: [[String: Any]] = []
        var parent: String?

        for message in conversation.sortedMessages {
            let uuid = message.id.uuidString.lowercased()
            let body: [String: Any]
            let type: String

            switch message.role {
            case .system:
                continue
            case .user:
                type = "user"
                body = ["role": "user", "content": message.content]
            case .tool:
                type = "user"
                body = ["role": "user",
                        "content": [[
                            "type": "tool_result",
                            "tool_use_id": message.toolCallId ?? "",
                            "content": message.content
                        ] as [String: Any]]]
            case .assistant:
                type = "assistant"
                var blocks: [[String: Any]] = []
                if let reasoning = message.reasoningText, !reasoning.isEmpty {
                    blocks.append(["type": "thinking", "thinking": reasoning, "signature": ""])
                }
                if !message.content.isEmpty {
                    blocks.append(["type": "text", "text": message.content])
                }
                let calls = toolCalls(from: message.toolCallsJSON)
                for call in calls {
                    blocks.append(["type": "tool_use",
                                   "id": call.id,
                                   "name": call.function.name,
                                   "input": jsonObject(from: call.function.arguments)])
                }
                body = ["id": "msg_" + uuid.replacingOccurrences(of: "-", with: ""),
                        "type": "message",
                        "role": "assistant",
                        "model": model,
                        "content": blocks,
                        "stop_reason": calls.isEmpty ? "end_turn" : "tool_use",
                        "stop_sequence": NSNull()]
            }

            var entry: [String: Any] = [
                "parentUuid": parent as Any? ?? NSNull(),
                "isSidechain": false,
                "userType": "external",
                "cwd": "",
                "sessionId": sessionID,
                "version": appVersion,
                "type": type,
                "message": body,
                "uuid": uuid,
                "timestamp": stamp.string(from: message.createdAt)
            ]
            // DGXChat extras (ignored by Claude-format readers).
            if let worked = message.workedSeconds { entry["durationMs"] = Int(worked * 1000) }
            entries.append(entry)
            parent = uuid
        }

        // Claude Code lists the conversation title as a `summary` line.
        var lines: [String] = []
        if let leaf = parent {
            lines.append(encode(["type": "summary", "summary": conversation.title, "leafUuid": leaf]))
        }
        lines += entries.map(encode)
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    private static func toolCalls(from json: String?) -> [APIToolCall] {
        guard let data = json?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([APIToolCall].self, from: data)) ?? []
    }

    /// Tool arguments arrive as a JSON string; `tool_use.input` wants the object.
    private static func jsonObject(from arguments: String) -> Any {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [String: Any]() }
        return object
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .withoutEscapingSlashes]),
              let line = String(data: data, encoding: .utf8) else { return "{}" }
        return line
    }
}

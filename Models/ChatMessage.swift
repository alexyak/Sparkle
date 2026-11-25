import Foundation
import SwiftData

/// One message inside a conversation.
@Model
final class ChatMessage {
    // CloudKit sync: no unique constraints; every attribute has a default.
    var id: UUID = UUID()
    var roleRaw: String = MessageRole.assistant.rawValue
    var content: String = ""
    /// Tool calls requested by the assistant (JSON-encoded for storage).
    var toolCallsJSON: String?
    /// For role == "tool": the tool call id this message answers.
    var toolCallId: String?
    /// Total seconds spent running tools before this answer (nil if none ran).
    var workedSeconds: Double?
    /// JSON-encoded `[ActivityStep]` log for the turn that produced this answer.
    var stepsJSON: String?
    /// Full reasoning ("thinking") text the model produced for this message.
    var reasoningText: String?
    var createdAt: Date = Date.now
    var order: Int = 0
    var conversation: Conversation?

    /// SwiftData requires an explicit init (no memberwise for @Model with defaults).
    init(id: UUID = UUID(),
         role: MessageRole,
         content: String,
         toolCallsJSON: String? = nil,
         toolCallId: String? = nil,
         workedSeconds: Double? = nil,
         stepsJSON: String? = nil,
         reasoningText: String? = nil,
         createdAt: Date = .now,
         order: Int = 0) {
        self.id = id
        self.roleRaw = role.rawValue
        self.content = content
        self.toolCallsJSON = toolCallsJSON
        self.toolCallId = toolCallId
        self.workedSeconds = workedSeconds
        self.stepsJSON = stepsJSON
        self.reasoningText = reasoningText
        self.createdAt = createdAt
        self.order = order
    }

    var role: MessageRole {
        get { MessageRole(rawValue: roleRaw) ?? .assistant }
        set { roleRaw = newValue.rawValue }
    }
}

enum MessageRole: String, Codable {
    case system
    case user
    case assistant
    case tool
}

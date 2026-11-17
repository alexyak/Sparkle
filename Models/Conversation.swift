import Foundation
import SwiftData

@Model
final class Conversation {
    @Attribute(.unique) var id: UUID
    var title: String
    var modelID: String?
    var systemPrompt: String?
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
    var messages: [ChatMessage]

    /// Files/folders attached to this conversation as context.
    @Relationship(deleteRule: .cascade, inverse: \SessionResource.conversation)
    var resources: [SessionResource]

    init(title: String = "New Chat",
         modelID: String? = nil,
         systemPrompt: String? = nil,
         createdAt: Date = .now) {
        self.id = UUID()
        self.title = title
        self.modelID = modelID
        self.systemPrompt = systemPrompt
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.messages = []
        self.resources = []
    }

    var sortedMessages: [ChatMessage] {
        messages.sorted { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) }
    }
}

/// Inverse relationship so messages know their conversation.
@Model
final class MessageConversation {
    var message: ChatMessage?
    var conversation: Conversation?

    init(message: ChatMessage? = nil, conversation: Conversation? = nil) {
        self.message = message
        self.conversation = conversation
    }
}

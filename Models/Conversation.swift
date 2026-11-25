import Foundation
import SwiftData

@Model
final class Conversation {
    // CloudKit sync: no unique constraints, every attribute has a default,
    // and relationships are optional.
    var id: UUID = UUID()
    var title: String = "New Chat"
    var modelID: String?
    var systemPrompt: String?
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
    var messagesStorage: [ChatMessage]?

    /// Files/folders attached to this conversation as context.
    @Relationship(deleteRule: .cascade, inverse: \SessionResource.conversation)
    var resourcesStorage: [SessionResource]?

    var messages: [ChatMessage] {
        get { messagesStorage ?? [] }
        set { messagesStorage = newValue }
    }

    var resources: [SessionResource] {
        get { resourcesStorage ?? [] }
        set { resourcesStorage = newValue }
    }

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

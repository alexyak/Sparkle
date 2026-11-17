import SwiftUI

#Preview("Conversations") {
    NavigationStack {
        ConversationListView(conversations: PreviewData.conversations,
                             selected: .constant(PreviewData.conversations.first))
    }
    .modelContainer(PreviewData.container)
}

#Preview("Empty") {
    NavigationStack {
        ConversationListView(conversations: [], selected: .constant(nil))
    }
    .modelContainer(PreviewData.container)
}

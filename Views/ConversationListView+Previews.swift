import SwiftUI

#Preview("Conversations") {
    NavigationStack {
        ConversationListView(conversations: PreviewData.conversations,
                             selected: .constant(PreviewData.conversations.first),
                             searchText: .constant(""))
    }
    .modelContainer(PreviewData.container)
}

#Preview("Empty") {
    NavigationStack {
        ConversationListView(conversations: [], selected: .constant(nil), searchText: .constant(""))
    }
    .modelContainer(PreviewData.container)
}

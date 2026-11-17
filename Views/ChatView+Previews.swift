import SwiftUI
import SwiftData

#Preview("Chat") {
    NavigationStack {
        ChatView(conversation: PreviewData.conversations[0])
    }
    .modelContainer(PreviewData.container)
}

#Preview("Tool call") {
    NavigationStack {
        ChatView(conversation: PreviewData.conversations[1])
    }
    .modelContainer(PreviewData.container)
}

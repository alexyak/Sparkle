import SwiftUI
import SwiftData

@main
struct DGXChatApp: App {
    let container: ModelContainer = {
        do {
            return try ModelContainer(for: Conversation.self, ChatMessage.self, SessionResource.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
        #if os(macOS)
        // A previewed file (opened from a link in the chat) gets its own window,
        // which can be resized or taken full screen.
        WindowGroup("Preview", id: FilePreviewWindow.id, for: URL.self) { $url in
            if let url {
                FilePreviewSheet(file: PreviewFile(url: url))
            }
        }
        .defaultSize(width: 900, height: 700)
        #endif
    }
}

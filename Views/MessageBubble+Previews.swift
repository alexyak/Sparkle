import SwiftUI

#Preview("User") {
    MessageBubble(message: ChatMessage(role: .user, content: "How much VRAM does the DGX Spark have?"))
        .padding()
}

#Preview("Assistant (markdown)") {
    MessageBubble(message: ChatMessage(role: .assistant, content: PreviewData.sampleMarkdown))
        .padding()
}

#Preview("Assistant (streaming)") {
    MessageBubble(message: ChatMessage(role: .assistant, content: "The DGX Spark ships with 128 GB of"),
                  streaming: true)
        .padding()
}

#Preview("Tool result") {
    MessageBubble(message: ChatMessage(role: .tool, content: "2026-10-24T15:55:00Z", toolCallId: "call_1"))
        .padding()
}

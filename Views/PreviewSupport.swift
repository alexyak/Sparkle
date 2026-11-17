import SwiftUI
import SwiftData

/// Shared sample data for view previews.
@MainActor
enum PreviewData {
    static let (container, conversations) = {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Conversation.self, ChatMessage.self, SessionResource.self, configurations: config)
        let context = ModelContext(container)

        let setup = Conversation(title: "DGX Spark setup", modelID: "qwen3-32b")
        context.insert(setup)
        let user = ChatMessage(role: .user, content: "How much VRAM does the DGX Spark have?", order: 0)
        let assistant = ChatMessage(role: .assistant, content: """
        The DGX Spark ships with **128 GB** of unified LPDDR5x memory.

        - 20-core Arm CPU
        - Up to 1 PFLOP FP4
        - ConnectX-7 networking

        ```swift
        let vramGB = 128
        ```
        """, order: 1)
        context.insert(user)
        context.insert(assistant)
        user.conversation = setup
        assistant.conversation = setup

        let tools = Conversation(title: "Tool calling demo", modelID: "qwen3-32b")
        context.insert(tools)
        let toolUser = ChatMessage(role: .user, content: "What time is it?", order: 0)
        let toolAssistant = ChatMessage(role: .assistant,
                                        content: "Let me check.",
                                        toolCallsJSON: "[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"current_time\",\"arguments\":\"{}\"}}]",
                                        order: 1)
        let toolResult = ChatMessage(role: .tool, content: "2026-10-24T15:55:00Z", toolCallId: "call_1", order: 2)
        context.insert(toolUser)
        context.insert(toolAssistant)
        context.insert(toolResult)
        toolUser.conversation = tools
        toolAssistant.conversation = tools
        toolResult.conversation = tools

        try? context.save()
        return (container, [setup, tools])
    }()

    static let sampleMarkdown = """
    # DGX Spark Notes

    The Spark is a **Grace Blackwell** desktop AI machine.

    ## Highlights
    1. 128 GB unified memory
    2. 1 PFLOP FP4 performance
    3. Runs *local* LLMs

    > Tip: serve models with vLLM on the LAN.

    ```python
    from openai import OpenAI
    client = OpenAI(base_url="http://192.168.1.100:8000/v1")
    ```

    Inline `code`, [links](https://nvidia.com), and a rule:

    ---

    | Spec | Value | Notes |
    |:-----|:-----:|------:|
    | Memory | 128 GB | unified LPDDR5x |
    | Compute | 1 PFLOP | FP4 sparse |
    | Bandwidth | 273 GB/s | |
    """
}

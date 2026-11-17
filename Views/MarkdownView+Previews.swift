import SwiftUI

#Preview("Full markdown") {
    MarkdownView(text: PreviewData.sampleMarkdown)
        .padding()
}

#Preview("Code block") {
    CodeBlockView(language: "swift", code: "let vramGB = 128\nprint(vramGB)")
        .padding()
}

import SwiftUI
import WebKit

/// A file saved by the assistant that the user opened from a link in the chat.
struct PreviewFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Id of the macOS window that shows a previewed file.
enum FilePreviewWindow {
    static let id = "file-preview"
}

extension View {
    /// Opens links to files the assistant saved in a preview instead of handing
    /// them to the system: full screen on iOS, in its own window on macOS.
    /// Every other link goes to the system as usual.
    func opensSavedFilesInPreview() -> some View {
        modifier(SavedFilePreviewModifier())
    }
}

private struct SavedFilePreviewModifier: ViewModifier {
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #else
    @State private var previewFile: PreviewFile?
    #endif

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard let fileURL = url.savedFileURL else { return .systemAction }
                #if os(macOS)
                openWindow(id: FilePreviewWindow.id, value: fileURL)
                #else
                previewFile = PreviewFile(url: fileURL)
                #endif
                return .handled
            })
            #if !os(macOS)
            .fullScreenCover(item: $previewFile) { file in
                FilePreviewSheet(file: file)
            }
            #endif
    }
}

/// Shows a saved file (SVG, image, PDF, HTML, text) inside the app. The app is
/// sandboxed and the file lives in its container, so other apps such as a
/// browser usually can't read it; previewing it here always works.
struct FilePreviewSheet: View {
    let file: PreviewFile
    @Environment(\.dismiss) private var dismiss

    private var exists: Bool {
        FileManager.default.fileExists(atPath: file.url.path)
    }

    private var isMarkdown: Bool {
        ["md", "markdown"].contains(file.url.pathExtension.lowercased())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(file.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if exists {
                    #if os(macOS)
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([file.url])
                    }
                    #else
                    ShareLink(item: file.url)
                    #endif
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            if exists {
                if isMarkdown {
                    MarkdownFileView(url: file.url)
                } else {
                    FileWebView(url: file.url)
                }
            } else {
                ContentUnavailableView("File not found",
                                       systemImage: "doc.questionmark",
                                       description: Text(file.url.lastPathComponent))
            }
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 520)
        #endif
    }
}

/// Renders a Markdown file with the app's own `MarkdownView`.
private struct MarkdownFileView: View {
    let url: URL
    @State private var text: String?

    var body: some View {
        ScrollView {
            if let text {
                MarkdownView(text: text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .task(id: url) {
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
    }
}

/// A web view that only displays one local file: scripts are off and it may
/// read nothing outside the file's folder.
private struct FileWebView {
    let url: URL

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return webView
    }
}

#if os(macOS)
extension FileWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
extension FileWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView() }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

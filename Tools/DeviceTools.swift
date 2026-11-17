import Foundation
import AVFoundation

// MARK: - Device tools

/// Read/write files inside the app's own Documents directory.
struct DeviceFilesTool: Tool {
    var name = "device_files"
    var description = """
    Manage files in the app's Documents folder on this device. \
    Actions: "list" (list files, optional subdirectory), "read" (return text \
    contents), "write" (create or overwrite a text file), "delete", "mkdir". \
    Paths are relative to Documents, e.g. "notes/ideas.txt". Use this for \
    content the user asks you to save between conversations.
    """
    var parameters: [String: AnyCodableValue] = [
        "type": .string("object"),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([.string("list"), .string("read"), .string("write"),
                                .string("delete"), .string("mkdir")]),
                "description": .string("Operation to perform")
            ]),
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative path inside Documents")
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string("Text content (required for write)")
            ])
        ]),
        "required": .array([.string("action")])
    ]

    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Resolve a relative path safely inside Documents.
    private func resolve(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return documents }
        let url = documents.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(documents.standardizedFileURL.path) else { return nil }
        return url
    }

    func execute(arguments: String) async -> String {
        struct Args: Decodable { let action: String; let path: String?; let content: String? }
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data),
              let url = resolve(args.path) else {
            return "Error: invalid arguments"
        }
        let fm = FileManager.default
        switch args.action {
        case "list":
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                return "Error: '\(args.path ?? "")' does not exist"
            }
            guard isDir.boolValue else { return url.path + " is a file" }
            let items = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            if items.isEmpty { return "Folder is empty." }
            return items.sorted().joined(separator: "\n")
        case "read":
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return "Error: could not read \(url.lastPathComponent) (not found or not UTF-8 text)"
            }
            let cap = 100_000
            return String(text.prefix(cap))
        case "write":
            guard let content = args.content else {
                // A long file can be cut off by the token limit; the server then drops
                // the unfinished argument and the call arrives without content.
                return "Error: content is required for write. If you did include it, your reply was probably "
                    + "cut off by the token limit before the file was complete. Write a much shorter version "
                    + "(for SVG: few elements, no long comments or repeated styling) and try again."
            }
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                // Hand the model a finished markdown link; models tend to wrap raw
                // addresses in backticks, which makes them plain code, not a link.
                return "Wrote \(content.count) characters to \(args.path ?? "Documents"). "
                    + "To show the user a link to the file, paste this markdown as is "
                    + "(not in backticks): [\(url.lastPathComponent)](\(url.absoluteString))"
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "delete":
            guard args.path != nil else { return "Error: path is required for delete" }
            do {
                try fm.removeItem(at: url)
                return "Deleted \(args.path!)"
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "mkdir":
            guard args.path != nil else { return "Error: path is required for mkdir" }
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                return "Created \(args.path!)"
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        default:
            return "Error: unknown action '\(args.action)'"
        }
    }
}

/// Read/write the system clipboard.
struct ClipboardTool: Tool {
    var name = "clipboard"
    var description = """
    Access the device clipboard. Actions: "read" (return the current clipboard \
    text) or "write" (place text on the clipboard). Use read when the user \
    says they copied something, and write to copy text for them.
    """
    var parameters: [String: AnyCodableValue] = [
        "type": .string("object"),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([.string("read"), .string("write")]),
                "description": .string("read or write")
            ]),
            "text": .object([
                "type": .string("string"),
                "description": .string("Text to place on the clipboard (required for write)")
            ])
        ]),
        "required": .array([.string("action")])
    ]

    func execute(arguments: String) async -> String {
        struct Args: Decodable { let action: String; let text: String? }
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return "Error: invalid arguments"
        }
        switch args.action {
        case "read":
            guard let text = Clipboard.string else {
                return "Clipboard is empty or does not contain text."
            }
            return text
        case "write":
            guard let text = args.text else { return "Error: text is required for write" }
            Clipboard.string = text
            return "Copied \(text.count) characters to the clipboard."
        default:
            return "Error: unknown action '\(args.action)'"
        }
    }
}

/// Text-to-speech via AVSpeechSynthesizer.
struct SpeakTool: Tool {
    var name = "speak"
    var description = """
    Speak text aloud using the device's text-to-speech voice. Returns \
    immediately while the speech plays. Use when the user asks you to read \
    something out loud.
    """
    var parameters: [String: AnyCodableValue] = [
        "type": .string("object"),
        "properties": .object([
            "text": .object([
                "type": .string("string"),
                "description": .string("Text to speak")
            ]),
            "rate": .object([
                "type": .string("number"),
                "description": .string("Words per minute (default 180)")
            ])
        ]),
        "required": .array([.string("text")])
    ]

    func execute(arguments: String) async -> String {
        struct Args: Decodable { let text: String; let rate: Double? }
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data),
              !args.text.isEmpty else {
            return "Error: invalid arguments"
        }
        await SpeechActor.shared.speak(args.text, rate: args.rate ?? 180)
        return "Speaking."
    }
}

/// Keeps a single synthesizer alive across tool calls (a fresh instance per
/// call would be deallocated mid-utterance).
final class SpeechActor: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    static let shared = SpeechActor()

    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, rate: Double) async {
        // Interrupt anything already playing.
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Float(rate) / 200  // AVSpeechUtterance default is 0.5 ≈ 180 wpm
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
            synthesizer.speak(utterance)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        finish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        finish()
    }

    private func finish() {
        let cont = continuation
        continuation = nil
        cont?.resume()
    }
}

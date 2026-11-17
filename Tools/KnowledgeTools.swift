import Foundation

/// Tools for exploring the current conversation's attached resources and
/// the persistent knowledge base.
///
/// The browse tool needs access to the conversation's resources, so the
/// view model installs the current resource list before each turn.

/// Lets the model list and read files attached to the current conversation
/// without the whole content being pre-injected into the prompt.
struct ResourceBrowseTool: Tool {
    var name = "resource_browse"
    var description = """
    List or read files attached to this conversation as resources. \
    Use action "list" to see available files (folders are expanded to \
    absolute paths). Use action "read" with a file path to get its contents. \
    Small resources are included in your context; large folders are only \
    listed — use this tool to read their files on demand.
    """
    var parameters: [String: AnyCodableValue] = [
        "type": .string("object"),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([.string("list"), .string("read")]),
                "description": .string("list or read")
            ]),
            "path": .object([
                "type": .string("string"),
                "description": .string("File path to read (required for read)")
            ])
        ]),
        "required": .array([.string("action")])
    ]

    /// Installed by ChatViewModel before each turn.
    nonisolated(unsafe) static var resources: [SessionResource] = []

    func execute(arguments: String) async -> String {
        struct Args: Decodable { let action: String; let path: String? }
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return "Error: invalid arguments"
        }
        switch args.action {
        case "list":
            if Self.resources.isEmpty { return "No resources attached to this conversation." }
            var out = "Attached resources:\n"
            for resource in Self.resources {
                guard let url = resource.resolvedURL() else {
                    out += "- \(resource.name) (unavailable)\n"
                    continue
                }
                if resource.isFolder {
                    out += "- \(resource.name)/ (folder)\n"
                    // Without an active security scope, iOS returns an empty
                    // listing for folders picked outside the app sandbox.
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    for file in Self.textFiles(in: url, limit: 300) {
                        out += "    \(file.path)\n"
                    }
                } else {
                    out += "- \(resource.name) (\(url.path))\n"
                }
            }
            return out
        case "read":
            guard let path = args.path else { return "Error: path is required for read" }
            let url = Self.resolve(path)
            // Access must be started on the security-scoped resource URL
            // (the folder or file the user picked); paths under it inherit it.
            let anchor = Self.resources.lazy.compactMap { $0.resolvedURL() }
                .first { url.path.hasPrefix($0.path) }
            let scoped = anchor?.startAccessingSecurityScopedResource() ?? false
            defer { if scoped, let anchor { anchor.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                return "Error: could not read \(url.lastPathComponent)"
            }
            let cap = 100_000
            guard let text = String(data: data.prefix(cap), encoding: .utf8) else {
                return "Error: \(url.lastPathComponent) is not valid UTF-8 text"
            }
            return text
        default:
            return "Error: unknown action '\(args.action)'"
        }
    }

    /// Compact listing for prompts with a small context window: attached files
    /// by name, and folder contents as paths relative to the folder (which
    /// `read` accepts), capped at `maxFiles` per folder.
    static func promptListing(of resources: [SessionResource], maxFiles: Int = 30) -> String {
        var lines: [String] = []
        for resource in resources {
            guard resource.isFolder, let base = resource.resolvedURL() else {
                lines.append("- \(resource.name)")
                continue
            }
            let scoped = base.startAccessingSecurityScopedResource()
            defer { if scoped { base.stopAccessingSecurityScopedResource() } }
            let files = textFiles(in: base, limit: 1000)
            let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
            let relative = files.map { $0.path.hasPrefix(prefix) ? String($0.path.dropFirst(prefix.count)) : $0.lastPathComponent }
                .sorted()
            var line = "- \(resource.name)/ (folder): " + relative.prefix(maxFiles).joined(separator: ", ")
            if relative.count > maxFiles { line += ", … (\(relative.count - maxFiles) more; use action \"list\")" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Accepts an absolute path, an attached file's name, or a path relative to
    /// an attached folder, with or without the folder's own name in front
    /// (small models often pass the name they were shown).
    private static func resolve(_ path: String) -> URL {
        guard !path.hasPrefix("/") else { return URL(fileURLWithPath: path) }
        for resource in resources {
            guard let base = resource.resolvedURL() else { continue }
            if !resource.isFolder, resource.name == path || base.lastPathComponent == path {
                return base
            }
            if resource.isFolder {
                let scoped = base.startAccessingSecurityScopedResource()
                defer { if scoped { base.stopAccessingSecurityScopedResource() } }
                var relative = path
                if relative.hasPrefix(resource.name + "/") { relative.removeFirst(resource.name.count + 1) }
                let candidate = base.appending(path: relative)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return URL(fileURLWithPath: path)
    }

    private static func textFiles(in url: URL, limit: Int) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url,
                                             includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for case let fileURL as URL in enumerator {
            guard result.count < limit else { break }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            result.append(fileURL)
        }
        return result
    }
}

/// Search tool over the persistent knowledge base.
struct KnowledgeSearchTool: Tool {
    var name = "knowledge_search"
    var isParallelSafe: Bool { true }
    var description = """
    Search the user's persistent knowledge base (indexed documents from \
    files and folders previously added). Returns the most relevant passages. \
    Use this when the answer may be in the user's own documents.
    """
    var parameters: [String: AnyCodableValue] = [
        "type": .string("object"),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("Search terms")
            ]),
            "limit": .object([
                "type": .string("integer"),
                "description": .string("Max passages to return (default 6)")
            ])
        ]),
        "required": .array([.string("query")])
    ]

    func execute(arguments: String) async -> String {
        struct Args: Decodable { let query: String; let limit: Int? }
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return "Error: invalid arguments"
        }
        return await KnowledgeBase.shared.search(query: args.query, limit: args.limit ?? 6)
    }
}

/// Lets the model add a file/folder path to the knowledge base index.
/// (The user can also index from Settings; this enables conversational setup.)
struct KnowledgeIndexTool: Tool {
    var name = "knowledge_index"
    var description = """
    Index a file or folder path into the persistent knowledge base so it can \
    be searched later with knowledge_search. Accepts an absolute path. \
    Use action "remove" with a path to delete it from the index, or "list" to \
    see indexed documents.
    """
    var parameters: [String: AnyCodableValue] = [
        "type": .string("object"),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([.string("add"), .string("remove"), .string("list")]),
                "description": .string("add (index a path), remove, or list indexed documents")
            ]),
            "path": .object([
                "type": .string("string"),
                "description": .string("Absolute path to index or remove")
            ])
        ]),
        "required": .array([.string("action")])
    ]

    func execute(arguments: String) async -> String {
        struct Args: Decodable { let action: String; let path: String? }
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return "Error: invalid arguments"
        }
        switch args.action {
        case "add":
            guard let path = args.path else { return "Error: path is required" }
            return await KnowledgeBase.shared.add(url: URL(fileURLWithPath: path))
        case "remove":
            guard let path = args.path else { return "Error: path is required" }
            return await KnowledgeBase.shared.remove(path: path)
        case "list":
            return await KnowledgeBase.shared.list()
        default:
            return "Error: unknown action '\(args.action)'"
        }
    }
}

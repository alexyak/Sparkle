import Foundation

/// A persistent, searchable knowledge base of text chunks indexed from
/// files and folders the user has added. The index is stored as JSON in
/// Documents (visible in the Files app) so it survives app restarts and is shared across
/// conversations.
actor KnowledgeBase {
    static let shared = KnowledgeBase()

    struct Chunk: Codable {
        let docPath: String
        let docTitle: String
        let index: Int
        let text: String
    }

    struct Document: Codable, Identifiable, Sendable {
        let path: String
        let title: String
        let chunkCount: Int
        let indexedAt: Date
        var id: String { path }
    }

    private struct Store: Codable {
        var documents: [String: Document]
        var chunks: [Chunk]
    }

    private var store = Store(documents: [:], chunks: [])
    private let storeURL: URL
    private static let chunkLines = 40

    private init() {
        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KnowledgeBase", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("index.json")

        // One-time migration from the old Application Support location.
        let legacyURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KnowledgeBase/index.json")
        if !fm.fileExists(atPath: storeURL.path), fm.fileExists(atPath: legacyURL.path) {
            try? fm.moveItem(at: legacyURL, to: storeURL)
        }

        if let data = try? Data(contentsOf: storeURL),
           let loaded = try? JSONDecoder().decode(Store.self, from: data) {
            store = loaded
        }
    }

    // MARK: - Indexing

    /// Indexes a file or folder. Re-indexing the same path replaces the old
    /// entry. Returns a summary line for the model.
    func add(url: URL, maxFiles: Int = 200, maxBytesPerFile: Int = 200_000) -> String {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return "Error: path not found: \(url.path)"
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var indexed: [(path: String, text: String)] = []
        if isDir.boolValue {
            for file in Self.textFiles(in: url, limit: maxFiles) {
                if let text = Self.readText(file, cap: maxBytesPerFile), !text.isEmpty {
                    indexed.append((file.path, text))
                }
            }
            if indexed.isEmpty { return "No readable text files found under \(url.lastPathComponent)." }
        } else {
            guard let text = Self.readText(url, cap: maxBytesPerFile) else {
                return "Error: could not read \(url.lastPathComponent) (binary or unreadable)."
            }
            indexed.append((url.path, text))
        }

        // Replace any previous entry for each source path.
        let paths = Set(indexed.map(\.path))
        store.chunks.removeAll { paths.contains($0.docPath) }
        for path in paths { store.documents.removeValue(forKey: path) }

        var addedChunks = 0
        for (path, text) in indexed {
            let chunks = Self.chunk(text)
            for (i, part) in chunks.enumerated() {
                store.chunks.append(Chunk(docPath: path,
                                          docTitle: URL(fileURLWithPath: path).lastPathComponent,
                                          index: i,
                                          text: part))
            }
            store.documents[path] = Document(path: path,
                                             title: URL(fileURLWithPath: path).lastPathComponent,
                                             chunkCount: chunks.count,
                                             indexedAt: .now)
            addedChunks += chunks.count
        }
        save()
        return "Indexed \(indexed.count) file(s), \(addedChunks) chunk(s) into the knowledge base."
    }

    func remove(path: String) -> String {
        guard store.documents[path] != nil else { return "Not in knowledge base: \(path)" }
        store.documents.removeValue(forKey: path)
        store.chunks.removeAll { $0.docPath == path }
        save()
        return "Removed \(URL(fileURLWithPath: path).lastPathComponent) from the knowledge base."
    }

    /// Documents currently indexed, newest first (for the Settings UI).
    func documents() -> [Document] {
        store.documents.values.sorted { $0.indexedAt > $1.indexedAt }
    }

    func list() -> String {
        guard !store.documents.isEmpty else { return "Knowledge base is empty." }
        let docs = store.documents.values.sorted { $0.indexedAt > $1.indexedAt }
        return docs.map { "- \($0.title) (\($0.chunkCount) chunks)" }.joined(separator: "\n")
    }

    // MARK: - Search

    /// Lightweight term-frequency search over indexed chunks. Returns the
    /// best-matching chunks with their source paths.
    func search(query: String, limit: Int = 6) -> String {
        let terms = Self.tokenize(query)
        guard !terms.isEmpty else { return "Empty query." }
        guard !store.chunks.isEmpty else { return "Knowledge base is empty." }

        // Document frequency for idf weighting.
        var df: [String: Int] = [:]
        for term in terms {
            df[term] = store.chunks.filter { $0.text.lowercased().contains(term) }.count
        }
        let total = store.chunks.count
        var scored: [(score: Double, chunk: Chunk)] = []
        for chunk in store.chunks {
            let lower = chunk.text.lowercased()
            var score = 0.0
            for term in terms {
                let tf = Double(lower.components(separatedBy: term).count - 1)
                guard tf > 0 else { continue }
                let d = Double(df[term] ?? 1)
                score += tf * log(Double(total) / (1 + d))
            }
            if score > 0 { scored.append((score, chunk)) }
        }
        guard !scored.isEmpty else { return "No matches for: \(query)" }
        let top = scored.sorted { $0.score > $1.score }.prefix(limit)
        return top.map { hit in
            "### \(hit.chunk.docTitle) (chunk \(hit.chunk.index))\n\(hit.chunk.text)"
        }.joined(separator: "\n\n")
    }

    // MARK: - Persistence

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(store) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    // MARK: - Helpers

    private static func chunk(_ text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > chunkLines else { return [text] }
        var result: [String] = []
        var start = 0
        while start < lines.count {
            let end = min(start + chunkLines, lines.count)
            result.append(lines[start..<end].joined(separator: "\n"))
            start = end
        }
        return result
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 }
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
            let ext = fileURL.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "gif", "heic", "pdf", "zip", "tar", "gz",
                "mp4", "mov", "mp3", "wav", "bin", "dylib", "so", "a", "o"].contains(ext) {
                continue
            }
            result.append(fileURL)
        }
        return result
    }

    private static func readText(_ url: URL, cap: Int) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data.prefix(cap), encoding: .utf8)
    }
}

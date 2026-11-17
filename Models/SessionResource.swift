import Foundation
import SwiftData

/// A file or folder attached to a conversation as context.
/// The URL is persisted as a security-scoped bookmark so the reference
/// survives app restarts.
@Model
final class SessionResource {
    @Attribute(.unique) var id: UUID
    var name: String
    var isFolder: Bool
    var bookmarkData: Data
    var addedAt: Date
    var conversation: Conversation?

    init(name: String, isFolder: Bool, bookmarkData: Data, addedAt: Date = .now) {
        self.id = UUID()
        self.name = name
        self.isFolder = isFolder
        self.bookmarkData = bookmarkData
        self.addedAt = addedAt
    }

    /// Resolves the stored bookmark to a live URL, activating the
    /// security scope for sandboxed file-picker access.
    func resolvedURL() -> URL? {
        var stale = false
        #if os(macOS)
        if let url = try? URL(resolvingBookmarkData: bookmarkData,
                              options: .withSecurityScope,
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale) {
            return url
        }
        #endif
        return try? URL(resolvingBookmarkData: bookmarkData,
                        options: [],
                        relativeTo: nil,
                        bookmarkDataIsStale: &stale)
    }

    /// Reads the resource's text content for injection into the model context.
    /// Applies per-file and total size caps so context stays bounded.
    func readContext(maxBytesPerFile: Int = 60_000,
                     maxTotalBytes: Int = 200_000,
                     maxFolderFiles: Int = 40) -> String {
        guard let url = resolvedURL() else {
            return "<unavailable: \(name)>"
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return "<unavailable: \(name)>"
        }

        var output = ""
        if isDir.boolValue {
            // Enumerate everything first to decide between full contents
            // and a listing-only injection for large folders.
            let allFiles = Self.textFiles(in: url, limit: .max)
            let totalSize = allFiles.reduce(0) { sum, file -> Int in
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return sum + size
            }
            let instructionFiles = allFiles.filter(Self.isInstructionFile)
            if allFiles.count > maxFolderFiles || totalSize > maxTotalBytes {
                // Too big to inline: give the model the file tree and let it
                // fetch what it needs via resource_browse.
                output += "<large folder: \(allFiles.count) text files, "
                    + String(format: "%.1f MB", Double(totalSize) / 1_048_576)
                    + " — regular contents not included. Use the resource_browse tool "
                    + "with action \"list\" and path \"\(url.path)\" to see files, "
                    + "and action \"read\" to read specific files.\n\n"
                for file in instructionFiles {
                    let rel = file.path.replacingOccurrences(of: url.path + "/", with: "")
                    output += "### \(rel)\n```\n\(Self.readText(file, cap: maxBytesPerFile))\n```\n"
                }
                let listingLimit = 300
                for file in allFiles.prefix(listingLimit) {
                    let rel = file.path.replacingOccurrences(of: url.path + "/", with: "")
                    output += "- \(rel)\n"
                }
                if allFiles.count > listingLimit {
                    output += "- <…\(allFiles.count - listingLimit) more files>\n"
                }
                output += ">"
            } else {
                let prioritizedFiles = instructionFiles + allFiles.filter { !Self.isInstructionFile($0) }
                for file in prioritizedFiles {
                    guard output.utf8.count < maxTotalBytes else {
                        output += "\n<…truncated>\n"
                        break
                    }
                    let body = Self.readText(file, cap: maxBytesPerFile)
                    let rel = file.path.replacingOccurrences(of: url.path + "/", with: "")
                    output += "### \(rel)\n```\n\(body)\n```\n"
                }
            }
        } else {
            output = "### \(url.lastPathComponent)\n```\n\(Self.readText(url, cap: maxBytesPerFile))\n```\n"
        }
        return output
    }

    private static func isInstructionFile(_ url: URL) -> Bool {
        ["agents.md", "claude.md"].contains(url.lastPathComponent.lowercased())
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
            // Skip obvious binaries by extension.
            let ext = fileURL.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "gif", "heic", "pdf", "zip", "tar", "gz",
                "mp4", "mov", "mp3", "wav", "bin", "dylib", "so", "a", "o"].contains(ext) {
                continue
            }
            result.append(fileURL)
        }
        return result
    }

    private static func readText(_ url: URL, cap: Int) -> String {
        guard let data = try? Data(contentsOf: url) else { return "<unreadable>" }
        let limited = data.prefix(cap)
        guard let text = String(data: limited, encoding: .utf8) else {
            return "<binary file>"
        }
        return text
    }
}

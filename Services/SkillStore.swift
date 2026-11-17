import Foundation

/// An installed skill: a folder containing a `SKILL.md` with `name` and
/// `description` frontmatter, plus optional bundled files.
struct Skill: Identifiable, Sendable {
    let name: String
    let description: String
    let directory: URL
    var isEnabled: Bool
    var id: String { name }
}

/// Manages skills stored in Documents/Skills (visible in the Files app).
/// Only name + description go into the system prompt; the model loads the
/// full instructions on demand with the `load_skill` tool.
enum SkillStore {
    private static let disabledKey = "settings.disabledSkills"
    private static let skillFile = "SKILL.md"

    static var rootURL: URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skills", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Queries

    static func all() -> [Skill] {
        let fm = FileManager.default
        let disabled = Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? [])
        let dirs = (try? fm.contentsOfDirectory(at: rootURL,
                                                includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? []
        return dirs.compactMap { dir -> Skill? in
            guard let text = try? String(contentsOf: dir.appendingPathComponent(skillFile), encoding: .utf8)
            else { return nil }
            let meta = parse(text).meta
            let name = meta["name"] ?? dir.lastPathComponent
            return Skill(name: name,
                         description: meta["description"] ?? "",
                         directory: dir,
                         isEnabled: !disabled.contains(name))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func skill(named name: String) -> Skill? {
        all().first { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.isEnabled }
    }

    /// Instructions (SKILL.md body) plus a listing of bundled files.
    static func load(_ skill: Skill) -> String {
        guard let text = try? String(contentsOf: skill.directory.appendingPathComponent(skillFile),
                                     encoding: .utf8) else {
            return "Error: could not read \(skillFile) for skill '\(skill.name)'."
        }
        var result = parse(text).body.trimmingCharacters(in: .whitespacesAndNewlines)
        let extras = bundledFiles(in: skill.directory)
        if !extras.isEmpty {
            result += "\n\nBundled files (read with load_skill's `file` argument):\n"
                + extras.map { "- \($0)" }.joined(separator: "\n")
        }
        return result
    }

    /// Reads a file bundled inside a skill folder. Paths cannot escape it.
    static func readFile(_ relativePath: String, in skill: Skill, cap: Int = 100_000) -> String {
        let base = skill.directory.standardizedFileURL
        let target = base.appendingPathComponent(relativePath).standardizedFileURL
        guard target.path.hasPrefix(base.path + "/") else { return "Error: path is outside the skill folder." }
        guard let data = try? Data(contentsOf: target),
              let text = String(data: data.prefix(cap), encoding: .utf8) else {
            return "Error: could not read '\(relativePath)' (missing or binary)."
        }
        return text
    }

    /// Section appended to the system prompt, or nil when no skill is enabled.
    static func catalogPrompt() -> String? {
        let active = all().filter(\.isEnabled)
        guard !active.isEmpty else { return nil }
        let list = active.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        return """
        You have access to skills — specialised instructions you can load on demand. \
        When the user's request matches a skill, call the load_skill tool with its name \
        before answering, then follow the instructions it returns.

        Available skills:
        \(list)
        """
    }

    // MARK: - Management

    static func setEnabled(_ enabled: Bool, name: String) {
        var disabled = Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? [])
        if enabled { disabled.remove(name) } else { disabled.insert(name) }
        UserDefaults.standard.set(Array(disabled), forKey: disabledKey)
    }

    static func remove(_ skill: Skill) {
        try? FileManager.default.removeItem(at: skill.directory)
    }

    /// Imports a skill folder (containing SKILL.md) or a single markdown file.
    /// Re-importing a skill with the same name replaces it. Returns a status line.
    static func importSkill(from url: URL) -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return "Error: file not found." }

        let skillURL = isDir.boolValue ? url.appendingPathComponent(skillFile) : url
        guard let text = try? String(contentsOf: skillURL, encoding: .utf8) else {
            return isDir.boolValue
                ? "Error: \(url.lastPathComponent) has no readable \(skillFile)."
                : "Error: could not read \(url.lastPathComponent) as text."
        }
        let meta = parse(text).meta
        let fallback = isDir.boolValue ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let name = meta["name"] ?? fallback
        guard meta["description"] != nil else {
            return "Error: \(skillFile) needs a `description:` line in its frontmatter."
        }

        let dest = rootURL.appendingPathComponent(sanitize(name), isDirectory: true)
        do {
            try? fm.removeItem(at: dest)
            if isDir.boolValue {
                try fm.copyItem(at: url, to: dest)
            } else {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                try text.write(to: dest.appendingPathComponent(skillFile), atomically: true, encoding: .utf8)
            }
        } catch {
            return "Error: \(error.localizedDescription)"
        }
        return "Installed skill '\(name)'."
    }

    /// Creates a skill from text (e.g. written by the model at the user's request).
    /// Refuses to replace an existing skill unless `overwrite` is set.
    static func create(name: String, description: String, instructions: String, overwrite: Bool = false) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !description.isEmpty,
              !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: name, description and instructions are all required."
        }
        let fm = FileManager.default
        let dest = rootURL.appendingPathComponent(sanitize(name), isDirectory: true)
        if fm.fileExists(atPath: dest.path), !overwrite {
            return "Error: a skill named '\(name)' already exists. Pass overwrite=true only if the user asked to replace it."
        }
        let escapedName = name.replacingOccurrences(of: "\n", with: " ")
        let content = "---\nname: \(escapedName)\ndescription: \(description)\n---\n\n\(instructions)\n"
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            try content.write(to: dest.appendingPathComponent(skillFile), atomically: true, encoding: .utf8)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
        return "Created skill '\(name)'. It is now available via load_skill."
    }

    // MARK: - Helpers

    private static func sanitize(_ name: String) -> String {
        let cleaned = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let result = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "skill" : result
    }

    private static func bundledFiles(in dir: URL, limit: Int = 50) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: dir,
                                                              includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles]) else { return [] }
        let base = dir.standardizedFileURL.path + "/"
        var result: [String] = []
        for case let file as URL in enumerator {
            guard result.count < limit,
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            let relative = String(path.dropFirst(base.count))
            if relative != skillFile { result.append(relative) }
        }
        return result.sorted()
    }

    /// Splits optional `---` YAML-style frontmatter (simple `key: value` lines) from the body.
    private static func parse(_ text: String) -> (meta: [String: String], body: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return ([:], text) }

        var meta: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty, !value.isEmpty { meta[key] = value }
        }
        return (meta, lines[(end + 1)...].joined(separator: "\n"))
    }
}

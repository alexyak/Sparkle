import Foundation

/// Lets the user create a skill by asking for it in chat.
struct CreateSkillTool: Tool {
    var name = "create_skill"
    var description = "Create and install a new skill when the user asks to save or add one. Write clear, reusable instructions. The description should say when the skill applies, since it is all that is shown before the skill is loaded."
    var parameters: [String: AnyCodableValue] = [
        "type": .string("object"),
        "properties": .object([
            "name": .object([
                "type": .string("string"),
                "description": .string("Short skill name, e.g. 'code-review'")
            ]),
            "description": .object([
                "type": .string("string"),
                "description": .string("One sentence on what the skill does and when to use it")
            ]),
            "instructions": .object([
                "type": .string("string"),
                "description": .string("Full skill instructions in markdown")
            ]),
            "overwrite": .object([
                "type": .string("boolean"),
                "description": .string("Replace an existing skill with the same name. Only if the user asked.")
            ])
        ]),
        "required": .array([.string("name"), .string("description"), .string("instructions")])
    ]

    func execute(arguments: String) async -> String {
        struct Args: Decodable {
            let name: String
            let description: String
            let instructions: String
            let overwrite: Bool?
        }
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return "Error: invalid arguments"
        }
        return SkillStore.create(name: args.name, description: args.description,
                                 instructions: args.instructions, overwrite: args.overwrite ?? false)
    }
}

/// Loads the full instructions of an installed skill on demand.
struct LoadSkillTool: Tool {
    var name = "load_skill"
    var description = "Load the full instructions of an installed skill by name. Call this when the user's request matches a skill listed in the system prompt. Optionally pass `file` to read a file bundled with the skill."
    var parameters: [String: AnyCodableValue] = [
        "type": .string("object"),
        "properties": .object([
            "name": .object([
                "type": .string("string"),
                "description": .string("Name of the skill to load")
            ]),
            "file": .object([
                "type": .string("string"),
                "description": .string("Optional relative path of a bundled file inside the skill folder")
            ])
        ]),
        "required": .array([.string("name")])
    ]

    func execute(arguments: String) async -> String {
        struct Args: Decodable { let name: String; let file: String? }
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return "Error: invalid arguments"
        }
        guard let skill = SkillStore.skill(named: args.name) else {
            let names = SkillStore.all().filter(\.isEnabled).map(\.name).joined(separator: ", ")
            return "Error: no skill named '\(args.name)'. Available: \(names.isEmpty ? "none" : names)"
        }
        if let file = args.file, !file.isEmpty {
            return SkillStore.readFile(file, in: skill)
        }
        return SkillStore.load(skill)
    }
}

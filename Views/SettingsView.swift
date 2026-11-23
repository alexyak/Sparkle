import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings.shared
    @State private var connectionStatus: String?
    @State private var testingConnection = false
    @State private var detectingModel = false
    @State private var modelStatus: String?
    @State private var kbDocs: [KnowledgeBase.Document] = []
    @State private var kbMessage: String?
    @State private var showKBImporter = false
    @State private var skills: [Skill] = []
    @State private var skillMessage: String?
    @State private var showSkillImporter = false

    /// Availability of the Apple Intelligence model.
    @ViewBuilder
    private var onDeviceStatus: some View {
        if let reason = OnDeviceModels.appleUnavailableReason {
            Text("Apple Intelligence: \(reason)")
                .font(.caption)
                .foregroundStyle(.red)
        } else {
            Text("✓ Apple Intelligence is available")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Endpoint") {
                    Picker("Active endpoint", selection: Binding(
                        get: { settings.activeEndpointID ?? UUID() },
                        set: { settings.switchEndpoint(to: $0); connectionStatus = nil; modelStatus = nil }
                    )) {
                        ForEach(settings.endpoints) { endpoint in
                            Text(endpoint.name).tag(endpoint.id)
                        }
                    }
                    TextField("Name", text: $settings.activeEndpointName)
                    if settings.isOnDevice {
                        onDeviceStatus
                    } else {
                        TextField("Base URL", text: $settings.baseURL)
                            .urlFieldStyle()
                        SecureField("API Key (optional)", text: $settings.apiKey)
                        Picker("API", selection: $settings.apiMode) {
                            ForEach(APIMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        if settings.apiMode.isBackground {
                            Text("The server keeps generating if the connection drops, and the app picks the reply back up.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            testConnection()
                        } label: {
                            if testingConnection {
                                HStack { ProgressView(); Text("Testing…") }
                            } else {
                                Text("Test Connection")
                            }
                        }
                        .disabled(testingConnection)
                        if let connectionStatus {
                            Text(connectionStatus)
                                .font(.caption)
                                .foregroundStyle(connectionStatus.hasPrefix("✓") ? Color.green : Color.red)
                        }
                    }
                    Button("Add Endpoint", systemImage: "plus") {
                        settings.addEndpoint()
                        connectionStatus = nil
                        modelStatus = nil
                    }
                    if !settings.isOnDevice, settings.endpoints.filter({ $0.kind == .server }).count > 1 {
                        Button("Delete This Endpoint", systemImage: "trash", role: .destructive) {
                            settings.removeActiveEndpoint()
                            connectionStatus = nil
                            modelStatus = nil
                        }
                    }
                }

                Section("Model") {
                    if !settings.isOnDevice {
                        TextField("Model ID", text: $settings.modelID)
                            .noAutocapitalization()
                            .autocorrectionDisabled()
                        Button {
                            detectModel()
                        } label: {
                            if detectingModel {
                                HStack { ProgressView(); Text("Detecting…") }
                            } else {
                                Text("Detect from server")
                            }
                        }
                        .disabled(detectingModel)
                        if let modelStatus {
                            Text(modelStatus)
                                .font(.caption)
                                .foregroundStyle(modelStatus.hasPrefix("✓") ? Color.green : Color.red)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Temperature: \(settings.temperature, specifier: "%.2f")")
                        Slider(value: $settings.temperature, in: 0...2)
                    }
                    Stepper("Max tokens: \(settings.maxTokens)", value: $settings.maxTokens, in: 256...32768, step: 256)
                    if !settings.isOnDevice {
                        Picker("Thinking", selection: $settings.thinkingEffort) {
                            ForEach(ThinkingEffort.allCases) { effort in
                                Text(effort.label).tag(effort)
                            }
                        }
                    }
                    if !settings.isOnDevice {
                        Picker("Context window", selection: $settings.contextWindow) {
                            Text("4K").tag(4096)
                            Text("8K").tag(8192)
                            Text("16K").tag(16384)
                            Text("32K").tag(32768)
                            Text("64K").tag(65536)
                            Text("128K").tag(131072)
                            Text("256K").tag(262144)
                        }
                    }
                }

                Section("System Prompt") {
                    TextField("System prompt", text: $settings.systemPrompt,
                              prompt: Text("You are…"), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(3...10)
                }

                Section("Tools") {
                    Toggle("Enable tool calling (web, knowledge base, resources, calculator, time)", isOn: $settings.toolsEnabled)
                    Stepper("Max tool rounds: \(settings.maxToolRounds)", value: $settings.maxToolRounds, in: 1...50)
                    Toggle("Use Foundation Models session (experimental)", isOn: $settings.useFoundationSession)
                }

                Section("Sub-agents") {
                    Text("Sub-agents run delegated tasks in parallel with their own tool loop. Leave the fields below empty to reuse the main model and server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Sub-agent model ID (optional)", text: $settings.subagentModelID)
                        .noAutocapitalization()
                        .autocorrectionDisabled()
                    TextField("Sub-agent server URL (optional)", text: $settings.subagentBaseURL)
                        .urlFieldStyle()
                }

                Section("Skills") {
                    if skills.isEmpty {
                        Text("No skills installed. Add a skill folder containing a SKILL.md (with name and description frontmatter), or a single .md file. The model loads a skill when a request matches it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(skills) { skill in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(skill.name)
                                        .font(.callout)
                                    Text(skill.description)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Toggle("Enabled", isOn: Binding(
                                    get: { skill.isEnabled },
                                    set: { SkillStore.setEnabled($0, name: skill.name); refreshSkills() }
                                ))
                                .labelsHidden()
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    SkillStore.remove(skill)
                                    refreshSkills()
                                }
                            }
                        }
                    }
                    Button("Add Skill…", systemImage: "plus") {
                        showSkillImporter = true
                    }
                    if let skillMessage {
                        Text(skillMessage)
                            .font(.caption)
                            .foregroundStyle(skillMessage.hasPrefix("Error") ? Color.red : Color.secondary)
                    }
                }

                Section("Knowledge Base") {
                    if kbDocs.isEmpty {
                        Text("No documents indexed. Add files or folders — the model can search them with the knowledge_search tool.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(kbDocs) { doc in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(doc.title)
                                        .font(.callout)
                                    Text("\(doc.chunkCount) chunk(s)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Remove", role: .destructive) {
                                    Task {
                                        _ = await KnowledgeBase.shared.remove(path: doc.path)
                                        await refreshKB()
                                    }
                                }
                                .font(.caption)
                            }
                        }
                    }
                    Button("Add Files or Folder…", systemImage: "plus") {
                        showKBImporter = true
                    }
                    if let kbMessage {
                        Text(kbMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .settingsSheetFrame()
            .navigationTitle("Settings")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                refreshSkills()
                await refreshKB()
            }
            .fileImporter(isPresented: $showSkillImporter,
                          allowedContentTypes: [.folder, .plainText, .text],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    for url in urls {
                        skillMessage = SkillStore.importSkill(from: url)
                    }
                    refreshSkills()
                }
            }
            .fileImporter(isPresented: $showKBImporter,
                          allowedContentTypes: [.item, .folder],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Task {
                        for url in urls {
                            kbMessage = await KnowledgeBase.shared.add(url: url)
                        }
                        await refreshKB()
                    }
                }
            }
        }
    }

    private func refreshSkills() {
        skills = SkillStore.all()
    }

    private func refreshKB() async {
        kbDocs = await KnowledgeBase.shared.documents()
    }

    /// Queries the server's /v1/models endpoint and fills in the model ID.
    /// Keeps the current ID if the server still serves it.
    private func detectModel() {
        detectingModel = true
        modelStatus = nil
        Task {
            defer { detectingModel = false }
            guard let url = settings.serverURL else {
                modelStatus = "✗ Invalid URL"
                return
            }
            let client = LLMClient(baseURL: url, apiKey: settings.apiKey.isEmpty ? nil : settings.apiKey)
            do {
                let models = try await client.fetchModels()
                guard let first = models.first else {
                    modelStatus = "✗ Server reported no models"
                    return
                }
                if !models.contains(where: { $0.id == settings.modelID }) {
                    settings.modelID = first.id
                }
                modelStatus = "✓ Using \(settings.modelID)"
                    + (models.count > 1 ? " (\(models.count) available — switch in the chat's model menu)" : "")
            } catch {
                modelStatus = "✗ \(error.localizedDescription)"
            }
        }
    }

    private func testConnection() {
        testingConnection = true
        connectionStatus = nil
        Task {
            guard let url = settings.serverURL else {
                connectionStatus = "✗ Invalid URL"
                testingConnection = false
                return
            }
            let client = LLMClient(baseURL: url, apiKey: settings.apiKey.isEmpty ? nil : settings.apiKey)
            do {
                let models = try await client.fetchModels()
                connectionStatus = "✓ Connected — \(models.count) model(s) available"
                if settings.modelID.isEmpty, let first = models.first {
                    settings.modelID = first.id
                }
            } catch {
                connectionStatus = "✗ \(error.localizedDescription)"
            }
            testingConnection = false
        }
    }
}

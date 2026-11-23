import Foundation
import Observation

/// App-wide settings persisted via UserDefaults.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let baseURL = "settings.baseURL"
        static let apiKey = "settings.apiKey"
        static let modelID = "settings.modelID"
        static let temperature = "settings.temperature"
        static let maxTokens = "settings.maxTokens"
        static let autoMaxTokens = "settings.autoMaxTokens"
        static let systemPrompt = "settings.systemPrompt"
        static let toolsEnabled = "settings.toolsEnabled"
        static let maxToolRounds = "settings.maxToolRounds"
        static let useFoundationSession = "settings.useFoundationSession"
        static let thinkingEffort = "settings.thinkingEffort"
        static let contextWindow = "settings.contextWindow"
        static let subagentBaseURL = "settings.subagentBaseURL"
        static let subagentModelID = "settings.subagentModelID"
        static let endpoints = "settings.endpoints"
        static let activeEndpointID = "settings.activeEndpointID"
    }

    /// A saved server + credentials + last-used model.
    struct Endpoint: Codable, Identifiable, Equatable {
        enum Kind: String, Codable {
            case server
            case onDevice
        }

        var id = UUID()
        var name: String
        var baseURL: String
        var apiKey: String = ""
        var modelID: String = ""
        var kind: Kind = .server
        var apiMode: APIMode = .chatCompletions

        init(id: UUID = UUID(), name: String, baseURL: String, apiKey: String = "",
             modelID: String = "", kind: Kind = .server, apiMode: APIMode = .chatCompletions) {
            self.id = id
            self.name = name
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.modelID = modelID
            self.kind = kind
            self.apiMode = apiMode
        }

        // Endpoints saved before `kind` or `apiMode` existed decode as
        // chat-completions servers.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            baseURL = try c.decode(String.self, forKey: .baseURL)
            apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
            modelID = try c.decodeIfPresent(String.self, forKey: .modelID) ?? ""
            kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .server
            apiMode = try c.decodeIfPresent(APIMode.self, forKey: .apiMode) ?? .chatCompletions
        }
    }

    /// Saved endpoints. `baseURL`, `apiKey` and `modelID` below always mirror
    /// the active one, so the rest of the app keeps reading those.
    private(set) var endpoints: [Endpoint] = []
    private(set) var activeEndpointID: UUID?
    private var isSwitching = false

    var baseURL: String {
        didSet { defaults.set(baseURL, forKey: Keys.baseURL); syncActiveEndpoint() }
    }
    var apiKey: String {
        didSet { defaults.set(apiKey, forKey: Keys.apiKey); syncActiveEndpoint() }
    }
    var modelID: String {
        didSet { defaults.set(modelID, forKey: Keys.modelID); syncActiveEndpoint() }
    }
    /// API the active endpoint is called with (stored on the endpoint).
    var apiMode: APIMode {
        didSet { syncActiveEndpoint() }
    }
    var temperature: Double {
        didSet { defaults.set(temperature, forKey: Keys.temperature) }
    }
    var maxTokens: Int {
        didSet { defaults.set(maxTokens, forKey: Keys.maxTokens) }
    }
    /// Leave the reply length uncapped: `max_tokens` isn't sent, so the server
    /// allows as many tokens as the context window has room for.
    var autoMaxTokens: Bool {
        didSet { defaults.set(autoMaxTokens, forKey: Keys.autoMaxTokens) }
    }
    /// The `max_tokens` to send to a server; nil in Auto mode.
    var requestMaxTokens: Int? { autoMaxTokens ? nil : maxTokens }
    var systemPrompt: String {
        didSet { defaults.set(systemPrompt, forKey: Keys.systemPrompt) }
    }
    var toolsEnabled: Bool {
        didSet { defaults.set(toolsEnabled, forKey: Keys.toolsEnabled) }
    }
    /// Max tool rounds per turn before the model is forced to answer
    /// (server turns using the app's own tool loop).
    var maxToolRounds: Int {
        didSet { defaults.set(maxToolRounds, forKey: Keys.maxToolRounds) }
    }
    /// How much the model may think before answering (server turns only).
    var thinkingEffort: ThinkingEffort {
        didSet { defaults.set(thinkingEffort.rawValue, forKey: Keys.thinkingEffort) }
    }
    /// Run server turns through a Foundation Models session (`DGXLanguageModel`)
    /// instead of the app's own tool loop.
    var useFoundationSession: Bool {
        didSet { defaults.set(useFoundationSession, forKey: Keys.useFoundationSession) }
    }
    /// Model context window in tokens, used to compute context usage %.
    var contextWindow: Int {
        didSet { defaults.set(contextWindow, forKey: Keys.contextWindow) }
    }
    /// Optional separate endpoint for sub-agents (e.g. a cheaper server).
    /// Empty means: use the main server URL.
    var subagentBaseURL: String {
        didSet { defaults.set(subagentBaseURL, forKey: Keys.subagentBaseURL) }
    }
    /// Optional model for sub-agents (e.g. a smaller/cheaper model).
    /// Empty means: use the main model.
    var subagentModelID: String {
        didSet { defaults.set(subagentModelID, forKey: Keys.subagentModelID) }
    }

    static let defaultSystemPrompt = "You are a helpful assistant running on the user's DGX Spark."

    private init() {
        baseURL = defaults.string(forKey: Keys.baseURL) ?? "http://192.168.1.100:8000"
        apiKey = defaults.string(forKey: Keys.apiKey) ?? ""
        modelID = defaults.string(forKey: Keys.modelID) ?? ""
        apiMode = .chatCompletions
        temperature = defaults.object(forKey: Keys.temperature) as? Double ?? 0.7
        maxTokens = defaults.object(forKey: Keys.maxTokens) as? Int ?? 4096
        autoMaxTokens = defaults.object(forKey: Keys.autoMaxTokens) as? Bool ?? true
        systemPrompt = defaults.string(forKey: Keys.systemPrompt) ?? Self.defaultSystemPrompt
        toolsEnabled = defaults.object(forKey: Keys.toolsEnabled) as? Bool ?? true
        maxToolRounds = defaults.object(forKey: Keys.maxToolRounds) as? Int ?? 20
        thinkingEffort = defaults.string(forKey: Keys.thinkingEffort).flatMap(ThinkingEffort.init(rawValue:)) ?? .serverDefault
        useFoundationSession = defaults.object(forKey: Keys.useFoundationSession) as? Bool ?? false
        contextWindow = defaults.object(forKey: Keys.contextWindow) as? Int ?? 131072
        subagentBaseURL = defaults.string(forKey: Keys.subagentBaseURL) ?? ""
        subagentModelID = defaults.string(forKey: Keys.subagentModelID) ?? ""

        if let data = defaults.data(forKey: Keys.endpoints),
           let saved = try? JSONDecoder().decode([Endpoint].self, from: data) {
            endpoints = saved
        }
        let savedID = defaults.string(forKey: Keys.activeEndpointID).flatMap(UUID.init(uuidString:))
        // `apiMode` is set before anything that syncs, so a sync can't overwrite
        // the saved value with the default.
        if let savedID, let saved = endpoints.first(where: { $0.id == savedID }) {
            activeEndpointID = savedID
            apiMode = saved.apiMode
        } else if let first = endpoints.first(where: { $0.kind == .server }) {
            activeEndpointID = first.id
            apiMode = first.apiMode
            baseURL = first.baseURL
            apiKey = first.apiKey
            modelID = first.modelID
            saveEndpoints()
        } else {
            // First launch with endpoints: wrap the existing single server.
            let first = Endpoint(name: "Default", baseURL: baseURL, apiKey: apiKey, modelID: modelID)
            endpoints.insert(first, at: 0)
            activeEndpointID = first.id
            saveEndpoints()
        }
        // The on-device endpoint is built in; make sure it exists.
        if !endpoints.contains(where: { $0.kind == .onDevice }) {
            endpoints.append(Endpoint(name: "On Device", baseURL: "", kind: .onDevice))
            saveEndpoints()
        }
    }

    // MARK: - Endpoints

    var activeEndpoint: Endpoint? {
        endpoints.first { $0.id == activeEndpointID }
    }

    /// Display name of the active endpoint (editable).
    var activeEndpointName: String {
        get { activeEndpoint?.name ?? "" }
        set {
            guard let index = endpoints.firstIndex(where: { $0.id == activeEndpointID }) else { return }
            endpoints[index].name = newValue
            saveEndpoints()
        }
    }

    var isOnDevice: Bool { activeEndpoint?.kind == .onDevice }

    func switchEndpoint(to id: UUID) {
        guard id != activeEndpointID, let target = endpoints.first(where: { $0.id == id }) else { return }
        syncActiveEndpoint()
        isSwitching = true
        activeEndpointID = id
        baseURL = target.baseURL
        apiKey = target.apiKey
        modelID = target.modelID
        apiMode = target.apiMode
        isSwitching = false
        defaults.set(id.uuidString, forKey: Keys.activeEndpointID)
    }

    /// Adds an empty endpoint and makes it active.
    func addEndpoint() {
        syncActiveEndpoint()
        let endpoint = Endpoint(name: "Endpoint \(endpoints.count + 1)", baseURL: "http://")
        endpoints.append(endpoint)
        saveEndpoints()
        switchEndpoint(to: endpoint.id)
    }

    /// Removes the active endpoint (at least one always remains).
    func removeActiveEndpoint() {
        // The built-in on-device endpoint can't be removed, and one server stays.
        guard let id = activeEndpointID, activeEndpoint?.kind == .server,
              endpoints.filter({ $0.kind == .server }).count > 1,
              let next = endpoints.first(where: { $0.id != id && $0.kind == .server }) else { return }
        switchEndpoint(to: next.id)
        endpoints.removeAll { $0.id == id }
        saveEndpoints()
    }

    private func syncActiveEndpoint() {
        guard !isSwitching,
              let index = endpoints.firstIndex(where: { $0.id == activeEndpointID }) else { return }
        endpoints[index].baseURL = baseURL
        endpoints[index].apiKey = apiKey
        endpoints[index].modelID = modelID
        endpoints[index].apiMode = apiMode
        saveEndpoints()
    }

    private func saveEndpoints() {
        if let data = try? JSONEncoder().encode(endpoints) {
            defaults.set(data, forKey: Keys.endpoints)
        }
        if let activeEndpointID {
            defaults.set(activeEndpointID.uuidString, forKey: Keys.activeEndpointID)
        }
    }

    var serverURL: URL? {
        URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

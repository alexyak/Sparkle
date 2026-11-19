import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayScale) private var displayScale
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @AppStorage("selectedConversationID") private var selectedConversationID = ""
    @State private var selectedConversation: Conversation?
    @State private var showSettings = false
    @State private var searchText = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var didRestoreSelection = false
    @State private var persistenceError: String?

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCollapsed: Bool { horizontalSizeClass == .compact }
    #else
    private let isCollapsed = false
    #endif

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
    }

    private var newChatButton: some View {
        Button {
            newConversation()
        } label: {
            Label("New Chat", systemImage: "square.and.pencil")
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ConversationListView(conversations: conversations,
                                 selected: $selectedConversation,
                                 searchText: $searchText,
                                 isCollapsed: isCollapsed)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
                .toolbar {
                    #if os(iOS)
                    // Compact width: search on the left of the bottom bar, New Chat
                    // on the right. They're declared together so the spacer can
                    // separate them. Regular width puts both in the chat view.
                    if isCollapsed {
                        DefaultToolbarItem(kind: .search, placement: .bottomBar)
                        ToolbarSpacer(.flexible, placement: .bottomBar)
                        ToolbarItem(placement: .bottomBar) {
                            newChatButton
                        }
                    }
                    #endif
                    ToolbarItem(placement: .primaryAction) {
                        ModelPicker()
                    }
                    ToolbarItem(placement: .primaryAction) {
                        settingsButton
                    }
                }
        } detail: {
            detailContent
                // Regular width: New Chat at the far left of the chat view and
                // the collapsible search at the far right. Results show in the
                // sidebar, which reads the same query.
                .chatSearch(text: $searchText, isEnabled: !isCollapsed)
                .toolbar {
                    if !isCollapsed {
                        ToolbarItem(placement: .navigation) {
                            newChatButton
                        }
                        DefaultToolbarItem(kind: .search, placement: .primaryAction)
                    }
                }
                // Hairline divider between the sidebar and the detail column,
                // running the full height including under the navigation bars.
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.appSeparator)
                        .frame(width: 1 / displayScale)
                        .ignoresSafeArea()
                }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onAppear {
            restoreSelection()
        }
        .onChange(of: conversations.map(\.id)) { _, _ in
            if selectedConversation == nil {
                restoreSelection()
            }
        }
        .onChange(of: selectedConversation?.id) { _, newID in
            guard didRestoreSelection else { return }
            selectedConversationID = newID?.uuidString ?? ""
        }
        .alert("Unable to Save Changes", isPresented: Binding(
            get: { persistenceError != nil },
            set: { if !$0 { persistenceError = nil } }
        )) {
            Button("OK") { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "")
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        Group {
            if let selectedConversation {
                ChatView(conversation: selectedConversation,
                         onCreateBranch: selectBranch)
                    .id(selectedConversation.id)
            } else {
                ContentUnavailableView("No Chat Selected",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Create a new chat or pick one from the sidebar."))
            }
        }
    }

    private func restoreSelection() {
        guard !conversations.isEmpty else {
            didRestoreSelection = true
            return
        }

        if let savedID = UUID(uuidString: selectedConversationID),
           let savedConversation = conversations.first(where: { $0.id == savedID }) {
            selectedConversation = savedConversation
        } else if selectedConversation == nil {
            selectedConversation = conversations.first
        }
        didRestoreSelection = true
    }

    private func selectBranch(_ conversation: Conversation) {
        selectedConversation = conversation
    }

    private func newConversation() {
        let conversation = Conversation(modelID: AppSettings.shared.modelID,
                                        systemPrompt: AppSettings.shared.systemPrompt)
        modelContext.insert(conversation)
        do {
            try modelContext.save()
        } catch {
            persistenceError = error.localizedDescription
        }
        selectedConversation = conversation
    }
}

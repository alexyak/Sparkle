import SwiftUI
import SwiftData

struct ConversationListView: View {
    let conversations: [Conversation]
    @Binding var selected: Conversation?
    @Environment(\.modelContext) private var modelContext
    /// True when the split view is collapsed into a stack (iPhone, Slide Over).
    /// Passed in from the root because a sidebar column reports its own, narrower
    /// size class even on a full-width iPad.
    var isCollapsed = false
    @State private var saveError: String?
    /// Ids of the groups the user has collapsed; everything starts expanded.
    @State private var collapsedGroups: Set<String> = []
    @State private var searchText = ""
    @State private var searchResults: [SearchResult] = []

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if trimmedQuery.isEmpty {
                conversationList
            } else {
                searchResultList
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search all chats")
        .task(id: trimmedQuery) {
            // Debounce typing, then scan titles and message text.
            guard !trimmedQuery.isEmpty else {
                searchResults = []
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            searchResults = search(trimmedQuery)
        }
        .navigationTitle("Chats")
        .task { SessionLog.prepare(conversations) }
        .alert("Unable to Save Changes", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: Search

    private struct SearchResult: Identifiable {
        let conversation: Conversation
        /// Text around the first match in a message; nil when only the title matched.
        let snippet: String?
        var id: UUID { conversation.id }
    }

    private static let matchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Chats whose title or user/assistant messages contain `query`, newest first.
    private func search(_ query: String) -> [SearchResult] {
        var results: [SearchResult] = []
        for conversation in conversations.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let titleMatches = conversation.title.range(of: query, options: Self.matchOptions) != nil
            var snippet: String?
            for message in conversation.sortedMessages where message.role == .user || message.role == .assistant {
                if let range = message.content.range(of: query, options: Self.matchOptions) {
                    snippet = Self.snippet(in: message.content, around: range)
                    break
                }
            }
            if titleMatches || snippet != nil {
                results.append(SearchResult(conversation: conversation, snippet: snippet))
            }
        }
        return results
    }

    private static func snippet(in text: String, around range: Range<String.Index>) -> String {
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
        let body = text[start..<end]
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
    }

    /// A tappable conversation row. In compact width the row is tagged for the
    /// list's selection, which is what makes the collapsed (iPhone) split view
    /// push the detail; a plain button setting the binding doesn't. Elsewhere a
    /// button keeps our own rounded highlight without the system selection box.
    @ViewBuilder
    private func row<Content: View>(for conversation: Conversation,
                                    @ViewBuilder content: () -> Content) -> some View {
        if isCollapsed {
            content().tag(conversation)
        } else {
            plainRow(for: conversation, content: content)
        }
    }

    /// Only the compact layout uses list selection (to drive the push); in
    /// regular width it's off so the system draws no selection box of its own.
    private var listSelection: Binding<Conversation?> {
        isCollapsed ? $selected : .constant(nil)
    }

    private func plainRow<Content: View>(for conversation: Conversation,
                                         @ViewBuilder content: () -> Content) -> some View {
        Button {
            selected = conversation
        } label: {
            content()
        }
        .buttonStyle(.plain)
    }

    private var searchResultList: some View {
        List(selection: listSelection) {
            if searchResults.isEmpty {
                ContentUnavailableView.search(text: trimmedQuery)
                    .listRowBackground(Color.clear)
            } else {
                Section("\(searchResults.count) \(searchResults.count == 1 ? "chat" : "chats")") {
                    ForEach(searchResults) { result in
                        row(for: result.conversation) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.conversation.title)
                                    .font(.body)
                                    .lineLimit(1)
                                if let snippet = result.snippet {
                                    Text(snippet)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.leading, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(!isCollapsed && selected == result.conversation ? Color.accentColor.opacity(0.25) : Color.clear)
                                .padding(.horizontal, 6)
                        )
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var conversationList: some View {
        // Rows are plain buttons with our own rounded highlight; the system
        // selection style draws a full-width rectangle that can't be rounded.
        List(selection: listSelection) {
            ForEach(groupedConversations) { group in
                Section {
                    ForEach(collapsedGroups.contains(group.id) ? [] : group.conversations) { conversation in
                        row(for: conversation) {
                            Text(conversation.title)
                                .font(.body)
                                .lineLimit(1)
                                .padding(.leading, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(!isCollapsed && selected == conversation ? Color.accentColor.opacity(0.25) : Color.clear)
                                .padding(.horizontal, 6)
                        )
                        .contextMenu {
                            if let transcript = SessionLog.exportURL(for: conversation.id) {
                                ShareLink(item: transcript) {
                                    Label("Export Transcript", systemImage: "square.and.arrow.up")
                                }
                            }
                            Button(role: .destructive) {
                                delete(conversation)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    delete(conversation)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    // Own header button instead of the system disclosure, which
                    // only shows its chevron on hover.
                    let isExpanded = !collapsedGroups.contains(group.id)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if isExpanded {
                                collapsedGroups.insert(group.id)
                            } else {
                                collapsedGroups.remove(group.id)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(group.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .textCase(nil)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                .padding(.trailing, 16)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(group.title)
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                }
            }
        }
        .listStyle(.sidebar)
    }

    private struct ConversationGroup: Identifiable {
        let id: String
        let title: String
        var conversations: [Conversation]
    }

    /// Buckets chats by last update: Today, Yesterday, the previous 7 and 30 days,
    /// then one section per month of the current year, then one per older year.
    /// Sections come out newest first.
    private var groupedConversations: [ConversationGroup] {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
        let monthAgo = calendar.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfToday
        let currentYear = calendar.component(.year, from: now)

        var groups: [ConversationGroup] = []
        for conversation in conversations.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let date = conversation.updatedAt
            let id: String
            let title: String
            if date >= startOfToday {
                (id, title) = ("today", "Today")
            } else if date >= yesterday {
                (id, title) = ("yesterday", "Yesterday")
            } else if date >= weekAgo {
                (id, title) = ("week", "Previous 7 Days")
            } else if date >= monthAgo {
                (id, title) = ("month", "Previous 30 Days")
            } else {
                let parts = calendar.dateComponents([.year, .month], from: date)
                if parts.year == currentYear {
                    id = "m-\(parts.year ?? 0)-\(parts.month ?? 0)"
                    title = date.formatted(.dateTime.month(.wide))
                } else {
                    id = "y-\(parts.year ?? 0)"
                    title = date.formatted(.dateTime.year())
                }
            }
            if let index = groups.firstIndex(where: { $0.id == id }) {
                groups[index].conversations.append(conversation)
            } else {
                groups.append(ConversationGroup(id: id, title: title, conversations: [conversation]))
            }
        }
        return groups
    }

    private func delete(_ conversation: Conversation) {
        if selected == conversation { selected = nil }
        SessionLog.delete(conversationID: conversation.id)
        modelContext.delete(conversation)
        do {
            try modelContext.save()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

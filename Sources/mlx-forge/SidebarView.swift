// Forge — sidebar: brand, new-chat, conversation list.

import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var app
    @State private var showClearAllConfirm = false
    @State private var pendingDeleteConversationID: UUID?
    @State private var pendingDeleteConversationTitle = ""

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Theme.s4)
                .padding(.vertical, Theme.s3)

            List(selection: $app.selectedConversationID) {
                Section("Chats") {
                    ForEach(app.conversations) { conversation in
                        ConversationRow(conversation: conversation)
                            .tag(conversation.id)
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    pendingDeleteConversationID = conversation.id
                                    pendingDeleteConversationTitle = conversation.title
                                }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()
            footer
                .padding(Theme.s3)
        }
        .background(.black.opacity(0.2))
        .confirmationDialog(
            "Clear all conversations?",
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                app.clearAllConversations()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every chat in the sidebar. You can’t undo this.")
        }
        .alert(
            "Delete conversation?",
            isPresented: Binding(
                get: { pendingDeleteConversationID != nil },
                set: { if !$0 { pendingDeleteConversationID = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteConversationID {
                    app.deleteConversation(id)
                }
                pendingDeleteConversationID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteConversationID = nil
            }
        } message: {
            Text("\"\(pendingDeleteConversationTitle)\" will be permanently removed.")
        }
    }

    private var header: some View {
        HStack(spacing: Theme.s2) {
            ForgeMark(size: 18, animated: false)
            Text("FORGE")
                .font(.headline.weight(.heavy))
                .kerning(3)
                .foregroundStyle(Theme.emberGradient)
            Spacer()
            Button("Clear All") {
                showClearAllConfirm = true
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(app.conversations.isEmpty ? .tertiary : .secondary)
            .disabled(app.conversations.isEmpty)
            .help("Delete every conversation in the sidebar")
            Button {
                app.newConversation()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New chat (⌘N)")
        }
    }

    private var footer: some View {
        Button {
            app.showModelBrowser = true
        } label: {
            HStack(spacing: Theme.s2) {
                Image(systemName: "shippingbox")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Model Library")
                        .font(.callout.weight(.medium))
                    Text("\(app.store.localModels.count) installed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !app.store.downloads.filter({ !$0.finished && $0.failed == nil }).isEmpty {
                    ProgressView()
                        .controlSize(.small)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(Theme.s3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassCard()
        .help("Browse, download, and manage models (⌘M)")
    }
}

private struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(conversation.title)
                .font(.callout)
                .lineLimit(1)
            HStack(spacing: Theme.s1) {
                Text(conversation.updatedAt, format: .relative(presentation: .named))
                if let model = conversation.lastModelID {
                    Text("·")
                    Text(model.split(separator: "/").last.map(String.init) ?? model)
                        .lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

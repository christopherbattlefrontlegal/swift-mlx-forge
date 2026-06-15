// Forge — sidebar: brand, new-chat, conversation list.

import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var app

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
                                    app.deleteConversation(conversation.id)
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
    }

    private var header: some View {
        HStack(spacing: Theme.s2) {
            ForgeMark(size: 18)
            Text("FORGE")
                .font(.headline.weight(.heavy))
                .kerning(3)
                .foregroundStyle(Theme.emberGradient)
            Spacer()
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

// Forge — large text viewer presented as a sheet for very long user (or other) messages.
// Renders with full MarkdownText (code blocks, prose) and offers copy-to-clipboard.

import AppKit
import SwiftUI

struct LargeTextView: View {
    let text: String
    var onDismiss: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: Theme.s3) {
                Text("Full Message")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                Text("\(text.count) characters")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.s2)
                    .padding(.vertical, Theme.s1)
                    .background(.white.opacity(0.06))
                    .clipShape(.capsule)

                Button {
                    copyToClipboard()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Theme.okGreen : Theme.ember)
                .disabled(copied)

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close")
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
            .background(.ultraThinMaterial)

            Divider()
                .background(Color.white.opacity(0.08))

            // Scrollable rich content (re-uses existing MarkdownText for consistent
            // fenced code blocks, inline formatting, and per-block copy buttons).
            ScrollView(.vertical, showsIndicators: true) {
                MarkdownText(text: text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.s5)
            }
            .background(Theme.assistantBubble.opacity(0.65))
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(Theme.backgroundGradient)
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            copied = false
        }
    }
}

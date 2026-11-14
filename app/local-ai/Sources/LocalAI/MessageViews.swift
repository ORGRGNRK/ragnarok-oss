import ToolCallParsing
import AppKit
import SwiftUI

enum Clipboard {
    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let isStreaming: Bool

    @State private var copied = false

    var body: some View {
        if message.role == .tool {
            ToolCallRow(message: message)
        } else {
            standardRow
        }
    }

    private var standardRow: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(message.role == .user ? "You" : "LocalAI")
                        .font(.headline)
                    if isStreaming {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer()
                    if !isStreaming && !message.content.isEmpty && !message.isError {
                        Button {
                            Clipboard.copy(message.content)
                            flashCopied()
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Copy message")
                    }
                }

                if let attachments = message.attachments, !attachments.isEmpty {
                    MessageAttachmentsView(attachments: attachments)
                }

                if !(message.role == .user && message.content.isEmpty) {
                    content
                }

                if !isStreaming, let claims = message.unverifiedClaims, !claims.isEmpty {
                    UnverifiedClaimsBadge(claims: claims)
                }

                if let stats = message.stats, !isStreaming {
                    Text(stats.summary)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var avatar: some View {
        Image(systemName: message.role == .user ? "person.crop.circle.fill" : "cpu.fill")
            .font(.system(size: 22))
            .foregroundStyle(message.role == .user ? Color.accentColor : Color.purple)
            .frame(width: 28)
    }

    @ViewBuilder
    private var content: some View {
        if message.isError {
            Label(message.content, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        } else if message.role == .assistant && message.content.isEmpty && isStreaming {
            Text("Thinking…")
                .foregroundStyle(.secondary)
        } else if message.role == .user {
            Text(message.content)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            MarkdownContentView(text: message.content)
        }
    }

    private func flashCopied() {
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

struct MarkdownContentView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(MarkdownParser.parse(text)) { segment in
                switch segment.kind {
                case .text(let prose):
                    Text(MarkdownParser.attributed(prose))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                }
            }
        }
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Clipboard.copy(code)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(
                        copied ? "Copied" : "Copy",
                        systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.12))

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.25))
        )
    }
}

/// A tool call and its result, as a small collapsible row.
struct ToolCallRow: View {
    let message: ChatMessage
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView {
                Text(message.content)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 240)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.7))
            )
        } label: {
            HStack(spacing: 6) {
                Image(systemName: message.isError ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                    .foregroundStyle(message.isError ? Color.red : Color.secondary)
                Text(message.toolCallSummary ?? "tool")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("· \(message.content.count) chars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let receipt = message.receipt {
                    Text(receipt.badge)
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill((receipt.ok ? Color.green : Color.red).opacity(0.18)))
                        .foregroundStyle(receipt.ok ? Color.green : Color.red)
                        .help("Receipt \(receipt.id)\nsha256 \(receipt.outputSHA256)\n\(receipt.timestamp.formatted(date: .abbreviated, time: .standard))")
                }
            }
        }
        .padding(.leading, 40)
        .padding(.trailing, 8)
    }
}

/// Red badge under a reply whose action claims have no receipt in the same turn.
struct UnverifiedClaimsBadge: View {
    let claims: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Unverified: no receipt for these claims", systemImage: "exclamationmark.shield.fill")
                .font(.caption.weight(.semibold))
            ForEach(Array(claims.enumerated()), id: \.offset) { _, claim in
                Text("[derived] " + claim)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(Color.red)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.5)))
    }
}

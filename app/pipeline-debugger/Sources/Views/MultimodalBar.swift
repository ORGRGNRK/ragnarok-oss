import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct MultimodalBar: View {
    @EnvironmentObject var state: AppState
    @State private var isTargeted: Bool = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Multimodal Context", systemImage: "photo.stack")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                Spacer()

                // Interactive Screenshot Button
                Button {
                    state.captureInteractiveScreenshot()
                } label: {
                    Label("Capture Screen", systemImage: "camera.viewfinder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Marquee selection or window screenshot")

                // Paste Image from Clipboard
                Button {
                    state.pasteImageFromClipboard()
                } label: {
                    Label("Paste Image", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Attach image currently in clipboard")

                // Add File Button
                Button {
                    state.selectImageFiles()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Add image file from disk")
            }

            // Thumbnail strip if images are attached
            if !state.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(state.attachments) { att in
                            HStack(spacing: 6) {
                                if let thumb = att.thumbnail {
                                    Image(nsImage: thumb)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 32, height: 32)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                } else {
                                    Image(systemName: "photo")
                                        .frame(width: 32, height: 32)
                                }

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(att.name)
                                        .font(.caption.bold())
                                        .lineLimit(1)
                                        .frame(maxWidth: 120, alignment: .leading)
                                    Text(ByteCountFormatter.string(fromByteCount: att.size, countStyle: .file))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Button {
                                    state.removeAttachment(att)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(4)
                            .background(Color(NSColor.controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(isTargeted ? Color.accentColor.opacity(0.1) : Color(NSColor.windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            state.handleDrop(providers: providers)
            return true
        }
    }
}

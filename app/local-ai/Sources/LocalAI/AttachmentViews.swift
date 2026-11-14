import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Picking / dropping / pasting

@MainActor
enum AttachmentPicker {
    /// Open panel: the only way files get attached besides drag-and-drop and paste.
    static func present(chat: ChatViewModel) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        panel.message = "Choose text, code, PDF or image files to attach to your message"
        if panel.runModal() == .OK {
            chat.addAttachments(urls: panel.urls)
        }
    }

    /// Handle dropped items (file URLs or raw image data, e.g. from a browser).
    static func handleDrop(_ providers: [NSItemProvider], chat: ChatViewModel) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in chat.addAttachments(urls: [url]) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                let name = provider.suggestedName ?? "Dropped image"
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage else { return }
                    Task { @MainActor in chat.addImage(image, name: name + ".jpg") }
                }
            }
        }
        return handled
    }

    /// ⌘V with files or an image on the pasteboard attaches them; plain text pastes normally.
    /// Returns true if the paste was consumed.
    static func handlePaste(chat: ChatViewModel) -> Bool {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !urls.isEmpty
        {
            chat.addAttachments(urls: urls)
            return true
        }
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        if pb.availableType(from: imageTypes) != nil, pb.string(forType: .string) == nil,
            let image = NSImage(pasteboard: pb)
        {
            let stamp = Date().formatted(.dateTime.year().month().day().hour().minute().second())
            chat.addImage(image, name: "Pasted image \(stamp).jpg")
            return true
        }
        return false
    }
}

/// Installs a local ⌘V key monitor while the input bar is on screen.
final class PasteMonitor {
    private var monitor: Any?

    @MainActor
    func install(chat: ChatViewModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak chat] event in
            guard let chat,
                event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                event.charactersIgnoringModifiers?.lowercased() == "v",
                let window = event.window,
                !(window.identifier?.rawValue.lowercased().contains("settings") ?? false),
                window.title != "Settings"
            else { return event }
            let consumed = MainActor.assumeIsolated { AttachmentPicker.handlePaste(chat: chat) }
            return consumed ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { remove() }
}

// MARK: - Chips (before sending) and thumbnails (in history)

struct AttachmentChipsView: View {
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var server: ServerManager
    @AppStorage(SettingsKey.backend) private var backend = AppSettings.defaultBackend

    var body: some View {
        if !chat.pendingAttachments.isEmpty || chat.attachmentError != nil {
            VStack(alignment: .leading, spacing: 6) {
                if !chat.pendingAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(chat.pendingAttachments) { attachment in
                                AttachmentChip(attachment: attachment) {
                                    chat.removeAttachment(attachment.id)
                                }
                            }
                        }
                    }
                }
                if let warning = chat.imageWarning {
                    Label(warning, systemImage: "eye.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let error = chat.attachmentError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

struct AttachmentChip: View {
    let attachment: ChatAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            AttachmentIcon(attachment: attachment, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(attachment.truncated ? .orange : .secondary)
            }
            .frame(maxWidth: 180, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove attachment")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
    }

    private var detail: String {
        switch attachment.kind {
        case .image: return "Image · \(attachment.sizeText)"
        case .text:
            let chars = (attachment.text?.count ?? 0).formatted()
            return attachment.truncated
                ? "Truncated to \(chars) chars" : "\(attachment.sizeText) · \(chars) chars"
        }
    }
}

struct AttachmentIcon: View {
    let attachment: ChatAttachment
    let size: CGFloat

    var body: some View {
        if attachment.kind == .image, let image = ThumbnailCache.image(for: attachment) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: attachment.systemImage)
                .font(.system(size: size * 0.6))
                .frame(width: size, height: size)
                .foregroundStyle(.secondary)
        }
    }
}

/// Attachments shown under a sent user message.
struct MessageAttachmentsView: View {
    let attachments: [ChatAttachment]
    @State private var preview: ChatAttachment?

    var body: some View {
        let images = attachments.filter { $0.kind == .image }
        let files = attachments.filter { $0.kind == .text }
        VStack(alignment: .leading, spacing: 6) {
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(images) { image in
                            if let ns = ThumbnailCache.image(for: image) {
                                Image(nsImage: ns)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 120, height: 90)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.secondary.opacity(0.3))
                                    )
                                    .help(image.filename)
                                    .onTapGesture { preview = image }
                            }
                        }
                    }
                }
            }
            ForEach(files) { file in
                HStack(spacing: 6) {
                    Image(systemName: file.systemImage).foregroundStyle(.secondary)
                    Text(file.filename).lineLimit(1).truncationMode(.middle)
                    Text(file.truncated ? "· truncated" : "· \(file.sizeText)")
                        .foregroundStyle(file.truncated ? .orange : .secondary)
                }
                .font(.caption)
            }
        }
        .sheet(item: $preview) { image in
            VStack(spacing: 10) {
                if let ns = ThumbnailCache.image(for: image) {
                    Image(nsImage: ns)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 900, maxHeight: 700)
                }
                HStack {
                    Text(image.filename).font(.caption)
                    Spacer()
                    Button("Close") { preview = nil }.keyboardShortcut(.cancelAction)
                }
            }
            .padding()
        }
    }
}

// MARK: - Server status bar with model picker

struct ServerStatusBar: View {
    @EnvironmentObject private var server: ServerManager
    @AppStorage(SettingsKey.serverURL) private var serverURL = AppSettings.defaultServerURL

    var body: some View {
        HStack(spacing: 8) {
            switch server.status {
            case .unknown, .checking:
                ProgressView().controlSize(.small)
                Text("Connecting to \(serverURL)…").lineLimit(1)
            case .online(let kind):
                Image(systemName: "server.rack").foregroundStyle(.green)
                Text(kind.label).fontWeight(.medium)
                if server.models.isEmpty {
                    Text("No models on the server").foregroundStyle(.secondary)
                } else {
                    ServerModelPicker()
                        .frame(maxWidth: 360)
                    if !server.selectedModel.isEmpty
                        && server.supportsVision(server.selectedModel)
                    {
                        Label("vision", systemImage: "eye")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            case .offline(let message):
                Image(systemName: "bolt.horizontal.circle").foregroundStyle(.orange)
                Text(message).lineLimit(2).textSelection(.enabled)
            }
            Spacer()
            Button {
                Task { await server.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(server.status == .checking)
            .help("Re-check the server and fetch its model list")
            SettingsLink { Text("Server Settings…") }
        }
    }
}

struct ServerModelPicker: View {
    @EnvironmentObject private var server: ServerManager

    var body: some View {
        Picker("Model", selection: $server.selectedModel) {
            if !server.models.contains(where: { $0.id == server.selectedModel }) {
                Text(server.selectedModel.isEmpty ? "Choose a model" : server.selectedModel)
                    .tag(server.selectedModel)
            }
            ForEach(server.models) { model in
                Text(model.detail.map { "\(model.id)  (\($0))" } ?? model.id).tag(model.id)
            }
        }
        .labelsHidden()
    }
}

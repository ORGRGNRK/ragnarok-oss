import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// A file or image the user attached to a message. Stored inside chats.json:
/// text is already capped, images are downscaled JPEG (base64).
struct ChatAttachment: Identifiable, Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        case text
        case image
    }

    var id: UUID = UUID()
    var kind: Kind
    var filename: String
    /// Size of the original file / image data.
    var byteCount: Int
    /// `.text`: extracted (and possibly truncated) text.
    var text: String?
    var truncated: Bool = false
    /// `.image`: base64 JPEG/PNG for the model.
    var imageBase64: String?
    var mimeType: String?

    var dataURI: String? {
        guard let imageBase64 else { return nil }
        return "data:\(mimeType ?? "image/jpeg");base64,\(imageBase64)"
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    var systemImage: String {
        switch kind {
        case .image: return "photo"
        case .text:
            let ext = (filename as NSString).pathExtension.lowercased()
            if ext == "pdf" { return "doc.richtext" }
            return "doc.text"
        }
    }
}

enum AttachmentError: LocalizedError {
    case tooLarge(String, Int)
    case unsupported(String)
    case unreadable(String, String)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let name, let bytes):
            return "\(name) is too large (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)); limit \(ByteCountFormatter.string(fromByteCount: Int64(AttachmentLoader.maxFileBytes), countStyle: .file)))."
        case .unsupported(let name):
            return "\(name) isn't a text, code, PDF or image file."
        case .unreadable(let name, let why):
            return "Couldn't read \(name): \(why)"
        }
    }
}

enum AttachmentLoader {
    /// Per-file cap on inlined text (≈ 7–8k tokens).
    static let maxTextChars = 30_000
    static let maxFileBytes = 30 * 1024 * 1024
    /// Longest image edge sent to the model.
    static let maxImageEdge: CGFloat = 1280
    static let maxAttachmentsPerMessage = 10

    /// Load a file the user explicitly picked, dropped or pasted.
    static func load(url: URL) throws -> ChatAttachment {
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentTypeKey])
        if values?.isDirectory == true { throw AttachmentError.unsupported(name) }
        let size = values?.fileSize ?? 0
        if size > maxFileBytes { throw AttachmentError.tooLarge(name, size) }
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)

        if let type, type.conforms(to: .pdf) {
            guard let doc = PDFDocument(url: url) else {
                throw AttachmentError.unreadable(name, "not a valid PDF")
            }
            var pages: [String] = []
            var total = 0
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i), let s = page.string else { continue }
                pages.append(s)
                total += s.count
                if total > maxTextChars { break }
            }
            let joined = pages.joined(separator: "\n\n")
            if joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AttachmentError.unreadable(name, "the PDF has no extractable text (scanned?)")
            }
            return makeText(name: name, size: size, text: joined)
        }

        if let type, type.conforms(to: .image) {
            guard let image = NSImage(contentsOf: url) else {
                throw AttachmentError.unreadable(name, "not a readable image")
            }
            return try fromImage(image, name: name, originalBytes: size)
        }

        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw AttachmentError.unreadable(name, error.localizedDescription)
        }
        // Binary check: NUL bytes in the first 8 KB → not text.
        if data.prefix(8192).contains(0) { throw AttachmentError.unsupported(name) }
        let text =
            String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        return makeText(name: name, size: size == 0 ? data.count : size, text: text)
    }

    private static func makeText(name: String, size: Int, text: String) -> ChatAttachment {
        let truncated = text.count > maxTextChars
        return ChatAttachment(
            kind: .text, filename: name, byteCount: size,
            text: truncated ? String(text.prefix(maxTextChars)) : text,
            truncated: truncated)
    }

    /// Downscale to `maxImageEdge` and encode as JPEG (transparent areas become white).
    static func fromImage(_ image: NSImage, name: String, originalBytes: Int? = nil) throws
        -> ChatAttachment
    {
        guard
            let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw AttachmentError.unreadable(name, "could not decode image") }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let scale = min(1, maxImageEdge / max(w, h, 1))
        let tw = max(1, Int((w * scale).rounded()))
        let th = max(1, Int((h * scale).rounded()))
        guard
            let ctx = CGContext(
                data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw AttachmentError.unreadable(name, "could not resize image") }
        // White background so transparent PNGs/screenshots don't turn black in JPEG.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: tw, height: th))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let scaled = ctx.makeImage() else {
            throw AttachmentError.unreadable(name, "could not resize image")
        }
        let rep = NSBitmapImageRep(cgImage: scaled)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { throw AttachmentError.unreadable(name, "could not encode image") }
        return ChatAttachment(
            kind: .image, filename: name, byteCount: originalBytes ?? jpeg.count,
            imageBase64: jpeg.base64EncodedString(), mimeType: "image/jpeg")
    }

    /// The text the model sees for a user turn: the typed text plus inlined files.
    static func promptText(
        _ userText: String, attachments: [ChatAttachment], imagesNote: String? = nil
    ) -> String {
        var parts: [String] = []
        if !userText.isEmpty { parts.append(userText) }
        for a in attachments where a.kind == .text {
            var block = "[Attached file: \(a.filename)]\n```\n\(a.text ?? "")\n```"
            if a.truncated {
                block +=
                    "\n[Note: \(a.filename) was truncated to the first \(maxTextChars) characters.]"
            }
            parts.append(block)
        }
        if let imagesNote { parts.append(imagesNote) }
        return parts.joined(separator: "\n\n")
    }
}

/// Small decoded-thumbnail cache so the transcript doesn't re-decode base64 every render.
@MainActor
enum ThumbnailCache {
    private static var cache: [UUID: NSImage] = [:]

    static func image(for attachment: ChatAttachment) -> NSImage? {
        if let hit = cache[attachment.id] { return hit }
        guard let b64 = attachment.imageBase64, let data = Data(base64Encoded: b64),
            let image = NSImage(data: data)
        else { return nil }
        cache[attachment.id] = image
        return image
    }
}

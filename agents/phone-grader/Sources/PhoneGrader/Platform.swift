import SwiftUI
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
/// The platform's native image type (NSImage on the Mac, UIImage on iPhone/iPad).
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

// Small cross-platform shims so the SwiftUI views are shared between the Mac app
// (Package.swift executable) and the iPhone/iPad app (iOS/PhoneGraderiOS.xcodeproj).
// On macOS every helper here does exactly what the original Mac-only code did.

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension Color {
    /// Card fill: the Mac's control background; the grouped secondary background on iOS.
    static var cardBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}

extension View {
    /// Mac: exactly `.frame(width:alignment:)` (unchanged layout). iOS: the same width as a
    /// maximum, so iPhone rows can shrink instead of overflowing.
    @ViewBuilder func pgWidth(_ width: CGFloat, alignment: Alignment = .center) -> some View {
        #if os(macOS)
        frame(width: width, alignment: alignment)
        #else
        frame(maxWidth: width, alignment: alignment)
        #endif
    }
}

/// Mac: a plain HStack (unchanged layout). iOS: an HStack when it fits the width,
/// otherwise the same items stacked vertically (iPhone portrait).
struct FlexRow<Content: View>: View {
    var alignment: VerticalAlignment = .center
    var spacing: CGFloat? = nil
    @ViewBuilder var content: Content

    var body: some View {
        #if os(macOS)
        HStack(alignment: alignment, spacing: spacing) { content }
        #else
        ViewThatFits(in: .horizontal) {
            HStack(alignment: alignment, spacing: spacing) { content }
            VStack(alignment: .leading, spacing: spacing ?? 8) { content }
        }
        #endif
    }
}

enum PlatformImaging {
    static func jpeg(_ cg: CGImage, quality: CGFloat = 0.85) -> Data? {
        #if os(macOS)
        NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: quality])
        #else
        UIImage(cgImage: cg).jpegData(compressionQuality: quality)
        #endif
    }

    static func png(_ cg: CGImage) -> Data? {
        #if os(macOS)
        NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        #else
        UIImage(cgImage: cg).pngData()
        #endif
    }

    /// Decode any image (JPEG/HEIC/PNG), apply its EXIF orientation, and downscale so the
    /// long edge is at most `maxPixel` (never upscales).
    static func upright(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Full-size decode, no orientation change (the rig applies its own rotation).
    static func raw(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

func copyToPasteboard(_ s: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
    #else
    UIPasteboard.general.string = s
    #endif
}

/// Files picked through SwiftUI's file importer can be security-scoped (always on iOS).
func withSecurityScope<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
    let ok = url.startAccessingSecurityScopedResource()
    defer { if ok { url.stopAccessingSecurityScopedResource() } }
    return try body()
}

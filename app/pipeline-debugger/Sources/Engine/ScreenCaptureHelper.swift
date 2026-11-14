import AppKit
import Foundation
import UniformTypeIdentifiers

public final class ScreenCaptureHelper {
    public static let shared = ScreenCaptureHelper()

    public func captureInteractive(completion: @escaping (URL?) -> Void) {
        let tmpDir = FileManager.default.temporaryDirectory
        let fileURL = tmpDir.appendingPathComponent("pipeline_screenshot_\(UUID().uuidString.prefix(8)).png")

        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", fileURL.path]

            do {
                try p.run()
                p.waitUntilExit()
                DispatchQueue.main.async {
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        completion(fileURL)
                    } else {
                        completion(nil)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(nil)
                }
            }
        }
    }

    public func captureFromClipboard() -> URL? {
        let pb = NSPasteboard.general
        guard let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
              let image = images.first,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }

        let tmpDir = FileManager.default.temporaryDirectory
        let fileURL = tmpDir.appendingPathComponent("clipboard_img_\(UUID().uuidString.prefix(8)).png")
        do {
            try png.write(to: fileURL)
            return fileURL
        } catch {
            return nil
        }
    }

    public func openFilePicker(completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.image, .png, .jpeg, .webP, .gif]
        panel.title = "Select Visual Pipeline Attachments or Screenshots"

        if panel.runModal() == .OK {
            completion(panel.urls)
        } else {
            completion([])
        }
    }
}

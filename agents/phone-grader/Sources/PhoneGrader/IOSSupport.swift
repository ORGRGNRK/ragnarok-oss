#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PhoneGraderCore

// iPhone / iPad only. The Mac app never compiles this file's contents.

/// iOS entry point (the Mac's entry point is Entry.swift, which is macOS-only).
@main
struct PhoneGraderiOSApp: App {
    @StateObject private var state = AppState()
    @StateObject private var rig = RigSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .environmentObject(state.history)
                .environmentObject(rig)
        }
    }
}

/// Camera capture for the Grade tab's photos (UIImagePickerController; the system asks for camera permission).
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.cameraCaptureMode = .photo
        c.delegate = context.coordinator
        return c
    }
    func updateUIViewController(_ c: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
}

/// Share-sheet file for the 1080² listing photo (rendered only when shared).
struct ListingPhotoExport: Transferable {
    let record: HistoryRecord
    let maskIMEI: Bool
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .png) { item in
            guard let d = await ListingPhoto.png(item.record, maskIMEI: item.maskIMEI) else { throw CocoaError(.fileWriteUnknown) }
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("phonegrader-\(item.record.id).png")
            try d.write(to: u, options: .atomic)
            return SentTransferredFile(u)
        }
    }
}

/// Share-sheet file for the QR receipt (same content as the printed receipt; the share sheet also offers Print).
struct ReceiptExport: Transferable {
    let record: HistoryRecord
    let maskIMEI: Bool
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .png) { item in
            guard let d = await ReceiptPrinter.png(item.record, maskIMEI: item.maskIMEI) else { throw CocoaError(.fileWriteUnknown) }
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("phonegrader-receipt-\(item.record.id).png")
            try d.write(to: u, options: .atomic)
            return SentTransferredFile(u)
        }
    }
}

func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
#endif

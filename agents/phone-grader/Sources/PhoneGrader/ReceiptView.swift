import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import UniformTypeIdentifiers
import PhoneGraderCore

/// History → record → one "Share" menu. Everything buyer-facing renders from `record.facts` (PhoneFacts).
struct ShareMenu: View {
    let record: HistoryRecord
    @EnvironmentObject var state: AppState
    @AppStorage("receiptMaskIMEI") var maskIMEI = false
    @State private var message: String?

    var body: some View {
        FlexRow {
            Menu("Share") {
                #if os(macOS)
                Button("Save listing photo…") { savePhoto() }
                #endif
                Button("Copy listing text") {
                    let t = record.listingText(location: state.location)
                    copyToPasteboard(t.title + "\n\n" + t.description); message = "Listing text copied."
                }
                Button("Print receipt…") { ReceiptPrinter.print(record, maskIMEI: maskIMEI) }
                Divider()
                Toggle("Hide IMEI/serial", isOn: $maskIMEI)
            }.fixedSize()
            #if os(iOS)
            ShareLink(item: ListingPhotoExport(record: record, maskIMEI: maskIMEI), preview: SharePreview("Listing photo #\(record.id)")) {
                Label("Listing photo", systemImage: "photo")
            }
            ShareLink(item: ReceiptExport(record: record, maskIMEI: maskIMEI), preview: SharePreview("QR receipt #\(record.id)")) {
                Label("QR receipt", systemImage: "qrcode")
            }
            #endif
            if let m = message { Text(m).font(.caption).foregroundStyle(.secondary) }
        }
    }

    #if os(macOS)
    func savePhoto() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.png]; p.nameFieldStringValue = "phonegrader-\(record.id).png"
        guard p.runModal() == .OK, let u = p.url else { return }
        do {
            guard let d = ListingPhoto.png(record, maskIMEI: maskIMEI) else { message = "Couldn't render the photo"; return }
            try d.write(to: u); message = "Saved \(u.lastPathComponent)"
        } catch { message = error.localizedDescription }
    }
    #endif
}

/// Clean square listing photo (1080×1080): big facts, small facts-only QR in the corner.
/// No letter grade, no prices of any kind.
struct ListingPhoto: View {
    let facts: PhoneFacts
    let qr: CGImage?
    let maskIMEI: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 26) {
                Text(facts.model).font(.system(size: 78, weight: .heavy, design: .rounded)).lineLimit(2).minimumScaleFactor(0.6)
                Text([facts.storageText, facts.unlocked ? "Unlocked" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 52, weight: .bold, design: .rounded)).foregroundStyle(Color(red: 0.1, green: 0.45, blue: 0.85))
                Rectangle().fill(Color.black.opacity(0.12)).frame(height: 3)
                ForEach(rows, id: \.self) { r in
                    Text(r).font(.system(size: 40, weight: .semibold, design: .rounded)).lineLimit(2).minimumScaleFactor(0.7)
                        .foregroundStyle(r.hasPrefix("⚠️") ? Color(red: 0.75, green: 0.35, blue: 0) : .black)
                }
                Spacer(minLength: 0)
            }
            .padding(72).frame(width: 1080, height: 1080, alignment: .topLeading)
            if let qr {
                Image(decorative: qr, scale: 1).interpolation(.none).resizable().frame(width: 170, height: 170).padding(44)
            }
        }
        .frame(width: 1080, height: 1080).background(Color.white).foregroundStyle(.black)
    }

    var rows: [String] {
        var r = facts.lines(emoji: true).filter { !$0.contains("Carrier lock not checked") && !($0.contains("Unlocked") && facts.unlocked) }
        if !maskIMEI, let m = facts.imei { r.append("🔢 IMEI \(m)") }
        return r
    }

    @MainActor static func png(_ record: HistoryRecord, maskIMEI: Bool) -> Data? {
        let f = record.facts
        let view = ListingPhoto(facts: f, qr: ReceiptQR.image(f.qrText(recordId: record.id, maskIMEI: maskIMEI), scale: 6), maskIMEI: maskIMEI)
        let r = ImageRenderer(content: view); r.scale = 1
        guard let cg = r.cgImage else { return nil }
        return PlatformImaging.png(cg)
    }
}

/// Printed receipt: the full QR receipt text (grade + checklist + SICKW; never Atlas prices or profit).
enum ReceiptPrinter {
    @MainActor static func content(_ record: HistoryRecord, maskIMEI: Bool) -> some View {
        let text = Receipt.text(record.receiptInput, ReceiptOptions(maskIMEI: maskIMEI, includeListingPrice: true))
        return VStack(alignment: .leading, spacing: 12) {
            if let cg = ReceiptQR.image(text, scale: 4) {
                Image(decorative: cg, scale: 1).interpolation(.none).resizable().frame(width: 220, height: 220)
            }
            Text(text).font(.system(size: 9, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(width: 520, alignment: .topLeading).background(Color.white).foregroundStyle(.black)
    }

    /// Receipt as a PNG (iOS share sheet / print).
    @MainActor static func png(_ record: HistoryRecord, maskIMEI: Bool) -> Data? {
        let r = ImageRenderer(content: content(record, maskIMEI: maskIMEI)); r.scale = 3
        return r.cgImage.flatMap(PlatformImaging.png)
    }

    #if os(iOS)
    @MainActor static func print(_ record: HistoryRecord, maskIMEI: Bool) {
        guard let d = png(record, maskIMEI: maskIMEI), let img = UIImage(data: d) else { return }
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .grayscale; info.jobName = "PhoneGrader receipt #\(record.id)"
        let c = UIPrintInteractionController.shared
        c.printInfo = info; c.printingItem = img
        c.present(animated: true)
    }
    #else
    @MainActor static func print(_ record: HistoryRecord, maskIMEI: Bool) {
        let content = ReceiptPrinter.content(record, maskIMEI: maskIMEI)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit; info.verticalPagination = .automatic
        let op = NSPrintOperation(view: host, printInfo: info)
        op.jobTitle = "PhoneGrader receipt #\(record.id)"
        op.runModal(for: NSApp.keyWindow ?? NSWindow(), delegate: nil, didRun: nil, contextInfo: nil)
    }
    #endif
}

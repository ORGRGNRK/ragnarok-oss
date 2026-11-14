import AppIntents
import SwiftUI
import WidgetKit

/// Ragnarok's tiles for the Mac's Control Center (and menu bar). Built into Ragnarok.app by make-app.sh.
/// OpenIntent runs the shared action in Ragnarok, with authentication still required to unlock.
@main
struct RagnarokControls: WidgetBundle {
    var body: some Widget {
        OpenRagnarokControl()
        LockRagnarokControl()
    }
}

struct OpenRagnarokControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "co.rgnrk.heimdall.open") {
            ControlWidgetButton(action: RagnarokControlIntent(target: .main)) {
                Label("Ragnarok", image: "RagnarokMark")   // custom symbol: Assets.xcassets/RagnarokMark.symbolset
            }
        }
        .displayName("Open Ragnarok")
        .description("Open Ragnarok.")
    }
}

struct LockRagnarokControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "co.rgnrk.heimdall.lock") {
            ControlWidgetButton(action: RagnarokControlIntent(target: .locked)) {
                Label("Lock Ragnarok", systemImage: "lock.fill")
            }
        }
        .displayName("Lock Ragnarok")
        .description("Lock Ragnarok now.")
    }
}

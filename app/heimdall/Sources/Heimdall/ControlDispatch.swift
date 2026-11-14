import Foundation

/// Only these two compiled actions are exposed to Control Center. No unlock or arbitrary commands.
@MainActor
enum RagnarokControlDispatch {
    enum Action { case open, lock }

    static func perform(_ action: Action) {
        apply(action, lock: { Gate.shared.lock("Control Center") }, show: { AppDelegate.showMain() })
    }

    /// Lock before showing a window, including when no main window currently exists.
    static func apply(_ action: Action, lock: () -> Void, show: () -> Void) {
        if action == .lock { lock() }
        show()
    }
}

// macOS only: the Mac entry point (app or --cli). The iOS entry point is PhoneGraderiOSApp in IOSSupport.swift.
#if os(macOS)
import Foundation
import SwiftUI

/// One binary, two faces: `PhoneGrader` opens the app; `PhoneGrader --cli …`
/// (the `pgctl` wrapper) runs the same code headless. Same bundle, same
/// settings, same Keychain items, same history.json.
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        guard args.count > 1, args[1] == "--cli" else { PhoneGraderApp.main(); return }
        AppState.headless = true
        Task { @MainActor in
            let code = await CLI(Array(args.dropFirst(2))).run()
            exit(code)
        }
        dispatchMain()
    }
}
#endif

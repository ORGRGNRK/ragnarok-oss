import AppKit
import SwiftTerm
import SwiftUI

/// The Shell tab's screen: a real terminal (SwiftTerm) drawing the ShellSession's pseudo-terminal.
/// ShellSession still owns zsh, the command log and the transcript; this view only draws bytes and sends keys back,
/// so menus (gh auth login), arrow keys, progress bars, vim, top and less work like in Terminal.
struct ShellTerminal: NSViewRepresentable {
    @ObservedObject var shell: ShellSession

    func makeCoordinator() -> Coordinator { Coordinator(shell: shell) }

    func makeNSView(context: Context) -> HeimdallTerminalView {
        let v = HeimdallTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        v.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        v.session = shell
        v.processDelegate = context.coordinator
        v.optionAsMetaKey = false   // Option types characters (macOS default), like Terminal.app out of the box
        if !shell.replay.isEmpty { v.feed(byteArray: shell.replay[...]) }   // screen so far (after a tab switch)
        shell.rawSink = { [weak v] bytes in v?.feed(byteArray: bytes) }
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ v: HeimdallTerminalView, context: Context) {}

    static func dismantleNSView(_ v: HeimdallTerminalView, coordinator: Coordinator) {
        coordinator.shell.rawSink = nil
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let shell: ShellSession
        init(shell: ShellSession) { self.shell = shell }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { shell.resize(cols: newCols, rows: newRows) }
        }
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {}
    }
}

/// SwiftTerm's local-process view with its own process never started: keystrokes go to Heimdall's ShellSession instead.
final class HeimdallTerminalView: LocalProcessTerminalView {
    weak var session: ShellSession?

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { session?.sendRaw(data) }
    }
}

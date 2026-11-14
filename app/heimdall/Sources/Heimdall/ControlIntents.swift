import AppIntents

/// Shared by the app and its controls extension. OpenIntent is the supported way
/// for a control to enter the app process; OpenURLIntent only accepts universal links.
enum RagnarokControlDestination: String, AppEnum {
    case main
    case locked

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Ragnarok destination")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .main: "Ragnarok", .locked: "Locked Ragnarok"
    ]
}

struct RagnarokControlIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Ragnarok"
    static let description = IntentDescription("Open Ragnarok, optionally locking it first. Unlocking still requires authentication.")
    @Parameter(title: "Destination") var target: RagnarokControlDestination

    init() {}
    init(target: RagnarokControlDestination) { self.target = target }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if RAGNAROK_CONTROLS_EXTENSION
        // OpenIntent must be routed to the containing app. Fail visibly if the
        // system ever runs this extension implementation instead of reporting success.
        try requireContainingApp()
        #else
        RagnarokControlDispatch.perform(target == .locked ? .lock : .open)
        #endif
        return .result()
    }
}

private func requireContainingApp() throws { throw ControlIntentError.appRequired }

private enum ControlIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appRequired
    var localizedStringResource: LocalizedStringResource {
        "Ragnarok could not receive the control action. Open Ragnarok and try again."
    }
}

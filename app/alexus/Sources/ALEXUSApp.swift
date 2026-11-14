import SwiftUI
@main struct ALEXUSApp: App {
    @StateObject private var model=AppModel()
    var body: some Scene {
        WindowGroup { RootView().environmentObject(model).preferredColorScheme(.dark) }
        #if os(macOS)
        .defaultSize(width:1120,height:780)
        #endif
    }
}

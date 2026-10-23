import SwiftUI

@main
struct MarginediOSApp: App {
    @State private var playback = MobilePlaybackOwner()
    var body: some Scene {
        WindowGroup { MobileRootView(playback: playback) }
    }
}

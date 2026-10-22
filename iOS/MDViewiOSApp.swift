import SwiftUI

@main
struct MDViewiOSApp: App {
    @State private var playback = MobilePlaybackOwner()
    var body: some Scene {
        WindowGroup { MobileRootView(playback: playback) }
    }
}

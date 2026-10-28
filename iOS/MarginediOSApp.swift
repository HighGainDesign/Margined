import SwiftUI

@main
struct MarginediOSApp: App {
    @State private var playback = MobilePlaybackOwner()
    @State private var imageFolders = MobileImageFolders()
    var body: some Scene {
        WindowGroup { MobileRootView(playback: playback, imageFolders: imageFolders) }
    }
}

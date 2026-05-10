import SwiftUI

@main
struct CloudGalleryApp: App {
    @StateObject private var store = GalleryStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}

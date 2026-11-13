import SwiftUI

@main
struct BPCNewsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = FeedStore.shared

    var body: some Scene {
        WindowGroup {
            FeedView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}

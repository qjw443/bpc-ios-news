import SwiftUI

@main
struct BPCNewsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = FeedStore.shared
    @StateObject private var push = PushManager.shared

    var body: some Scene {
        WindowGroup {
            FeedView()
                .environmentObject(store)
                .environmentObject(push)
                .preferredColorScheme(nil)
        }
    }
}

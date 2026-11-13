import SwiftUI

@main
struct BPCNewsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = FeedStore.shared

    var body: some Scene {
        WindowGroup {
            TabView {
                FeedView()
                    .environmentObject(store)
                    .tabItem { Label("新闻", systemImage: "newspaper.fill") }
                MacroView()
                    .tabItem { Label("宏观", systemImage: "chart.xyaxis.line") }
            }
            .tint(Theme.orange)
            .preferredColorScheme(.dark)
        }
    }
}

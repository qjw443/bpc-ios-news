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
                PolyView()
                    .tabItem { Label("预测", systemImage: "chart.bar.xaxis") }
                ResearchView()
                    .tabItem { Label("研报", systemImage: "doc.text.magnifyingglass") }
            }
            .tint(Theme.orange)
            .preferredColorScheme(.dark)
        }
    }
}

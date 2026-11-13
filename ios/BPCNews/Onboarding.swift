import SwiftUI

/// 首次启动引导：把「源 / 本机去墙 / 中文 / 后台限制」一次讲清楚，
/// 避免用户以为「没通知 = App 坏了」。
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboarded") private var onboarded = false

    private let rows: [(String, String, String)] = [
        ("newspaper", "直接来自彭博与路透",
         "发现层只连两家自己的官方接口：彭博 sitemap + 6 个栏目 RSS；路透官方 sitemap，被挑战时用 App 内浏览器打开栏目页抓取。"),
        ("shield.lefthalf.filled", "在手机本机解除付费墙",
         "拦截付费墙脚本、去掉模糊与订阅浮层、清掉计量计数，全部在你的 iPhone 上完成，没有第三方服务器。"),
        ("character.book.closed", "中文优先",
         "默认用 Apple 端上翻译（iOS 18+）整句译；低版本或没下载语言包时用内置财经词典兜底。"),
        ("bell.badge", "关于后台通知（重要）",
         "iOS 不允许普通 App 常驻后台。App 前台每 60 秒一轮；退到后台由系统调度（通常 15–60 分钟一次）。想更快就回到前台，或打开 App 立即补推。"),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("彭博与路透新闻")
                                .font(.system(size: 26, weight: .heavy))
                                .tracking(1.5)
                                .foregroundColor(Theme.ink)
                            Kicker(text: "本机直连 · 无服务器 · 自签版", color: Theme.orange, size: 9)
                        }
                        .padding(.top, 10)

                        ForEach(rows, id: \.1) { row in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: row.0)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(Theme.orange)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.1)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(Theme.ink)
                                    Text(row.2)
                                        .font(.system(size: 12))
                                        .foregroundColor(Theme.inkDim)
                                        .lineSpacing(4)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Hairline()
                        }

                        Button {
                            onboarded = true
                            dismiss()
                        } label: {
                            Text("开始使用")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Theme.bg)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(Theme.ink)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .padding(.top, 6)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }
}

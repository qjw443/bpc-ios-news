import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = FeedStore.shared

    @AppStorage("src_bloomberg") private var srcBloomberg: Bool = true
    @AppStorage("src_reuters") private var srcReuters: Bool = true
    @AppStorage("auto_fetch") private var autoFetch: Bool = true
    @AppStorage("fresh_hours") private var freshHours: Int = 24
    @AppStorage("auto_monitor") private var autoMonitor: Bool = true
    @AppStorage("poll_seconds") private var pollSeconds: Int = 30
    @AppStorage("keep_alive") private var keepAlive: Bool = true
    @AppStorage("translate_on_open") private var translateOnOpen: Bool = false
    @AppStorage("zh_mode") private var zhMode: String = "dict"
    @AppStorage("llm_url") private var llmURL: String = "https://api.deepseek.com/chat/completions"
    @AppStorage("llm_model") private var llmModel: String = "deepseek-chat"
    @AppStorage("llm_key") private var llmKey: String = ""

    @State private var message = ""
    @State private var busy = false
    @State private var rulesCount = 0
    @State private var notifStatus = "…"

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                Form {
                    sourceSection
                    sourceStatusSection
                    fetchSection
                    notifSection
                    translateSection
                    diagSection
                    dataSection
                    aboutSection
                }
                .scrollContentBackground(.hidden)
                .background(Theme.bg)
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }.foregroundColor(Theme.ink)
                }
            }
            .onAppear {
                rulesCount = PaywallEngine.shared.compiledCount
                // 首次进入时把「中文模式」落盘，保证 Picker 与 Settings 判定一致
                if UserDefaults.standard.string(forKey: "zh_mode") == nil {
                    zhMode = Settings.zhMode
                }
                loadNotifStatus()
            }
            .onChange(of: keepAlive) { on in
                if on { SilentKeeper.start() } else { SilentKeeper.stop() }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func loadNotifStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let text: String
            switch s.authorizationStatus {
            case .authorized, .provisional, .ephemeral: text = "已开启"
            case .denied: text = "已关闭（去系统设置）"
            case .notDetermined: text = "未请求"
            @unknown default: text = "未知"
            }
            DispatchQueue.main.async { notifStatus = text }
        }
    }

    private var notifSection: some View {
        Section {
            LabeledContent("通知权限") {
                Button {
                    if let u = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(u)
                    }
                } label: {
                    Text(notifStatus)
                        .font(.system(size: 11))
                        .foregroundColor(notifStatus == "已开启" ? Theme.inkDim : Theme.orange)
                }
            }
            LabeledContent("前台轮询") {
                Text("每 \(pollSeconds) 秒").font(.mono(11)).foregroundColor(Theme.inkDim)
            }
            LabeledContent("后台刷新") {
                Text("系统调度（15–60 分钟）").font(.system(size: 11)).foregroundColor(Theme.inkDim)
            }
            Button {
                AppDelegate.sendTestNotification()
                message = "已排入一条测试通知（2 秒后）"
            } label: {
                HStack {
                    Text("发送测试通知").foregroundColor(Theme.orange)
                    Spacer()
                    Image(systemName: "bell.badge").font(.system(size: 12)).foregroundColor(Theme.orange)
                }
            }
            Toggle(isOn: $keepAlive) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("后台保活（更强）").foregroundColor(Theme.ink)
                    Text("播放静音音频以争取后台运行时间，耗电")
                        .font(.system(size: 10)).foregroundColor(Theme.inkDim)
                }
            }.tint(Theme.orange)
        } header: {
            Kicker(text: "通知").padding(.bottom, 2)
        } footer: {
            Text("普通模式下 iOS 只允许系统按电量/使用习惯调度后台任务。打开「后台保活」后，App 用静音音频维持后台运行，定时器继续按设定间隔抓取并本地通知（更及时，但更耗电）。")
                .font(.system(size: 10)).foregroundColor(Theme.inkDim)
        }
        .listRowBackground(Theme.surface)
    }

    private var sourceSection: some View {
        Section {
            Toggle(isOn: $srcBloomberg) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("彭博 Bloomberg").foregroundColor(Theme.ink)
                    Text("拦 bwbx.io fence 脚本 + 清计量 cookie")
                        .font(.system(size: 10)).foregroundColor(Theme.inkDim)
                }
            }.tint(Theme.orange)

            Toggle(isOn: $srcReuters) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("路透 Reuters").foregroundColor(Theme.ink)
                    Text("拦 arc/subs 订阅脚本 + 清 cookie")
                        .font(.system(size: 10)).foregroundColor(Theme.inkDim)
                }
            }.tint(Theme.orange)
        } header: {
            Kicker(text: "信源").padding(.bottom, 2)
        } footer: {
            Text("改动后下拉刷新生效。")
                .font(.system(size: 10)).foregroundColor(Theme.inkDim)
        }
        .listRowBackground(Theme.surface)
    }

    private var sourceStatusSection: some View {
        Section {
            if store.sourceStatuses.isEmpty {
                Text("还没有抓过。下拉刷新后这里会列出每个源的结果。")
                    .font(.system(size: 11)).foregroundColor(Theme.inkDim)
            }
            ForEach(store.sourceStatuses) { s in
                HStack(spacing: 8) {
                    Text(s.name)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.ink)
                        .lineLimit(1)
                    Spacer()
                    Text(s.ok ? "\(s.count) 条" : s.note)
                        .font(.mono(10))
                        .foregroundColor(s.ok ? Theme.inkDim
                                              : Color(red: 1, green: 0.45, blue: 0.30))
                }
            }
        } header: {
            Kicker(text: "发现源 · 官方接口").padding(.bottom, 2)
        } footer: {
            Text("彭博：sitemap/news/latest.xml + 6 个官方 RSS。路透：官方 news-sitemap；若被边缘反爬挑战（401），自动改用 App 内浏览器打开栏目页抽链接。")
                .font(.system(size: 10)).foregroundColor(Theme.inkDim)
        }
        .listRowBackground(Theme.surface)
    }

    private var fetchSection: some View {
        Section {
            Toggle(isOn: $autoMonitor) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动监控").foregroundColor(Theme.ink)
                    Text("前台定时轮询 · 回前台即刷 · 网络恢复即刷")
                        .font(.system(size: 10)).foregroundColor(Theme.inkDim)
                }
            }.tint(Theme.orange)
            Picker(selection: $pollSeconds) {
                Text("15 秒（极速）").tag(15)
                Text("30 秒").tag(30)
                Text("60 秒").tag(60)
                Text("2 分钟").tag(120)
            } label: {
                Text("轮询间隔").foregroundColor(Theme.ink)
            }
            LabeledContent("上次检查") {
                Text(store.lastCheckText).font(.mono(11)).foregroundColor(Theme.inkDim)
            }
            Button {
                store.refresh(notify: false)
                message = "已触发一轮发现"
            } label: {
                Text("立即抓一轮标题").foregroundColor(Theme.orange)
            }
            LabeledContent("最近状态") {
                Text(store.status.isEmpty ? "—" : store.status)
                    .font(.system(size: 11)).foregroundColor(Theme.inkDim)
            }
            LabeledContent("待读条数") {
                Text("\(store.pendingCount) 条").font(.mono(11)).foregroundColor(Theme.inkDim)
            }
            Picker(selection: $freshHours) {
                Text("最近 6 小时").tag(6)
                Text("最近 12 小时").tag(12)
                Text("最近 24 小时").tag(24)
                Text("最近 48 小时").tag(48)
            } label: {
                Text("时间窗").foregroundColor(Theme.ink)
            }
        } header: {
            Kicker(text: "发现").padding(.bottom, 2)
        } footer: {
            Text("这里只拉标题流（彭博 sitemap/RSS + 路透官方源）。时间窗会把站点带出的旧闻截掉；正文只在你点开某一条时才在本机抓取。")
                .font(.system(size: 10)).foregroundColor(Theme.inkDim)
        }
        .listRowBackground(Theme.surface)
    }

    private var translateSection: some View {
        Section {
            Picker(selection: $zhMode) {
                Text("系统端上翻译 · 离线").tag("sys")
                Text("离线词典 · 术语替换").tag("dict")
                Text("大模型整句翻译").tag("llm")
                Text("只看原文").tag("off")
            } label: {
                Text("中文模式").foregroundColor(Theme.ink)
            }
            TextField("https://api.deepseek.com/chat/completions", text: $llmURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.URL)
                .foregroundColor(Theme.ink)
            TextField("deepseek-chat", text: $llmModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .foregroundColor(Theme.ink)
            SecureField("LLM API Key（仅大模型模式需要）", text: $llmKey)
                .foregroundColor(Theme.ink)
            Toggle(isOn: $translateOnOpen) {
                Text("打开文章即翻译").foregroundColor(Theme.ink)
            }.tint(Theme.orange)
        } header: {
            Kicker(text: "中文").padding(.bottom, 2)
        } footer: {
            Text("「系统端上翻译」= Apple 内置模型（iOS 18+），首次会弹语言包下载，之后完全离线、不需要 Key。低版本自动回落到词典（\(Dict.entryCount) 条术语替换）。")
                .font(.system(size: 10)).foregroundColor(Theme.inkDim)
        }
        .listRowBackground(Theme.surface)
    }

    private var diagSection: some View {
        Section {
            Button {
                UIPasteboard.general.string = Diagnostics.shared.report
                message = "诊断报告已复制，直接贴给我"
            } label: {
                Text("复制诊断报告").foregroundColor(Theme.orange)
            }
            Button {
                Diagnostics.shared.clear()
                message = "诊断记录已清空"
            } label: {
                Text("清空诊断记录").foregroundColor(Theme.inkDim)
            }
            if let last = Diagnostics.shared.entries.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(last.site) · \(last.ok ? "成功" : "失败") · \(last.via) · \(last.blocks) 段 · \(last.ms)ms")
                        .font(.mono(10)).foregroundColor(Theme.inkDim)
                    if !last.walls.isEmpty {
                        Text("残留遮罩：" + last.walls.joined(separator: " / "))
                            .font(.system(size: 10))
                            .foregroundColor(Color(red: 1, green: 0.55, blue: 0.2))
                    }
                }
            }
        } header: {
            Kicker(text: "诊断（真机排障用）").padding(.bottom, 2)
        } footer: {
            Text("每次抓取都会记录命中的提取策略、段数、耗时与残留遮罩。哪篇没绕过去，复制报告发我即可精准定位。")
                .font(.system(size: 10)).foregroundColor(Theme.inkDim)
        }
        .listRowBackground(Theme.surface)
    }

    private var dataSection: some View {
        Section {
            Button {
                busy = true
                PaywallEngine.shared.wipeAllCookies {
                    busy = false
                    message = "已清除 Cookie 与网站数据"
                }
            } label: {
                HStack {
                    Text("清除 Cookie / 网站数据").foregroundColor(Theme.orange)
                    if busy { Spacer(); ProgressView().tint(Theme.orange) }
                }
            }
            .disabled(busy)

            Button {
                Library.shared.removeAll()
                store.items = []
                message = "本地文章已清空"
            } label: {
                Text("清空本地文章").foregroundColor(Color(red: 1, green: 0.36, blue: 0.32))
            }
        } header: {
            Kicker(text: "数据").padding(.bottom, 2)
        } footer: {
            if !message.isEmpty {
                Text(message).font(.system(size: 10)).foregroundColor(Theme.inkDim)
            }
        }
        .listRowBackground(Theme.surface)
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("版本") {
                Text(Settings.appVersion).font(.mono(11)).foregroundColor(Theme.inkDim)
            }
            LabeledContent("拦截规则") {
                Text("\(rulesCount) / 2 站点").font(.mono(11)).foregroundColor(Theme.inkDim)
            }
            LabeledContent("离线词条") {
                Text("\(Dict.entryCount)").font(.mono(11)).foregroundColor(Theme.inkDim)
            }
            LabeledContent("运行方式") {
                Text("App 内置 · 无服务器").font(.system(size: 11)).foregroundColor(Theme.inkDim)
            }
        } header: {
            Kicker(text: "关于").padding(.bottom, 2)
        }
        .listRowBackground(Theme.surface)
    }
}

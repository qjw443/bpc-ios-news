import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = FeedStore.shared

    @AppStorage("src_bloomberg") private var srcBloomberg: Bool = true
    @AppStorage("src_reuters") private var srcReuters: Bool = true
    @AppStorage("auto_fetch") private var autoFetch: Bool = true
    @AppStorage("translate_on_open") private var translateOnOpen: Bool = false
    @AppStorage("llm_url") private var llmURL: String = "https://api.deepseek.com/chat/completions"
    @AppStorage("llm_model") private var llmModel: String = "deepseek-chat"
    @AppStorage("llm_key") private var llmKey: String = ""

    @State private var message = ""
    @State private var busy = false
    @State private var rulesCount = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                Form {
                    sourceSection
                    fetchSection
                    translateSection
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
            .onAppear { rulesCount = PaywallEngine.shared.compiledCount }
        }
        .preferredColorScheme(.dark)
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

    private var fetchSection: some View {
        Section {
            Toggle(isOn: $autoFetch) {
                Text("自动预热正文").foregroundColor(Theme.ink)
            }.tint(Theme.orange)
            Button {
                store.refresh(notify: false)
                message = "已触发一轮发现"
            } label: {
                Text("立即抓一轮").foregroundColor(Theme.orange)
            }
            LabeledContent("最近状态") {
                Text(store.status.isEmpty ? "—" : store.status)
                    .font(.system(size: 11)).foregroundColor(Theme.inkDim)
            }
            LabeledContent("待取正文") {
                Text("\(store.pendingCount) 条").font(.mono(11)).foregroundColor(Theme.inkDim)
            }
        } header: {
            Kicker(text: "抓取").padding(.bottom, 2)
        } footer: {
            Text("发现走 Google News RSS（分钟级）。iOS 后台刷新由系统调度，通常 15–60 分钟一次；App 在前台时每 60 秒一轮。")
                .font(.system(size: 10)).foregroundColor(Theme.inkDim)
        }
        .listRowBackground(Theme.surface)
    }

    private var translateSection: some View {
        Section {
            TextField("https://api.deepseek.com/chat/completions", text: $llmURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.URL)
                .foregroundColor(Theme.ink)
            TextField("deepseek-chat", text: $llmModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .foregroundColor(Theme.ink)
            SecureField("LLM API Key（留空则不显示翻译）", text: $llmKey)
                .foregroundColor(Theme.ink)
            Toggle(isOn: $translateOnOpen) {
                Text("打开文章即翻译").foregroundColor(Theme.ink)
            }.tint(Theme.orange)
        } header: {
            Kicker(text: "翻译（可选）").padding(.bottom, 2)
        } footer: {
            Text("填 Key 后阅读页底部出现「译成中文」，段落 1:1 对齐；不填也能读原文。")
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
            LabeledContent("运行方式") {
                Text("App 内置 · 无服务器").font(.system(size: 11)).foregroundColor(Theme.inkDim)
            }
        } header: {
            Kicker(text: "关于").padding(.bottom, 2)
        }
        .listRowBackground(Theme.surface)
    }
}

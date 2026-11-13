import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var push: PushManager

    @AppStorage("api_base") private var base: String = Settings.defaultBase
    @AppStorage("api_token") private var token: String = ""
    @AppStorage("apns_env") private var apnsEnv: String = ""
    @AppStorage("src_bloomberg") private var srcBloomberg: Bool = true
    @AppStorage("src_reuters") private var srcReuters: Bool = true
    @AppStorage("quiet_from") private var quietFrom: Int = 0
    @AppStorage("quiet_to") private var quietTo: Int = 0

    @State private var message: String = ""
    @State private var busy: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                Form {
                    serverSection
                    sourceSection
                    pushSection
                    quietSection
                    actionSection
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
                    Button("关闭") { dismiss() }
                        .foregroundColor(Theme.ink)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var serverSection: some View {
        Section {
            TextField("https://news.example.com", text: $base)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.URL)
                .foregroundColor(Theme.ink)
            SecureField("API Token", text: $token)
                .foregroundColor(Theme.ink)
            Button {
                Task { await testConnection() }
            } label: {
                HStack {
                    Text("测试连接").foregroundColor(Theme.orange)
                    if busy { Spacer(); ProgressView().tint(Theme.orange) }
                }
            }
            .disabled(busy)
        } header: {
            Kicker(text: "服务器").padding(.bottom, 2)
        } footer: {
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.inkDim)
            }
        }
        .listRowBackground(Theme.surface)
    }

    private var sourceSection: some View {
        Section {
            Toggle(isOn: $srcBloomberg) {
                Text("彭博 Bloomberg").foregroundColor(Theme.ink)
            }
            .tint(Theme.orange)
            Toggle(isOn: $srcReuters) {
                Text("路透 Reuters").foregroundColor(Theme.ink)
            }
            .tint(Theme.orange)
        } header: {
            Kicker(text: "信源").padding(.bottom, 2)
        }
        .listRowBackground(Theme.surface)
    }

    private var pushSection: some View {
        Section {
            Picker(selection: $apnsEnv) {
                Text("自动").tag("")
                Text("sandbox（开发证书）").tag("sandbox")
                Text("production（发布证书）").tag("production")
            } label: {
                Text("APNs 环境").foregroundColor(Theme.ink)
            }
            LabeledContent("注册状态") {
                Text(push.status)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.inkDim)
            }
            LabeledContent("Token") {
                Text(push.token.isEmpty ? "—" : String(push.token.prefix(12)) + "…")
                    .font(.mono(11))
                    .foregroundColor(Theme.inkDim)
            }
            Button {
                Task { await testPush() }
            } label: {
                Text("发送测试推送").foregroundColor(Theme.orange)
            }
            .disabled(busy || push.token.isEmpty)
        } header: {
            Kicker(text: "推送").padding(.bottom, 2)
        } footer: {
            Text("自签一般用开发描述文件 → sandbox。若证书不含 Push 权限，App 自动降级为「前台 60s 轮询 + 本地通知」。当前上报：\(Settings.apnsEnv)")
                .font(.system(size: 10))
                .foregroundColor(Theme.inkDim)
        }
        .listRowBackground(Theme.surface)
    }

    private var quietSection: some View {
        Section {
            Stepper(value: $quietFrom, in: 0...23) {
                Text("静默开始　\(quietFrom):00").foregroundColor(Theme.ink)
            }
            Stepper(value: $quietTo, in: 0...23) {
                Text("静默结束　\(quietTo):00").foregroundColor(Theme.ink)
            }
        } header: {
            Kicker(text: "静默时段").padding(.bottom, 2)
        } footer: {
            Text("静默时段内新稿只入库不推送（服务端判定）。两端设为相同值即关闭。")
                .font(.system(size: 10))
                .foregroundColor(Theme.inkDim)
        }
        .listRowBackground(Theme.surface)
    }

    private var actionSection: some View {
        Section {
            Button {
                Task { await save() }
            } label: {
                HStack {
                    Text("保存并重新登记推送").foregroundColor(Theme.bg)
                    Spacer()
                    if busy { ProgressView().tint(Theme.bg) }
                }
                .font(.system(size: 14, weight: .semibold))
                .padding(.vertical, 4)
            }
            .listRowBackground(Theme.ink)
        }
    }

    // MARK: - 动作

    private func save() async {
        busy = true
        defer { busy = false }
        let t = push.token
        if !t.isEmpty { await push.upload(t) }
        message = "已保存"
        try? await Task.sleep(nanoseconds: 400_000_000)
        dismiss()
    }

    private func testConnection() async {
        busy = true
        message = ""
        defer { busy = false }
        struct Stats: Decodable {
            let articles: Int
            let devices: Int
        }
        do {
            let s: Stats = try await APIClient.get("/v1/stats", as: Stats.self)
            message = "连接正常 · 文章 \(s.articles) · 设备 \(s.devices)"
        } catch {
            message = "连接失败：" + error.localizedDescription
        }
    }

    private func testPush() async {
        busy = true
        defer { busy = false }
        do {
            let data = try await APIClient.post(
                "/v1/testpush?token=\(push.token)&env=\(Settings.apnsEnv)", json: [:])
            message = String(data: data, encoding: .utf8) ?? "已发送"
        } catch {
            message = "推送失败：" + error.localizedDescription
        }
    }
}

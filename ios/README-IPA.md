# 出 IPA + 自签（Windows 全流程）

> 目标：**拿到一个 unsigned IPA，然后用你自己的证书签成可安装包。**
> 本机是 Windows，没有 `swift` / `xcodebuild`，所以编译必须借 macOS。

---

## 0. 先改一个地方（唯一必改项）

`ios/project.yml`：

```yaml
settings:
  base:
    PRODUCT_BUNDLE_IDENTIFIER: com.yourname.bpcnews   # ← 改成你的
```

**规则**：这个 Bundle ID 必须能对应上你描述文件里的 App ID：
- 描述文件是 `ABCDE12345.*`（通配符）→ 随便填，签名脚本会自动对齐；
- 描述文件是 `ABCDE12345.com.yourname.bpcnews` → 必须一字不差。

> 为什么要固定：APNs device token 是「设备 + Bundle ID + 环境」三元组绑定的，改 ID 等于换了个 App，历史 token 全部作废。

---

## 1. 路线 A：一条命令（推荐，无需 Mac）

```powershell
cd E:\bpc-ios-news
gh auth login                                  # 只需一次
.\scripts\make_ipa.ps1 -RepoName bpc-ios-news -Public
```

脚本会自己走完：推码 → 触发 `build-unsigned-ipa` → `gh run watch` 等编译 →
下载 artifact → 校验 `Payload` / `Info.plist` / 可执行文件 → 打印 Bundle ID 与 IPA 路径
（默认落在 `E:\bpc-ios-news\dist\BPCNews-unsigned.ipa`）。

只想重编、不推码：`.\scripts\make_ipa.ps1 -Rebuild`。

## 2. 路线 B：有 Mac 就用三条命令

```bash
bash scripts/build_unsigned_ipa.sh
# 产物: ios/BPCNews-unsigned.ipa
```

---

## 3. 本机自签

### 3.1 先跑预检（强烈建议）

```powershell
.\scripts\sign_ipa_windows.ps1 `
  -Ipa .\BPCNews-unsigned.ipa `
  -P12 .\cert.p12 `
  -Provision .\dev.mobileprovision `
  -Password 你的p12密码
```

脚本会替你检查并打印：
- 描述文件里的 `application-identifier`（App ID / Team ID）
- 是否**通配符**
- **有效期**
- 是否**开发描述文件**（→ 推送只能是 sandbox）
- App 当前 Bundle ID 与描述文件是否匹配；不匹配就用 `plistlib` 改写 Info.plist，并同步 `BGTaskSchedulerPermittedIdentifiers`

### 3.2 签名（两条路）

**A) zsign（命令行，可脚本化）**

```powershell
.\scripts\sign_ipa_windows.ps1 `
  -Ipa .\BPCNews-unsigned.ipa -P12 .\cert.p12 `
  -Provision .\dev.mobileprovision -Password 123456 `
  -Zsign C:\tools\zsign.exe -Out .\BPCNews-signed.ipa
```

**B) Sideloadly（图形化，最省事，自动对齐 Bundle ID）**

1. iPhone 连线，打开 Sideloadly
2. IPA 选 `BPCNews-unsigned.ipa`
3. Apple ID 填你的开发者账号 → Advanced 里指定 p12 / 描述文件
4. Start，输入密码，等待完成

**C) 轻松签 / Esign（直接在 iPhone 上签）**：导入 p12 + mobileprovision，选 IPA 签名安装。

---

## 4. 装完之后

1. 首次启动 → 「设置」
2. 服务器地址填 `https://你的域名`
3. API Token 填服务端 `.env` 里的 `API_TOKEN`
4. **APNs 环境**：
   - 开发描述文件（`ProvisionedDevices` 存在）→ 选 `sandbox`
   - 发布描述文件 → 选 `production`
   - 不确定就留「自动」
5. 点「保存并重新登记推送」→ 看「注册状态」
6. 点「发送测试推送」，服务端返回 `{"status":200}` 即通

---

## 5. 证书与重签（重要）

| 场景 | 后果 | 处理 |
|---|---|---|
| 免费 7 天证书过期 | App 打不开 | **用同一个 Bundle ID 重签同一个 IPA**，重装即可；服务端数据不动 |
| 换了 Bundle ID | 变成另一个 App，推送 token 换新 | 重装后 App 会自动重新上报，服务端旧 token 收 410 自动清理 |
| 只换描述文件、ID 不变 | device token 通常复用 | 无需操作 |

**所以**：IPA 留着、p12+描述文件留着，7 天到期就是「重签 + 覆盖安装」两分钟的事。

---

## 6. 关于推送能不能用（先看这张表，别白忙）

| 你的账号/证书 | `aps-environment` | 结果 |
|---|---|---|
| 免费 Apple ID | 拿不到 | `registerForRemoteNotifications` 失败 → App 降级为 **轮询 + 本地通知** |
| 付费开发者 + App ID **未**勾 Push | 描述文件不含 | 同上 |
| 付费开发者 + App ID **勾了** Push + 对应描述文件 | 有 | **APNs 可用**（开发件走 sandbox） |

降级不影响功能：前台 60 秒轮询、退到后台靠 `BGAppRefreshTask`（系统给 15 分钟起，实际几分钟到几十分钟），拿到新文章就发**本地通知**，点击照样直达中文正文。只是「秒级」变「分钟级」。

---

## 7. 编译失败对照表

| 报错 | 原因 | 修 |
|---|---|---|
| `xcodegen: command not found` | CI 里 brew 没装上 | 重跑 workflow |
| `No such module 'BackgroundTasks'` | 平台写错 | `platform: iOS` 已在 project.yml 里 |
| `Signing for "BPCNews" requires a development team` | 忘了关签名 | 用本脚本/CI 的 `CODE_SIGNING_ALLOWED=NO` |
| `Multiple commands produce Info.plist` | 同时开了 `GENERATE_INFOPLIST_FILE` | project.yml 已设 `NO`，别改 |
| 装完闪退 | 描述文件不含该设备 UDID | 开发描述文件必须加你的 UDID |
| 打开就显示「服务器地址无效」 | 没填设置 | 设置页填域名（必须 HTTPS 公网证书） |

# BPC News · 彭博/路透 中文推送（iOS App + 服务端）

> 把 Chrome 版 **Bypass Paywalls Clean** 的绕过规则搬到服务端（Playwright），
> iOS App 只做三件事：**收推送、读中文、点原文**。

```
Google News RSS ──45s──► 去重入库 ──► BPC引擎(Playwright) ──► LLM翻译 ──► APNs ──► iPhone
                                        │
                              rules/bloomberg.yaml
                              rules/reuters.yaml
```

---

## 1. 目录

```
bpc-ios-news/
├─ server/                     # Python 3.11 + FastAPI + Playwright
│  ├─ app.py                   # 编排 + HTTP 接口
│  ├─ sources.py               # 采集（Google News RSS，实测可用）
│  ├─ bypass.py                # BPC 引擎（改头/掐脚本/清cookie/清DOM/取__NEXT_DATA__）
│  ├─ stealth.py               # 反检测：自洽指纹 / headless 抹除 / 代理 / 拦截识别
│  ├─ translate.py             # 分段 1:1 对齐翻译 + 术语表 + 缓存
│  ├─ push.py                  # APNs ES256(.p8) + sandbox/production 分流
│  ├─ store.py                 # SQLite(aiosqlite)
│  ├─ rules/*.yaml             # 站点规则（BPC 规则的 YAML 化）
│  └─ tools/smoke.py           # 离线自检
├─ ios/
│  ├─ project.yml              # XcodeGen 工程描述
│  ├─ BPCNews/*.swift          # SwiftUI App（8 个文件）
│  └─ README-IPA.md            # 出 IPA / 自签 详细步骤  ← 你要的
├─ .github/workflows/ios-unsigned.yml   # macOS runner 编 unsigned IPA
├─ scripts/
│  ├─ build_unsigned_ipa.sh    # macOS 本地出包
│  ├─ sign_ipa_windows.ps1     # Windows 自签（zsign / Sideloadly）
│  └─ push_to_github.ps1       # 一键推 GitHub 触发 CI
├─ docker-compose.yml / Caddyfile / .env.example
```

---

## 2. 服务端 3 步起

```bash
cp .env.example .env        # 填 API_TOKEN / APNS_* / LLM_KEY
mkdir -p secrets data && cp AuthKey_XXXX.p8 secrets/AuthKey.p8
docker compose up -d --build   # 首次会拉 Playwright 镜像，约 2GB
curl -s https://news.example.com/healthz
```

验证流水线（在有网的环境里）：

```bash
docker compose exec app python tools/smoke.py --rules
docker compose exec app python tools/smoke.py --url "https://www.bloomberg.com/news/articles/2026-11-13/xxxx"
curl -s -X POST "https://news.example.com/v1/scan" -H "Authorization: Bearer $API_TOKEN"
curl -s "https://news.example.com/v1/stats" -H "Authorization: Bearer $API_TOKEN"
```

`stats` 里 `avg_lag_seconds` 就是你的真实延迟，正常 60–600 秒。

**本机静态校验（无需 PyYAML / 无需联网）**：

```powershell
cd E:\bpc-ios-news
python server\tools\yamlcheck.py server\rules\bloomberg.yaml server\rules\reuters.yaml `
    ios\project.yml .github\workflows\ios-unsigned.yml docker-compose.yml
```

期望输出 `result: 5/5 passed`。它会抓制表符、缩进非 2 倍数、重复键、引号未闭合——
这些问题在 `yaml.safe_load` 时会直接让服务端起不来，所以先本地挡掉。

---

## 3. 出 IPA：一条命令

```powershell
cd E:\bpc-ios-news
gh auth login          # 只需一次
.\scripts\make_ipa.ps1 -RepoName bpc-ios-news -Public
```

自动完成：建仓/推码 → 触发 `build-unsigned-ipa` → 等 macOS runner 编译（5–8 分钟）
→ 下载 artifact → 校验 `Payload` 结构 + 读出 Bundle ID → 打印 IPA 路径。

产物：`E:\bpc-ios-news\dist\BPCNews-unsigned.ipa`（未签名，可直接拿去签）。

- 为什么未签名：zsign / Sideloadly / 轻松签 都需要一个没有 `_CodeSignature` 的干净包，
  自己注入 p12 与描述文件。脚本第 5 步会明确报告「确认为未签名」。
- 为什么借 macOS：Windows 上没有 Xcode / iPhoneOS SDK，arm64 的编译环节在
  GitHub 的 macOS runner 上完成，这一步已被脚本全自动串好。
- 有 Mac：`bash scripts/build_unsigned_ipa.sh` 等价。

## 3.5 反检测伪装（防被判定为爬虫）

只改 UA 等于自报家门。站点做的是**交叉校验**，任何一项自相矛盾就进挑战页。
本项目按「一整套自洽指纹」来做：

| 层 | 做法 | 文件 |
|---|---|---|
| 指纹一致性 | UA ↔ `sec-ch-ua` ↔ platform ↔ 视口 ↔ 时区 ↔ WebGL 同源；三档案 `win_desktop`/`mac_desktop`/`linux_desktop` | [server/stealth.py](server/stealth.py) |
| 发请求前自检 | `validate()` 抓「有 Referer 却声明 sec-fetch-site=none」「UA=Windows 但 platform=macOS」等矛盾，直接拒发 | 同上 |
| headless 抹除 | `navigator.webdriver`、plugins/mimeTypes、`window.chrome`、WebGL 厂商串、`Notification.permission`、`navigator.connection`、`Function.prototype.toString` 伪装 native、删 `__playwright` 痕迹 | `STEALTH_JS` |
| 双模式 | `browser`（真 Chrome 指纹）/ `bot`（Googlebot，**极简头、绝不带** UA-CH 与 Sec-Fetch）按顺序尝试，失败自动切换 | `rules/*.yaml → modes:` |
| 人味 | 贝塞尔鼠标轨迹、分段滚动（320–720px/次）、与篇幅相关的停顿、偶发回滚 | `human_read()` |
| 拦截识别 | 区分 Cloudflare / DataDome / HUMAN(PerimeterX) / Akamai / Arc 挑战 / 限流，命中即退避换模式 | `detect_block()` |
| 出口 IP | `PW_PROXY=http://user:pass@ip:port` 走住宅代理（数据中心 IP 是最大破绽） | 环境变量 |
| 暖 cookie | 需要「老访客」的站保留 `PW_USER_DATA_DIR` 下的持久化档案 | 环境变量 |

```bash
PW_PROFILE=win_desktop     # win_desktop | mac_desktop | linux_desktop
PW_CHANNEL=chrome          # 优先真实 Chrome，其次 chromium
PW_PROXY=http://u:p@1.2.3.4:8080
PW_USER_DATA_DIR=./data/profiles
```

**模式策略**：Bloomberg 先 `browser`（清 cookie 触发首访重置 + 掐 `bwbx.io` fence 脚本），
失手退 `bot`；Reuters 只用 `browser` 且保留 cookie（它认「老访客」，裸会话更容易吃 401）。

---

## 4. 核心逻辑（为什么这么设计）

### 4.1 处理状态机

```
RSS新条目 ──► pending ──fetch──► ──translate──► ──save──► ──push──► done
                  └──(异常)──► failed(reason)  ← 只标记本条，不阻塞其它
```

- **去重键** `sha1(normalize(url)|title)`：同一篇被多个源抓到只处理一次。
- **幂等**：`seen.key` 主键 + `articles.id` 主键 + `pushed(device,article_id)` 主键，重跑不会重复推送。
- **首发保护** `MAX_PUSH_AGE_SECONDS`(默认 3h)：一上线不会被历史文章刷屏。
- **重试**：LLM 3 次指数退避；抓取失败写 `failed` 并记原因，次日看 `reason` 就知道是改版还是被墙。

### 4.2 绕过逻辑（与 BPC 一一对应）

| BPC | 本项目 |
|---|---|
| `useragent: 'googlebot'` + `Referer` + `X-Forwarded-For` | `context(user_agent=..., extra_http_headers=...)` |
| `block_regex: /\.bwbx\.io\/s3\/fence\/.../ ` | `route.abort()` 正则命中 |
| `remove_cookies` | `clear_cookies()` + `localStorage.clear()` |
| `cs_code: rm_class/rm_elem` | `cleanup_js` + `inject_css` |
| `ld_json` / `__NEXT_DATA__` | `extract.kind: next_data` → Arcadia 节点转 blocks |
| `ld_archive_is` | 正文不足 3 段 → archive.ph 兜底 |

### 4.3 推送降级（自签必读）

| 你的证书 | APNs | App 行为 |
|---|---|---|
| 免费 Apple ID（7 天） | ❌ 无 Push 权限 | 自动切换：前台 60s 轮询 + 后台 15min 刷新 + **本地通知** |
| 付费账号 + 未开 Push 的 App ID | ❌ `didFailToRegister` | 同上 |
| 付费账号 + 已开 Push + 对应描述文件 | ✅ | 服务端 APNs 秒级推送，点击直达中文正文 |

App 会自动把结果写进「设置 → 推送 → 注册状态」，不会静默失败。

---

## 5. 排错速查

| 现象 | 原因 | 处理 |
|---|---|---|
| `401 unauthorized` | API_TOKEN 不一致 | 同步 `.env` 与 App 设置页 |
| feed 空但 stats 有文章 | App 里 `after` 太大 | 设置页下拉刷新（full=true） |
| `reason: blocks_short:0` | 站点改版/规则失效 | 改 `rules/*.yaml` 选择器后 `docker compose restart app` |
| `paywalled_residual: true` | 反爬升级 | 换 UA、开 `PROBE_FEEDS`、或加住宅代理 |
| APNs `403 InvalidProviderToken` | ES256 用了 DER 签名 | 本项目已用 `decode_dss_signature` 修正 |
| APNs `BadDeviceToken` | sandbox/production 选错 | 设置页改 APNs 环境后重新登记 |
| APNs `Unregistered` | 重装/换证书 | 服务端自动删 token，App 重启会重新上报 |
| 后台不刷新 | 低电量模式 / BGTask 被限流 | 属系统行为，前台轮询兜底 |

---

## 6. 成本

| 项 | 说明 |
|---|---|
| 服务器 | 1C2G VPS 即可（Playwright 单并发约占 350MB） |
| LLM | 约 200 篇/天 ≈ **¥1.5–4/天**（deepseek-chat） |
| APNs | 免费 |
| Apple 开发者 | $99/年（只有它能让 APNs 真正可用） |

# BPC News · App 内置付费墙绕过（iOS / 自签版）

> **全部在 iPhone 上完成，不需要服务器。**
> App 自己发现彭博/路透最新稿 → 自己在设备上解除付费墙取全文 → 原生渲染中文阅读。

---

## 1. 架构（v2：纯 App 内）

```
Google News RSS (site:bloomberg.com / site:reuters.com, when:2h)
        │ URLSession + XMLParser（设备本地）
        ▼
本地库（JSON 落盘，去重） ── 本地通知（新稿提醒）
        │
        ▼  点开文章
WKWebView（离屏）
   ├─ WKContentRuleList  按正则拦付费墙脚本   ← 替代扩展的 block_regex
   ├─ WKUserScript       去 articleBlur/订阅浮层/清 storage  ← 替代 cs_code
   ├─ customUserAgent    真 Chrome；失败退 Googlebot  ← 替代 modifyHeaders
   └─ nonPersistent 数据仓 → 每次全新会话 ≈ 清 cookie（重置计量墙）
        │
        ▼ evaluateJavaScript
__NEXT_DATA__ → props.pageProps.story.body.content（彭博 Arcadia）
DOM data-testid="paragraph-N"（路透）
        │
        ▼
原生 SwiftUI 阅读（黑底白字 / 衬线标题 / 中英对照）+ 可选 LLM 翻译
```

**为什么这套在 iOS 上成立**：`WKContentRuleList` 是 Safari 内容拦截规则，WKWebView 原生支持，
可以对子资源做正则拦截 —— 这正是 BPC 扩展 `declineNetRequest.block` 的等价物。
另外手机走的是**住宅 IP**，比 VPS 的数据中心 IP 更不容易被判爬虫。

---

## 2. 目录

```
E:\bpc-ios-news\
├─ ios/
│  ├─ BPCNews/                   14 个 Swift 文件
│  │  ├─ Rules.swift             站点规则：拦哪些 JS / 怎么清 DOM / 提取 JS
│  │  ├─ PaywallEngine.swift     规则编译 + 离屏 WKWebView 抓取器
│  │  ├─ Discovery.swift         RSS 发现 + 解析
│  │  ├─ Library.swift           本地模型与落盘
│  │  ├─ FeedStore.swift         编排：发现→入库→抓正文→通知
│  │  ├─ FeedView.swift          列表（黑底白字，Bloomberg 版式）
│  │  ├─ ReaderView.swift        原生阅读 + 译/原对照
│  │  ├─ WebReaderView.swift     兜底：带拦截规则的原始页面
│  │  ├─ Translate.swift         可选 LLM 翻译（段落 1:1）
│  │  └─ Theme.swift             设计 token
│  ├─ BPCNews.xcodeproj/         已生成，Xcode 可直接打开
│  └─ tools/                     工程生成与结构自检
├─ server/                       旧版服务端（v2 不再需要，留作参考）
├─ scripts/make_ipa.ps1          一条命令出 IPA
├─ scripts/sign_ipa_windows.ps1  Windows 自签
└─ scripts/verify_ipa.py         IPA 验真（解析 Mach-O 头）
```

---

## 3. 出 IPA

```powershell
cd E:\bpc-ios-news
gh auth login
.\scripts\make_ipa.ps1 -RepoName bpc-ios-news -Public
# 产物：dist\BPCNews-unsigned.ipa
python .\scripts\verify_ipa.py .\dist\BPCNews-unsigned.ipa
```

## 4. 用

1. 自签装到 iPhone（见 [ios/README-IPA.md](ios/README-IPA.md)）
2. 打开 App → 下拉刷新 → 看到彭博/路透最新稿
3. 点开 → App 内自动拦截付费墙脚本并提取全文
4. 设置里可开「自动预热正文」「打开即翻译」（需填 LLM Key）

---

## 5. 能力边界（工程事实）

| 项 | 现实 |
|---|---|
| 发现延迟 | Google News RSS 索引通常 1–10 分钟 |
| 前台刷新 | 60 秒一轮 |
| 后台刷新 | iOS 系统调度，通常 15–60 分钟（`BGAppRefreshTask` 上限，系统说了算） |
| 推送 | 无服务器 ⇒ 用本地通知；不依赖 APNs 证书 |
| 翻译 | 可选；不填 Key 就只读原文 |

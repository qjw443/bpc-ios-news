import SwiftUI
import UIKit

/// 系统分享面板：微信 / 朋友圈 会作为系统 Share Extension 出现在这里
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.excludedActivityTypes = [.assignToContact, .print, .addToReadingList, .postToFlickr]
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

enum ArticleShare {

    /// 分享内容：中文标题 + 英文原标题 + 前若干段正文 + 原文链接 + 首图
    /// 提供「文字 + 图片 + 链接」组合，微信里才能同时出现「发送给朋友」与「分享到朋友圈」
    static func items(for a: Article, showOriginal: Bool) -> [Any] {
        let zhTitle = a.titleZh.isEmpty ? a.title : a.titleZh
        var blocks: [String] = [zhTitle]
        if !a.titleZh.isEmpty, a.titleZh != a.title {
            blocks.append(a.title)
        }

        let bodyLines = a.blocks
            .filter { $0.type == "p" || $0.type == "h2" || $0.type == "quote" }
            .prefix(6)
            .map { b -> String in
                if showOriginal { return b.text }
                return b.zh.isEmpty ? b.text : b.zh
            }
            .filter { !$0.isEmpty }
        if !bodyLines.isEmpty {
            blocks.append(bodyLines.joined(separator: "\n\n"))
        }

        blocks.append("原文：" + a.url)
        blocks.append("—— 来自「彭博与路透新闻」")

        var out: [Any] = [blocks.joined(separator: "\n\n")]
        if let src = a.blocks.first(where: { $0.type == "img" && ($0.src?.isEmpty == false) })?.src,
           let url = URL(string: src) {
            out.append(url)
        }
        // 附一个可点开的链接对象，朋友圈会渲染成卡片
        if let link = URL(string: a.url) { out.append(link) }
        return out
    }

    /// 纯文本（用于「复制全文」，粘贴到微信聊天框）
    static func plainText(for a: Article, showOriginal: Bool) -> String {
        let zhTitle = a.titleZh.isEmpty ? a.title : a.titleZh
        var lines = [zhTitle]
        if !a.titleZh.isEmpty, a.titleZh != a.title { lines.append(a.title) }
        for b in a.blocks {
            switch b.type {
            case "hr": continue
            case "img": if !b.text.isEmpty { lines.append("［图］" + b.text) }
            default:
                let t = showOriginal ? b.text : (b.zh.isEmpty ? b.text : b.zh)
                if !t.isEmpty { lines.append(t) }
            }
        }
        lines.append("原文：" + a.url)
        return lines.joined(separator: "\n\n")
    }
}

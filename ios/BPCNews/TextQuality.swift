import Foundation

/// 译文质量判定：区分「真的翻译了」和「词典只替换了几个词」。
///
/// 之前把词典的半成品当成已翻译写进库，导致后续翻译看到 titleZh 非空就跳过，
/// 结果出现 `Mexico 降息 Fuels Speculation 官员 Want a 更弱 Peso` 这种半英半中。
enum TextQuality {

    /// 汉字占「字母类字符」的比例
    static func chineseRatio(_ s: String) -> Double {
        var letters = 0
        var han = 0
        for u in s.unicodeScalars {
            if (0x4E00...0x9FFF).contains(u.value) { han += 1; letters += 1 }
            else if CharacterSet.letters.contains(u) { letters += 1 }
        }
        guard letters > 0 else { return 0 }
        return Double(han) / Double(letters)
    }

    /// 是否算「真的译成中文」：汉字占比 ≥ 55%
    static func isTranslated(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return chineseRatio(t) >= 0.55
    }

    /// 半成品（有中文但比例不够）→ 需要重新翻译
    static func needsRetranslate(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return true }
        return chineseRatio(t) < 0.55
    }
}

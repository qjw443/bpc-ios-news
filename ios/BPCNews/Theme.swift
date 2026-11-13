import SwiftUI

/// 视觉基调：纯黑底 / 纸白字 / 一枚信号橙。参考 Bloomberg 的编辑版式：
/// 密排大写小标题（kicker）、衬线大标题、0.5pt 发丝线分隔、无多余装饰。
enum Theme {
    static let bg       = Color.black
    static let surface  = Color(red: 0.047, green: 0.047, blue: 0.051)   // #0C0C0D
    static let raised   = Color(red: 0.086, green: 0.086, blue: 0.090)   // #161617
    static let hairline = Color(red: 0.145, green: 0.145, blue: 0.153)   // #252527
    static let ink      = Color(red: 0.960, green: 0.960, blue: 0.955)   // #F5F5F4
    static let inkDim   = Color(red: 0.545, green: 0.545, blue: 0.560)   // #8B8B8F
    static let orange   = Color(red: 1.000, green: 0.420, blue: 0.000)   // #FF6B00
    static let green    = Color(red: 0.180, green: 0.760, blue: 0.450)
}

extension Font {
    /// 标题用衬线（New York / Times 风格），正文用系统无衬线
    static func editorial(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// 发丝线：Bloomberg 版式里最重要的“廉价”元素
struct Hairline: View {
    var color: Color = Theme.hairline
    var body: some View {
        Rectangle().fill(color).frame(height: 0.5)
    }
}

/// 大写密排小标题
struct Kicker: View {
    let text: String
    var color: Color = Theme.inkDim
    var size: CGFloat = 10
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .semibold))
            .tracking(1.8)
            .foregroundColor(color)
            .lineLimit(1)
    }
}

/// 信源标签：彭博=白底黑字（庄重），路透=橙底黑字（醒目）
struct SourceTag: View {
    let site: String

    private var text: String {
        switch site {
        case "bloomberg": return "BLOOMBERG"
        case "reuters": return "REUTERS"
        case "wsj": return "WSJ"
        default: return site.uppercased()
        }
    }

    private var bg: Color {
        switch site {
        case "bloomberg": return Theme.ink
        case "reuters": return Theme.orange
        case "wsj": return Color(red: 0.85, green: 0.22, blue: 0.22)
        default: return Theme.surface
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .black))
            .tracking(1.2)
            .foregroundColor(site == "bloomberg" ? Theme.bg : .white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2.5)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    }
}

import AppKit
import SwiftUI

/// 写作区（纸面）背景色主题。
///
/// 编辑器与预览共用一套配色：选定「白纸 / 米黄 / 护眼绿 / 深色」时会同时固定
/// 窗口外观，避免侧栏是浅色、纸面却是深色这种割裂感；「跟随系统」则完全交给 macOS。
enum PaperTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case sepia
    case green
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "白纸"
        case .sepia: return "米黄"
        case .green: return "护眼绿"
        case .dark: return "深色"
        }
    }

    var detail: String {
        switch self {
        case .system: return "跟随 macOS 的浅色 / 深色外观"
        case .light: return "纯白纸面，适合白天或明亮环境"
        case .sepia: return "暖色米黄，降低屏幕蓝光刺激"
        case .green: return "低饱和浅绿，长时间读写更舒服"
        case .dark: return "深色纸面，夜间写作不刺眼"
        }
    }

    /// 需要强制窗口外观时返回对应值；`nil` 表示跟随系统。
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light, .sepia, .green: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// 给 SwiftUI 的 `.preferredColorScheme` 用。
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        default: return .light
        }
    }

    var isDark: Bool { self == .dark }

    /// 设置页色块上的勾选颜色：深色底用白勾，浅色底用纸面正文色。
    var checkColor: NSColor {
        isDark ? .white : NSColor(hex: spec.text)
    }

    /// 设置页 / 工具栏上显示的色块。
    var swatch: NSColor { NSColor(hex: spec.background) }

    /// 编辑器（NSTextView + 语法高亮）配色。
    var editorPalette: EditorPalette {
        guard self != .system else { return .system }
        return EditorPalette(
            background: NSColor(hex: spec.background),
            text: NSColor(hex: spec.text),
            secondary: NSColor(hex: spec.muted),
            marker: NSColor(hex: spec.marker),
            codeBackground: NSColor(hex: spec.codeBackground),
            link: NSColor(hex: spec.link)
        )
    }

    /// 预览网页的 CSS 变量。放在 `Markdown.css` 之前，后面的样式全部引用这些变量。
    var cssVariables: String {
        switch self {
        case .system:
            return """
            :root { color-scheme: light dark; \(Self.lightSpec.cssVariables) }
            @media (prefers-color-scheme: dark) { :root { \(Self.darkSpec.cssVariables) } }
            """
        case .light, .sepia, .green:
            return ":root { color-scheme: light; \(spec.cssVariables) }"
        case .dark:
            return ":root { color-scheme: dark; \(spec.cssVariables) }"
        }
    }

    private var spec: Spec {
        switch self {
        case .system, .light: return Self.lightSpec
        case .sepia: return Self.sepiaSpec
        case .green: return Self.greenSpec
        case .dark: return Self.darkSpec
        }
    }

    // MARK: - 配色表

    private struct Spec {
        let background: String
        let text: String
        let muted: String
        let marker: String
        let codeBackground: String
        let preBackground: String
        let border: String
        let borderStrong: String
        let link: String
        let mark: String
        let copyBackground: String
        let copyText: String
        let copyBorder: String
        let wiki: String
        let tokenKeyword: String
        let tokenString: String
        let tokenComment: String
        let tokenNumber: String

        var cssVariables: String {
            """
            --bg: \(background); --fg: \(text); --muted: \(muted);
            --marker: \(marker); --code-bg: \(codeBackground); --pre-bg: \(preBackground);
            --border: \(border); --border-strong: \(borderStrong); --link: \(link);
            --mark: \(mark); --copy-bg: \(copyBackground); --copy-fg: \(copyText);
            --copy-border: \(copyBorder); --wiki: \(wiki);
            --tok-kw: \(tokenKeyword); --tok-str: \(tokenString);
            --tok-com: \(tokenComment); --tok-num: \(tokenNumber);
            """
        }
    }

    private static let lightSpec = Spec(
        background: "#ffffff",
        text: "#1d1d1f",
        muted: "#6e6e73",
        marker: "#b0b0b5",
        codeBackground: "#f2f2f4",
        preBackground: "#f6f6f8",
        border: "#e0e0e4",
        borderStrong: "#d0d0d5",
        link: "#0969da",
        mark: "#fff3a3",
        copyBackground: "rgba(255,255,255,0.92)",
        copyText: "#555555",
        copyBorder: "rgba(0,0,0,0.12)",
        wiki: "#8b5cf6",
        tokenKeyword: "#9b2393",
        tokenString: "#c41a16",
        tokenComment: "#6c7986",
        tokenNumber: "#1c00cf"
    )

    private static let sepiaSpec = Spec(
        background: "#f8f1e0",
        text: "#3b3427",
        muted: "#7a6e58",
        marker: "#b6a888",
        codeBackground: "#efe5d0",
        preBackground: "#f2e9d6",
        border: "#e0d3b8",
        borderStrong: "#d2c2a2",
        link: "#9a5b13",
        mark: "#f0d78c",
        copyBackground: "rgba(250,244,230,0.92)",
        copyText: "#6b5d45",
        copyBorder: "rgba(59,52,39,0.15)",
        wiki: "#7c5cbf",
        tokenKeyword: "#8a3f7d",
        tokenString: "#a33b20",
        tokenComment: "#8c7e66",
        tokenNumber: "#5b4a8a"
    )

    private static let greenSpec = Spec(
        background: "#eaf2e6",
        text: "#24301f",
        muted: "#63735a",
        marker: "#a6b79c",
        codeBackground: "#dde9d6",
        preBackground: "#e1ecdb",
        border: "#c9d8c0",
        borderStrong: "#b9cbae",
        link: "#2f7d4f",
        mark: "#d7e8a8",
        copyBackground: "rgba(234,242,230,0.92)",
        copyText: "#45563c",
        copyBorder: "rgba(36,48,31,0.15)",
        wiki: "#6b4fa0",
        tokenKeyword: "#7d3a72",
        tokenString: "#9b3a1f",
        tokenComment: "#6f7d63",
        tokenNumber: "#4f4a8a"
    )

    private static let darkSpec = Spec(
        background: "#1c1c1e",
        text: "#e6e6e6",
        muted: "#b0b0b5",
        marker: "#7c7c80",
        codeBackground: "#2c2c2e",
        preBackground: "#2c2c2e",
        border: "#3a3a3c",
        borderStrong: "#48484a",
        link: "#6cb4ff",
        mark: "#665c00",
        copyBackground: "rgba(44,44,46,0.92)",
        copyText: "#dddddd",
        copyBorder: "rgba(255,255,255,0.15)",
        wiki: "#b794f6",
        tokenKeyword: "#fc5fa3",
        tokenString: "#fc6a5d",
        tokenComment: "#7f8c98",
        tokenNumber: "#d0bf69"
    )
}

/// 编辑器里用到的动态 / 固定颜色集合。
struct EditorPalette {
    let background: NSColor
    let text: NSColor
    let secondary: NSColor
    let marker: NSColor
    let codeBackground: NSColor
    let link: NSColor

    /// 跟随系统时用语义色，浅色 / 深色切换由 AppKit 自己完成。
    static let system = EditorPalette(
        background: .textBackgroundColor,
        text: .labelColor,
        secondary: .secondaryLabelColor,
        marker: .tertiaryLabelColor,
        codeBackground: NSColor.labelColor.withAlphaComponent(0.07),
        link: .linkColor
    )
}

extension NSColor {
    /// 用 `#rrggbb` / `#rrggbbaa` 构造 sRGB 颜色。解析失败时退回黑色，避免崩溃。
    convenience init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let red, green, blue, alpha: CGFloat
        switch cleaned.count {
        case 8:
            red = CGFloat((value >> 24) & 0xff) / 255
            green = CGFloat((value >> 16) & 0xff) / 255
            blue = CGFloat((value >> 8) & 0xff) / 255
            alpha = CGFloat(value & 0xff) / 255
        default:
            red = CGFloat((value >> 16) & 0xff) / 255
            green = CGFloat((value >> 8) & 0xff) / 255
            blue = CGFloat(value & 0xff) / 255
            alpha = 1
        }
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

import AppKit

/// 把 Markdown 源码按结构着色：标题变大变粗、粗体显示为粗体、代码换成等宽、
/// 记号（# ** ` > -）压暗，让你看得到结构而不是一堆符号。
final class MarkdownSyntaxHighlighter: NSObject, NSTextStorageDelegate {
    weak var textView: NSTextView?

    /// 正文字号，标题与代码都按它按比例缩放
    var fontSize: CGFloat = 15

    /// 纯文本（.txt）：只上基础属性，不解析 Markdown
    var isPlainText = false

    /// 超过这个长度就只高亮光标所在段落，避免长文每次按键全量重排
    private let paragraphHighlightLimit = 8_000

    private var baseFont: NSFont {
        // 纯文本用等宽：日志、配置这类内容对齐更重要
        isPlainText
            ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : NSFont.systemFont(ofSize: fontSize)
    }
    private var monoFont: NSFont { NSFont.monospacedSystemFont(ofSize: fontSize * 0.9, weight: .regular) }

    private var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = max(4, fontSize * 0.4)
        style.paragraphSpacing = max(3, fontSize * 0.25)
        return style
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraphStyle]
    }

    private var markerColor: NSColor { .tertiaryLabelColor }
    private var codeBackground: NSColor { NSColor.labelColor.withAlphaComponent(0.07) }

    // MARK: - NSTextStorageDelegate

    private var highlightScheduled = false
    private var pendingAfterComposition = false

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        // 中文输入法组字期间不要动属性，否则会打断候选
        guard textView?.hasMarkedText() != true else { return }

        // 不要在 didProcessEditing 里改属性：那样会把排版/字形缓存搞坏，
        // 表现为中文整段不显示（ASCII 正常）。等这一轮编辑结束再上色。
        scheduleHighlight(around: editedRange.location)
    }

    // MARK: - 入口

    /// 延后一次上色。组字期间直接跳过，等输入法提交后再补。
    func scheduleHighlight(around location: Int) {
        guard !highlightScheduled else { return }
        highlightScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.highlightScheduled = false

            guard let textView = self.textView, let storage = textView.textStorage else { return }
            guard !textView.hasMarkedText() else {
                // 还在组字：记一笔，等 textDidChange 里补
                self.pendingAfterComposition = true
                return
            }
            self.pendingAfterComposition = false
            self.highlight(storage, around: textView.selectedRange().location)
            self.updateTypingAttributes(textView)
        }
    }

    /// 组字结束（或普通输入）后调用：把之前跳过的那次补上
    func refreshAfterInput() {
        guard let textView, let storage = textView.textStorage else { return }
        guard !textView.hasMarkedText() else { return }
        guard pendingAfterComposition else { return }
        pendingAfterComposition = false
        highlight(storage, around: textView.selectedRange().location)
        updateTypingAttributes(textView)
    }

    /// 全文高亮（首次加载、切换笔记）
    func highlightAll(_ storage: NSTextStorage, caret: Int = 0) {
        highlight(storage, around: caret, forceFull: true)
    }

    func highlight(_ storage: NSTextStorage, around location: Int, forceFull: Bool = false) {
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }

        var start = 0
        var end = ns.length
        if !forceFull, ns.length > paragraphHighlightLimit {
            let caret = min(max(0, location), ns.length - 1)
            let paragraph = ns.paragraphRange(for: NSRange(location: caret, length: 0))
            start = paragraph.location
            end = NSMaxRange(paragraph)
        }

        // 代码围栏是跨行的，必须从头数出当前状态
        var inCode = fenceState(ns, upTo: start)

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: NSRange(location: start, length: end - start))

        if isPlainText {
            storage.endEditing()
            return
        }

        var index = start
        while index < end {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            guard lineRange.length > 0 else { break }
            applyLine(ns, lineRange: lineRange, storage: storage, inCode: &inCode)
            index = NSMaxRange(lineRange)
        }
        storage.endEditing()
    }

    // MARK: - 单行

    private func applyLine(
        _ ns: NSString,
        lineRange: NSRange,
        storage: NSTextStorage,
        inCode: inout Bool
    ) {
        let raw = ns.substring(with: lineRange)
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if line.hasPrefix("```") {
            storage.addAttribute(.foregroundColor, value: markerColor, range: lineRange)
            inCode.toggle()
            return
        }

        if inCode {
            storage.addAttributes(
                [.font: monoFont, .foregroundColor: NSColor.labelColor, .backgroundColor: codeBackground],
                range: lineRange
            )
            return
        }

        if let match = firstMatch(#"^(#{1,6})(\s+)(.*)$"#, in: ns, range: lineRange) {
            let level = match.range(at: 1).length
            let contentRange = match.range(at: 3)
            if contentRange.location != NSNotFound {
                storage.addAttributes([
                    .font: headingFont(level: level),
                    .foregroundColor: NSColor.labelColor
                ], range: contentRange)
            }
            storage.addAttribute(.foregroundColor, value: markerColor, range: match.range(at: 1))
            return
        }

        if isHorizontalRule(line) {
            storage.addAttribute(.foregroundColor, value: markerColor, range: lineRange)
            return
        }

        if let match = firstMatch(#"^(\s*)(>\s?)"#, in: ns, range: lineRange) {
            storage.addAttribute(.foregroundColor, value: markerColor, range: match.range(at: 2))
            let rest = NSRange(
                location: NSMaxRange(match.range(at: 2)),
                length: max(0, NSMaxRange(lineRange) - NSMaxRange(match.range(at: 2)))
            )
            if rest.length > 0 {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: rest)
            }
            applyInline(ns, lineRange: lineRange, storage: storage)
            return
        }

        if let match = firstMatch(#"^(\s*)([-*+]|\d+[.)])(\s+)"#, in: ns, range: lineRange) {
            storage.addAttribute(.foregroundColor, value: markerColor, range: match.range(at: 2))
        }

        applyInline(ns, lineRange: lineRange, storage: storage)
    }

    private func applyInline(_ ns: NSString, lineRange: NSRange, storage: NSTextStorage) {
        // 行内代码优先，避免里面的 * 被当成强调
        for match in allMatches(#"`([^`\n]+)`"#, in: ns, range: lineRange) {
            storage.addAttributes([.font: monoFont, .backgroundColor: codeBackground], range: match.range)
        }

        for match in allMatches(#"\*\*([^*\n]+)\*\*"#, in: ns, range: lineRange) {
            storage.addAttribute(.font, value: boldFont(baseFont), range: match.range(at: 1))
            dimMarkers(storage, match: match, length: 2)
        }

        for match in allMatches(#"(?<![*\w])\*([^*\n]+)\*(?!\*)"#, in: ns, range: lineRange) {
            storage.addAttribute(.font, value: italicFont(baseFont), range: match.range(at: 1))
            dimMarkers(storage, match: match, length: 1)
        }

        for match in allMatches(#"~~([^~\n]+)~~"#, in: ns, range: lineRange) {
            storage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.secondaryLabelColor
            ], range: match.range(at: 1))
        }

        for match in allMatches(WikiLinks.pattern, in: ns, range: lineRange) {
            storage.addAttribute(.foregroundColor, value: markerColor, range: match.range(at: 0))
            let nameRange = match.range(at: 2).location == NSNotFound
                ? match.range(at: 1)
                : match.range(at: 2)
            if nameRange.location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: nameRange)
            }
        }

        for match in allMatches(#"\[([^\]\n]+)\]\(([^)\n]+)\)"#, in: ns, range: lineRange) {
            // 先整体压暗，再单独把链接文字提亮，顺序反了文字会被盖掉
            storage.addAttribute(.foregroundColor, value: markerColor, range: match.range(at: 0))
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: match.range(at: 1))
            storage.addAttribute(.foregroundColor, value: markerColor, range: match.range(at: 2))
        }
    }

    // MARK: - 工具

    private func headingFont(level: Int) -> NSFont {
        // 相对正文的倍数，换字号时整体等比缩放
        let ratios: [CGFloat] = [1.6, 1.33, 1.13, 1.03, 1.0, 1.0]
        let ratio = ratios[min(max(level - 1, 0), ratios.count - 1)]
        return NSFont.systemFont(ofSize: (fontSize * ratio).rounded(), weight: .bold)
    }

    // 注意：不要用 NSFontManager.convert(toHaveTrait:) —— 对中文回退字形不生效，
    // 看起来和正文一样。显式构造带 weight 的系统字体才真的粗。
    private func boldFont(_ font: NSFont) -> NSFont {
        if font.isFixedPitch {
            return NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
        }
        return NSFont.systemFont(ofSize: font.pointSize, weight: .bold)
    }

    private func italicFont(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    private func isHorizontalRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" } || stripped.allSatisfy { $0 == "_" }
    }

    /// 开头和结尾的记号都压暗，中间内容保持正文色
    private func dimMarkers(_ storage: NSTextStorage, match: NSTextCheckingResult, length: Int) {
        let full = match.range(at: 0)
        guard full.length >= length * 2 else { return }
        storage.addAttribute(
            .foregroundColor, value: markerColor,
            range: NSRange(location: full.location, length: length)
        )
        storage.addAttribute(
            .foregroundColor, value: markerColor,
            range: NSRange(location: NSMaxRange(full) - length, length: length)
        )
    }

    private func fenceState(_ ns: NSString, upTo location: Int) -> Bool {
        var inCode = false
        var index = 0
        while index < location {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            guard lineRange.length > 0 else { break }
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("```") { inCode.toggle() }
            index = NSMaxRange(lineRange)
        }
        return inCode
    }

    func firstMatch(_ pattern: String, in ns: NSString, range: NSRange) -> NSTextCheckingResult? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        return re.firstMatch(in: ns as String, options: [], range: range)
    }

    func allMatches(_ pattern: String, in ns: NSString, range: NSRange) -> [NSTextCheckingResult] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: ns as String, options: [], range: range)
    }

    /// 让新输入的字继承当前段落的字体（在代码块里继续输代码、在标题里继续输标题）
    func updateTypingAttributes(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        var attributes = baseAttributes
        if storage.length > 0 {
            let location = min(max(0, textView.selectedRange().location), storage.length - 1)
            let existing = storage.attributes(at: location, effectiveRange: nil)
            if let font = existing[.font] { attributes[.font] = font }
            if let style = existing[.paragraphStyle] { attributes[.paragraphStyle] = style }
        }
        textView.typingAttributes = attributes
    }
}

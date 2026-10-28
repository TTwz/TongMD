import AppKit

/// 编辑器里所有“插入格式”的动作。全部走 NSTextView.insertText，
/// 这样撤销、选区、输入法都是系统行为，不用自己维护文本状态。
enum TextActions {

    // MARK: - 包裹类

    static func toggleWrap(_ textView: NSTextView, marker: String, placeholder: String) {
        let ns = textView.string as NSString
        let selection = textView.selectedRange()

        guard selection.length > 0 else {
            let insert = marker + placeholder + marker
            textView.insertText(insert, replacementRange: selection)
            let placeholderStart = selection.location + marker.count
            textView.setSelectedRange(NSRange(location: placeholderStart, length: (placeholder as NSString).length))
            return
        }

        let selected = ns.substring(with: selection)

        // 选中内容自身就带记号：去掉
        if selected.hasPrefix(marker), selected.hasSuffix(marker), selected.count > marker.count * 2 {
            let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
            textView.insertText(inner, replacementRange: selection)
            textView.setSelectedRange(NSRange(location: selection.location, length: (inner as NSString).length))
            return
        }

        // 记号在选择区两侧：一起去掉
        let length = marker.count
        if selection.location >= length, NSMaxRange(selection) + length <= ns.length {
            let before = NSRange(location: selection.location - length, length: length)
            let after = NSRange(location: NSMaxRange(selection), length: length)
            if ns.substring(with: before) == marker, ns.substring(with: after) == marker {
                let span = NSRange(location: before.location, length: selection.length + length * 2)
                textView.insertText(selected, replacementRange: span)
                textView.setSelectedRange(NSRange(location: before.location, length: selection.length))
                return
            }
        }

        let wrapped = marker + selected + marker
        textView.insertText(wrapped, replacementRange: selection)
        textView.setSelectedRange(NSRange(location: selection.location + length, length: selection.length))
    }

    static func insertLink(_ textView: NSTextView) {
        let ns = textView.string as NSString
        let selection = textView.selectedRange()
        let selected = selection.length > 0 ? ns.substring(with: selection) : "链接文字"

        let insert = "[\(selected)](https://)"
        textView.insertText(insert, replacementRange: selection)

        // 光标落在 URL 上，直接粘地址就行
        let urlStart = selection.location + 1 + (selected as NSString).length + 2
        textView.setSelectedRange(NSRange(location: urlStart, length: 8))
    }

    static func toggleStrikethrough(_ textView: NSTextView) {
        toggleWrap(textView, marker: "~~", placeholder: "删除线")
    }

    static func toggleHighlight(_ textView: NSTextView) {
        toggleWrap(textView, marker: "==", placeholder: "高亮")
    }

    static func toggleNumberedList(_ textView: NSTextView) {
        togglePrefix(textView, prefix: "1. ", pattern: #"^\s*\d+[.)]\s+"#)
    }

    static func toggleTaskList(_ textView: NSTextView) {
        togglePrefix(textView, prefix: "- [ ] ", pattern: #"^\s*[-*+]\s+\[[ xX]\]\s+"#)
    }

    static func insertTable(_ textView: NSTextView) {
        let table = "| 列 1 | 列 2 |\n| --- | --- |\n|  |  |\n"
        let selection = textView.selectedRange()
        textView.insertText(table, replacementRange: selection)
        // 选中第一列表头，直接输入就能替换
        textView.setSelectedRange(NSRange(location: selection.location + 2, length: 3))
    }

    static func insertHorizontalRule(_ textView: NSTextView) {
        let selection = textView.selectedRange()
        textView.insertText("\n\n---\n\n", replacementRange: selection)
        textView.setSelectedRange(NSRange(location: selection.location + 6, length: 0))
    }

    static func insertCodeBlock(_ textView: NSTextView, language: String) {
        let ns = textView.string as NSString
        let selection = textView.selectedRange()
        let selected = selection.length > 0 ? ns.substring(with: selection) : ""
        let insert = "```\(language)\n\(selected)\n```"
        textView.insertText(insert, replacementRange: selection)
        let contentStart = selection.location + 3 + language.count + 1
        textView.setSelectedRange(NSRange(location: contentStart, length: (selected as NSString).length))
    }

    static func toggleCodeBlock(_ textView: NSTextView) {
        let ns = textView.string as NSString
        let selection = textView.selectedRange()
        let selected = selection.length > 0 ? ns.substring(with: selection) : ""

        if selected.hasPrefix("```"), selected.hasSuffix("```"), selected.count >= 6 {
            let inner = String(selected.dropFirst(3).dropLast(3))
            let trimmed = inner.trimmingCharacters(in: .newlines)
            textView.insertText(trimmed, replacementRange: selection)
            textView.setSelectedRange(NSRange(location: selection.location, length: (trimmed as NSString).length))
            return
        }

        let insert = "```\n\(selected)\n```"
        textView.insertText(insert, replacementRange: selection)
        let contentStart = selection.location + 4
        textView.setSelectedRange(NSRange(location: contentStart, length: (selected as NSString).length))
    }

    // MARK: - 行前缀类

    static func toggleHeading(_ textView: NSTextView, level: Int) {
        let prefix = level <= 0 ? "" : String(repeating: "#", count: level) + " "
        togglePrefix(textView, prefix: prefix, pattern: #"^\s*#{1,6}\s+"#)
    }

    static func toggleBulletList(_ textView: NSTextView) {
        togglePrefix(textView, prefix: "- ", pattern: #"^\s*[-*+]\s+"#)
    }

    static func toggleBlockquote(_ textView: NSTextView) {
        togglePrefix(textView, prefix: "> ", pattern: #"^\s*>\s?"#)
    }

    /// 在选中行上增删行首记号；已经全都是该记号时视为关闭
    static func togglePrefix(_ textView: NSTextView, prefix: String, pattern: String) {
        let ns = textView.string as NSString
        let selection = textView.selectedRange()
        let lineRange = ns.lineRange(for: selection)
        let block = ns.substring(with: lineRange)

        let lines = block.components(separatedBy: "\n")
        let hasTrailingNewline = block.hasSuffix("\n")
        var body = hasTrailingNewline ? Array(lines.dropLast()) : lines
        guard !body.isEmpty else { return }

        let regex = try? NSRegularExpression(pattern: pattern)
        let nonEmpty = body.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        let allHavePrefix = !nonEmpty.isEmpty && nonEmpty.allSatisfy { line in
            guard let regex else { return false }
            return regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: (line as NSString).length)) != nil
        }

        body = body.map { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            var stripped = line
            if let regex,
               let match = regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: (line as NSString).length)) {
                stripped = (line as NSString).replacingCharacters(in: match.range, with: "")
            }
            return allHavePrefix ? stripped : prefix + stripped
        }

        var replacement = body.joined(separator: "\n")
        if hasTrailingNewline { replacement += "\n" }

        textView.insertText(replacement, replacementRange: lineRange)
        textView.setSelectedRange(NSRange(location: lineRange.location, length: (replacement as NSString).length))
    }

    // MARK: - 智能续行

    /// 回车时自动延续列表 / 引用；空项目再回车则退出列表
    static func insertSmartNewline(in textView: NSTextView) -> Bool {
        let ns = textView.string as NSString
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }

        let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)

        guard let continuation = continuationPrefix(for: line) else { return false }

        if continuation.isEmpty {
            // 空的列表项/引用：把这行删掉，等于退出列表
            textView.insertText("", replacementRange: lineRange)
            return true
        }

        textView.insertText("\n" + continuation, replacementRange: selection)
        return true
    }

    /// 纯函数，便于单独测试。返回值 nil 表示不是列表/引用行；
    /// 返回 "" 表示这是一个空项目，应该退出列表。
    static func continuationPrefix(for line: String) -> String? {
        if let match = match(#"^(\s*)([-*+])\s+(.*)$"#, line) {
            let content = match.content.trimmingCharacters(in: .whitespaces)
            return content.isEmpty ? "" : match.indent + match.marker + " "
        }
        if let match = match(#"^(\s*)(\d+)[.)]\s+(.*)$"#, line) {
            let content = match.content.trimmingCharacters(in: .whitespaces)
            if content.isEmpty { return "" }
            let next = (Int(match.marker.dropLast()) ?? 1) + 1
            return match.indent + "\(next). "
        }
        if let match = match(#"^(\s*)(>)\s?(.*)$"#, line) {
            let content = match.content.trimmingCharacters(in: .whitespaces)
            return content.isEmpty ? "" : match.indent + "> "
        }
        return nil
    }

    private static func match(_ pattern: String, _ line: String) -> (indent: String, marker: String, content: String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: (line as NSString).length)
        guard let result = regex.firstMatch(in: line, options: [], range: range),
              result.numberOfRanges > 3 else { return nil }
        let ns = line as NSString
        let indent = result.range(at: 1).location == NSNotFound ? "" : ns.substring(with: result.range(at: 1))
        let marker = result.range(at: 2).location == NSNotFound ? "" : ns.substring(with: result.range(at: 2))
        let content = result.range(at: 3).location == NSNotFound ? "" : ns.substring(with: result.range(at: 3))
        return (indent, marker, content)
    }
}

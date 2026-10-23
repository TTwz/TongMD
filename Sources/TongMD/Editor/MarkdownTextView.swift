import AppKit

/// 编辑器本体：负责拦截回车（智能续行）和对外暴露格式化动作。
/// 这些 @objc 方法会被菜单和工具条通过响应者链调用（target = nil），
/// 所以不用在 SwiftUI 层持有文本视图引用。
final class MarkdownTextView: NSTextView {
    var highlighter: MarkdownSyntaxHighlighter?
    /// .txt：禁用 Markdown 编辑动作（智能续行、插入标记）
    var isPlainText = false

    override func insertNewline(_ sender: Any?) {
        // 中文输入法组字时，回车是「确认候选词」，绝不能在这里插换行或续列表，
        // 否则会出现「吞字 + 莫名其妙换行」。
        guard !hasMarkedText() else {
            super.insertNewline(sender)
            return
        }
        guard !isPlainText else {
            super.insertNewline(sender)
            return
        }
        if TextActions.insertSmartNewline(in: self) { return }
        super.insertNewline(sender)
    }

    // MARK: - 行内

    private var allowsMarkdownFormatting: Bool { !isPlainText }

    @objc func toggleBold(_ sender: Any?) {
        guard allowsMarkdownFormatting else { return }
        TextActions.toggleWrap(self, marker: "**", placeholder: "粗体")
    }

    @objc func toggleItalic(_ sender: Any?) {
        guard allowsMarkdownFormatting else { return }
        TextActions.toggleWrap(self, marker: "*", placeholder: "斜体")
    }

    @objc func toggleInlineCode(_ sender: Any?) {
        guard allowsMarkdownFormatting else { return }
        TextActions.toggleWrap(self, marker: "`", placeholder: "代码")
    }

    @objc func insertMarkdownLink(_ sender: Any?) {
        guard allowsMarkdownFormatting else { return }
        TextActions.insertLink(self)
    }

    @objc func toggleCodeBlock(_ sender: Any?) {
        guard allowsMarkdownFormatting else { return }
        TextActions.toggleCodeBlock(self)
    }

    // MARK: - 行前缀

    @objc func toggleHeading1(_ sender: Any?) {
        guard allowsMarkdownFormatting else { return }
        TextActions.toggleHeading(self, level: 1)
    }
    @objc func toggleHeading2(_ sender: Any?) {
        guard allowsMarkdownFormatting else { return }
        TextActions.toggleHeading(self, level: 2)
    }
    @objc func toggleHeading3(_ sender: Any?) {
        guard allowsMarkdownFormatting else { return }
        TextActions.toggleHeading(self, level: 3)
    }
    @objc func toggleParagraph(_ sender: Any?) {
        guard allowsMarkdownFormatting else { return }
        TextActions.toggleHeading(self, level: 0)
    }

    @objc func toggleBulletList(_ sender: Any?) {
        guard allowsMarkdownFormatting else { return }
        TextActions.toggleBulletList(self)
    }
    @objc func toggleBlockquote(_ sender: Any?) {
        guard allowsMarkdownFormatting else { return }
        TextActions.toggleBlockquote(self)
    }

    // MARK: - 撤销支持

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        super.validateUserInterfaceItem(item)
    }
}

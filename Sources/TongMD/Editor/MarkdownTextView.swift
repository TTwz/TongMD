import AppKit

/// 编辑器本体：负责拦截回车（智能续行）和对外暴露格式化动作。
/// 这些 @objc 方法会被菜单和工具条通过响应者链调用（target = nil），
/// 所以不用在 SwiftUI 层持有文本视图引用。
final class MarkdownTextView: NSTextView {
    var highlighter: MarkdownSyntaxHighlighter?
    /// .txt：禁用 Markdown 编辑动作（智能续行、插入标记）
    var isPlainText = false
    /// 当前笔记所在目录：用于计算相对路径
    var attachmentDirectory: URL?
    /// 笔记库根目录：附件统一存到它下面的 assets/
    var attachmentRoot: URL?
    /// 用于 [[ 补全的笔记标题
    var noteTitles: [String] = []

    // 纯文本 NSTextView 默认不接受图片，系统会在调用 paste: 前禁用菜单和 ⌘V。
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + ImageClipboard.imageTypes + [.fileURL]
    }

    func canPasteImage(from pasteboard: NSPasteboard) -> Bool {
        isEditable && attachmentDirectory != nil && ImageClipboard.containsImage(in: pasteboard)
    }

    override func paste(_ sender: Any?) {
        if insertPastedImage(from: .general) { return }
        super.paste(sender)
    }

    /// 返回 true 表示这次粘贴已经被当作图片处理掉了
    @discardableResult
    func insertPastedImage(from pasteboard: NSPasteboard) -> Bool {
        guard canPasteImage(from: pasteboard), let directory = attachmentDirectory else { return false }

        if let imageURL = ImageClipboard.imageFileURL(from: pasteboard),
           let data = try? Data(contentsOf: imageURL) {
            return insertImage(
                data,
                name: imageURL.deletingPathExtension().lastPathComponent,
                ext: imageURL.pathExtension.lowercased(),
                into: directory
            )
        }

        if let png = ImageClipboard.pngData(from: pasteboard) {
            return insertImage(png, name: "截图", ext: "png", into: directory)
        }
        // 仍然失败：把剪贴板实际类型抛给用户，方便定位是哪种格式没覆盖
        let types = (pasteboard.types ?? []).map(\.rawValue).joined(separator: ", ")
        NotificationCenter.default.post(
            name: .tongmdPasteFailed,
            object: nil,
            userInfo: ["message": "没能从剪贴板读到图片。剪贴板里的类型是：\(types.isEmpty ? "（空）" : types)"]
        )
        return false
    }

    /// 菜单「插入剪贴板截图」走这里：即使 ⌘V 被别的响应者截走也有入口
    @objc func insertImageFromClipboard(_ sender: Any?) {
        guard insertPastedImage(from: .general) else {
            NSSound.beep()
            return
        }
    }

    private func insertImage(_ data: Data, name: String, ext: String, into directory: URL) -> Bool {
        // 统一放到笔记库根的 assets/；没有根目录时退回笔记旁的 assets/
        let base = attachmentRoot ?? directory
        guard let fileURL = AttachmentStore.save(data: data, name: name, ext: ext, into: base) else {
            reportPasteFailure(NSError(
                domain: "TongMD", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "assets 目录不可写"]
            ))
            return false
        }

        let link = AttachmentStore.relativePath(from: directory, to: fileURL)
        let markup = isPlainText ? link : "![\(AttachmentStore.sanitize(name))](\(link))"
        insertText(markup, replacementRange: selectedRange())
        return true
    }

    private func reportPasteFailure(_ error: Error) {
        NSSound.beep()
        NotificationCenter.default.post(
            name: .tongmdPasteFailed,
            object: nil,
            userInfo: ["message": "图片没能保存到 assets/：\(error.localizedDescription)"]
        )
    }

    static func sanitizeAttachmentName(_ name: String) -> String {
        AttachmentStore.sanitize(name)
    }

    private static func legacySanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).union(.init(charactersIn: "·"))
        var result = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        while result.contains("--") { result = result.replacingOccurrences(of: "--", with: "-") }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        return result.isEmpty ? "image" : result
    }

    func currentLinkSuggestion() -> LinkCompletion.Suggestion? {
        LinkCompletion.suggestion(
            text: string,
            caret: selectedRange().location,
            titles: noteTitles
        )
    }

    private lazy var linkCompletion = LinkCompletionController()

    private func refreshLinkCompletion() {
        guard !hasMarkedText(), let suggestion = currentLinkSuggestion() else {
            linkCompletion.hide()
            return
        }

        linkCompletion.onCommit = { [weak self] title in
            guard let self, let current = self.currentLinkSuggestion() else { return }
            self.insertText(title + "]]", replacementRange: current.range)
            self.linkCompletion.hide()
        }

        let caret = selectedRange().location
        let rect = firstRect(
            forCharacterRange: NSRange(location: caret, length: 0),
            actualRange: nil
        )
        linkCompletion.show(
            items: suggestion.items,
            at: NSPoint(x: rect.minX, y: rect.minY)
        )
    }

    override func didChangeText() {
        super.didChangeText()
        refreshLinkCompletion()
    }

    #if DEBUG
    var debugCompletionVisible: Bool { linkCompletion.isVisible }
    var debugCompletionCount: Int { linkCompletion.itemCount }
    func debugHideCompletion() { linkCompletion.hide() }
    #endif

    /// 光标移动时由 delegate 调用，用来隐藏或刷新补全浮层
    func linkCompletionDidMoveCaret() {
        refreshLinkCompletion()
    }

    override func keyDown(with event: NSEvent) {
        if linkCompletion.isVisible {
            switch event.keyCode {
            case 53:   // Esc
                linkCompletion.hide()
                return
            case 125:  // ↓
                linkCompletion.moveSelection(by: 1)
                return
            case 126:  // ↑
                linkCompletion.moveSelection(by: -1)
                return
            case 36, 48: // Return / Tab
                if linkCompletion.commitSelected() { return }
            default:
                break
            }
        }
        super.keyDown(with: event)
        if linkCompletion.isVisible, event.keyCode == 123 || event.keyCode == 124 {
            refreshLinkCompletion()
        }
    }

    override func resignFirstResponder() -> Bool {
        linkCompletion.hide()
        return super.resignFirstResponder()
    }

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

    @objc func toggleStrikethrough(_ sender: Any?) {
        guard allowsMarkdownFormatting else { return }
        TextActions.toggleStrikethrough(self)
    }

    @objc func toggleHighlight(_ sender: Any?) {
        guard allowsMarkdownFormatting else { return }
        TextActions.toggleHighlight(self)
    }

    @objc func insertTable(_ sender: Any?) {
        guard allowsMarkdownFormatting else { return }
        TextActions.insertTable(self)
    }

    @objc func insertHorizontalRule(_ sender: Any?) {
        guard allowsMarkdownFormatting else { return }
        TextActions.insertHorizontalRule(self)
    }

    @objc func insertSwiftCodeBlock(_ sender: Any?) {
        guard allowsMarkdownFormatting else { return }
        TextActions.insertCodeBlock(self, language: "swift")
    }

    @objc func insertPythonCodeBlock(_ sender: Any?) {
        guard allowsMarkdownFormatting else { return }
        TextActions.insertCodeBlock(self, language: "python")
    }

    @objc func insertJavaScriptCodeBlock(_ sender: Any?) {
        guard allowsMarkdownFormatting else { return }
        TextActions.insertCodeBlock(self, language: "js")
    }

    @objc func insertBashCodeBlock(_ sender: Any?) {
        guard allowsMarkdownFormatting else { return }
        TextActions.insertCodeBlock(self, language: "bash")
    }

    @objc func insertJavaCodeBlock(_ sender: Any?) {
        guard allowsMarkdownFormatting else { return }
        TextActions.insertCodeBlock(self, language: "java")
    }

    @objc func insertSQLCodeBlock(_ sender: Any?) {
        guard allowsMarkdownFormatting else { return }
        TextActions.insertCodeBlock(self, language: "sql")
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

    @objc func toggleNumberedList(_ sender: Any?) {
        guard allowsMarkdownFormatting else { return }
        TextActions.toggleNumberedList(self)
    }

    @objc func toggleTaskList(_ sender: Any?) {
        guard allowsMarkdownFormatting else { return }
        TextActions.toggleTaskList(self)
    }

    // MARK: - 撤销支持

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)), canPasteImage(from: .general) {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }
}

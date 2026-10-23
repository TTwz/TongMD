import AppKit

/// 编辑器本体：负责拦截回车（智能续行）和对外暴露格式化动作。
/// 这些 @objc 方法会被菜单和工具条通过响应者链调用（target = nil），
/// 所以不用在 SwiftUI 层持有文本视图引用。
final class MarkdownTextView: NSTextView {
    var highlighter: MarkdownSyntaxHighlighter?
    /// .txt：禁用 Markdown 编辑动作（智能续行、插入标记）
    var isPlainText = false
    /// 当前笔记所在目录：粘贴进来的图片会存到它的 assets/ 下
    var attachmentDirectory: URL?

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"]

    override func paste(_ sender: Any?) {
        if insertPastedImage(from: .general) { return }
        super.paste(sender)
    }

    /// 返回 true 表示这次粘贴已经被当作图片处理掉了
    @discardableResult
    func insertPastedImage(from pasteboard: NSPasteboard) -> Bool {
        guard let directory = attachmentDirectory else { return false }

        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL],
           let imageURL = urls.first(where: { Self.imageExtensions.contains($0.pathExtension.lowercased()) }),
           let data = try? Data(contentsOf: imageURL) {
            return insertImage(
                data,
                name: imageURL.deletingPathExtension().lastPathComponent,
                ext: imageURL.pathExtension.lowercased(),
                into: directory
            )
        }

        // 截图通常在剪贴板里是 TIFF/PNG，个别工具给 JPEG/HEIC
        let bitmapTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, .init("public.jpeg"), .init("public.heic")]
        for type in bitmapTypes {
            if let data = pasteboard.data(forType: type),
               let rep = NSBitmapImageRep(data: data),
               let png = rep.representation(using: .png, properties: [:]) {
                return insertImage(png, name: "粘贴的图片", ext: "png", into: directory)
            }
        }

        // 通用兜底：任何 image 家族的 UTType / 延迟加载的图片都交给 AppKit
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return insertImage(png, name: "截图", ext: "png", into: directory)
        }

        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return insertImage(png, name: "粘贴的图片", ext: "png", into: directory)
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
        let assets = directory.appendingPathComponent("assets", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        } catch {
            reportPasteFailure(error)
            return false
        }

        let safeName = Self.sanitizeAttachmentName(name)
        var fileURL = assets.appendingPathComponent("\(safeName).\(ext)")
        var index = 2
        while FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = assets.appendingPathComponent("\(safeName)-\(index).\(ext)")
            index += 1
        }

        do {
            try data.write(to: fileURL)
        } catch {
            reportPasteFailure(error)
            return false
        }

        let relative = "assets/\(fileURL.lastPathComponent)"
        let markup = isPlainText ? relative : "![\(safeName)](\(relative))"
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
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).union(.init(charactersIn: "·"))
        var result = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        while result.contains("--") { result = result.replacingOccurrences(of: "--", with: "-") }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        return result.isEmpty ? "image" : result
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

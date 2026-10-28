#if DEBUG
import AppKit
import SwiftUI

enum ClipboardSelfTest {
    @MainActor
    static func run(in root: URL, check: (String, Bool) -> Void) throws {
        print("剪贴板快捷键回归")
        let vault = root.appendingPathComponent("clipboard-vault", isDirectory: true)
        let destination = vault.appendingPathComponent("目标", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let note = vault.appendingPathComponent("笔记.md")
        let otherNote = vault.appendingPathComponent("其它.md")
        try "before after".write(to: note, atomically: true, encoding: .utf8)
        try "其它内容".write(to: otherNote, atomically: true, encoding: .utf8)

        let previousTokenDirectory = TokenStore.directoryOverride
        TokenStore.directoryOverride = root.appendingPathComponent("clipboard-test-credentials")
        defer { TokenStore.directoryOverride = previousTokenDirectory }
        let model = AppModel(temporaryVault: vault)
        model.selection = nil
        model.openNote(note)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        editor.isRichText = false
        editor.attachmentDirectory = vault
        editor.string = model.text
        let coordinator = MarkdownEditor(text: Binding(
            get: { model.text }, set: { model.textChanged($0) }
        )).makeCoordinator()
        editor.delegate = coordinator
        window.contentView?.addSubview(editor)

        let pasteboard = NSPasteboard(name: .init("dev.tong.TongMD.clipboard-regression"))
        defer { pasteboard.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 12, height: 12))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 12, height: 12).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!

        func key(_ character: String, modifiers: NSEvent.ModifierFlags = .command) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                             timestamp: 0, windowNumber: window.windowNumber, context: nil,
                             characters: character, charactersIgnoringModifiers: character,
                             isARepeat: false, keyCode: character == "c" ? 8 : 9)!
        }

        // 模拟截图后回到仍有光标的编辑器，无需重新点击左侧文件。
        model.sidebarSelection = []
        check("编辑器能获得焦点", window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        check("纯文本编辑器接受截图类型", editor.readablePasteboardTypes.contains(.tiff)
              && editor.readablePasteboardTypes.contains(.png) && editor.canPasteImage(from: pasteboard))
        check("编辑器聚焦时 ⌘V 直接插入 TIFF 截图",
              model.handleClipboardShortcut(key("v"), in: window, pasteboard: pasteboard))
        model.saveNow()
        let saved = try String(contentsOf: note, encoding: .utf8)
        check("截图在光标处插入并写入当前笔记", saved == "before ![截图](assets/截图.png)after")
        check("截图文件实际落盘", FileManager.default.fileExists(
            atPath: vault.appendingPathComponent("assets/截图.png").path))

        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        check("编辑器聚焦时 ⌘V 直接插入 PNG 截图",
              model.handleClipboardShortcut(key("v"), in: window, pasteboard: pasteboard))
        model.saveNow()
        check("连续截图不覆盖已有附件", FileManager.default.fileExists(
            atPath: vault.appendingPathComponent("assets/截图-2.png").path))

        window.makeFirstResponder(nil)
        check("编辑器失焦后截图粘贴仍可用", model.handleClipboardShortcut(key("v"), in: window,
                                                                                   pasteboard: pasteboard))
        model.saveNow()
        window.makeFirstResponder(editor)

        var pasteFailures = 0
        let observer = NotificationCenter.default.addObserver(forName: .tongmdPasteFailed,
                                                             object: nil, queue: nil) { _ in
            pasteFailures += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        pasteboard.clearContents()
        pasteboard.setString("普通文本", forType: .string)
        check("普通文本 ⌘V 留给系统", !model.handleClipboardShortcut(key("v"), in: window,
                                                                             pasteboard: pasteboard))
        check("普通文本不再报告图片错误", !editor.insertPastedImage(from: pasteboard) && pasteFailures == 0)
        check("编辑器 ⌘C 不复制侧栏文件", !model.handleClipboardShortcut(key("c"), in: window,
                                                                                  pasteboard: pasteboard))

        // 焦点在侧栏时，⌘C 写入文件 URL，⌘V 复制文件内容。
        window.makeFirstResponder(nil)
        model.sidebarSelection = [note, otherNote]
        check("侧栏 ⌘C 复制选中的多个文件", model.handleClipboardShortcut(key("c"), in: window,
                                                                                 pasteboard: pasteboard))
        let copiedURLs = pasteboard.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        check("剪贴板保存标准文件 URL", Set(copiedURLs) == Set([note, otherNote]))
        model.sidebarSelection = [destination]
        check("侧栏 ⌘V 粘贴文件", model.handleClipboardShortcut(key("v"), in: window,
                                                                       pasteboard: pasteboard))
        let pastedNote = destination.appendingPathComponent(note.lastPathComponent)
        check("文件复制内容一致", try String(contentsOf: pastedNote, encoding: .utf8)
              == String(contentsOf: note, encoding: .utf8))
        check("侧栏重复粘贴不覆盖", model.handleClipboardShortcut(key("v"), in: window,
                                                                          pasteboard: pasteboard)
              && FileManager.default.fileExists(atPath: destination.appendingPathComponent("笔记 2.md").path))

        let input = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        window.contentView?.addSubview(input)
        window.makeFirstResponder(input)
        check("搜索和设置输入框 ⌘C 留给系统", !model.handleClipboardShortcut(key("c"), in: window,
                                                                                        pasteboard: pasteboard))
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        check("其它输入框不会把图片写进笔记", !model.handleClipboardShortcut(key("v"), in: window,
                                                                                        pasteboard: pasteboard))
        window.makeFirstResponder(editor)
        check("额外修饰键不触发普通粘贴", !model.handleClipboardShortcut(
            key("v", modifiers: [.command, .shift]), in: window, pasteboard: pasteboard))
        check("Caps Lock 不影响截图快捷键", model.handleClipboardShortcut(
            key("v", modifiers: [.command, .capsLock]), in: window, pasteboard: pasteboard))
        model.saveNow()
        editor.isEditable = false
        check("只读编辑器不写入附件", !model.handleClipboardShortcut(key("v"), in: window,
                                                                                 pasteboard: pasteboard))
    }
}
#endif

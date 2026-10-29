#if DEBUG
import AppKit
import SwiftUI
import WebKit

/// 开发期自检截图，用于没有录屏权限时检查界面。
/// 用法：TongMD --vault <笔记库> --snapshot out.png
///
/// 产出：
/// - `out.png`：整窗首帧
/// - `out-preview.png`：模拟输入之后，用 WebKit 自己的快照接口抓的预览区
///
/// 会断言「输入后预览 DOM 确实变长了」，防止增量更新路径悄悄坏掉。
/// （NSView.cacheDisplay 抓不到 JS 更新后的 WKWebView 图层，所以预览必须用 takeSnapshot。）
enum Snapshot {
    @MainActor
    static func run(outputPath: String) -> Int32 {
        _ = NSApplication.shared

        let model = AppModel()
        guard model.vaultURL != nil else {
            print("需要 --vault <笔记库路径>")
            return 2
        }
        model.mode = .split
        if let raw = ProcessInfo.processInfo.environment["TONGMD_FONT_SIZE"],
           let value = Double(raw) {
            model.fontSize = value
        }

        let size = NSSize(width: 1280, height: 800)
        let root = RootView()
            .environmentObject(model)
            .frame(width: size.width, height: size.height)

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()

        func spin(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }

        /// 同步执行一段 JS 并拿到结果
        func eval(_ web: WKWebView, _ script: String) -> Any? {
            var result: Any?
            var done = false
            web.evaluateJavaScript(script) { value, _ in
                result = value
                done = true
            }
            let deadline = Date().addingTimeInterval(2)
            while !done, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            return result
        }

        func writePNG(_ image: NSImage, to path: String) -> Bool {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return false }
            try? png.write(to: URL(fileURLWithPath: path))
            print("已写入 \(path) · \(rep.pixelsWide)x\(rep.pixelsHigh)")
            return true
        }

        func captureWindow(to path: String) {
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: URL(fileURLWithPath: path))
            print("已写入 \(path) · \(rep.pixelsWide)x\(rep.pixelsHigh)")
        }

        // 可选：模拟侧栏选中，检查高亮
        if let attachment = ProcessInfo.processInfo.environment["TONGMD_ATTACHMENT"],
           let vault = model.vaultURL {
            let url = vault.appendingPathComponent(attachment)
            if FileManager.default.fileExists(atPath: url.path) {
                model.sidebarSelection = [url]
            }
        }

        if ProcessInfo.processInfo.environment["TONGMD_TABS"] == "1" {
            for note in model.notes.prefix(3) { model.openNote(note.url) }
        }

        if ProcessInfo.processInfo.environment["TONGMD_OUTLINE"] == "1" {
            model.showOutline = true
        }

        if let title = ProcessInfo.processInfo.environment["TONGMD_OPEN"],
           let note = model.notes.first(where: { $0.title == title }) {
            model.openNote(note.url)
        }

        if let mode = ProcessInfo.processInfo.environment["TONGMD_SELECT"] {
            if mode == "folder", let folder = model.tree.first(where: { $0.isDirectory }) {
                model.sidebarSelection = [folder.url]
            } else if mode == "multi" {
                var urls = Set<URL>()
                if let note = model.notes.first { urls.insert(note.url) }
                if let folder = model.tree.first(where: { $0.isDirectory }) { urls.insert(folder.url) }
                model.sidebarSelection = urls
            }
        }

        // 首帧
        spin(2.0)
        captureWindow(to: outputPath)

        guard let noteURL = model.selection,
              let web = findWebView(in: hosting) else {
            print("没找到笔记或预览视图")
            return 3
        }

        let before = (eval(web, "document.body.innerHTML.length") as? Int) ?? 0
        let original = model.text

        // 走真实路径：textChanged → 250ms debounce → JS 增量替换
        model.textChanged(original + "\n\n## 增量更新测试\n\n这段文字是在首帧之后写进去的，预览没有整页重载。\n")
        spin(1.5)

        let after = (eval(web, "document.body.innerHTML.length") as? Int) ?? 0
        print("预览 DOM: \(before) → \(after) 字节")
        guard after > before else {
            print("✗ 预览没有增量更新")
            try? original.write(to: noteURL, atomically: true, encoding: .utf8)
            return 6
        }

        var snapshot: NSImage?
        var snapDone = false
        web.takeSnapshot(with: nil) { image, error in
            snapshot = image
            if let error { print("takeSnapshot 失败: \(error.localizedDescription)") }
            snapDone = true
        }
        let deadline = Date().addingTimeInterval(3)
        while !snapDone, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        if let image = snapshot {
            _ = writePNG(image, to: outputPath.replacingOccurrences(of: ".png", with: "-preview.png"))
        }
        print("✓ 预览增量更新正常")

        // 搜索界面
        model.searchText = "同步"
        spin(0.8)
        captureWindow(to: outputPath.replacingOccurrences(of: ".png", with: "-search.png"))
        model.searchText = ""

        // 反向链接：打开被引用的那篇
        if let linked = model.notes.first(where: { $0.title == "同步设计" }) {
            model.selection = linked.url
            spin(0.6)
            captureWindow(to: outputPath.replacingOccurrences(of: ".png", with: "-backlinks.png"))
        }

        // 别把演示库改脏
        try? original.write(to: noteURL, atomically: true, encoding: .utf8)
        return 0
    }

    private static func findWebView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for subview in view.subviews {
            if let found = findWebView(in: subview) { return found }
        }
        return nil
    }
}
#endif

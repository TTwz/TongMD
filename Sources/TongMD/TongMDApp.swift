import SwiftUI

@main
struct TongMDApp: App {
    @StateObject private var model = AppModel()

    init() {
        #if DEBUG
        if CommandLine.arguments.contains("--git-probe") {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gitprobe-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let git = GitEngine(token: "")
            let initResult = try? git.run(
                ["init", "--bare", "-b", "main", "p.git"], in: dir
            )
            print("init:", initResult?.code ?? -1, initResult?.error ?? "")
            let ls = try? git.lsRemote(dir.appendingPathComponent("p.git").path)
            print("ls:", ls ?? "nil")
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--window-shot"),
           CommandLine.arguments.count > index + 1 {
            let output = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
                    exit(1)
                }
                window.setFrame(NSRect(x: 120, y: 120, width: 1000, height: 720), display: true)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                let target = window.contentView?.superview ?? window.contentView
                guard let target,
                      let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else {
                    exit(1)
                }
                target.cacheDisplay(in: target.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: output))
                exit(0)
            }
        }
        if CommandLine.arguments.contains("--dump-toolbar") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                for window in NSApp.windows {
                    print("WINDOW:", window.title, window.frame)
                    for item in window.toolbar?.items ?? [] {
                        let frame = item.view?.frame ?? .zero
                        print("  ITEM:", item.itemIdentifier.rawValue, "|label=", item.label,
                              "|frame=", frame,
                              "|subviews=", item.view?.subviews.count ?? -1)
                    }
                }
                exit(0)
            }
        }
        if CommandLine.arguments.contains("--search-bench") {
            exit(SearchBench.run())
        }
        if CommandLine.arguments.contains("--dump-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let menu = NSApp.mainMenu {
                    for item in menu.items {
                        print("MENU:", item.title)
                        for sub in item.submenu?.items ?? [] {
                            let mask = sub.keyEquivalentModifierMask.rawValue
                            print("  -", sub.title, "|key=\(sub.keyEquivalent)|mask=\(mask)|action=\(String(describing: sub.action))")
                        }
                    }
                }
                exit(0)
            }
        }
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTest.run())
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
           CommandLine.arguments.count > index + 1 {
            exit(Snapshot.run(outputPath: CommandLine.arguments[index + 1]))
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        .commands { TongMDCommands(model: model) }

        MenuBarExtra("TongMD", systemImage: "square.and.pencil") {
            Button("快速记录…") { model.toggleQuickCapture() }
                .disabled(model.vaultURL == nil)
            Button("今日笔记") { model.openDailyNote() }
                .disabled(model.vaultURL == nil)
            Divider()
            Button("打开主窗口") { NSApp.activate(ignoringOtherApps: true) }
        }
    }
}

struct TongMDCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建笔记") { model.createNote() }
                .keyboardShortcut("n", modifiers: .command)
            Button("打开笔记库…") { model.pickVaultFolder() }
                .keyboardShortcut("o", modifiers: .command)
            Button("新建文本文件") { model.createNote(fileExtension: "txt") }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("新建文件夹") { model.createFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("保存") { model.saveNow() }
                .keyboardShortcut("s", modifiers: .command)
            Button("今日笔记") { model.openDailyNote() }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(model.vaultURL == nil)
            Button("快速记录…") { model.toggleQuickCapture() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(model.vaultURL == nil)
            Divider()
            Button("导出 HTML…") { model.exportHTML() }
                .disabled(model.currentNote == nil)
            Button("导出 PDF…") { model.exportPDF() }
                .disabled(model.currentNote == nil)
            Divider()
            Button("版本历史…") { model.openHistory() }
                .keyboardShortcut("y", modifiers: [.command])
                .disabled(model.vaultURL == nil)
            Button("快速切换…") { model.showQuickSwitcher = true }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(model.vaultURL == nil)
            Button("检查断链…") { model.checkBrokenLinks() }
                .disabled(model.vaultURL == nil)
            Button("整理附件到 assets/…") { model.pendingConsolidation = true }
                .disabled(model.vaultURL == nil)
            Button("关闭标签页") { model.closeActiveTab() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model.openTabs.isEmpty)
            Button("同步到 GitHub") { model.sync() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.vaultURL == nil || model.isBusy)
            Divider()
            Button("在 Finder 中显示笔记库") {
                if let url = model.vaultURL { model.revealInFinder(url) }
            }
            .disabled(model.vaultURL == nil)
        }
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { model.showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .textEditing) {
            Button("查找笔记") { model.searchFocusToken += 1 }
                .keyboardShortcut("f", modifiers: .command)
        }

        CommandMenu("视图") {
            Button("返回") { model.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.canGoBack)
            Divider()
            Picker("显示模式", selection: $model.mode) {
                ForEach(EditorMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button(model.showOutline ? "隐藏大纲" : "显示大纲") { model.showOutline.toggle() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.selection == nil)
            Divider()
            Button("放大字号") { model.increaseFontSize() }
                .keyboardShortcut("+", modifiers: .command)
            Button("缩小字号") { model.decreaseFontSize() }
                .keyboardShortcut("-", modifiers: .command)
            Button("实际大小") { model.resetFontSize() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("Markdown 速查") { model.showCheatSheet = true }
                .keyboardShortcut("/", modifiers: [.command, .shift])
        }

        CommandMenu("格式") {
            Button("粗体") { EditorActions.perform("toggleBold:") }
                .keyboardShortcut("b", modifiers: .command)
            Button("斜体") { EditorActions.perform("toggleItalic:") }
                .keyboardShortcut("i", modifiers: .command)
            Button("行内代码") { EditorActions.perform("toggleInlineCode:") }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("代码块") { EditorActions.perform("toggleCodeBlock:") }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("粘贴诊断…") { model.showPasteDiagnostics() }
            Button("插入剪贴板截图") { model.insertScreenshotFromClipboard() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Button("删除线") { EditorActions.perform("toggleStrikethrough:") }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Button("高亮") { EditorActions.perform("toggleHighlight:") }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("任务清单") { EditorActions.perform("toggleTaskList:") }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("插入表格") { EditorActions.perform("insertTable:") }
            Button("分割线") { EditorActions.perform("insertHorizontalRule:") }
            Button("链接") { EditorActions.perform("insertMarkdownLink:") }
                .keyboardShortcut("k", modifiers: .command)

            Divider()

            Button("标题 1") { EditorActions.perform("toggleHeading1:") }
                .keyboardShortcut("1", modifiers: .command)
            Button("标题 2") { EditorActions.perform("toggleHeading2:") }
                .keyboardShortcut("2", modifiers: .command)
            Button("标题 3") { EditorActions.perform("toggleHeading3:") }
                .keyboardShortcut("3", modifiers: .command)
            Button("正文") { EditorActions.perform("toggleParagraph:") }
                .keyboardShortcut("0", modifiers: [.command, .option])

            Divider()

            Button("无序列表") { EditorActions.perform("toggleBulletList:") }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("引用") { EditorActions.perform("toggleBlockquote:") }
                .keyboardShortcut("b", modifiers: [.command, .shift])
        }
    }
}

import SwiftUI

@main
struct TongMDApp: App {
    @StateObject private var model = AppModel()

    init() {
        #if DEBUG
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

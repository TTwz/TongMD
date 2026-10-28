import SwiftUI

/// 编辑区上方的格式条：解决“记不住语法”的发现性问题。
/// 按钮通过响应者链调用 MarkdownTextView 上的动作，不需要持有文本视图。
struct FormatBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            headingButton("H1", selector: "toggleHeading1:", help: "标题 1  ⌘1")
            headingButton("H2", selector: "toggleHeading2:", help: "标题 2  ⌘2")
            headingButton("H3", selector: "toggleHeading3:", help: "标题 3  ⌘3")

            divider

            iconButton("bold", selector: "toggleBold:", help: "粗体  ⌘B")
            iconButton("italic", selector: "toggleItalic:", help: "斜体  ⌘I")
            iconButton("strikethrough", selector: "toggleStrikethrough:", help: "删除线  ⇧⌘X")
            iconButton("highlighter", selector: "toggleHighlight:", help: "高亮  ⇧⌘H")
            iconButton("chevron.left.slash.chevron.right", selector: "toggleInlineCode:", help: "行内代码  ⇧⌘C")
            iconButton("link", selector: "insertMarkdownLink:", help: "链接  ⌘K")

            divider

            iconButton("list.bullet", selector: "toggleBulletList:", help: "无序列表  ⇧⌘L")
            iconButton("list.number", selector: "toggleNumberedList:", help: "有序列表")
            iconButton("checklist", selector: "toggleTaskList:", help: "任务清单  ⇧⌘T")
            iconButton("text.quote", selector: "toggleBlockquote:", help: "引用  ⇧⌘B")

            divider

            iconButton("tablecells", selector: "insertTable:", help: "插入表格")
            iconButton("minus", selector: "insertHorizontalRule:", help: "分割线")

            Spacer()

            Button { model.decreaseFontSize() } label: {
                Image(systemName: "textformat.size.smaller")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)
            .help("缩小字号 ⌘-")

            Button { model.increaseFontSize() } label: {
                Image(systemName: "textformat.size.larger")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)
            .help("放大字号 ⌘+")

            Menu {
                Button("Swift") { EditorActions.perform("insertSwiftCodeBlock:") }
                Button("Python") { EditorActions.perform("insertPythonCodeBlock:") }
                Button("JavaScript") { EditorActions.perform("insertJavaScriptCodeBlock:") }
                Button("Bash") { EditorActions.perform("insertBashCodeBlock:") }
                Button("Java") { EditorActions.perform("insertJavaCodeBlock:") }
                Button("SQL") { EditorActions.perform("insertSQLCodeBlock:") }
                Divider()
                Button("纯文本") { EditorActions.perform("toggleCodeBlock:") }
            } label: {
                Label("代码块", systemImage: "curlybraces")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("代码块  ⇧⌘K")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var divider: some View {
        Divider()
            .frame(height: 14)
            .padding(.horizontal, 6)
    }

    private func headingButton(_ title: String, selector: String, help: String) -> some View {
        Button {
            EditorActions.perform(selector)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func iconButton(_ symbol: String, selector: String, help: String) -> some View {
        Button {
            EditorActions.perform(selector)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 24, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// 通过响应者链把动作发给当前第一响应者（也就是正在编辑的 MarkdownTextView）
enum EditorActions {
    static func perform(_ selectorName: String) {
        NSApp.sendAction(Selector(selectorName), to: nil, from: nil)
    }
}

import SwiftUI

/// Markdown 速查。放菜单里，忘了就 ⌘/ 看一眼。
struct MarkdownCheatSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable {
        let id = UUID()
        let syntax: String
        let note: String
        let shortcut: String
    }

    private let rows: [Row] = [
        Row(syntax: "# 一级标题\n## 二级标题\n### 三级标题", note: "同样的快捷键再按一次取消", shortcut: "⌘1 / ⌘2 / ⌘3"),
        Row(syntax: "**粗体**", note: "也可以选中文字再按", shortcut: "⌘B"),
        Row(syntax: "*斜体*", note: "", shortcut: "⌘I"),
        Row(syntax: "`行内代码`", note: "", shortcut: "⇧⌘C"),
        Row(syntax: "```\n代码块\n```", note: "", shortcut: "⇧⌘K"),
        Row(syntax: "[链接文字](https://…)", note: "光标会自动停在网址上", shortcut: "⌘K"),
        Row(syntax: "- 列表项", note: "回车自动续行，空项目回车退出", shortcut: "⇧⌘L"),
        Row(syntax: "1. 列表项", note: "回车自动递增编号", shortcut: ""),
        Row(syntax: "> 引用", note: "回车自动续引", shortcut: "⇧⌘B"),
        Row(syntax: "---", note: "分割线", shortcut: ""),
        Row(syntax: "~~删除线~~", note: "", shortcut: ""),
        Row(syntax: "![说明](images/a.png)", note: "相对路径，图片会内联进预览", shortcut: ""),
        Row(syntax: "[[另一篇笔记]]", note: "双链，目前只做样式，还不能跳转", shortcut: "")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Markdown 速查")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        HStack(alignment: .top, spacing: 16) {
                            Text(row.syntax)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(width: 210, alignment: .leading)

                            VStack(alignment: .leading, spacing: 2) {
                                if !row.shortcut.isEmpty {
                                    Text(row.shortcut)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                if !row.note.isEmpty {
                                    Text(row.note)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 9)
                        Divider()
                    }
                }
                .padding(.horizontal, 18)
            }
        }
        .frame(width: 560, height: 540)
    }
}

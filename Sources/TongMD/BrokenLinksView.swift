import SwiftUI

/// 断链检查结果：列出哪篇笔记引用了不存在的笔记或文件
struct BrokenLinksView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("断链检查").font(.headline)
                Spacer()
                Text("\(model.brokenLinks.count) 处")
                    .font(.callout)
                    .foregroundStyle(model.brokenLinks.isEmpty ? Color.secondary : Color.orange)
            }
            .padding(14)

            Divider()

            if model.brokenLinks.isEmpty {
                ContentUnavailableView(
                    "没有发现断链",
                    systemImage: "checkmark.seal",
                    description: Text("所有 [[双链]] 和本地文件引用都能找到目标")
                )
            } else {
                List(model.brokenLinks) { link in
                    Button {
                        let target = link.note.url
                        model.showBrokenLinks = false
                        DispatchQueue.main.async { model.openNote(target) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: link.isWiki ? "link.badge.plus" : "doc.badge.ellipsis")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(link.note.title)
                                    .font(.callout)
                                    .lineLimit(1)
                                Text(link.target)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text(link.isWiki ? "双链" : "文件")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Text("双链按标题匹配，文件按相对路径匹配。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("重新检查") { model.checkBrokenLinks() }
                    .controlSize(.small)
                Button("关闭") { model.showBrokenLinks = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 500, height: 430)
    }
}

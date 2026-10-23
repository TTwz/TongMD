import SwiftUI

/// 打开中的笔记标签页。点标签切换，点 × 关闭。
struct TabBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(model.openTabs, id: \.self) { url in
                    tab(url)
                    Divider().frame(height: 15)
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 30)
        .background(.bar)
    }

    private func tab(_ url: URL) -> some View {
        let isActive = model.selection == url
        let title = url.deletingPathExtension().lastPathComponent
        let icon = url.pathExtension.lowercased() == "txt" ? "doc.plaintext" : "doc.richtext"

        return HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)

            Button {
                model.closeTab(url)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(isActive ? 1 : 0.45)
            .help("关闭标签页 ⌘W")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(isActive ? Color(nsColor: .textBackgroundColor) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.openNote(url) }
        .contextMenu {
            Button("关闭标签页") { model.closeTab(url) }
            Button("关闭其它标签页") {
                for other in model.openTabs where other != url {
                    model.closeTab(other)
                }
                model.openNote(url)
            }
        }
    }
}

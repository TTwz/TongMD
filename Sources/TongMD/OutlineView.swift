import SwiftUI

/// 文档左侧的大纲面板：列出标题，点击滚动定位，可随时隐藏
struct OutlinePane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("大纲")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.showOutline = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("隐藏大纲 ⇧⌘O")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if model.outline.isEmpty {
                        Text("这篇笔记还没有标题")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(model.outline) { item in
                            row(item)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(width: 220)
        .background(.bar)
    }

    private func row(_ item: OutlineItem) -> some View {
        let isActive = model.activeOutlineOffset == item.offset

        return Button {
            model.jumpToOutline(item)
        } label: {
            HStack(spacing: 4) {
                if item.level > 1 {
                    Spacer(minLength: 0)
                        .frame(width: CGFloat(item.level - 1) * 12)
                }
                Text(item.title)
                    .font(.system(size: 12, weight: isActive ? .medium : .regular))
                    .lineLimit(1)
                    .foregroundStyle(isActive ? .primary : (item.level == 1 ? .primary : .secondary))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
                    .padding(.horizontal, 4)
            )
            .overlay(alignment: .leading) {
                if isActive {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.accentColor)
                        .frame(width: 2, height: 14)
                        .padding(.leading, 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

import SwiftUI

struct OutlineView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if model.outline.isEmpty {
                    Text("这篇笔记还没有标题")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                } else {
                    ForEach(model.outline) { item in
                        Button {
                            model.pendingScrollRange = NSRange(location: item.offset, length: 0)
                            model.showOutline = false
                        } label: {
                            Text(item.title)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .padding(.leading, CGFloat(item.level - 1) * 12)
                                .padding(.vertical, 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(10)
        }
        .frame(width: 240, height: 320)
    }
}

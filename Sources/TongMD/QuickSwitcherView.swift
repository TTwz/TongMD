import SwiftUI

/// ⌘P：按标题模糊切换笔记
struct QuickSwitcherView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("跳转到笔记…", text: $model.quickQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit {
                        if let first = model.quickResults.first {
                            model.openQuickResult(first)
                        }
                    }
                Text("Esc 关闭")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)

            Divider()

            if model.quickResults.isEmpty {
                ContentUnavailableView("没有匹配的笔记", systemImage: "magnifyingglass")
                    .frame(maxHeight: .infinity)
            } else {
                List(model.quickResults) { note in
                    Button {
                        model.openQuickResult(note)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: note.isPlainText ? "doc.plaintext" : "doc.richtext")
                                .foregroundStyle(.secondary)
                            Text(note.title)
                                .lineLimit(1)
                            Spacer()
                            Text(note.relativePath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 520, height: 440)
        .onAppear {
            model.quickQuery = ""
            focused = true
        }
        .onExitCommand {
            model.showQuickSwitcher = false
        }
    }
}

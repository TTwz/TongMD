import SwiftUI

/// 当前笔记的 git 版本历史：左侧提交列表，右侧该版本内容
struct HistoryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                Text("版本历史")
                    .font(.headline)
                Text(model.historyNoteURL?.lastPathComponent ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.historyEntries.count) 个版本")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)

            Divider()

            if model.historyEntries.isEmpty {
                ContentUnavailableView(
                    "还没有版本记录",
                    systemImage: "clock",
                    description: Text("这篇笔记提交过之后，这里会出现历史版本。")
                )
                .frame(maxHeight: .infinity)
            } else {
                HSplitView {
                    List(selection: $model.historySelection) {
                        ForEach(model.historyEntries) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.message)
                                    .font(.callout)
                                    .lineLimit(1)
                                Text("\(entry.shortHash) · \(entry.date.formatted(date: .numeric, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                            .tag(entry.id)
                        }
                    }
                    .frame(minWidth: 250, idealWidth: 280)

                    ScrollView {
                        if model.historyLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(40)
                        } else {
                            Text(model.historyPreview)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        }
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }

            Divider()

            HStack(spacing: 8) {
                Text("恢复会用这个版本覆盖当前文件，保存后作为新提交。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { model.showHistory = false }
                Button("恢复此版本") { model.restoreSelectedVersion() }
                    .disabled(model.historySelection == nil || model.historyEntries.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 860, height: 540)
    }
}

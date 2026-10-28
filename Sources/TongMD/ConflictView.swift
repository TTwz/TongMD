import SwiftUI

/// 同步冲突：左右对比本地/远端，逐个文件选择保留哪边或手动合并
struct ConflictView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("同步冲突")
                    .font(.headline)
                Text("\(model.conflicts.count) 个文件")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("处理完点「完成并重试同步」")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)

            Divider()

            HSplitView {
                List(selection: $model.conflictIndex) {
                    ForEach(Array(model.conflicts.enumerated()), id: \.offset) { index, file in
                        HStack(spacing: 6) {
                            Image(systemName: file.resolved
                                  ? "checkmark.circle.fill"
                                  : "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(file.resolved ? Color.green : Color.orange)
                            Text(file.path)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.vertical, 2)
                        .tag(index)
                    }
                }
                .frame(minWidth: 190, idealWidth: 220)

                detail
            }

            Divider()

            HStack(spacing: 8) {
                Text("选择后会写入工作区并提交，再用 ours 策略合并远端历史。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { model.cancelConflicts() }
                Button("完成并重试同步") { model.finishConflicts() }
                    .disabled(!model.allConflictsResolved)
            }
            .padding(12)
        }
        .frame(width: 1000, height: 640)
    }

    @ViewBuilder
    private var detail: some View {
        if model.conflicts.indices.contains(model.conflictIndex) {
            let file = model.conflicts[model.conflictIndex]

            VStack(spacing: 0) {
                HStack(spacing: 1) {
                    pane(title: "本地", text: file.localText)
                    pane(title: "远端", text: file.remoteText)
                }
                .frame(maxHeight: .infinity)

                Divider()

                if model.showMergeEditor {
                    VStack(spacing: 8) {
                        TextEditor(text: $model.mergeDraft)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 140)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            )
                        HStack {
                            Text("以本地内容为起点，改成最终要保存的版本。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("取消") { model.showMergeEditor = false }
                            Button("保存合并结果") { model.saveConflictMerge() }
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(10)
                } else {
                    HStack(spacing: 8) {
                        Button("保留本地") { model.resolveConflictKeepLocal() }
                        Button("采用远端") { model.resolveConflictUseRemote() }
                        Button("手动编辑") {
                            model.mergeDraft = file.localText
                            model.showMergeEditor = true
                        }
                        Spacer()
                        if file.resolved {
                            Label("已处理", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(10)
                }
            }
        } else {
            Text("没有冲突文件")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func pane(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)

            ScrollView {
                Text(text.isEmpty ? "（空）" : text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

import SwiftUI

struct QuickCaptureView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(.secondary)
                Text("快速记录")
                    .font(.headline)
                Spacer()
                Text("回车保存，Esc 关闭")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            TextField("记点什么…", text: $model.captureText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit { model.submitCapture() }

            HStack {
                Text("保存到今日笔记的「速记」小节")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { model.dismissQuickCapture() }
                Button("保存") { model.submitCapture() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 520)
        .onAppear { focused = true }
        .onExitCommand { model.dismissQuickCapture() }
    }
}

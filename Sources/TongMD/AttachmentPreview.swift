import SwiftUI

/// 图片附件预览：点击侧栏里的图片时显示，不起编辑器
struct AttachmentPreview: View {
    let url: URL
    @EnvironmentObject private var model: AppModel

    private var references: [Note] {
        model.referencingNotes(for: url)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(24)
                } else {
                    ContentUnavailableView(
                        "无法预览这个文件",
                        systemImage: "photo",
                        description: Text(url.lastPathComponent)
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))

            Divider()
            referencesBar
            Divider()
            footer
        }
        .navigationTitle(url.lastPathComponent)
    }

    /// 被哪些笔记引用，点名字直接跳过去
    private var referencesBar: some View {
        HStack(spacing: 6) {
            if references.isEmpty {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text("没有被任何笔记引用")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: "link")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("引用：")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForEach(references.prefix(3)) { note in
                    Button(note.title) { model.openNote(note.url) }
                        .buttonStyle(.link)
                        .font(.caption2)
                        .lineLimit(1)
                }

                if references.count > 3 {
                    Menu("还有 \(references.count - 3) 篇") {
                        ForEach(Array(references.dropFirst(3))) { note in
                            Button(note.title) { model.openNote(note.url) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(.caption2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(metadata)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("在 Finder 中显示") { model.revealInFinder(url) }
                .controlSize(.small)
            Button("移到废纸篓", role: .destructive) { model.requestDeleteAttachment(url) }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var metadata: String {
        var parts: [String] = []

        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let image = NSImage(contentsOf: url) {
            parts.append("\(Int(image.size.width)) × \(Int(image.size.height))")
        }
        parts.append(url.deletingLastPathComponent().lastPathComponent)
        return parts.joined(separator: " · ")
    }
}

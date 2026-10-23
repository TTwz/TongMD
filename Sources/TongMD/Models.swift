import Foundation
import SwiftUI

struct Note: Identifiable, Hashable, Sendable {
    let url: URL
    let relativePath: String

    var id: URL { url }

    var title: String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? url.lastPathComponent : name
    }

    /// .txt 当纯文本处理：不渲染 Markdown，也不做语法高亮
    var isPlainText: Bool {
        url.pathExtension.lowercased() == "txt"
    }

    /// 侧栏图标按类型区分：Markdown 用带格式的文档，纯文本用 plaintext
    var iconName: String {
        switch url.pathExtension.lowercased() {
        case "txt": return "doc.plaintext"
        case "md", "markdown": return "doc.richtext"
        default: return "doc.text"
        }
    }

    /// 相对于笔记库的子目录，根目录下的笔记为空
    var subtitle: String {
        (relativePath as NSString).deletingLastPathComponent
    }

    init(url: URL, root: URL) {
        self.url = url
        let rootPath = root.standardizedFileURL.path
        var relative = url.standardizedFileURL.path
        if relative.hasPrefix(rootPath) {
            relative = String(relative.dropFirst(rootPath.count))
        }
        if relative.hasPrefix("/") {
            relative = String(relative.dropFirst())
        }
        self.relativePath = relative
    }
}

enum EditorMode: String, CaseIterable, Identifiable {
    case edit
    case split
    case preview

    var id: String { rawValue }

    var label: String {
        switch self {
        case .edit: return "编辑"
        case .split: return "分栏"
        case .preview: return "预览"
        }
    }

    var symbol: String {
        switch self {
        case .edit: return "square.and.pencil"
        case .split: return "rectangle.split.2x1"
        case .preview: return "doc.richtext"
        }
    }
}

enum SyncState: Equatable {
    case idle
    case running(String)
    case ok(String)
    case failed(String)

    var text: String {
        switch self {
        case .idle: return "未同步"
        case .running(let message): return message
        case .ok(let message): return message
        case .failed(let message): return message
        }
    }

    var color: Color {
        switch self {
        case .idle: return .secondary
        case .running: return .orange
        case .ok: return .green
        case .failed: return .red
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// 侧栏树节点：目录可以展开，笔记是叶子
struct VaultNode: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let relativePath: String
    var children: [VaultNode]?

    var id: URL { url }

    var title: String {
        isDirectory ? name : (url.pathExtension.isEmpty ? name : url.deletingPathExtension().lastPathComponent)
    }

    var iconName: String {
        guard !isDirectory else { return "folder" }
        switch url.pathExtension.lowercased() {
        case "txt": return "doc.plaintext"
        case "md", "markdown": return "doc.richtext"
        default: return "doc.text"
        }
    }
}

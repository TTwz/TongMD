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

    static let noteExtensions: Set<String> = ["md", "markdown", "txt"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "svg"]

    var isNote: Bool {
        !isDirectory && Self.noteExtensions.contains(url.pathExtension.lowercased())
    }

    var isImage: Bool {
        !isDirectory && Self.imageExtensions.contains(url.pathExtension.lowercased())
    }

    var iconName: String {
        guard !isDirectory else { return "folder" }
        if isImage { return "photo" }
        switch url.pathExtension.lowercased() {
        case "txt": return "doc.plaintext"
        case "md", "markdown": return "doc.richtext"
        default: return "doc.text"
        }
    }
}


/// 附件统计（非 md/txt 文件）
struct AttachmentStats: Sendable, Equatable {
    var count = 0
    var bytes: Int64 = 0
    var largestName = ""
    var largestBytes: Int64 = 0

    var isLarge: Bool { bytes > 100 * 1024 * 1024 || largestBytes > 10 * 1024 * 1024 }

    var formattedTotal: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    var formattedLargest: String { ByteCountFormatter.string(fromByteCount: largestBytes, countStyle: .file) }
}


extension Notification.Name {
    static let tongmdPasteFailed = Notification.Name("dev.tong.TongMD.pasteFailed")
}


struct BrokenLink: Identifiable {
    let id = UUID()
    let note: Note
    let target: String
    let isWiki: Bool
}


struct Backlink: Identifiable {
    let id = UUID()
    let note: Note
    /// 引用所在的那一行（用于展示上下文）
    let excerpt: String
    /// 该行在笔记里的字符偏移，点击后跳过去
    let offset: Int
}


struct TagCount: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let count: Int
}


struct FileVersion: Identifiable, Equatable {
    let id: String
    let date: Date
    let message: String

    var shortHash: String { String(id.prefix(7)) }
}


struct ConflictFile: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let localText: String
    let remoteText: String
    var resolved: Bool = false
    /// nil 表示保留本地、不写文件
    var finalText: String?
}


struct VisibleNode: Identifiable {
    var id: URL { node.url }
    let node: VaultNode
    let depth: Int
}

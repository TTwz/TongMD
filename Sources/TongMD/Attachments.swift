import AppKit
import Foundation

/// 附件落盘：统一走这里，编辑器和菜单入口共用
enum AttachmentStore {
    /// 保存到指定目录下的 assets/，返回文件 URL
    static func save(data: Data, name: String, ext: String = "png", into directory: URL) -> URL? {
        let assets = directory.appendingPathComponent("assets", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        // 内容去重：同一张图已经在 assets/ 里就直接复用，不再复制一份
        if let existing = existingFile(matching: data, ext: ext, in: assets) {
            return existing
        }

        let safeName = sanitize(name)
        var fileURL = assets.appendingPathComponent("\(safeName).\(ext)")
        var index = 2
        while FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = assets.appendingPathComponent("\(safeName)-\(index).\(ext)")
            index += 1
        }

        do {
            try data.write(to: fileURL)
        } catch {
            return nil
        }
        return fileURL
    }

    /// 在 assets/ 里找内容完全相同的文件（先比大小，再比字节）
    static func existingFile(matching data: Data, ext: String, in assets: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: assets,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for file in files where file.pathExtension.lowercased() == ext.lowercased() {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size == data.count else { continue }
            if (try? Data(contentsOf: file)) == data {
                return file
            }
        }
        return nil
    }

    /// 从 directory 到 file 的相对路径，例如 ../../assets/x.png
    static func relativePath(from directory: URL, to file: URL) -> String {
        let from = directory.standardizedFileURL.pathComponents
        let to = file.standardizedFileURL.pathComponents
        var index = 0
        while index < min(from.count, to.count), from[index] == to[index] {
            index += 1
        }
        let ups = Array(repeating: "..", count: from.count - index)
        let downs = Array(to[index...])
        return (ups + downs).joined(separator: "/")
    }

    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_"))
            .union(.init(charactersIn: "·"))
        var result = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        while result.contains("--") { result = result.replacingOccurrences(of: "--", with: "-") }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        return result.isEmpty ? "image" : result
    }
}

/// 从剪贴板取图片：覆盖 macOS 截图的裸 TIFF、PNG/JPEG 以及延迟加载的图片
enum ImageClipboard {
    static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, .init("public.jpeg"), .init("public.heic")
    ] + NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"]

    static func imageFileURL(from pasteboard: NSPasteboard) -> URL? {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        return urls?.first { imageExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// 菜单校验只看类型，不在每次刷新菜单时解码整张截图。
    static func containsImage(in pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: imageTypes) != nil || imageFileURL(from: pasteboard) != nil
    }

    static func pngData(from pasteboard: NSPasteboard = .general) -> Data? {
        for type in imageTypes {
            if let data = pasteboard.data(forType: type),
               let rep = NSBitmapImageRep(data: data),
               let png = rep.representation(using: .png, properties: [:]) {
                return png
            }
        }

        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }

        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        return nil
    }
}

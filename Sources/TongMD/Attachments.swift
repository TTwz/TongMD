import AppKit
import Foundation

/// 附件落盘：统一走这里，编辑器和菜单入口共用
enum AttachmentStore {
    /// 返回相对路径（如 assets/截屏.png），失败返回 nil
    static func save(data: Data, name: String, ext: String = "png", into directory: URL) -> String? {
        let assets = directory.appendingPathComponent("assets", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        } catch {
            return nil
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
        return "assets/\(fileURL.lastPathComponent)"
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
    static func pngData(from pasteboard: NSPasteboard = .general) -> Data? {
        let types: [NSPasteboard.PasteboardType] = [
            .png, .tiff, .init("public.jpeg"), .init("public.heic")
        ]
        for type in types {
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

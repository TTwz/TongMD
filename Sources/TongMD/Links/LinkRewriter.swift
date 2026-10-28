import Foundation

/// 重命名/移动时改写链接，保证引用不断。
///
/// - `[[笔记名]]` / `[[笔记名|别名]]` / `[[笔记名#小节]]`：按标题改写
/// - `[文字](相对路径)` / `![说明](相对路径)`：按文件路径改写
enum LinkRewriter {
    static let markdownPattern = #"(!?)\[([^\]\n]*)\]\(([^)\s]+)\)"#

    // MARK: - Wiki 链接

    static func rewriteWikiLinks(in text: String, from oldTitle: String, to newTitle: String) -> String {
        guard !oldTitle.isEmpty, oldTitle != newTitle,
              let regex = try? NSRegularExpression(pattern: WikiLinks.pattern) else { return text }

        let ns = text as NSString
        var result = text

        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let targetRange = match.range(at: 1)
            let rawTarget = ns.substring(with: targetRange)

            let pieces = rawTarget.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let base = String(pieces[0]).trimmingCharacters(in: .whitespaces)
            let heading = pieces.count > 1 ? "#" + String(pieces[1]) : ""

            let last = (base as NSString).lastPathComponent
            guard last.caseInsensitiveCompare(oldTitle) == .orderedSame
                    || base.caseInsensitiveCompare(oldTitle) == .orderedSame else { continue }

            // 保留 `项目/` 这类前缀
            let prefix = base.hasSuffix(last) ? String(base.dropLast(last.count)) : ""
            result = (result as NSString).replacingCharacters(
                in: targetRange,
                with: prefix + newTitle + heading
            )
        }
        return result
    }

    // MARK: - 相对路径链接

    /// - Parameters:
    ///   - oldNotePath: 改写前笔记的路径
    ///   - newNotePath: 改写后笔记的路径（同一篇未移动就传一样的）
    ///   - moves: 旧绝对路径 -> 新绝对路径
    static func rewriteRelativeLinks(
        in text: String,
        oldNotePath: URL,
        newNotePath: URL,
        moves: [String: String]
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: markdownPattern) else { return text }

        let oldDirectory = oldNotePath.deletingLastPathComponent().standardizedFileURL
        let newDirectory = newNotePath.deletingLastPathComponent().standardizedFileURL
        let noteMoved = oldDirectory.path != newDirectory.path

        let ns = text as NSString
        var result = text

        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let sourceRange = match.range(at: 3)
            let rawSource = ns.substring(with: sourceRange)
            let trimmed = rawSource.trimmingCharacters(in: .whitespaces)

            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("http") || trimmed.hasPrefix("https")
                || trimmed.hasPrefix("mailto:") || trimmed.hasPrefix("data:")
                || trimmed.hasPrefix("tel:") || trimmed.hasPrefix("#")
                || trimmed.hasPrefix("/") { continue }

            // 拆掉锚点，改完再拼回去
            let hashIndex = trimmed.firstIndex(of: "#")
            let pathPart = hashIndex.map { String(trimmed[..<$0]) } ?? trimmed
            let fragment = hashIndex.map { String(trimmed[$0...]) } ?? ""
            guard !pathPart.isEmpty else { continue }

            let decoded = pathPart.removingPercentEncoding ?? pathPart
            let absolute = oldDirectory.appendingPathComponent(decoded).standardizedFileURL
            let newAbsolute = moves[absolute.path].map { URL(fileURLWithPath: $0).standardizedFileURL }

            // 笔记没动、目标也没动，就不用改
            if !noteMoved, newAbsolute == nil { continue }

            let destination = newAbsolute ?? absolute
            let relative = AttachmentStore.relativePath(from: newDirectory, to: destination)
            let replacement = relative + fragment
            if replacement != rawSource {
                result = (result as NSString).replacingCharacters(in: sourceRange, with: replacement)
            }
        }
        return result
    }

    /// 组合改写
    static func rewrite(
        in text: String,
        oldNotePath: URL,
        newNotePath: URL,
        moves: [String: String],
        titleChange: (old: String, new: String)? = nil
    ) -> String {
        var output = text
        if let titleChange {
            output = rewriteWikiLinks(in: output, from: titleChange.old, to: titleChange.new)
        }
        output = rewriteRelativeLinks(
            in: output,
            oldNotePath: oldNotePath,
            newNotePath: newNotePath,
            moves: moves
        )
        return output
    }

    /// 取出正文里所有本地链接目标（用于断链检查）
    static func localLinkTargets(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: markdownPattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 3)) }
            .filter {
                !$0.hasPrefix("http") && !$0.hasPrefix("mailto:")
                    && !$0.hasPrefix("data:") && !$0.hasPrefix("#")
                    && !$0.hasPrefix("tel:") && !$0.hasPrefix("/")
            }
    }
}

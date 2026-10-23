import Foundation

/// `[[目标]]` / `[[目标|显示文字]]` 的解析与匹配。
enum WikiLinks {

    static let pattern = #"\[\[([^\]|\n]+)(?:\|([^\]\n]+))?\]\]"#

    /// 取出所有链接目标（不含显示文字）
    static func targets(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex
            .matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces) }
    }

    /// 这篇文本是否引用了目标笔记。允许写路径（`项目/同步设计`）或只写文件名。
    static func refers(_ text: String, to title: String) -> Bool {
        let needle = title.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return false }
        return targets(in: text).contains { target in
            if target.caseInsensitiveCompare(needle) == .orderedSame { return true }
            let last = (target as NSString).lastPathComponent
            if last.caseInsensitiveCompare(needle) == .orderedSame { return true }
            return false
        }
    }
}

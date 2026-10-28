import Foundation

/// 解析正文里的 `#标签`。跳过围栏代码、行内代码、Markdown 标题和 URL 锚点。
enum TagParser {
    static func tags(in text: String) -> [String] {
        var stripped = text
        stripped = stripped.replacingOccurrences(
            of: "```[\\s\\S]*?```", with: " ", options: .regularExpression
        )
        stripped = stripped.replacingOccurrences(
            of: "`[^`\\n]+`", with: " ", options: .regularExpression
        )

        guard let regex = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}_&/])#([\p{L}\p{N}_-]{1,30})"#
        ) else { return [] }

        let ns = stripped as NSString
        var seen = Set<String>()
        var result: [String] = []
        for match in regex.matches(in: stripped, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range(at: 1))
            if seen.insert(tag.lowercased()).inserted {
                result.append(tag)
            }
        }
        return result
    }
}

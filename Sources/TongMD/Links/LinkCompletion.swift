import Foundation

/// `[[` 补全：判断光标是否在未闭合的双链里，并给出候选标题
enum LinkCompletion {
    struct Suggestion {
        /// 替换范围：`[[` 之后到光标
        let range: NSRange
        /// 已输入的部分
        let partial: String
        /// 候选标题（不含 `]]`）
        let items: [String]
    }

    static func suggestion(text: String, caret: Int, titles: [String]) -> Suggestion? {
        let ns = text as NSString
        guard caret >= 0, caret <= ns.length else { return nil }

        let prefix = ns.substring(to: caret)
        let afterOpen = ns.range(of: "[[", options: .backwards, range: NSRange(location: 0, length: caret))
        guard afterOpen.location != NSNotFound else { return nil }

        let start = afterOpen.location + 2
        let length = caret - start
        guard length >= 0 else { return nil }

        let partial = ns.substring(with: NSRange(location: start, length: length))
        // 已经闭合、换了行、或者在写别名，就不补全
        guard !partial.contains("]]"), !partial.contains("\n"), !partial.contains("|") else { return nil }
        if prefix.hasSuffix("]]") { return nil }

        let trimmed = partial.trimmingCharacters(in: .whitespaces)
        var matches = titles
        if !trimmed.isEmpty {
            matches = titles.filter { $0.localizedCaseInsensitiveContains(trimmed) }
            matches.sort { lhs, rhs in
                let l = lhs.lowercased().hasPrefix(trimmed.lowercased())
                let r = rhs.lowercased().hasPrefix(trimmed.lowercased())
                if l != r { return l }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        }

        guard !matches.isEmpty else { return nil }
        return Suggestion(
            range: NSRange(location: start, length: length),
            partial: partial,
            items: Array(matches.prefix(20))
        )
    }
}

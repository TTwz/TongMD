import Foundation

struct SearchResult: Identifiable, Sendable {
    let note: Note
    let score: Int
    let matches: Int
    let snippet: String

    var id: URL { note.url }
}

/// 内存全文检索。
///
/// 为什么不用 FTS5：中文分词才是一等公民。`unicode61` 不分中文词，`trigram` 又要求
/// 至少 3 个字，"同步"这种两字词直接搜不到。笔记库通常就几 MB，直接对内存里的文本做
/// 大小写不敏感的匹配，语义精确（任意长度、任意语言），几十毫秒内出结果。
enum SearchEngine {

    static func terms(from query: String) -> [String] {
        query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// 多关键词是 AND 关系；标题命中加权，命中次数多的排前面。
    static func search(query: String, in documents: [(note: Note, text: String)]) -> [SearchResult] {
        let keywords = terms(from: query)
        guard !keywords.isEmpty else { return [] }

        var results: [SearchResult] = []

        for document in documents {
            var total = 0
            var firstMatchOffset = -1
            var allFound = true

            for keyword in keywords {
                let count = occurrences(of: keyword, in: document.text)
                if count == 0 {
                    allFound = false
                    break
                }
                total += count
                if firstMatchOffset < 0,
                   let range = document.text.range(of: keyword, options: .caseInsensitive) {
                    firstMatchOffset = document.text.distance(
                        from: document.text.startIndex,
                        to: range.lowerBound
                    )
                }
            }

            guard allFound else { continue }

            var score = total
            if keywords.contains(where: {
                document.note.title.range(of: $0, options: .caseInsensitive) != nil
            }) {
                score += 50
            }
            if keywords.contains(where: {
                document.note.relativePath.range(of: $0, options: .caseInsensitive) != nil
            }) {
                score += 10
            }

            results.append(SearchResult(
                note: document.note,
                score: score,
                matches: total,
                snippet: snippet(from: document.text, around: max(0, firstMatchOffset))
            ))
        }

        return results.sorted {
            $0.score == $1.score
                ? $0.note.relativePath.localizedStandardCompare($1.note.relativePath) == .orderedAscending
                : $0.score > $1.score
        }
    }

    static func occurrences(of keyword: String, in text: String) -> Int {
        guard !keyword.isEmpty else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: keyword, options: .caseInsensitive, range: searchRange) {
            count += 1
            guard found.upperBound < text.endIndex else { break }
            searchRange = found.upperBound..<text.endIndex
        }
        return count
    }

    /// 截取命中位置附近的文字，压平换行并去掉行首的 Markdown 记号
    static func snippet(from text: String, around offset: Int, radius: Int = 26) -> String {
        let characters = Array(text)
        guard !characters.isEmpty else { return "" }

        let center = min(max(0, offset), characters.count - 1)
        let start = max(0, center - radius)
        let end = min(characters.count, center + radius * 2)

        var slice = String(characters[start..<end])
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        // 片段是给列表看的，把 Markdown 记号压掉，避免出现 “### 代码 ```swift” 这种噪音
        slice = slice.replacingOccurrences(of: #"[#>*`_~]+"#, with: " ", options: .regularExpression)
        slice = slice.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        slice = slice.trimmingCharacters(in: .whitespaces)

        let prefix = start > 0 ? "…" : ""
        let suffix = end < characters.count ? "…" : ""
        return prefix + slice.trimmingCharacters(in: .whitespaces) + suffix
    }
}

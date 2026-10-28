import Foundation

/// 标题模糊匹配：子序列命中，连续/词首有加分，标题越短越靠前
enum FuzzyMatch {
    static func score(_ query: String, in candidate: String) -> Int? {
        let needle = Array(query.lowercased())
        guard !needle.isEmpty else { return 0 }

        let haystack = Array(candidate.lowercased())
        var queryIndex = 0
        var score = 0
        var lastMatch = -2
        var firstMatch = -1

        for (index, character) in haystack.enumerated() {
            guard queryIndex < needle.count, character == needle[queryIndex] else { continue }
            if firstMatch < 0 { firstMatch = index }
            score += 1
            if index == lastMatch + 1 { score += 2 }
            if index == 0 || [" ", "/", "-", "_"].contains(haystack[index - 1]) { score += 3 }
            lastMatch = index
            queryIndex += 1
        }

        guard queryIndex == needle.count else { return nil }
        if firstMatch == 0 { score += 4 }
        return score - haystack.count / 8
    }

    static func ranked(_ query: String, candidates: [String]) -> [String] {
        candidates
            .compactMap { candidate -> (String, Int)? in
                guard let value = score(query, in: candidate) else { return nil }
                return (candidate, value)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

import Foundation

/// 搜索语法：`tag:知识库 folder:项目 before:2026-01-01 after:2025-01-01 关键词`
struct SearchQuery {
    var terms: [String] = []
    var tags: [String] = []
    var folders: [String] = []
    var before: Date?
    var after: Date?

    var isEmpty: Bool {
        terms.isEmpty && tags.isEmpty && folders.isEmpty && before == nil && after == nil
    }

    static func parse(_ raw: String) -> SearchQuery {
        var query = SearchQuery()
        for rawToken in raw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let token = String(rawToken)
            if let value = dropPrefix(token, "tag:") {
                query.tags.append(value.lowercased())
            } else if let value = dropPrefix(token, "folder:") {
                query.folders.append(value.lowercased())
            } else if let value = dropPrefix(token, "before:") {
                query.before = parseDate(value)
            } else if let value = dropPrefix(token, "after:") {
                query.after = parseDate(value)
            } else if !token.isEmpty {
                query.terms.append(token)
            }
        }
        return query
    }

    private static func dropPrefix(_ token: String, _ prefix: String) -> String? {
        guard token.lowercased().hasPrefix(prefix) else { return nil }
        let value = String(token.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return value.isEmpty ? nil : value
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}

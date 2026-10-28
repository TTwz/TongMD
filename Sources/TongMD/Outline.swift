import Foundation

struct OutlineItem: Identifiable, Equatable {
    let id: Int
    let level: Int
    let title: String
    /// 标题所在行的字符偏移，用于滚动定位
    let offset: Int
}

enum Outline {
    static func items(in text: String) -> [OutlineItem] {
        var result: [OutlineItem] = []
        var offset = 0
        var inFence = false

        for line in text.components(separatedBy: "\n") {
            defer { offset += (line as NSString).length + 1 }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            guard !inFence else { continue }

            var level = 0
            for character in trimmed {
                if character == "#" { level += 1 } else { break }
            }
            guard (1...6).contains(level) else { continue }
            let rest = trimmed.dropFirst(level)
            guard rest.isEmpty || rest.first == " " else { continue }

            let title = rest.trimmingCharacters(in: .whitespaces)
            result.append(OutlineItem(
                id: offset,
                level: level,
                title: title.isEmpty ? "（无标题）" : title,
                offset: offset
            ))
        }
        return result
    }
}

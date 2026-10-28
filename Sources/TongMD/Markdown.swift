import Foundation

/// 极简 Markdown 渲染器。MVP 够用：标题、段落、列表、引用、代码块、行内样式、图片、链接、分割线。
/// 需要更完整的语法时再换 swift-markdown，接口保持不变即可。
enum Markdown {

    /// 只产出 body 片段：编辑时用它做增量替换，避免整页重载
    static func body(from markdown: String, baseDirectory: URL?) -> String {
        var html = render(markdown)
        if let base = baseDirectory {
            html = inlineLocalImages(html, base: base)
        }
        return html
    }

    /// .txt 的预览：不做任何 Markdown 解析，按原文呈现（保留空行和缩进）
    static func plainBody(_ text: String) -> String {
        "<pre class=\"plain\">\(escape(text))</pre>"
    }

    /// 完整文档：只在首次加载或切换笔记时用
    static func document(body: String, fontSize: CGFloat = 16) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>:root { --base: \(Int(fontSize.rounded()))px }\(css)</style></head>
        <body>\(body)</body>
        <script>
        document.addEventListener('click', function (event) {
            var button = event.target && event.target.closest ? event.target.closest('.copy') : null;
            if (!button) { return; }
            var block = button.closest('.code-block');
            var code = block ? block.querySelector('pre code') : null;
            if (!code) { return; }
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tongmd) {
                window.webkit.messageHandlers.tongmd.postMessage({ type: 'copyCode', text: code.innerText });
            }
            button.textContent = '已复制';
            setTimeout(function () { button.textContent = '复制'; }, 1200);
        });

        document.addEventListener('change', function (event) {
            var target = event.target;
            if (!target || !target.matches || !target.matches('input[data-task]')) { return; }
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tongmd) {
                window.webkit.messageHandlers.tongmd.postMessage({
                    type: 'toggleTask',
                    line: parseInt(target.dataset.line, 10),
                    checked: target.checked
                });
            }
        });
        </script>
        </html>
        """
    }

    static func document(from markdown: String, baseDirectory: URL?, fontSize: CGFloat = 16) -> String {
        document(body: body(from: markdown, baseDirectory: baseDirectory), fontSize: fontSize)
    }

    // MARK: - 块级

    static func render(_ markdown: String) -> String {
        let normalized = preprocess(markdown)
        let lines = normalized.components(separatedBy: "\n")

        var out: [String] = []
        var paragraph: [String] = []
        var listTag: String?
        var footnotes: [(id: String, text: String)] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append("<p>" + paragraph.map { inline($0) }.joined(separator: "<br>") + "</p>")
            paragraph.removeAll()
        }
        func closeList() {
            if let tag = listTag {
                out.append("</\(tag)>")
                listTag = nil
            }
        }

        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // 代码块
            if line.hasPrefix("```") {
                flushParagraph()
                closeList()
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                let cls = lang.isEmpty ? "" : #" class="language-\#(escape(lang))""#
                let highlighted = highlightedCode(code.joined(separator: "\n"), language: lang)
                out.append(
                    "<div class=\"code-block\"><button class=\"copy\" type=\"button\">复制</button>" +
                    "<pre><code\(cls)>\(highlighted)</code></pre></div>"
                )
                continue
            }

            if line.isEmpty {
                flushParagraph()
                closeList()
                i += 1
                continue
            }

            if let level = headingLevel(line) {
                flushParagraph()
                closeList()
                let content = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                out.append("<h\(level)>\(inline(content))</h\(level)>")
                i += 1
                continue
            }

            if isRule(line) {
                flushParagraph()
                closeList()
                out.append("<hr>")
                i += 1
                continue
            }

            if line.hasPrefix(">") {
                flushParagraph()
                closeList()
                var quote: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quote.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out.append("<blockquote>" + quote.map { inline($0) }.joined(separator: "<br>") + "</blockquote>")
                continue
            }

            if let definition = footnoteDefinition(line) {
                flushParagraph()
                closeList()
                footnotes.append(definition)
                i += 1
                continue
            }

            // 表格：当前行含 |，下一行是分隔行
            if line.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                closeList()

                let header = tableCells(line)
                let alignments = tableAlignments(lines[i + 1], columns: header.count)
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count {
                    let candidate = lines[j].trimmingCharacters(in: .whitespaces)
                    guard !candidate.isEmpty, candidate.contains("|") else { break }
                    rows.append(tableCells(candidate))
                    j += 1
                }

                func style(_ index: Int) -> String {
                    guard index < alignments.count, let align = alignments[index] else { return "" }
                    return #" style="text-align:\#(align)""#
                }

                var table = "<table><thead><tr>"
                table += header.enumerated().map { "<th\(style($0.offset))>" + inline($0.element) + "</th>" }.joined()
                table += "</tr></thead><tbody>"
                for row in rows {
                    table += "<tr>" + row.enumerated().map { "<td\(style($0.offset))>" + inline($0.element) + "</td>" }.joined() + "</tr>"
                }
                table += "</tbody></table>"
                out.append(table)
                i = j
                continue
            }

            if let item = listItem(line) {
                flushParagraph()
                if listTag != item.tag {
                    closeList()
                    out.append("<\(item.tag)>")
                    listTag = item.tag
                }

                if let task = taskItem(item.text) {
                    out.append(
                        "<li class=\"task\"><input type=\"checkbox\" data-task=\"1\" " +
                        "data-line=\"\(i)\"\(task.checked ? " checked" : "")> " +
                        inline(task.text) + "</li>"
                    )
                } else {
                    out.append("<li>" + inline(item.text) + "</li>")
                }
                i += 1
                continue
            }

            paragraph.append(line)
            i += 1
        }

        flushParagraph()
        closeList()

        if !footnotes.isEmpty {
            var section = "<section class=\"footnotes\"><hr><ol>"
            for note in footnotes {
                let id = escape(note.id)
                section += "<li id=\"fn-\(id)\">" + inline(note.text)
                section += " <a href=\"#fnref-\(id)\">↩</a></li>"
            }
            section += "</ol></section>"
            out.append(section)
        }

        return out.joined(separator: "\n")
    }

    /// 粘进来的内容经常是从 JIRA / 需求系统复制的：行与行之间是字面量 `<br>`，
    /// 空格是 `&nbsp;`。直接转义会把这些标签原样显示出来，所以先做一层归一化。
    /// 代码段（围栏和行内）整段保护起来，里面写 `<br>` 要保持字面量。
    static func preprocess(_ markdown: String) -> String {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        var protected: [String] = []

        func protect(_ pattern: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return }
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                let original = ns.substring(with: match.range)
                protected.append(original)
                let token = "\u{1}PROTECTED\(protected.count - 1)\u{1}"
                text = (text as NSString).replacingCharacters(in: match.range, with: token)
            }
        }

        protect("```[\\s\\S]*?```")   // 围栏代码块
        protect("`[^`\n]+`")             // 行内代码

        // <br> / <br/> / <br /> → 换行
        text = text.replacingOccurrences(
            of: #"<br\s*/?>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )

        // 段落标签
        text = text.replacingOccurrences(
            of: #"</p\s*>"#,
            with: "\n\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: #"<p(\s[^>]*)?>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // 常见实体（&amp; 放最后，避免把别的实体二次解码）
        let entities = [
            ("&nbsp;", " "),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&amp;", "&")
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }

        for (index, original) in protected.enumerated().reversed() {
            text = text.replacingOccurrences(of: "\u{1}PROTECTED\(index)\u{1}", with: original)
        }
        return text
    }

    static func headingLevel(_ line: String) -> Int? {
        var count = 0
        for ch in line {
            if ch == "#" { count += 1 } else { break }
        }
        guard (1...6).contains(count) else { return nil }
        let rest = line.dropFirst(count)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return count
    }

    static func isRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" } || stripped.allSatisfy { $0 == "_" }
    }

    static func listItem(_ line: String) -> (tag: String, text: String)? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return ("ul", String(line.dropFirst(prefix.count)))
        }
        if let range = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            return ("ol", String(line[range.upperBound...]))
        }
        return nil
    }

    static func taskItem(_ text: String) -> (checked: Bool, text: String)? {
        guard text.count >= 4 else { return nil }
        let prefix = text.prefix(4)
        guard prefix.hasPrefix("["), prefix.hasSuffix("] ") else { return nil }
        let mark = prefix.dropFirst().first
        guard mark == " " || mark == "x" || mark == "X" else { return nil }
        return (mark == "x" || mark == "X", String(text.dropFirst(4)))
    }

    /// 把任务行的 [ ] / [x] 改成指定状态；不是任务行返回 nil
    static func toggledTaskLine(_ line: String, checked: Bool) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"^(\s*(?:[-*+]|\d+[.)])\s+)\[([ xX])\]"#
        ) else { return nil }
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let replacement = ns.substring(with: match.range(at: 1)) + (checked ? "[x]" : "[ ]")
        return ns.replacingCharacters(in: match.range, with: replacement)
    }

    static func footnoteDefinition(_ line: String) -> (id: String, text: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"^\[\^([^\]\n]+)\]:\s*(.*)$"#) else { return nil }
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return (ns.substring(with: match.range(at: 1)), ns.substring(with: match.range(at: 2)))
    }

    static func tableAlignments(_ line: String, columns: Int) -> [String?] {
        let cells = tableCells(line)
        return (0..<columns).map { index in
            guard index < cells.count else { return nil }
            let cell = cells[index].trimmingCharacters(in: .whitespaces)
            let left = cell.hasPrefix(":")
            let right = cell.hasSuffix(":")
            if left && right { return "center" }
            if right { return "right" }
            if left { return "left" }
            return nil
        }
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return false }
        let allowed = CharacterSet(charactersIn: "|:- \t")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func tableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }

        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in trimmed {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: - 行内

    static func inline(_ raw: String) -> String {
        var text = escape(raw)
        var codes: [String] = []

        // 行内代码先抽出来占位，避免里面的 * _ 被当成样式
        if let re = try? NSRegularExpression(pattern: "\u{60}([^\u{60}]+)\u{60}") {
            let ns = text as NSString
            let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for (index, match) in matches.enumerated().reversed() {
                let code = ns.substring(with: match.range(at: 1))
                // 反向遍历，必须插到 0：否则 index 会超过数组当前长度
                codes.insert("<code>\(code)</code>", at: 0)
                text = (text as NSString).replacingCharacters(in: match.range, with: "\u{1}\(index)\u{1}")
            }
        }

        text = sub(#"!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#, #"<img src="$2" alt="$1">"#, text)
        text = sub(#"\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#, #"<a href="$2">$1</a>"#, text)
        text = wikiLinks(text)
        text = sub(#"(?<![\w"'=])(https?://[^\s<]+)"#, #"<a href="$1">$1</a>"#, text)
        text = sub(#"\*\*([^*\n]+)\*\*"#, #"<strong>$1</strong>"#, text)
        text = sub(#"__([^_\n]+)__"#, #"<strong>$1</strong>"#, text)
        text = sub(#"\*([^*\n]+)\*"#, #"<em>$1</em>"#, text)
        text = sub(#"~~([^~\n]+)~~"#, #"<del>$1</del>"#, text)
        text = sub(#"==([^=\n]+)=="#, #"<mark>$1</mark>"#, text)
        text = sub(
            #"\[\^([^\]\n]+)\]"#,
            "<sup class=\"fn\" id=\"fnref-$1\"><a href=\"#fn-$1\">$1</a></sup>",
            text
        )

        for (index, html) in codes.enumerated() {
            text = text.replacingOccurrences(of: "\u{1}\(index)\u{1}", with: html)
        }
        return text
    }

    static func escape(_ raw: String) -> String {
        var out = raw.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        return out
    }

    /// [[目标]] / [[目标|显示文字]] → 可点击的 app 内部链接
    static func wikiLinks(_ input: String) -> String {
        guard let re = try? NSRegularExpression(pattern: WikiLinks.pattern) else { return input }
        let ns = input as NSString
        let matches = re.matches(in: input, range: NSRange(location: 0, length: ns.length))
        var result = input

        for match in matches.reversed() {
            let target = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let display = match.range(at: 2).location == NSNotFound
                ? target
                : ns.substring(with: match.range(at: 2))
            let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? target
            // display 在进到这里之前已经做过 HTML 转义
            let replacement = #"<a class="wiki" href="tongmd://note?name=\#(encoded)">\#(display)</a>"#
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }

    static func sub(_ pattern: String, _ template: String, _ input: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return re.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: template)
    }


    // MARK: - 代码块高亮

    private struct CodeSpec {
        let comment: String?
        let keywords: [String]
    }

    private static let codeSpecs: [String: CodeSpec] = [
        "swift": CodeSpec(
            comment: #"//[^\n]*|/\*[\s\S]*?\*/"#,
            keywords: ["func", "let", "var", "if", "else", "guard", "return", "struct", "class",
                       "enum", "protocol", "extension", "import", "for", "in", "while", "switch",
                       "case", "default", "try", "catch", "throw", "throws", "async", "await",
                       "some", "any", "init", "deinit", "self", "super", "nil", "true", "false",
                       "public", "private", "internal", "static", "final", "where", "as", "is"]
        ),
        "js": CodeSpec(
            comment: #"//[^\n]*|/\*[\s\S]*?\*/"#,
            keywords: ["const", "let", "var", "function", "return", "if", "else", "for", "while",
                       "class", "new", "import", "export", "from", "await", "async", "try",
                       "catch", "throw", "typeof", "instanceof", "null", "undefined", "true", "false"]
        ),
        "ts": CodeSpec(
            comment: #"//[^\n]*|/\*[\s\S]*?\*/"#,
            keywords: ["const", "let", "var", "function", "return", "if", "else", "for", "while",
                       "class", "interface", "type", "enum", "import", "export", "from", "await",
                       "async", "try", "catch", "throw", "null", "undefined", "true", "false"]
        ),
        "python": CodeSpec(
            comment: #"#[^\n]*"#,
            keywords: ["def", "class", "return", "if", "elif", "else", "for", "while", "in",
                       "import", "from", "as", "try", "except", "finally", "raise", "with",
                       "lambda", "yield", "async", "await", "None", "True", "False", "self"]
        ),
        "bash": CodeSpec(
            comment: #"#[^\n]*"#,
            keywords: ["if", "then", "else", "elif", "fi", "for", "do", "done", "while", "function",
                       "return", "export", "local", "echo", "cd", "source"]
        ),
        "json": CodeSpec(
            comment: nil,
            keywords: ["true", "false", "null"]
        ),
        "java": CodeSpec(
            comment: #"//[^\n]*|/\*[\s\S]*?\*/"#,
            keywords: ["public", "private", "protected", "class", "interface", "enum", "record",
                       "extends", "implements", "static", "final", "abstract", "void", "int",
                       "long", "double", "float", "boolean", "char", "String", "var", "new",
                       "return", "if", "else", "for", "while", "do", "switch", "case", "default",
                       "break", "continue", "try", "catch", "finally", "throw", "throws",
                       "import", "package", "this", "super", "null", "true", "false",
                       "instanceof", "synchronized", "volatile", "transient", "sealed", "permits"]
        ),
        "sql": CodeSpec(
            comment: #"--[^\n]*|/\*[\s\S]*?\*/"#,
            keywords: ["select", "from", "where", "insert", "into", "values", "update", "set",
                       "delete", "create", "table", "alter", "drop", "index", "join", "left",
                       "right", "inner", "outer", "on", "group", "by", "order", "having", "limit",
                       "offset", "and", "or", "not", "null", "is", "in", "as", "distinct",
                       "count", "sum", "avg", "min", "max", "union", "all", "case", "when",
                       "then", "else", "end", "primary", "key", "foreign", "references",
                       "default", "asc", "desc", "with", "exists", "between", "like"]
        )
    ]

    /// 轻量代码高亮：只处理注释、字符串、数字、关键字；未知语言原样转义
    static func highlightedCode(_ code: String, language: String) -> String {
        let lang = language.lowercased()
        let normalized: String
        switch lang {
        case "javascript": normalized = "js"
        case "typescript": normalized = "ts"
        case "py": normalized = "python"
        case "sh", "zsh", "shell": normalized = "bash"
        case "mysql", "postgres", "postgresql": normalized = "sql"
        default: normalized = lang
        }

        guard let spec = codeSpecs[normalized] else { return escape(code) }

        let stringPattern = #""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'"#
        let numberPattern = #"\b\d+(?:\.\d+)?\b"#
        let keywordPattern = "\\b(?:" + spec.keywords.joined(separator: "|") + ")\\b"

        var alternatives: [String] = []
        alternatives.append(spec.comment.map { "(" + $0 + ")" } ?? "(?!)")
        alternatives.append("(" + stringPattern + ")")
        alternatives.append("(" + numberPattern + ")")
        alternatives.append("(" + keywordPattern + ")")

        guard let regex = try? NSRegularExpression(
            pattern: alternatives.joined(separator: "|"),
            options: [.anchorsMatchLines, .caseInsensitive]
        ) else { return escape(code) }

        let ns = code as NSString
        var output = ""
        var last = 0

        for match in regex.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > last {
                output += escape(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            }

            let token = escape(ns.substring(with: match.range))
            let kind: String
            if match.range(at: 1).location != NSNotFound {
                kind = "com"
            } else if match.range(at: 2).location != NSNotFound {
                kind = "str"
            } else if match.range(at: 3).location != NSNotFound {
                kind = "num"
            } else {
                kind = "kw"
            }
            output += "<span class=\"tok-\(kind)\">\(token)</span>"
            last = NSMaxRange(match.range)
        }

        if last < ns.length {
            output += escape(ns.substring(from: last))
        }
        return output
    }

    // MARK: - 本地图片内联

    static func inlineLocalImages(_ html: String, base: URL) -> String {
        guard let re = try? NSRegularExpression(pattern: #"<img([^>]*?)src="([^"]+)""#) else { return html }
        let ns = html as NSString
        let matches = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var result = html

        for match in matches.reversed() {
            let src = ns.substring(with: match.range(at: 2))
            if src.hasPrefix("http"), !src.hasPrefix("https") { continue }
            if src.hasPrefix("http") || src.hasPrefix("data:") { continue }

            let decoded = src.removingPercentEncoding ?? src
            let fileURL = URL(fileURLWithPath: decoded, relativeTo: base).standardizedFileURL
            let original = ns.substring(with: match.range)

            // 图片字节和 base64 都不便宜，按「路径 + 修改时间」缓存，别每次敲字都重算
            if let cached = imageCache.get(fileURL) {
                result = (result as NSString).replacingCharacters(
                    in: match.range,
                    with: original.replacingOccurrences(of: src, with: cached)
                )
                continue
            }

            guard let data = try? Data(contentsOf: fileURL), data.count < 12_000_000 else { continue }

            let mime = mimeType(for: fileURL.pathExtension)
            let dataURI = "data:\(mime);base64,\(data.base64EncodedString())"
            imageCache.set(fileURL, uri: dataURI)
            result = (result as NSString).replacingCharacters(
                in: match.range,
                with: original.replacingOccurrences(of: src, with: dataURI)
            )
        }
        return result
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private final class ImageCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (mtime: Date, uri: String)] = [:]

        func get(_ url: URL) -> String? {
            guard let mtime = Markdown.modificationDate(url) else { return nil }
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[url.path], entry.mtime == mtime else { return nil }
            return entry.uri
        }

        func set(_ url: URL, uri: String) {
            guard let mtime = Markdown.modificationDate(url) else { return }
            lock.lock()
            defer { lock.unlock() }
            if entries.count > 64 { entries.removeAll() }
            entries[url.path] = (mtime, uri)
        }
    }

    private static let imageCache = ImageCache()

    static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "heic": return "image/heic"
        default: return "application/octet-stream"
        }
    }

    // MARK: - 样式

    static let css = """
    :root { color-scheme: light dark; }
    body {
        margin: 0 auto; padding: 32px 40px 120px; max-width: 760px;
        font-family: -apple-system, "PingFang SC", "Helvetica Neue", sans-serif;
        font-size: var(--base, 16px);
        line-height: 1.8;
        color: #1d1d1f; background: #ffffff;
        -webkit-font-smoothing: antialiased;
    }
    @media (prefers-color-scheme: dark) {
        body { color: #e6e6e6; background: #1c1c1e; }
        code, pre { background: #2c2c2e !important; }
        blockquote { border-color: #48484a !important; color: #b0b0b5 !important; }
        hr { border-color: #38383a !important; }
        a { color: #6cb4ff !important; }
    }
    h1, h2, h3, h4, h5, h6 { line-height: 1.35; margin: 1.6em 0 0.6em; font-weight: 650; }
    h1 { font-size: 1.75em; } h2 { font-size: 1.4em; } h3 { font-size: 1.18em; }
    h4, h5, h6 { font-size: 1em; }
    p { margin: 0.85em 0; }
    a { color: #0969da; text-decoration: none; }
    a:hover { text-decoration: underline; }
    code {
        font: 0.88em/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
        background: #f2f2f4; padding: 0.12em 0.35em; border-radius: 4px;
    }
    pre {
        background: #f6f6f8; padding: 14px 16px; border-radius: 8px; overflow-x: auto;
        line-height: 1.55;
    }
    pre code { background: none; padding: 0; font-size: 0.86em; }
    .code-block { position: relative; }
    .code-block .copy {
        position: absolute; top: 8px; right: 8px;
        font-size: 11px; line-height: 1; padding: 4px 8px;
        border-radius: 6px; border: 1px solid rgba(0,0,0,0.12);
        background: rgba(255,255,255,0.92); color: #555;
        opacity: 0; transition: opacity 0.12s ease; cursor: pointer;
    }
    .code-block:hover .copy { opacity: 1; }
    .code-block .copy:active { transform: scale(0.97); }
    @media (prefers-color-scheme: dark) {
        .code-block .copy { background: rgba(44,44,46,0.92); color: #ddd; border-color: rgba(255,255,255,0.15); }
    }
    pre.plain {
        background: transparent; padding: 0; border-radius: 0;
        font: 0.92em/1.7 ui-monospace, SFMono-Regular, Menlo, monospace;
        white-space: pre-wrap; word-break: break-word; margin: 0;
    }
    blockquote {
        margin: 1em 0; padding: 0.1em 0 0.1em 1em;
        border-left: 3px solid #d0d0d5; color: #6e6e73;
    }
    blockquote p { margin: 0.4em 0; }
    ul, ol { padding-left: 1.5em; margin: 0.85em 0; }
    li { margin: 0.3em 0; }
    hr { border: none; border-top: 1px solid #e0e0e4; margin: 2em 0; }
    img { max-width: 100%; border-radius: 6px; margin: 0.6em 0; }
    .wiki { color: #8b5cf6; border-bottom: 1px dashed currentColor; cursor: pointer; text-decoration: none; }
    .wiki:hover { color: #7c3aed; }
    del { color: #8e8e93; }
    mark { background: #fff3a3; color: inherit; padding: 0 2px; border-radius: 2px; }
    .tok-kw { color: #9b2393; }
    .tok-str { color: #c41a16; }
    .tok-com { color: #6c7986; font-style: italic; }
    .tok-num { color: #1c00cf; }
    @media (prefers-color-scheme: dark) {
        mark { background: #665c00; }
        .tok-kw { color: #fc5fa3; }
        .tok-str { color: #fc6a5d; }
        .tok-com { color: #7f8c98; }
        .tok-num { color: #d0bf69; }
    }
    table { border-collapse: collapse; margin: 1em 0; width: 100%; font-size: 0.95em; }
    th, td { border: 1px solid #e0e0e4; padding: 7px 10px; text-align: left; vertical-align: top; }
    th { background: #f6f6f8; font-weight: 600; }
    @media (prefers-color-scheme: dark) {
        th, td { border-color: #3a3a3c; }
        th { background: #2c2c2e; }
    }
    li.task { list-style: none; margin-left: -1.3em; }
    li.task input[type="checkbox"] { margin-right: 6px; transform: translateY(1px); }
    """
}

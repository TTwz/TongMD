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
        <body>\(body)</body></html>
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
                out.append("<pre><code\(cls)>\(escape(code.joined(separator: "\n")))</code></pre>")
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

            if let item = listItem(line) {
                flushParagraph()
                if listTag != item.tag {
                    closeList()
                    out.append("<\(item.tag)>")
                    listTag = item.tag
                }
                out.append("<li>" + inline(item.text) + "</li>")
                i += 1
                continue
            }

            paragraph.append(line)
            i += 1
        }

        flushParagraph()
        closeList()
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
                codes.insert("<code>\(code)</code>", at: index)
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
    """
}

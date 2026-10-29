#if DEBUG
import AppKit
import Foundation

/// 开发期自检：不依赖 GUI，直接验证 git 同步层和 Markdown 渲染。
/// 用法：`build/TongMD.app/Contents/MacOS/TongMD --self-test`（工作目录任意）
enum SelfTest {

    @MainActor
    static func run() -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        var failures: [String] = []
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".selftest", isDirectory: true)

        func check(_ name: String, _ condition: Bool) {
            print(condition ? "  ✓ \(name)" : "  ✗ \(name)")
            if !condition { failures.append(name) }
        }

        do {
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let bare = root.appendingPathComponent("remote.git")
            let work = root.appendingPathComponent("work")
            let other = root.appendingPathComponent("clone2")

            print("Markdown")
            let html = Markdown.render("# 标题\n\n正文 **加粗** 和 `code`。\n\n- 一\n- 二\n\n> 引用\n\n```swift\nlet a = 1\n```\n")
            check("标题", html.contains("<h1>标题</h1>"))
            check("加粗", html.contains("<strong>加粗</strong>"))
            check("行内代码", html.contains("<code>code</code>"))
            check("列表", html.contains("<ul>") && html.contains("<li>一</li>"))
            check("引用", html.contains("<blockquote>"))
            check("代码块", html.contains(#"<pre><code class="language-swift">"#))
            check("转义", Markdown.render("<script>").contains("&lt;script&gt;"))

            print("编辑器高亮")
            let sample = "# 标题\n\n**加粗** 和 `code`\n\n- 列表\n\n> 引用\n"
            let storage = NSTextStorage(string: sample)
            let highlighter = MarkdownSyntaxHighlighter()
            highlighter.highlightAll(storage)

            func attributes(of word: String) -> [NSAttributedString.Key: Any]? {
                let range = (sample as NSString).range(of: word)
                guard range.location != NSNotFound, NSMaxRange(range) <= storage.length else { return nil }
                return storage.attributes(at: range.location, effectiveRange: nil)
            }

            check("标题字号变大", ((attributes(of: "标题")?[.font] as? NSFont)?.pointSize ?? 0) > 15)
            check("加粗显示为粗体", ((attributes(of: "加粗")?[.font] as? NSFont)
                .map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) }) ?? false)
            check("行内代码等宽", (attributes(of: "code")?[.font] as? NSFont)?
                .fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false)
            check("列表记号变暗", (attributes(of: "- 列表")?[.foregroundColor] as? NSColor) != NSColor.labelColor)

            print("中文渲染")
            let renderView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
            let renderHighlighter = MarkdownSyntaxHighlighter()
            renderHighlighter.textView = renderView
            renderView.textStorage?.delegate = renderHighlighter
            renderView.string = "中文测试 ABC"
            if let storage = renderView.textStorage {
                renderHighlighter.highlightAll(storage, caret: 0)
            }
            renderView.setSelectedRange(NSRange(location: (renderView.string as NSString).length, length: 0))
            renderView.insertNewline(nil)
            // 上色是异步的，等一个 tick
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let cjkLocation = (renderView.string as NSString).range(of: "中文").location
            var cjkGlyph: CGGlyph = 0
            if let layoutManager = renderView.layoutManager, cjkLocation != NSNotFound {
                cjkGlyph = layoutManager.cgGlyph(at: layoutManager.glyphIndexForCharacter(at: cjkLocation))
            }
            check("编辑后中文仍有字形（不是空字形）", cjkGlyph != 0)

            print("字号缩放")
            let bigStorage = NSTextStorage(string: "# 标题\n\n正文")
            let bigHighlighter = MarkdownSyntaxHighlighter()
            bigHighlighter.fontSize = 20
            bigHighlighter.highlightAll(bigStorage)
            let titleFont = bigStorage.attributes(at: 2, effectiveRange: nil)[.font] as? NSFont
            let bodyFont = bigStorage.attributes(at: (bigStorage.string as NSString).range(of: "正文").location, effectiveRange: nil)[.font] as? NSFont
            check("标题随字号缩放", (titleFont?.pointSize ?? 0) >= 30)
            check("正文用设定字号", abs((bodyFont?.pointSize ?? 0) - 20) < 0.5)
            check("预览文档带字号变量", Markdown.document(body: "x", fontSize: 18).contains("--base: 18px"))

            print("智能续行")
            check("无序列表续行", TextActions.continuationPrefix(for: "- 一") == "- ")
            check("有序列表递增", TextActions.continuationPrefix(for: "1. 一") == "2. ")
            check("空列表项退出", TextActions.continuationPrefix(for: "- ") == "")
            check("引用续行", TextActions.continuationPrefix(for: "> 想法") == "> ")
            check("普通段落不处理", TextActions.continuationPrefix(for: "正文") == nil)

            print("搜索索引")
            let joined = SearchTokenizer.indexTokens("同步设计")
            check("索引含单字", joined.contains("同") && joined.contains("步"))
            check("索引含双字", joined.contains("同步") && joined.contains("设计"))
            check("英文按词切", SearchTokenizer.indexTokens("Git 101 Sync").contains("git"))
            check("查询中文取双字", SearchTokenizer.queryTokens("同步") == ["同步"])
            check("查询单字", SearchTokenizer.queryTokens("同") == ["同"])
            check("查询混合中英", SearchTokenizer.queryTokens("同步 git") == ["同步", "git"])

            let indexURL = root.appendingPathComponent("search-index/test.sqlite3")
            let index = try SearchIndex(path: indexURL)
            index.replaceAll([
                SearchIndex.Document(path: "/a.md", title: "同步设计", body: "本地是唯一写入点，git 负责传输。同步失败要提示。"),
                SearchIndex.Document(path: "/b.md", title: "随手记", body: "今天看了点和同步有关的文章。")
            ])
            check("索引条数", index.documentCount == 2)
            check("中文两字能搜到", try index.search("同步").count == 2)
            check("多词是 AND", try index.search("同步 git").count == 1)
            check("单字能搜到", try index.search("同").count == 2)
            let emptyHits = (try? index.search("量子力学")) ?? []
            check("无关词返回空", emptyHits.isEmpty)

            index.upsert(SearchIndex.Document(path: "/c.md", title: "新增", body: "完全不同的内容"))
            check("增量更新", try index.search("完全不同").count == 1)
            index.remove(path: "/c.md")
            check("删除后搜不到", try index.search("完全不同").isEmpty)

            print("搜索集成")
            let previousConfig = TokenStore.directoryOverride
            let configRoot = root.appendingPathComponent("integration-config")
            TokenStore.directoryOverride = configRoot
            let integVault = root.appendingPathComponent("integration-vault")
            try FileManager.default.createDirectory(at: integVault, withIntermediateDirectories: true)
            try "# 同步设计\n\n本地是唯一写入点，git 负责传输。".write(
                to: integVault.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
            try "今天看了点和同步有关的文章。".write(
                to: integVault.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)

            let integModel = AppModel(temporaryVault: integVault)
            integModel.searchText = "同步"
            let integDeadline = Date().addingTimeInterval(3)
            while integModel.searchResults.count < 2, Date() < integDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            check("集成搜索有结果", integModel.searchResults.count == 2)
            check("索引文件已生成", FileManager.default.fileExists(
                atPath: configRoot.appendingPathComponent("search.sqlite3").path))
            TokenStore.directoryOverride = previousConfig

            print("索引维护")
            let maintIndex = try SearchIndex(path: root.appendingPathComponent("search-index/maint.sqlite3"))
            maintIndex.replaceAll([
                SearchIndex.Document(path: "/a.md", title: "同步", body: "同步内容一"),
                SearchIndex.Document(path: "/b.md", title: "设计", body: "设计内容二")
            ])
            check("索引占用可读取", maintIndex.sizeBytes > 0)
            maintIndex.optimize()
            check("优化后仍可搜索", (try? maintIndex.search("同步"))?.count == 1)

            for round in 0..<50 {
                maintIndex.upsert(SearchIndex.Document(
                    path: "/a.md", title: "同步", body: "第\(round)版 同步内容"
                ))
            }
            check("反复覆盖不重复计数", maintIndex.documentCount == 2)
            check("覆盖后能搜到最新内容", (try? maintIndex.search("第49版"))?.count == 1)

            let beforeCompact = maintIndex.sizeBytes
            maintIndex.compact()
            check("压缩后仍可搜索", (try? maintIndex.search("同步"))?.count == 1)
            check("压缩后体积不增加", maintIndex.sizeBytes <= beforeCompact)

            maintIndex.replaceAll([])
            check("清空后索引为空", maintIndex.documentCount == 0)

            print("全文搜索")
            let searchRoot = URL(fileURLWithPath: "/tmp/tongmd-selftest")
            let documents = [
                (note: Note(url: searchRoot.appendingPathComponent("同步设计.md"), root: searchRoot),
                 text: "# 同步设计\n\n本地是唯一写入点，git 负责传输。同步失败要提示。"),
                (note: Note(url: searchRoot.appendingPathComponent("随手记.md"), root: searchRoot),
                 text: "今天看了点和同步有关的文章。")
            ]
            let searchResults = SearchEngine.search(query: "同步", in: documents)
            check("中文两字词能搜到", searchResults.count == 2)
            check("标题命中的排前面", searchResults.first?.note.title == "同步设计")
            check("多关键词是 AND", SearchEngine.search(query: "同步 git", in: documents).count == 1)
            check("无关键词时返回空", SearchEngine.search(query: "量子力学", in: documents).isEmpty)
            check("片段包含关键词", searchResults.first?.snippet.contains("同步") ?? false)

            print("双链")
            check("解析多个目标", WikiLinks.targets(in: "见 [[同步设计]] 和 [[项目/计划|计划]]") == ["同步设计", "项目/计划"])
            check("识别反向引用", WikiLinks.refers("参考 [[同步设计]]", to: "同步设计"))
            check("不误判别的标题", !WikiLinks.refers("参考 [[同步设计]]", to: "别的笔记"))
            check("渲染成内部链接", Markdown.render("见 [[同步设计]]").contains("tongmd://note?name="))
            check("支持显示文字", Markdown.render("[[a|显示]]").contains(">显示</a>"))

            print("粘贴的 HTML")
            let br = Markdown.render("a<br>b")
            check("<br> 当换行", br.contains("<br>") && !br.contains("&lt;br&gt;"))
            check("<br/> 当换行", !Markdown.render("a<br/>b").contains("&lt;br"))
            check("<p> 当段落", Markdown.render("<p>一</p><p>二</p>").components(separatedBy: "<p>").count - 1 == 2)
            check("&nbsp; 当空格", Markdown.render("a&nbsp;b").contains("a b"))
            check("行内代码里的 br 保持字面量", Markdown.render("`<br>`").contains("&lt;br&gt;"))
            check("段落内换行不会被转义", !Markdown.render("第一行\n第二行").contains("&lt;br&gt;"))
            check("段落内换行是真的 br", Markdown.render("第一行\n第二行").contains("<br>"))

            print("编辑器回车")
            let editorText = "R-20614- 【存货】 存货管理迭代\nfintax-stock\n[[R-20614 上线配置]]\ntwz_feature_R-20614\n"
            let textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            let editorHighlighter = MarkdownSyntaxHighlighter()
            editorHighlighter.textView = textView
            textView.textStorage?.delegate = editorHighlighter
            textView.string = editorText
            if let storage = textView.textStorage {
                editorHighlighter.highlightAll(storage, caret: 0)
            }
            textView.setSelectedRange(NSRange(location: (editorText as NSString).length - 1, length: 0))
            textView.insertNewline(nil)
            check("回车后文本只多一个换行", textView.string == editorText + "\n")

            if let storage = textView.textStorage {
                let ns = storage.string as NSString
                for probe in ["存货", "上线配置", "fintax-stock"] {
                    let range = ns.range(of: probe)
                    guard range.location != NSNotFound else {
                        print("  [debug] 找不到 \(probe)")
                        continue
                    }
                    let attrs = storage.attributes(at: range.location, effectiveRange: nil)
                    let font = attrs[.font] as? NSFont
                    print("  [debug] \(probe): font=\(font?.fontName ?? "nil") size=\(font?.pointSize ?? -1) color=\(attrs[.foregroundColor] ?? "nil")")
                }
            }

            print("文件夹与移动")
            let treeRoot = root.appendingPathComponent("tree")
            let emptyFolder = treeRoot.appendingPathComponent("空目录")
            let subFolder = treeRoot.appendingPathComponent("子目录")
            let destFolder = treeRoot.appendingPathComponent("目标")
            for dir in [emptyFolder, subFolder, destFolder] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try "一".write(to: treeRoot.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
            try "二".write(to: subFolder.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)

            let tree = AppModel.buildTree(at: treeRoot, root: treeRoot)
            check("树里有空目录", tree.contains { $0.isDirectory && $0.name == "空目录" })
            check("目录排在文件前面", tree.first?.isDirectory == true)
            check("嵌套文件挂在子目录下", tree.first(where: { $0.name == "子目录" })?
                .children?.contains(where: { $0.name == "b.md" }) == true)

            let moved = try AppModel.moveItem(at: treeRoot.appendingPathComponent("a.md"), to: emptyFolder)
            check("移动到子目录", moved?.lastPathComponent == "a.md"
                && FileManager.default.fileExists(atPath: emptyFolder.appendingPathComponent("a.md").path))

            try "三".write(to: treeRoot.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
            let renamed = try AppModel.moveItem(at: treeRoot.appendingPathComponent("a.md"), to: emptyFolder)
            check("重名自动加序号", renamed?.lastPathComponent == "a 2.md")

            check("不能移进自己", try AppModel.moveItem(at: emptyFolder, to: emptyFolder) == nil)
            check("不能移进自己的子目录", try AppModel.moveItem(at: subFolder, to: subFolder.appendingPathComponent("x")) == nil)

            let movedFolder = try AppModel.moveItem(at: subFolder, to: destFolder)
            check("目录可整体移动", movedFolder?.lastPathComponent == "子目录"
                && FileManager.default.fileExists(atPath: destFolder.appendingPathComponent("子目录/b.md").path))

            let flat = AppModel.flatten(AppModel.buildTree(at: treeRoot, root: treeRoot))
            check("展开后能拿到全部节点", flat.contains { $0.name == "b.md" } && flat.contains { $0.name == "目标" })

            print("授权辅助")
            if GhCLI.isAvailable() {
                check("能找到 gh 可执行文件", GhCLI.executablePath() != nil)
                do {
                    _ = try GhCLI.token()
                    check("gh token 读取成功", true)
                } catch {
                    check("未登录时提示可操作", error.localizedDescription.contains("gh auth login"))
                }
            } else {
                print("  (没有 gh，跳过)")
            }

            print("Token 规范化")
            let fake = "github_pat_1234567890abcdefghijklmnop"
            let hexed = fake.utf8.map { String(format: "%02x", $0) }.joined()
            let normalized = AppModel.normalizeToken(hexed)
            check("十六进制粘贴能还原", normalized.wasHex && normalized.value == fake)
            check("正常 token 不被改", AppModel.normalizeToken(fake).value == fake
                && AppModel.normalizeToken(fake).wasHex == false)
            check("普通文本原样返回", AppModel.normalizeToken("hello world").value == "hello world")
            check("识别合法前缀", AppModel.looksLikeGitHubToken("ghp_abcdefghijklmnopqrstuvwx"))
            check("拒绝明显不是 token 的值", !AppModel.looksLikeGitHubToken("0123456789"))

            print("代理参数")
            check("HTTPS 代理优先", GitEngine.proxyArguments(from: [
                "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7897,
                "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890
            ]) == ["-c", "http.proxy=http://127.0.0.1:7897"])
            check("HTTP 代理兜底", GitEngine.proxyArguments(from: [
                "HTTPEnable": 1, "HTTPProxy": "10.0.0.2", "HTTPPort": 8080
            ]) == ["-c", "http.proxy=http://10.0.0.2:8080"])
            check("SOCKS 兜底", GitEngine.proxyArguments(from: [
                "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 1080
            ]) == ["-c", "http.proxy=socks5h://127.0.0.1:1080"])
            check("没有代理时为空", GitEngine.proxyArguments(from: [:]).isEmpty)
            check("代理参数进入网络参数", GitEngine.networkArguments(token: "").contains("http.version=HTTP/1.1"))
            check("始终禁用外部凭据助手", GitEngine.networkArguments(token: "").contains("credential.helper="))

            print("行内代码边界")
            let multiCode = Markdown.render("a `x` b `y` c `z`")
            check("三段行内代码不崩", multiCode.components(separatedBy: "<code>").count - 1 == 3)
            check("每段内容正确", multiCode.contains("<code>x</code>")
                && multiCode.contains("<code>y</code>")
                && multiCode.contains("<code>z</code>"))
            let twoCode = Markdown.render("`a` 和 `b`")
            check("两段行内代码不崩", twoCode.contains("<code>a</code>") && twoCode.contains("<code>b</code>"))

            print("图片不会被当笔记")
            let imgRoot = root.appendingPathComponent("image-vault")
            let imgAssets = imgRoot.appendingPathComponent("assets")
            try FileManager.default.createDirectory(at: imgAssets, withIntermediateDirectories: true)
            try "# 笔记\n".write(to: imgRoot.appendingPathComponent("n.md"), atomically: true, encoding: .utf8)
            let imgURL = imgAssets.appendingPathComponent("pic.png")
            try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]).write(to: imgURL)
            let imgModel = AppModel(temporaryVault: imgRoot)
            imgModel.openNote(imgURL)
            check("打开图片进入附件预览", imgModel.selectedAttachment == imgURL)
            check("图片不会占据笔记位置", imgModel.selection != imgURL)
            check("没有把图片当文本渲染", !imgModel.text.contains("PNG"))

            print("链接改写")
            let wikiText = "见 [[同步设计]]、[[同步设计|设计稿]] 和 [[项目/同步设计#实现]]"
            let wikiRewritten = LinkRewriter.rewriteWikiLinks(in: wikiText, from: "同步设计", to: "架构设计")
            check("基础双链改写", wikiRewritten.contains("[[架构设计]]"))
            check("别名保留", wikiRewritten.contains("[[架构设计|设计稿]]"))
            check("小节和路径前缀保留", wikiRewritten.contains("[[项目/架构设计#实现]]"))

            let rwRoot = root.appendingPathComponent("rw")
            let oldNotePath = rwRoot.appendingPathComponent("项目/a.md")
            let newNotePath = rwRoot.appendingPathComponent("a.md")
            let movedText = "![图](assets/x.png)\n[邻居](../b.md)\n[外链](https://example.com/x.md)"
            let movedRewritten = LinkRewriter.rewriteRelativeLinks(
                in: movedText, oldNotePath: oldNotePath, newNotePath: newNotePath, moves: [:]
            )
            check("移动后图片路径重算", movedRewritten.contains("(项目/assets/x.png)"))
            check("移动后笔记链接重算", movedRewritten.contains("(b.md)"))
            check("外链不动", movedRewritten.contains("https://example.com/x.md"))

            let imageOld = rwRoot.appendingPathComponent("assets/old.png")
            let imageNew = rwRoot.appendingPathComponent("assets/new.png")
            let imageRewritten = LinkRewriter.rewriteRelativeLinks(
                in: "![](assets/old.png)",
                oldNotePath: rwRoot.appendingPathComponent("n.md"),
                newNotePath: rwRoot.appendingPathComponent("n.md"),
                moves: [imageOld.path: imageNew.path]
            )
            check("图片改名后引用更新", imageRewritten.contains("(assets/new.png)"))

            print("重命名改写双链")
            let linkVault = root.appendingPathComponent("link-vault")
            try FileManager.default.createDirectory(at: linkVault, withIntermediateDirectories: true)
            let targetNote = linkVault.appendingPathComponent("同步设计.md")
            try "# 同步设计\n".write(to: targetNote, atomically: true, encoding: .utf8)
            let sourceNote = linkVault.appendingPathComponent("索引.md")
            try "见 [[同步设计|设计稿]]".write(to: sourceNote, atomically: true, encoding: .utf8)

            let linkModel = AppModel(temporaryVault: linkVault)
            linkModel.beginRename(targetNote)
            linkModel.renameText = "架构设计"
            linkModel.commitRename()

            let sourceText = (try? String(contentsOf: sourceNote, encoding: .utf8)) ?? ""
            check("双链跟着改名", sourceText.contains("[[架构设计|设计稿]]"))
            check("文件已重命名", FileManager.default.fileExists(
                atPath: linkVault.appendingPathComponent("架构设计.md").path))

            print("移动改写路径")
            let moveVault = root.appendingPathComponent("move-vault")
            let subDir = moveVault.appendingPathComponent("sub")
            let moveAssetsDir = moveVault.appendingPathComponent("assets")
            try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: moveAssetsDir, withIntermediateDirectories: true)
            try Data([1]).write(to: moveAssetsDir.appendingPathComponent("pic.png"))
            let moveNote = subDir.appendingPathComponent("a.md")
            try "![图](../assets/pic.png)\n".write(to: moveNote, atomically: true, encoding: .utf8)

            let moveModel = AppModel(temporaryVault: moveVault)
            moveModel.moveItems([moveNote], to: moveVault)
            let movedNoteText = (try? String(contentsOf: moveVault.appendingPathComponent("a.md"), encoding: .utf8)) ?? ""
            check("移动后图片引用可解析", movedNoteText.contains("(assets/pic.png)"))

            print("断链检查")
            let brokenVault = root.appendingPathComponent("broken-vault")
            try FileManager.default.createDirectory(at: brokenVault, withIntermediateDirectories: true)
            try "[[存在]] 和 [[不存在]]".write(
                to: brokenVault.appendingPathComponent("存在.md"), atomically: true, encoding: .utf8)
            let brokenModel = AppModel(temporaryVault: brokenVault)
            brokenModel.checkBrokenLinks()
            check("能发现断链", brokenModel.brokenLinks.count == 1)
            check("断链目标是缺失的那条", brokenModel.brokenLinks.first?.target == "不存在")

            print("Markdown 表格与任务")
            let tableHTML = Markdown.render("| 名称 | 状态 |\n| --- | --- |\n| 同步 | 完成 |")
            check("表格有表头", tableHTML.contains("<table>") && tableHTML.contains("<th>名称</th>"))
            check("表格有单元格", tableHTML.contains("<td>同步</td>"))
            let taskHTML = Markdown.render("- [ ] 待办\n- [x] 完成")
            check("任务清单渲染", taskHTML.contains("data-task") && taskHTML.contains("data-line=\"0\""))
            check("已完成项带 checked", taskHTML.contains("checked"))
            check("勾选任务行", Markdown.toggledTaskLine("- [ ] 待办", checked: true) == "- [x] 待办")
            check("取消勾选任务行", Markdown.toggledTaskLine("- [x] 待办", checked: false) == "- [ ] 待办")
            check("普通条目不变", Markdown.toggledTaskLine("- 普通", checked: true) == nil)

            print("标签解析")
            check("中文标签", TagParser.tags(in: "今天 #知识库 和 #PKM") == ["知识库", "PKM"])
            check("代码块里的不算", TagParser.tags(in: "```\n#不是\n```\n#是") == ["是"])
            check("标题不算", TagParser.tags(in: "# 标题\n正文 #标签") == ["标签"])
            check("重复只算一次", TagParser.tags(in: "#标签 #标签") == ["标签"])

            print("模糊匹配")
            check("子序列命中", FuzzyMatch.score("tmd", in: "TongMD 笔记") != nil)
            check("不命中返回 nil", FuzzyMatch.score("zzz", in: "TongMD") == nil)
            check("前缀优先", FuzzyMatch.ranked("同步", candidates: ["设计同步", "同步设计"]).first == "同步设计")
            check("中文命中", FuzzyMatch.score("知识", in: "个人知识库") != nil)

            print("双链补全")
            let completionTitles = ["同步设计", "架构设计", "随手记"]
            let suggestion = LinkCompletion.suggestion(text: "见 [[同", caret: 5, titles: completionTitles)
            check("补全能识别范围", suggestion?.range == NSRange(location: 4, length: 1))
            check("补全能过滤候选", suggestion?.items == ["同步设计"])
            check("已闭合不再补全", LinkCompletion.suggestion(text: "见 [[同步]]", caret: 8, titles: completionTitles) == nil)
            check("别名输入时不补全", LinkCompletion.suggestion(text: "[[同步|别", caret: 6, titles: completionTitles) == nil)

            print("反向链接上下文")
            let backlinkVault = root.appendingPathComponent("backlink-vault")
            try FileManager.default.createDirectory(at: backlinkVault, withIntermediateDirectories: true)
            let backlinkTarget = backlinkVault.appendingPathComponent("同步设计.md")
            try "# 同步设计\n".write(to: backlinkTarget, atomically: true, encoding: .utf8)
            try "第一行\n参考 [[同步设计]] 的设计 #知识库\n第三行".write(
                to: backlinkVault.appendingPathComponent("索引.md"), atomically: true, encoding: .utf8)

            let backlinkModel = AppModel(temporaryVault: backlinkVault)
            backlinkModel.openNote(backlinkTarget)
            check("反向链接有上下文", backlinkModel.backlinks.first?.excerpt.contains("[[同步设计]]") == true)
            check("反向链接可定位", (backlinkModel.backlinks.first?.offset ?? -1) >= 0)

            print("标签计数")
            check("标签计入侧栏", backlinkModel.tagCounts.contains { $0.name == "知识库" && $0.count == 1 })

            print("补全浮层交互")
            let completionWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            completionWindow.isReleasedWhenClosed = false
            let completionEditor = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
            completionEditor.noteTitles = ["同步设计", "架构设计", "随手记"]
            completionWindow.contentView?.addSubview(completionEditor)
            completionWindow.makeFirstResponder(completionEditor)

            completionEditor.insertText("[[", replacementRange: completionEditor.selectedRange())
            check("输入 [[ 弹出列表", completionEditor.debugCompletionVisible)
            check("列表是笔记标题", completionEditor.debugCompletionCount == 3)

            completionEditor.deleteBackward(nil)
            check("删除键能删掉字符", completionEditor.string == "[")
            check("删掉 [[ 后浮层关闭", !completionEditor.debugCompletionVisible)

            completionEditor.string = ""
            completionEditor.setSelectedRange(NSRange(location: 0, length: 0))
            completionEditor.insertText("[[同", replacementRange: completionEditor.selectedRange())
            check("继续输入会过滤", completionEditor.debugCompletionCount == 1)

            if let enter = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: completionWindow.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36
            ) {
                completionEditor.keyDown(with: enter)
            }
            check("回车补全成双链", completionEditor.string == "[[同步设计]]")
            check("补全后浮层关闭", !completionEditor.debugCompletionVisible)
            completionEditor.debugHideCompletion()
            completionWindow.close()

            print("Markdown 扩展语法")
            let alignedTable = Markdown.render("| 名称 | 数量 |\n|:--- | ---: |\n| 同步 | 3 |")
            check("表格左对齐", alignedTable.contains("text-align:left"))
            check("表格右对齐", alignedTable.contains("text-align:right"))

            let escapedTable = Markdown.render("| a \\| b | c |\n| --- | --- |\n| 1 | 2 |")
            check("表格转义竖线", escapedTable.contains("<th>a | b</th>"))
            check("高亮渲染", Markdown.render("==重点==").contains("<mark>重点</mark>"))

            let footnote = Markdown.render("正文[^1]\n\n[^1]: 脚注说明")
            check("脚注引用", footnote.contains("fnref-1"))
            check("脚注定义", footnote.contains("id=\"fn-1\"") && footnote.contains("脚注说明"))

            let swiftCode = Markdown.render("```swift\nfunc hello() { let x = \"hi\" }\n```")
            check("代码关键字高亮", swiftCode.contains("tok-kw"))
            check("代码字符串高亮", swiftCode.contains("tok-str"))
            check("未知语言不高亮", !Markdown.render("```\nplain\n```").contains("tok-"))

            let javaCode = Markdown.render("```java\npublic class Main { int x = 1; }\n```")
            check("Java 关键字高亮", javaCode.contains("tok-kw") && javaCode.contains("class"))
            let sqlCode = Markdown.render("```sql\nselect id from users where id = 1;\n```")
            check("SQL 关键字高亮（小写）", sqlCode.contains("tok-kw") && sqlCode.contains("select"))
            check("SQL 别名可用", Markdown.render("```mysql\nSELECT 1;\n```").contains("tok-kw"))

            let codeBlockHTML = Markdown.render("```swift\nlet x = 1\n```")
            check("代码块带复制按钮", codeBlockHTML.contains("class=\"code-block\"") && codeBlockHTML.contains("class=\"copy\""))

            print("冲突处理")
            let conflictGit = GitEngine(token: "")
            let conflictRoot = root.appendingPathComponent("conflict")
            try FileManager.default.createDirectory(at: conflictRoot, withIntermediateDirectories: true)
            let conflictBare = conflictRoot.appendingPathComponent("remote.git")
            try FileManager.default.createDirectory(at: conflictBare, withIntermediateDirectories: true)
            _ = try conflictGit.run(["init", "--bare", "-b", "main"], in: conflictBare)

            let cloneA = conflictRoot.appendingPathComponent("A")
            _ = try conflictGit.run(["clone", conflictBare.path, cloneA.path], in: conflictRoot)
            try "base".write(to: cloneA.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
            _ = try conflictGit.run(["add", "-A"], in: cloneA)
            _ = try conflictGit.run(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-m", "base"], in: cloneA)
            _ = try conflictGit.run(["push", "-u", "origin", "main"], in: cloneA)

            let cloneB = conflictRoot.appendingPathComponent("B")
            _ = try conflictGit.run(["clone", conflictBare.path, cloneB.path], in: conflictRoot)
            try "remote".write(to: cloneB.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
            _ = try conflictGit.run(["add", "-A"], in: cloneB)
            _ = try conflictGit.run(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-m", "remote"], in: cloneB)
            _ = try conflictGit.run(["push", "-u", "origin", "main"], in: cloneB)

            try "local".write(to: cloneA.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
            _ = try conflictGit.run(["add", "-A"], in: cloneA)
            _ = try conflictGit.run(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-m", "local"], in: cloneA)

            let conflictEngine = GitEngine(token: "")
            let mergeOutcome = try conflictEngine.sync(cloneA)
            check("同步能识别冲突", mergeOutcome.conflicts == ["a.md"])
            check("能读取远端版本",
                  conflictEngine.remoteFileContent("a.md", branch: "main", in: cloneA) == "remote")

            let conflictModel = AppModel(temporaryVault: cloneA)
            conflictModel.beginConflictResolution(paths: ["a.md"], branch: "main")
            check("冲突面板有本地内容", conflictModel.conflicts.first?.localText == "local")
            check("冲突面板有远端内容", conflictModel.conflicts.first?.remoteText == "remote")
            conflictModel.resolveConflictUseRemote()
            check("采用远端后标记完成",
                  conflictModel.conflicts.first?.resolved == true
                  && conflictModel.conflicts.first?.finalText == "remote")
            check("全部处理完", conflictModel.allConflictsResolved)

            print("侧栏扁平化")
            let flatVault = root.appendingPathComponent("flat-vault")
            let flatFolder = flatVault.appendingPathComponent("外层")
            try FileManager.default.createDirectory(at: flatFolder, withIntermediateDirectories: true)
            try "笔记".write(to: flatFolder.appendingPathComponent("内层.md"), atomically: true, encoding: .utf8)
            let flatModel = AppModel(temporaryVault: flatVault)
            check("展开时包含子节点", flatModel.visibleNodes.count == 2)
            check("子节点有缩进", flatModel.visibleNodes.last?.depth == 1)
            flatModel.collapsedFolders.insert(flatFolder)
            check("折叠后只剩文件夹", flatModel.visibleNodes.count == 1)
            flatModel.collapsedFolders.removeAll()
            check("再次展开恢复", flatModel.visibleNodes.count == 2)

            print("搜索操作符与大纲")
            let parsedQuery = SearchQuery.parse("tag:知识库 folder:项目 before:2026-01-01 after:2025-01-01 同步")
            check("解析关键词", parsedQuery.terms == ["同步"])
            check("解析标签", parsedQuery.tags == ["知识库"])
            check("解析目录", parsedQuery.folders == ["项目"])
            check("解析日期", parsedQuery.before != nil && parsedQuery.after != nil)

            let outlineText = "# 一\n\n正文\n## 二\n```\n# 不是标题\n```\n### 三"
            let outlineItems = Outline.items(in: outlineText)
            check("大纲层级", outlineItems.map(\.level) == [1, 2, 3])
            check("大纲标题", outlineItems.map(\.title) == ["一", "二", "三"])
            check("大纲偏移递增", outlineItems[0].offset < outlineItems[1].offset)

            let outlineVault = root.appendingPathComponent("outline-vault")
            try? FileManager.default.createDirectory(at: outlineVault, withIntermediateDirectories: true)
            let outlineNote = outlineVault.appendingPathComponent("o.md")
            try "# 一\n\n## 二\n".write(to: outlineNote, atomically: true, encoding: .utf8)
            let outlineModel = AppModel(temporaryVault: outlineVault)
            outlineModel.openNote(outlineNote)
            let items = outlineModel.outline
            if items.count >= 2 {
                outlineModel.mode = .split
                outlineModel.jumpToOutline(items[1])
                check("点大纲定位到标题偏移", outlineModel.pendingScrollRange?.location == items[1].offset)
                check("点大纲同时通知预览", outlineModel.pendingPreviewHeading == items[1].title)

                outlineModel.mode = .preview
                outlineModel.jumpToOutline(items[1])
                check("预览模式下只滚预览", outlineModel.pendingScrollRange == nil)
            } else {
                check("大纲条目至少两个", false)
            }

            print("每日笔记与速记")
            let dailyVault = root.appendingPathComponent("daily-vault")
            try FileManager.default.createDirectory(at: dailyVault, withIntermediateDirectories: true)
            let dailyModel = AppModel(temporaryVault: dailyVault)
            dailyModel.dailyTemplate = "# {{date}}\n\n## 速记\n"
            let dailyURL = dailyModel.ensureDailyNote()
            check("日记按日期命名", dailyURL?.lastPathComponent == Templates.dailyName() + ".md")
            let dailyText = (try? String(contentsOf: dailyURL!, encoding: .utf8)) ?? ""
            check("日记套用模板", dailyText.contains("# " + Templates.dailyName()))

            dailyModel.openDailyNote()
            check("打开今日笔记", dailyModel.selection == dailyURL)
            dailyModel.captureText = "买牛奶"
            dailyModel.submitCapture()
            let capturedText = (try? String(contentsOf: dailyURL!, encoding: .utf8)) ?? ""
            check("速记写入文件", capturedText.contains("买牛奶") && capturedText.contains("## 速记"))
            check("速记带时间前缀", capturedText.contains("- 0") || capturedText.contains("- 1") || capturedText.contains("- 2"))

            let renderedTemplate = Templates.render(
                "{{title}} {{date}} {{time}}",
                title: "标题",
                date: Date(timeIntervalSince1970: 0)
            )
            check("模板占位符", renderedTemplate.hasPrefix("标题 1970-01-01"))

            print("搜索过滤")
            let filterVault = root.appendingPathComponent("filter-vault")
            try FileManager.default.createDirectory(at: filterVault, withIntermediateDirectories: true)
            try "#知识库 同步设计".write(
                to: filterVault.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
            try "同步设计".write(
                to: filterVault.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
            let filterModel = AppModel(temporaryVault: filterVault)
            filterModel.searchText = "tag:知识库"
            check("按标签过滤", filterModel.searchResults.count == 1
                && filterModel.searchResults.first?.note.title == "a")
            filterModel.searchText = "tag:知识库 同步"
            let comboTarget = Date().addingTimeInterval(2)
            while filterModel.searchResults.count != 1, Date() < comboTarget {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            check("标签与关键词组合", filterModel.searchResults.count == 1)
            filterModel.searchText = "tag:不存在"
            check("标签无结果", filterModel.searchResults.isEmpty)

            let exportedHTML = Markdown.document(
                from: "| a | b |\n| --- | --- |\n| 1 | 2 |",
                baseDirectory: nil
            )
            check("导出 HTML 含表格", exportedHTML.contains("<table>"))

            print("版本历史")
            let histRepo = root.appendingPathComponent("hist-repo")
            try FileManager.default.createDirectory(at: histRepo, withIntermediateDirectories: true)
            let histGit = GitEngine(token: "")
            _ = try histGit.run(["init", "-b", "main"], in: histRepo)
            let histNote = histRepo.appendingPathComponent("a.md")
            try "第一版".write(to: histNote, atomically: true, encoding: .utf8)
            _ = try histGit.run(["add", "-A"], in: histRepo)
            _ = try histGit.run(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-m", "v1"], in: histRepo)
            try "第二版".write(to: histNote, atomically: true, encoding: .utf8)
            _ = try histGit.run(["add", "-A"], in: histRepo)
            _ = try histGit.run(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-m", "v2"], in: histRepo)

            let versions = histGit.fileLog("a.md", in: histRepo)
            check("提交历史两条", versions.count == 2)
            check("历史内容可读", (try? histGit.fileContent("a.md", at: versions[1].id, in: histRepo)) == "第一版")
            try histGit.restoreFile("a.md", from: versions[1].id, in: histRepo)
            check("恢复旧版本", (try? String(contentsOf: histNote, encoding: .utf8)) == "第一版")

            let histModel = AppModel(temporaryVault: histRepo)
            histModel.openHistory()
            check("模型能打开历史", histModel.showHistory && histModel.historyEntries.count == 2)
            let previewDeadline = Date().addingTimeInterval(3)
            while histModel.historyPreview.isEmpty, Date() < previewDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            check("预览最新版本", histModel.historyPreview.contains("第二版"))

            histModel.historySelection = histModel.historyEntries[1].id
            let oldDeadline = Date().addingTimeInterval(3)
            while !histModel.historyPreview.contains("第一版"), Date() < oldDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            check("预览旧版本", histModel.historyPreview.contains("第一版"))

            histModel.restoreSelectedVersion()
            check("恢复后文件已覆盖", (try? String(contentsOf: histNote, encoding: .utf8)) == "第一版")

            let otherHistNote = histRepo.appendingPathComponent("b.md")
            try "B 内容".write(to: otherHistNote, atomically: true, encoding: .utf8)
            _ = try histGit.run(["add", "-A"], in: histRepo)
            _ = try histGit.run(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-m", "b1"], in: histRepo)
            histModel.openHistory(for: otherHistNote)
            check("右键可查看指定笔记历史",
                  histModel.historyNoteURL == otherHistNote && histModel.historyEntries.count == 1)

            print("格式栏动作")
            let actionView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            actionView.string = "任务"
            actionView.setSelectedRange(NSRange(location: 0, length: 2))
            TextActions.toggleTaskList(actionView)
            check("任务清单加前缀", actionView.string == "- [ ] 任务")
            TextActions.toggleTaskList(actionView)
            check("再点取消任务清单", actionView.string == "任务")

            actionView.string = "条目"
            actionView.setSelectedRange(NSRange(location: 0, length: 2))
            TextActions.toggleNumberedList(actionView)
            check("有序列表加前缀", actionView.string == "1. 条目")

            actionView.string = ""
            actionView.setSelectedRange(NSRange(location: 0, length: 0))
            TextActions.insertTable(actionView)
            check("插入表格模板", actionView.string.contains("| 列 1 | 列 2 |") && actionView.string.contains("| --- | --- |"))

            actionView.string = ""
            actionView.setSelectedRange(NSRange(location: 0, length: 0))
            TextActions.insertCodeBlock(actionView, language: "swift")
            check("代码块带语言", actionView.string.hasPrefix("```swift"))

            actionView.string = "文字"
            actionView.setSelectedRange(NSRange(location: 0, length: 2))
            TextActions.toggleHighlight(actionView)
            check("高亮包裹", actionView.string == "==文字==")

            print("任务写回与标签过滤")
            let taskVault = root.appendingPathComponent("task-vault")
            try FileManager.default.createDirectory(at: taskVault, withIntermediateDirectories: true)
            let taskNote = taskVault.appendingPathComponent("待办.md")
            try "- [ ] 写完\n- [x] 已写".write(to: taskNote, atomically: true, encoding: .utf8)
            try "第二条 #项目".write(
                to: taskVault.appendingPathComponent("另一篇.md"), atomically: true, encoding: .utf8)

            let taskModel = AppModel(temporaryVault: taskVault)
            taskModel.openNote(taskNote)
            taskModel.toggleTask(line: 0, checked: true)
            let taskText = (try? String(contentsOf: taskNote, encoding: .utf8)) ?? ""
            check("勾选写回源文件", taskText.hasPrefix("- [x] 写完"))

            let copyBoard = NSPasteboard(name: NSPasteboard.Name("dev.tong.TongMD.copy-test"))
            copyBoard.clearContents()
            taskModel.copyCode("let x = 1", to: copyBoard)
            check("复制代码写入剪贴板", copyBoard.string(forType: .string) == "let x = 1")

            taskModel.activeTag = "项目"
            check("标签过滤出笔记", taskModel.taggedNotes.map(\.title) == ["另一篇"])
            taskModel.activeTag = nil
            check("清除标签后为空", taskModel.taggedNotes.isEmpty)

            print("快速切换")
            taskModel.quickQuery = "另一"
            check("⌘P 能按标题命中", taskModel.quickResults.first?.title == "另一篇")
            taskModel.quickQuery = "zzz"
            check("⌘P 无结果", taskModel.quickResults.isEmpty)

            print("附件整理")
            let conVault = root.appendingPathComponent("con-vault")
            let projDir = conVault.appendingPathComponent("项目")
            let projAssets = projDir.appendingPathComponent("assets")
            try FileManager.default.createDirectory(at: projAssets, withIntermediateDirectories: true)
            try Data([9]).write(to: projAssets.appendingPathComponent("pic.png"))
            try "![图](assets/pic.png)\n".write(to: projDir.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)

            let conModel = AppModel(temporaryVault: conVault)
            conModel.consolidateAttachments()

            check("图片移动到根 assets", FileManager.default.fileExists(
                atPath: conVault.appendingPathComponent("assets/pic.png").path))
            check("旧的 assets 目录已清掉", !FileManager.default.fileExists(atPath: projAssets.path))
            let rewrittenText = (try? String(contentsOf: projDir.appendingPathComponent("note.md"), encoding: .utf8)) ?? ""
            check("引用改成相对新路径", rewrittenText.contains("](../assets/pic.png)"))

            print("引用标识")
            let refVault = root.appendingPathComponent("ref-vault")
            let refAssets = refVault.appendingPathComponent("assets")
            let normalDir = refVault.appendingPathComponent("普通目录")
            try FileManager.default.createDirectory(at: refAssets, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: normalDir, withIntermediateDirectories: true)
            try Data([1]).write(to: refAssets.appendingPathComponent("used.png"))
            try Data([2]).write(to: refAssets.appendingPathComponent("unused.png"))
            try "![图](assets/used.png)\n".write(to: refVault.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)

            let refModel = AppModel(temporaryVault: refVault)
            check("被引用的图片有标记", refModel.referencedImageNames.contains("used.png"))
            check("未被引用的图片没有标记", !refModel.referencedImageNames.contains("unused.png"))
            check("assets 目录不能改名", !AppModel.canRename(refAssets))
            check("普通目录可以改名", AppModel.canRename(normalDir))

            print("附件可见")
            let visVault = root.appendingPathComponent("vis-vault")
            let visAssets = visVault.appendingPathComponent("assets")
            try FileManager.default.createDirectory(at: visAssets, withIntermediateDirectories: true)
            try "笔记".write(to: visVault.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
            try "png".write(to: visAssets.appendingPathComponent("pic.png"), atomically: true, encoding: .utf8)

            let visTree = AppModel.buildTree(at: visVault, root: visVault)
            check("assets 目录在侧栏可见", visTree.contains { $0.isDirectory && $0.name == "assets" })
            let assetsNode = visTree.first { $0.name == "assets" }
            check("图片出现在树里", assetsNode?.children?.contains { $0.name == "pic.png" } == true)
            check("图片识别为附件", AppModel.isImageFile(visAssets.appendingPathComponent("pic.png")))
            check("附件图标是 photo", assetsNode?.children?.first?.iconName == "photo")
            check("笔记列表不含图片", AppModel.flatten(visTree).filter { $0.isNote }
                .allSatisfy { $0.name != "pic.png" })
            check("md 不会被当成图片", !AppModel.isImageFile(visVault.appendingPathComponent("note.md")))

            print("Token 存储")
            TokenStore.directoryOverride = root.appendingPathComponent("token-store")
            check("Token 可写入", TokenStore.save("github_pat_selftest"))
            check("Token 可读回", TokenStore.load() == "github_pat_selftest")
            let permissions = (try? FileManager.default.attributesOfItem(atPath: TokenStore.fileURL.path))?[.posixPermissions] as? Int
            check("配置文件权限为 600", permissions == 0o600)
            _ = TokenStore.save("")
            check("清除后为空", TokenStore.load().isEmpty)
            check("不写入时也能安全读取", TokenStore.load().isEmpty)
            TokenStore.directoryOverride = nil

            print("凭据与权限")
            check("解析 API 地址", AppModel.apiURL(from: "https://github.com/TTwz/MarkDownFile.git")?.absoluteString
                == "https://api.github.com/repos/TTwz/MarkDownFile")
            check("SSH 地址不解析", AppModel.apiURL(from: "git@github.com:TTwz/MarkDownFile.git") == nil)
            let forbidden = GitResult(code: 128, output: "",
                error: "remote: Write access to repository not granted.\nfatal: The requested URL returned error: 403")
            check("403 提示写权限", GitEngine.friendlyMessage(for: forbidden).contains("Read and write"))

            print("网络兼容")
            let plainArgs = GitEngine.networkArguments(token: "")
            check("网络操作强制 HTTP/1.1", plainArgs.contains("http.version=HTTP/1.1"))
            check("带 token 时加 extraheader", GitEngine.networkArguments(token: "abc")
                .contains { $0.hasPrefix("http.extraheader=Authorization:") })
            check("空 token 不加 extraheader", !plainArgs.contains { $0.hasPrefix("http.extraheader=") })

            let authError = GitResult(code: 128, output: "", error: "fatal: Authentication failed for 'https://github.com/x/y.git/'")
            check("认证失败给中文建议", GitEngine.friendlyMessage(for: authError).contains("Token 无效"))
            let http2Error = GitResult(code: 128, output: "", error: "fatal: unable to access 'https://github.com/x/y.git/': Error in the HTTP2 framing layer")
            check("HTTP2 错误有对应提示", GitEngine.friendlyMessage(for: http2Error).contains("HTTP/2"))
            let notFound = GitResult(code: 128, output: "", error: "remote: Repository not found.")
            check("仓库不存在有对应提示", GitEngine.friendlyMessage(for: notFound).contains("仓库不存在"))

            print("assets 不进侧栏")
            let assetVault = root.appendingPathComponent("asset-vault")
            let bookDir = assetVault.appendingPathComponent("book")
            let assetsDir = bookDir.appendingPathComponent("assets")
            try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
            try "img".write(to: assetsDir.appendingPathComponent("a.png"), atomically: true, encoding: .utf8)
            try "笔记".write(to: bookDir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
            let assetTree = AppModel.buildTree(at: assetVault, root: assetVault)
            check("侧栏不显示 assets 目录", !assetTree.contains { $0.name == "assets" })
            check("笔记仍然显示", assetTree.first(where: { $0.name == "book" })?
                .children?.contains(where: { $0.name == "b.md" }) == true)

            print("附件存储")
            let attDir = root.appendingPathComponent("att")
            let firstURL = AttachmentStore.save(data: Data([1, 2]), name: "截图 1", into: attDir)
            let secondURL = AttachmentStore.save(data: Data([3]), name: "截图 1", into: attDir)
            check("存到 assets 目录下", firstURL?.deletingLastPathComponent().lastPathComponent == "assets")
            check("重名自动加序号", firstURL?.lastPathComponent != secondURL?.lastPathComponent)
            check("文件真的落盘", firstURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
            let dupData = Data([7, 7, 7, 7])
            let firstDup = AttachmentStore.save(data: dupData, name: "复用", into: attDir)
            let secondDup = AttachmentStore.save(data: dupData, name: "复用", into: attDir)
            check("相同图片复用同一个文件", firstDup == secondDup)
            let dupFiles = (try? FileManager.default.contentsOfDirectory(
                atPath: attDir.appendingPathComponent("assets").path
            ))?.filter { $0.hasPrefix("复用") } ?? []
            check("不会产生重复副本", dupFiles.count == 1)


            let nested = attDir.appendingPathComponent("a/b")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let target = attDir.appendingPathComponent("assets/x.png")
            check("相对路径：同级", AttachmentStore.relativePath(from: attDir, to: target) == "assets/x.png")
            check("相对路径：上两级", AttachmentStore.relativePath(from: nested, to: target) == "../../assets/x.png")

            print("截图粘贴")
            let pasteDir = root.appendingPathComponent("paste-note")
            try FileManager.default.createDirectory(at: pasteDir, withIntermediateDirectories: true)
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.tong.TongMD.selftest"))
            pasteboard.clearContents()
            let pasteImage = NSImage(size: NSSize(width: 24, height: 24))
            pasteImage.lockFocus()
            NSColor.systemBlue.setFill()
            NSRect(x: 0, y: 0, width: 24, height: 24).fill()
            pasteImage.unlockFocus()
            pasteboard.writeObjects([pasteImage])

            let pasteView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            pasteView.attachmentDirectory = pasteDir
            let rawTIFF = pasteImage.tiffRepresentation ?? Data()
            pasteboard.clearContents()
            pasteboard.setData(rawTIFF, forType: .tiff)

            let pasted = pasteView.insertPastedImage(from: pasteboard)
            check("能识别剪贴板里的图片", pasted)
            let pastedFiles = (try? FileManager.default.contentsOfDirectory(atPath: pasteDir.appendingPathComponent("assets").path)) ?? []
            check("图片写进了 assets/", pastedFiles.contains { $0.hasSuffix(".png") })
            check("插入了 Markdown 引用", pasteView.string.contains("(assets/") && pasteView.string.contains("!["))

            try ClipboardSelfTest.run(in: root, check: check)

            print("列表稳定性")
            let stableRoot = root.appendingPathComponent("stable")
            try FileManager.default.createDirectory(at: stableRoot, withIntermediateDirectories: true)
            let stableNote = stableRoot.appendingPathComponent("a.md")
            try "第一版".write(to: stableNote, atomically: true, encoding: .utf8)
            let treeBefore = AppModel.buildTree(at: stableRoot, root: stableRoot)
            try "改了内容\n第二行".write(to: stableNote, atomically: true, encoding: .utf8)
            let treeAfter = AppModel.buildTree(at: stableRoot, root: stableRoot)
            check("内容变化不会改变树结构（避免列表重建）", treeBefore == treeAfter)

            print("文件监听")
            let watchRoot = root.appendingPathComponent("watch")
            try FileManager.default.createDirectory(at: watchRoot, withIntermediateDirectories: true)
            let watcher = VaultWatcher()
            var fired = false
            watcher.onChange = { fired = true }
            watcher.start(watchRoot)
            try "x".write(to: watchRoot.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
            let watchDeadline = Date().addingTimeInterval(4)
            while !fired, Date() < watchDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            watcher.stop()
            check("FSEvents 能收到文件变化", fired)

            print("纯文本 txt")
            let txtRoot = root.appendingPathComponent("txt-vault")
            try FileManager.default.createDirectory(at: txtRoot, withIntermediateDirectories: true)
            let txtURL = txtRoot.appendingPathComponent("日志.txt")
            try "第一行\n\n# 不是标题\n<tag>\n".write(to: txtURL, atomically: true, encoding: .utf8)
            _ = txtURL

            let txtTree = AppModel.buildTree(at: txtRoot, root: txtRoot)
            check("扫描包含 txt", txtTree.contains { $0.name == "日志.txt" })
            check("识别为纯文本", Note(url: txtURL, root: txtRoot).isPlainText)
            check("md 不是纯文本", !Note(url: txtRoot.appendingPathComponent("a.md"), root: txtRoot).isPlainText)

            let plain = Markdown.plainBody("第一行\n# 不是标题\n<script>")
            check("包在 pre.plain 里", plain.contains("<pre class=\"plain\">"))
            check("不解析 Markdown", plain.contains("# 不是标题") && !plain.contains("<h1>"))
            check("转义 HTML", plain.contains("&lt;script&gt;"))
            check("保留换行", plain.contains("第一行\n# 不是标题"))

            let plainStorage = NSTextStorage(string: "# 标题\n正文")
            let plainHighlighter = MarkdownSyntaxHighlighter()
            plainHighlighter.isPlainText = true
            plainHighlighter.highlightAll(plainStorage)
            let plainTitleFont = plainStorage.attributes(at: 0, effectiveRange: nil)[.font] as? NSFont
            check("txt 不做标题放大", abs((plainTitleFont?.pointSize ?? 0) - 15) < 0.5)

            print("新建/移动")
            let vaultRoot = root.appendingPathComponent("dest-vault")
            let selectedFolder = vaultRoot.appendingPathComponent("已存在")
            try FileManager.default.createDirectory(at: selectedFolder, withIntermediateDirectories: true)

            check("没选中时建在根目录",
                  AppModel.folderDestination(vault: vaultRoot, explicit: nil, selection: []).path == vaultRoot.path)
            check("选中文件夹时建在它里面",
                  AppModel.folderDestination(vault: vaultRoot, explicit: nil, selection: [selectedFolder]).path == selectedFolder.path)
            check("右键指定的优先级最高",
                  AppModel.folderDestination(vault: vaultRoot, explicit: selectedFolder, selection: []).path == selectedFolder.path)
            check("选中多个时回到根目录",
                  AppModel.folderDestination(vault: vaultRoot, explicit: nil,
                                             selection: [selectedFolder, selectedFolder.appendingPathComponent("x")]).path == vaultRoot.path)

            // 批量移动
            let batchA = vaultRoot.appendingPathComponent("a.md")
            let batchB = vaultRoot.appendingPathComponent("b.md")
            try "a".write(to: batchA, atomically: true, encoding: .utf8)
            try "b".write(to: batchB, atomically: true, encoding: .utf8)
            _ = try AppModel.moveItem(at: batchA, to: selectedFolder)
            _ = try AppModel.moveItem(at: batchB, to: selectedFolder)
            check("批量移动后两个文件都在目标目录",
                  FileManager.default.fileExists(atPath: selectedFolder.appendingPathComponent("a.md").path)
                  && FileManager.default.fileExists(atPath: selectedFolder.appendingPathComponent("b.md").path))

            print("搜索定位与附件")
            check("中文命中位置", AppModel.firstMatchRange(of: "同步", in: "本地同步设计")?.location == 2)
            check("大小写不敏感", AppModel.firstMatchRange(of: "GIT", in: "用 git 同步")?.location == 2)
            check("找不到返回 nil", AppModel.firstMatchRange(of: "不存在", in: "abc") == nil)
            check("附件名清洗", MarkdownTextView.sanitizeAttachmentName("截屏 2026/10/23.png") == "截屏-2026-10-23-png")
            check("附件名不留空", MarkdownTextView.sanitizeAttachmentName("///") == "image")
            var bigStats = AttachmentStats()
            bigStats.bytes = 120 * 1024 * 1024
            check("超过 100MB 触发提示", bigStats.isLarge)

            print("Git")
            let git = GitEngine(token: "")
            let probeBare = root.appendingPathComponent("probe.git")
            _ = try git.run(["init", "--bare", "-b", "main", probeBare.lastPathComponent], in: root)
            check("验证连接能探测远端", try git.lsRemote(probeBare.path).contains("可访问"))
            _ = try git.run(["init", "--bare", "-b", "main", bare.lastPathComponent], in: root)
            check("创建裸仓库", FileManager.default.fileExists(atPath: bare.appendingPathComponent("HEAD").path))

            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try git.initialize(remote: bare.path, in: work)
            check("初始化工作仓库", git.isRepository(work))
            check("origin 已配置", git.remoteURL(work) == bare.path)
            check("分支名", (try git.currentBranch(work)) == "main")

            try "# 第一篇\n".write(to: work.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
            let first = try git.commitIfNeeded("note: 第一次", in: work)
            check("首次提交", first.committed && !first.hash.isEmpty)
            check("无改动不重复提交", try git.commitIfNeeded("noop", in: work).committed == false)

            let push = try git.run(["push", "-u", "origin", "main"], in: work)
            check("推送到远端", push.ok)

            try git.clone(bare.path, into: other)
            check("克隆成功", FileManager.default.fileExists(atPath: other.appendingPathComponent("a.md").path))

            try "# 第一篇\n来自另一台机器的修改\n".write(
                to: other.appendingPathComponent("a.md"), atomically: true, encoding: .utf8
            )
            _ = try git.commitIfNeeded("note: 另一台机器", in: other)
            check("第二台机器提交", try git.run(["push"], in: other).ok)

            let outcome = try git.sync(work)
            let merged = try String(contentsOf: work.appendingPathComponent("a.md"), encoding: .utf8)
            check("同步成功（\(outcome.summary)）", merged.contains("来自另一台机器"))

            print("冲突")
            try "# A\n".write(to: other.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
            _ = try git.commitIfNeeded("other: A", in: other)
            check("另一台机器推送", try git.run(["push"], in: other).ok)

            try "# B\n".write(to: work.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
            _ = try git.commitIfNeeded("work: B", in: work)

            let conflictOutcome = try git.sync(work)
            check("识别出冲突（\(conflictOutcome.summary)）", conflictOutcome.summary.contains("冲突"))
            check("没有留在 rebase 中途", git.isRebaseInProgress(work) == false)
            let kept = try String(contentsOf: work.appendingPathComponent("a.md"), encoding: .utf8)
            check("本地内容没有被覆盖", kept.contains("B"))

            print("笔记库")
            try "# 本地\n".write(to: work.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
            let note = Note(url: work.appendingPathComponent("b.md"), root: work)
            check("笔记标题", note.title == "b")
            check("相对路径", note.relativePath == "b.md")

        } catch {
            print("  ✗ 异常: \(error.localizedDescription)")
            failures.append("异常 \(error.localizedDescription)")
        }

        try? FileManager.default.removeItem(at: root)

        if ProcessInfo.processInfo.environment["TONGMD_NETWORK_TEST"] == "1" {
            print("联网（可选）")
            do {
                let summary = try GitEngine(token: "").lsRemote("https://github.com/octocat/Hello-World.git")
                check("走系统代理能访问 GitHub（\(summary)）", summary.contains("可访问"))
            } catch {
                check("走系统代理能访问 GitHub（\(error.localizedDescription)）", false)
            }
        }

        if failures.isEmpty {
            print("\n全部通过")
            return 0
        }
        print("\n失败 \(failures.count) 项")
        return 1
    }
}
#endif

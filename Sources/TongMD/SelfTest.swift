#if DEBUG
import AppKit
import Foundation

/// 开发期自检：不依赖 GUI，直接验证 git 同步层和 Markdown 渲染。
/// 用法：`build/TongMD.app/Contents/MacOS/TongMD --self-test`（工作目录任意）
enum SelfTest {

    static func run() -> Int32 {
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
            let pasted = pasteView.insertPastedImage(from: pasteboard)
            check("能识别剪贴板里的图片", pasted)
            let pastedFiles = (try? FileManager.default.contentsOfDirectory(atPath: pasteDir.appendingPathComponent("assets").path)) ?? []
            check("图片写进了 assets/", pastedFiles.contains { $0.hasSuffix(".png") })
            check("插入了 Markdown 引用", pasteView.string.contains("(assets/") && pasteView.string.contains("!["))

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

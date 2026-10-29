import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {

    private enum Keys {
        static let repo = "repoURL"
        static let vault = "vaultPath"
        static let autoCommit = "autoCommit"
        static let autoSync = "autoSync"
        static let dailyTemplate = "dailyTemplate"
        static let noteTemplate = "noteTemplate"
        static let mode = "editorMode"
        static let fontSize = "editorFontSize"
        static let showOutline = "showOutline"
    }

    private let defaults = UserDefaults.standard

    // MARK: - 设置

    @Published var repoURLString: String = "" {
        didSet { defaults.set(repoURLString, forKey: Keys.repo) }
    }
    @Published var token: String = "" {
        didSet {
            // 粘贴进来的可能是十六进制字符串，存之前就还原掉
            let normalized = Self.normalizeToken(token)
            if normalized.wasHex, normalized.value != token {
                token = normalized.value
                // didSet 不会因为内部赋值再次触发，这里补上落盘
                _ = TokenStore.save(normalized.value)
                return
            }
            if !TokenStore.save(token) {
                alertMessage = "Token 没能保存到本机配置（~/Library/Application Support/TongMD），检查一下目录权限。"
            }
        }
    }
    @Published var autoCommit: Bool = true {
        didSet { defaults.set(autoCommit, forKey: Keys.autoCommit) }
    }
    /// 保存/本地提交后自动 pull + push
    @Published var autoSync: Bool = true {
        didSet { defaults.set(autoSync, forKey: Keys.autoSync) }
    }
    @Published var dailyTemplate: String = Templates.defaultDaily {
        didSet { defaults.set(dailyTemplate, forKey: Keys.dailyTemplate) }
    }
    @Published var noteTemplate: String = "" {
        didSet { defaults.set(noteTemplate, forKey: Keys.noteTemplate) }
    }
    @Published var captureText = ""
    private var capturePanel: NSPanel?
    @Published var showSettings = false
    @Published var showCheatSheet = false
    @Published var alertMessage: String?
    @Published var infoMessage: String?

    @Published private(set) var vaultPath: String? {
        didSet {
            guard oldValue != vaultPath else { return }
            if !transientVault {
                defaults.set(vaultPath, forKey: Keys.vault)
            }
            if vaultPath == nil {
                notes = []
                selection = nil
                text = ""
                previewHTML = ""
                previewBody = ""
                branch = ""
            }
        }
    }

    // MARK: - 笔记

    @Published private(set) var notes: [Note] = []
    @Published private(set) var tree: [VaultNode] = []
    @Published private(set) var attachmentStats = AttachmentStats()
    @Published var openTabs: [URL] = []
    /// 选中图片附件时，详情区显示预览而不是编辑器
    @Published var selectedAttachment: URL?
    @Published var pendingAttachmentDeletion: URL?
    @Published var pendingConsolidation = false
    @Published private(set) var searchIndexBytes = 0
    @Published var brokenLinks: [BrokenLink] = []
    @Published var showBrokenLinks = false
    @Published private(set) var tagCounts: [TagCount] = []
    @Published var activeTag: String?
    @Published var showOutline: Bool = false {
        didSet { defaults.set(showOutline, forKey: Keys.showOutline) }
    }
    /// 预览里要滚动到的标题（点大纲时设置，滚完清空）
    @Published var pendingPreviewHeading: String?
    /// 当前高亮的大纲标题（点击或光标移动时更新）
    @Published var activeOutlineOffset: Int?

    var visibleNodes: [VisibleNode] {
        let collapsed = Set(collapsedFolders.map { $0.standardizedFileURL.path })
        var result: [VisibleNode] = []

        func walk(_ nodes: [VaultNode], _ depth: Int) {
            for node in nodes {
                result.append(VisibleNode(node: node, depth: depth))
                if node.isDirectory, !collapsed.contains(node.url.standardizedFileURL.path) {
                    walk(node.children ?? [], depth + 1)
                }
            }
        }
        walk(tree, 0)
        return result
    }
    private var pdfExporter: PDFExporter?
    var outline: [OutlineItem] { Outline.items(in: text) }

    /// 点大纲条目：常规模式滚动编辑器，预览模式滚动 WebView
    func jumpToOutline(_ item: OutlineItem) {
        activeOutlineOffset = item.offset
        pendingPreviewHeading = item.title
        if mode == .preview {
            pendingScrollRange = nil
        } else {
            pendingScrollRange = NSRange(location: item.offset, length: 0)
        }
    }

    /// 光标移动时，把高亮切到它前面最近的那个标题
    func updateActiveOutline(for caret: Int) {
        activeOutlineOffset = Self.nearestHeadingOffset(in: outline, caret: caret)
    }

    nonisolated static func nearestHeadingOffset(in items: [OutlineItem], caret: Int) -> Int? {
        var result: Int?
        for item in items where item.offset <= caret {
            result = item.offset
        }
        return result
    }

    @Published var conflicts: [ConflictFile] = []
    @Published var showConflicts = false
    @Published var conflictIndex = 0
    @Published var mergeDraft = ""
    @Published var showMergeEditor = false
    private var conflictBranch = ""

    @Published var showHistory = false
    @Published var historyEntries: [FileVersion] = []
    @Published var historySelection: String? {
        didSet {
            guard oldValue != historySelection, let hash = historySelection else { return }
            loadHistoryPreview(hash)
        }
    }
    @Published var historyPreview = ""
    @Published var historyLoading = false
    @Published var historyNoteURL: URL?
    @Published var showQuickSwitcher = false
    @Published var quickQuery = ""
    /// 被正文引用到的图片文件名（用于侧栏标识）
    @Published private(set) var referencedImageNames: Set<String> = []
    /// 侧栏里的多选（文件或文件夹）。单选文件时同步打开它。
    @Published var sidebarSelection: Set<URL> = [] {
        didSet {
            guard oldValue != sidebarSelection else { return }
            guard sidebarSelection.count == 1, let url = sidebarSelection.first else { return }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                collapsedFolders.remove(url)
            } else if Self.isImageFile(url) {
                selectedAttachment = url
            } else if url != selection {
                selection = url
                selectedAttachment = nil
            }
            if !isDirectory, !Self.isImageFile(url), !openTabs.contains(url) {
                openTabs.append(url)
            }
        }
    }
    /// 默认全部展开，只记收起的目录
    @Published var collapsedFolders: Set<URL> = []
    @Published var selection: URL? {
        didSet {
            guard oldValue != selection else { return }
            flushPendingSave()
            loadSelected()
        }
    }
    @Published private(set) var text: String = ""
    @Published private(set) var previewHTML: String = ""
    @Published private(set) var previewBody: String = ""
    @Published private(set) var isDirty = false
    @Published var searchText: String = "" {
        didSet { scheduleSearch() }
    }
    @Published private(set) var searchResults: [SearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var backlinks: [Backlink] = []
    @Published var searchFocusToken = 0
    /// 点了不存在的双链，等用户确认是否新建
    @Published var pendingWikiLink: String?
    /// 从搜索结果跳进笔记后，要滚动并选中的位置
    @Published var pendingScrollRange: NSRange?
    @Published var dropTarget: URL?
    @Published var showNewFolderPrompt = false
    @Published var newFolderName = "新建文件夹"
    @Published var newFolderDestination = "笔记库根目录"
    @Published var renameTarget: URL?
    @Published var renameText = ""
    /// 正文字号，编辑器与预览共用；标题按比例缩放
    @Published var fontSize: Double = 15 {
        didSet {
            let clamped = min(max(fontSize, 11), 24)
            if clamped != fontSize {
                fontSize = clamped
                return
            }
            defaults.set(fontSize, forKey: Keys.fontSize)
            previewHTML = Markdown.document(body: previewBody, fontSize: CGFloat(fontSize) + 1)
        }
    }
    @Published var mode: EditorMode = .split {
        didSet { defaults.set(mode.rawValue, forKey: Keys.mode) }
    }

    // MARK: - 同步

    @Published private(set) var syncState: SyncState = .idle
    @Published private(set) var branch: String = ""
    @Published private(set) var pendingChanges: Int = 0

    private var saveTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var commitTask: Task<Void, Never>?
    private var loadedMTime: Date?
    private var isCommitting = false
    /// 全文搜索用的正文缓存：mtime 没变就不重读
    private var contentCache: [URL: (mtime: Date?, text: String)] = [:]
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    /// 双链跳转的历史，供 ⌘[ 返回
    private var navigationHistory: [URL] = []
    private var newFolderParent: URL?
    private var lastReloadAt = Date.distantPast
    private var lastAttachmentScanAt = Date.distantPast
    private var lastPendingScanAt = Date.distantPast
    private let watcher = VaultWatcher()
    private var referenceRefreshTask: Task<Void, Never>?
    private var tagRefreshTask: Task<Void, Never>?
    private var searchIndex: SearchIndex?
    private var reindexTask: Task<Void, Never>?
    private var autoSyncTask: Task<Void, Never>?
    private var clipboardMonitor: Any?
    /// --vault 传进来的临时路径，不写进偏好设置，免得下次启动还停在演示库
    private var transientVault = false

    // MARK: - 派生

    var vaultURL: URL? {
        vaultPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    var isSearchActive: Bool { !searchText.trimmed.isEmpty }

    var canGoBack: Bool { !navigationHistory.isEmpty }

    var isPlainTextNote: Bool {
        guard let selection else { return false }
        return selection.pathExtension.lowercased() == "txt"
    }

    var currentNote: Note? {
        guard let url = selection else { return nil }
        return notes.first { $0.url == url }
    }

    var isBusy: Bool {
        if case .running = syncState { return true }
        return false
    }

    // MARK: - 生命周期

    init(temporaryVault: URL? = nil) {
        repoURLString = defaults.string(forKey: Keys.repo) ?? ""
        autoCommit = defaults.object(forKey: Keys.autoCommit) as? Bool ?? true
        autoSync = defaults.object(forKey: Keys.autoSync) as? Bool ?? true
        dailyTemplate = defaults.string(forKey: Keys.dailyTemplate) ?? Templates.defaultDaily
        noteTemplate = defaults.string(forKey: Keys.noteTemplate) ?? ""
        mode = EditorMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .split
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 15
        showOutline = defaults.object(forKey: Keys.showOutline) as? Bool ?? false
        token = TokenStore.load()

        installClipboardShortcuts()

        // 调试/脚本入口：TongMD --vault /path/to/notes
        var launchVault = temporaryVault
        if launchVault == nil, let index = CommandLine.arguments.firstIndex(of: "--vault"),
           CommandLine.arguments.count > index + 1 {
            launchVault = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        if let launchVault, FileManager.default.fileExists(atPath: launchVault.path) {
            transientVault = true
            vaultPath = launchVault.path
            reloadNotes()
            selection = notes.first?.url
            refreshBranch()
            startWatching()
            return
        }

        if let path = defaults.string(forKey: Keys.vault),
           FileManager.default.fileExists(atPath: path) {
            vaultPath = path
            reloadNotes()
            selection = notes.first?.url
            refreshBranch()
            startWatching()
        }
    }

    deinit {
        if let clipboardMonitor { NSEvent.removeMonitor(clipboardMonitor) }
    }

    // MARK: - 笔记库

    func setVault(_ url: URL) {
        vaultPath = url.path
        reloadNotes()
        selection = notes.first?.url
        refreshBranch()
        startWatching()
    }

    private func openSearchIndexIfNeeded() {
        guard vaultURL != nil else {
            searchIndex = nil
            return
        }
        guard searchIndex == nil else { return }
        searchIndex = try? SearchIndex(
            path: TokenStore.directory.appendingPathComponent("search.sqlite3")
        )
        refreshSearchIndexSize()
    }

    private func startWatching() {
        openSearchIndexIfNeeded()
        scheduleReindex()
        // 自检/快照不装 FSEvents：否则测试会留下大量监听和后台 git 子进程
        if CommandLine.arguments.contains("--self-test")
            || CommandLine.arguments.contains("--snapshot") { return }
        guard let vault = vaultURL else {
            watcher.stop()
            return
        }
        watcher.onChange = { [weak self] in
            guard let self, !self.isDirty else { return }

            // 只是当前这篇被外部改了：重载正文即可，不动侧栏
            if let url = self.selection, Self.modificationDate(of: url) != self.loadedMTime {
                self.loadSelected()
                return
            }

            // 其它情况（增删改文件名）才重建列表，而且限频
            guard Date().timeIntervalSince(self.lastReloadAt) > 1.5 else { return }
            self.reloadNotes()
        }
        watcher.start(vault)
    }

    func pickVaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择笔记库"
        panel.message = "选一个装 md 文件的文件夹（可以是已有的 git 仓库）"
        if panel.runModal() == .OK, let url = panel.url {
            setVault(url)
        }
    }

    func reloadNotes() {
        guard let root = vaultURL else {
            notes = []
            tree = []
            return
        }

        let newTree = Self.buildTree(at: root, root: root)
        let newNotes = Self.flatten(newTree)
            .filter { $0.isNote }
            .map { Note(url: $0.url, root: root) }

        // 关键：内容保存不会改变树结构，这里比较后再赋值，避免 SwiftUI 白白重建行
        if newTree != tree { tree = newTree }
        if newNotes != notes { notes = newNotes }
        lastReloadAt = Date()
        refreshContentCache()
        refreshReferencedImages()
        refreshTags()
        scheduleReindex()

        if let selected = selection, !notes.contains(where: { $0.url == selected }) {
            selection = nil
        }
        // @Published 赋值会触发整棵视图刷新，内容没变就别赋值
        let stillExisting = sidebarSelection.filter { FileManager.default.fileExists(atPath: $0.path) }
        if stillExisting != sidebarSelection { sidebarSelection = stillExisting }

        let validTabs = openTabs.filter { FileManager.default.fileExists(atPath: $0.path) }
        if validTabs != openTabs { openTabs = validTabs }
        refreshAttachmentStats()
        updateBacklinks()
        updatePendingChanges()
        if isSearchActive { scheduleSearch() }
    }

    /// 目录在前、文件在后，各自按名称排序
    nonisolated static func buildTree(at directory: URL, root: URL) -> [VaultNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []

        var nodes: [VaultNode] = []
        for url in contents {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let name = url.lastPathComponent
            if isDirectory {
                if name == ".git" || name == "node_modules" || name == ".obsidian" { continue }
                nodes.append(VaultNode(
                    url: url,
                    name: name,
                    isDirectory: true,
                    relativePath: relativePath(of: url, root: root),
                    children: buildTree(at: url, root: root)
                ))
            } else {
                let ext = url.pathExtension.lowercased()
                guard VaultNode.noteExtensions.contains(ext) || VaultNode.imageExtensions.contains(ext) else { continue }
                nodes.append(VaultNode(
                    url: url,
                    name: name,
                    isDirectory: false,
                    relativePath: relativePath(of: url, root: root),
                    children: nil
                ))
            }
        }

        return nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    nonisolated static func flatten(_ nodes: [VaultNode]) -> [VaultNode] {
        nodes.flatMap { node -> [VaultNode] in
            if let children = node.children {
                return [node] + flatten(children)
            }
            return [node]
        }
    }

    nonisolated static func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        var relative = url.standardizedFileURL.path
        if relative.hasPrefix(rootPath) { relative = String(relative.dropFirst(rootPath.count)) }
        if relative.hasPrefix("/") { relative = String(relative.dropFirst()) }
        return relative
    }

    /// 所有文件夹（给「移动到」菜单用）
    var allFolders: [VaultNode] {
        Self.flatten(tree).filter { $0.isDirectory }
    }

    // MARK: - 每日笔记与速记

    func dailyNoteURL(for date: Date = Date()) -> URL? {
        guard let vault = vaultURL else { return nil }
        return vault
            .appendingPathComponent("daily", isDirectory: true)
            .appendingPathComponent(Templates.dailyName(for: date) + ".md")
    }

    @discardableResult
    func ensureDailyNote(for date: Date = Date()) -> URL? {
        guard let url = dailyNoteURL(for: date) else { return nil }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            let body = Templates.render(dailyTemplate, title: Templates.dailyName(for: date), date: date)
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    func openDailyNote() {
        guard let url = ensureDailyNote() else {
            showSettings = true
            return
        }
        reloadNotes()
        openNote(url)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggleQuickCapture() {
        if let panel = capturePanel, panel.isVisible {
            panel.orderOut(nil)
            return
        }

        if capturePanel == nil {
            let hosting = NSHostingView(
                rootView: QuickCaptureView().environmentObject(self)
            )
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 150),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.contentView = hosting
            capturePanel = panel
        }

        captureText = ""
        capturePanel?.center()
        capturePanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismissQuickCapture() {
        captureText = ""
        capturePanel?.orderOut(nil)
    }

    func submitCapture() {
        let content = captureText.trimmed
        guard !content.isEmpty, let url = ensureDailyNote() else {
            dismissQuickCapture()
            return
        }

        appendCapture(content, to: url)
        captureText = ""
        capturePanel?.orderOut(nil)
        reloadNotes()
        if selection == url { loadSelected() }
    }

    private func appendCapture(_ text: String, to url: URL) {
        var body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let line = "- \(formatter.string(from: Date())) \(text)"

        let heading = "## 速记"
        if let headingRange = body.range(of: heading) {
            let afterHeading = body.index(after: headingRange.upperBound)
            if let newline = body[afterHeading...].firstIndex(of: "\n") {
                body.insert(contentsOf: line + "\n", at: body.index(after: newline))
            } else {
                body += "\n\n" + line + "\n"
            }
        } else {
            body += "\n\n" + heading + "\n" + line + "\n"
        }

        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    func createNote(in folder: URL? = nil, fileExtension: String = "md") {
        guard let vault = vaultURL else {
            showSettings = true
            return
        }
        flushPendingSave()

        let parent = folder ?? vault
        let ext = fileExtension.lowercased() == "txt" ? "txt" : "md"
        var url = parent.appendingPathComponent("未命名.\(ext)")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = parent.appendingPathComponent("未命名 \(index).\(ext)")
            index += 1
        }
        do {
            let initial: String
            if ext == "txt" {
                initial = ""
            } else if noteTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                initial = "# \n"
            } else {
                initial = Templates.render(noteTemplate, title: "未命名")
            }
            try initial.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alertMessage = "新建失败：\(error.localizedDescription)"
            return
        }
        reloadNotes()
        openNote(url)
    }

    func trash(_ note: Note) {
        flushPendingSave()
        do {
            try FileManager.default.trashItem(at: note.url, resultingItemURL: nil)
            contentCache.removeValue(forKey: note.url)
            if selection == note.url { selection = nil }
            reloadNotes()
        } catch {
            alertMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    func openNote(_ url: URL) {
        // 图片不是笔记：走附件预览，绝不能当文本读
        if Self.isImageFile(url) {
            sidebarSelection = [url]
            selectedAttachment = url
            return
        }
        sidebarSelection = [url]
        selectedAttachment = nil
        if selection != url { selection = url }
    }

    nonisolated static func isImageFile(_ url: URL) -> Bool {
        VaultNode.imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// 哪些笔记引用了这个附件（按文件名匹配相对路径）
    func referencingNotes(for attachment: URL) -> [Note] {
        let name = attachment.lastPathComponent
        return notes.filter { note in
            guard let content = contentCache[note.url]?.text else { return false }
            return content.contains(name)
        }
    }

    // MARK: - 链接一致性

    private static func filesUnder(_ folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(url)
            }
        }
        return files
    }

    /// 把所有笔记里的相对链接按 moves 重算，并可选地改写 wiki 链接标题
    private func rewriteAllLinks(moves: [String: String], titleChange: (old: String, new: String)?) {
        guard let vault = vaultURL, !moves.isEmpty || titleChange != nil else { return }

        let noteURLs = Self.flatten(Self.buildTree(at: vault, root: vault))
            .filter { $0.isNote }
            .map(\.url)
        let inverse = Dictionary(uniqueKeysWithValues: moves.map { ($1, $0) })

        for newURL in noteURLs {
            let oldURL = inverse[newURL.path].map { URL(fileURLWithPath: $0) } ?? newURL
            guard let data = try? Data(contentsOf: newURL),
                  let text = String(data: data, encoding: .utf8) else { continue }

            let updated = LinkRewriter.rewrite(
                in: text,
                oldNotePath: oldURL,
                newNotePath: newURL,
                moves: moves,
                titleChange: titleChange
            )
            if updated != text {
                try? updated.write(to: newURL, atomically: true, encoding: .utf8)
            }
        }
    }

    /// 检查断链：不存在的 [[笔记]] 和不存在的本地文件
    func checkBrokenLinks() {
        let titles = Set(notes.map { $0.title.lowercased() })
        var found: [BrokenLink] = []
        var seen = Set<String>()

        for note in notes {
            guard let text = contentCache[note.url]?.text else { continue }

            for target in WikiLinks.targets(in: text) {
                let base = target.split(separator: "#").first.map(String.init) ?? target
                let last = (base as NSString).lastPathComponent
                if !titles.contains(base.lowercased()), !titles.contains(last.lowercased()) {
                    let key = "w|\(note.url.path)|\(target)"
                    if seen.insert(key).inserted {
                        found.append(BrokenLink(note: note, target: target, isWiki: true))
                    }
                }
            }

            let directory = note.url.deletingLastPathComponent()
            for source in LinkRewriter.localLinkTargets(in: text) {
                let path = source.removingPercentEncoding ?? source
                let absolute = directory.appendingPathComponent(path).standardizedFileURL
                if !FileManager.default.fileExists(atPath: absolute.path) {
                    let key = "f|\(note.url.path)|\(source)"
                    if seen.insert(key).inserted {
                        found.append(BrokenLink(note: note, target: source, isWiki: false))
                    }
                }
            }
        }

        brokenLinks = found
        showBrokenLinks = true
    }

    // MARK: - 附件整理

    /// 把散落在各目录 assets/ 里的文件搬到根 assets/，并改写笔记里的引用
    func consolidateAttachments() {
        defer { pendingConsolidation = false }
        guard let vault = vaultURL else { return }

        let rootAssets = vault.appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootAssets, withIntermediateDirectories: true)
        let allNodes = Self.flatten(tree)
        let folders = allNodes.filter {
            $0.isDirectory
                && $0.name.lowercased() == "assets"
                && $0.url.standardizedFileURL != rootAssets.standardizedFileURL
        }
        guard !folders.isEmpty else {
            infoMessage = "没有需要整理的附件目录。"
            return
        }

        var moved: [String: String] = [:]
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder.url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for file in files {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                guard let destination = try? Self.moveItem(at: file, to: rootAssets) else { continue }
                moved[file.standardizedFileURL.path] = destination.standardizedFileURL.path
            }

            let leftover = (try? FileManager.default.contentsOfDirectory(atPath: folder.url.path)) ?? []
            if leftover.isEmpty { try? FileManager.default.removeItem(at: folder.url) }
        }

        guard !moved.isEmpty else {
            infoMessage = "没有找到可整理的附件。"
            return
        }

        var rewritten = 0
        for note in notes {
            guard let data = try? Data(contentsOf: note.url),
                  var text = String(data: data, encoding: .utf8) else { continue }
            let updated = Self.rewriteImageLinks(
                in: text,
                noteDirectory: note.url.deletingLastPathComponent(),
                moved: moved
            )
            if updated != text {
                if (try? updated.write(to: note.url, atomically: true, encoding: .utf8)) != nil {
                    rewritten += 1
                }
                text = updated
            }
        }

        reloadNotes()
        infoMessage = "已移动 \(moved.count) 个附件到根 assets/，更新了 \(rewritten) 篇笔记的引用。"
    }

    /// 把笔记里指向已移动图片的路径，改成从新位置算出的相对路径
    nonisolated static func rewriteImageLinks(
        in text: String,
        noteDirectory: URL,
        moved: [String: String]
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^)\s]+)\)"#) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result = text

        for match in matches.reversed() {
            let srcRange = match.range(at: 1)
            let src = ns.substring(with: srcRange)
            if src.hasPrefix("http") || src.hasPrefix("data:") { continue }
            let decoded = src.removingPercentEncoding ?? src
            let absolute = noteDirectory.appendingPathComponent(decoded).standardizedFileURL
            guard let newPath = moved[absolute.path] else { continue }

            let newSource = AttachmentStore.relativePath(
                from: noteDirectory,
                to: URL(fileURLWithPath: newPath)
            )
            result = (result as NSString).replacingCharacters(in: srcRange, with: newSource)
        }
        return result
    }

    func requestDeleteAttachment(_ url: URL) {
        if referencingNotes(for: url).isEmpty {
            trashItem(url)
        } else {
            pendingAttachmentDeletion = url
        }
    }

    func deleteAttachmentNow() {
        guard let url = pendingAttachmentDeletion else { return }
        pendingAttachmentDeletion = nil
        trashItem(url)
    }

    /// 从搜索结果跳转：打开后滚动到第一处命中
    func openSearchResult(_ note: Note) {
        openNote(note.url)
        if let range = Self.firstMatchRange(of: searchText.trimmed, in: text) {
            pendingScrollRange = range
        }
    }

    nonisolated static func firstMatchRange(of keyword: String, in text: String) -> NSRange? {
        guard !keyword.isEmpty else { return nil }
        guard let range = text.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }
        let location = text.distance(from: text.startIndex, to: range.lowerBound)
        let length = text.distance(from: range.lowerBound, to: range.upperBound)
        return NSRange(location: location, length: length)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - 文件夹与移动

    /// 目标目录规则（可预测优先）：
    /// 1. 右键某个文件夹 → 建在它里面
    /// 2. 当前选中的正好是一个文件夹 → 建在它里面
    /// 3. 其它情况（选中笔记、多选、没选）→ 建在笔记库根目录
    func createFolder(in parent: URL? = nil) {
        guard let vault = vaultURL else {
            showSettings = true
            return
        }

        let destination = Self.folderDestination(vault: vault, explicit: parent, selection: sidebarSelection)

        newFolderParent = destination
        newFolderName = "新建文件夹"
        let relative = Self.relativePath(of: destination, root: vault)
        newFolderDestination = relative.isEmpty ? "笔记库根目录" : relative
        showNewFolderPrompt = true
    }

    func commitNewFolder() {
        defer { showNewFolderPrompt = false }
        guard let parent = newFolderParent else { return }
        let name = newFolderName.trimmed
        guard !name.isEmpty else { return }

        let folder = Self.uniqueDestination(for: parent.appendingPathComponent(name), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            reloadNotes()
            collapsedFolders.remove(parent)
            sidebarSelection = [folder]
        } catch {
            alertMessage = "新建文件夹失败：\(error.localizedDescription)"
        }
    }

    /// 新建文件夹落在哪里：右键指定的优先，其次是选中的文件夹，否则根目录。
    /// 之前用「当前笔记的父目录」，导致建完一个又建到上一个里面，已废弃。
    nonisolated static func folderDestination(vault: URL, explicit: URL?, selection: Set<URL>) -> URL {
        if let explicit { return explicit }
        if selection.count == 1,
           let first = selection.first,
           (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return first
        }
        return vault
    }

    func beginRename(_ url: URL) {
        renameTarget = url
        renameText = url.deletingPathExtension().lastPathComponent
    }

    func commitRename() {
        guard let target = renameTarget else { return }
        defer { renameTarget = nil }

        let name = renameText.trimmed
        guard !name.isEmpty else { return }

        guard Self.canRename(target) else {
            alertMessage = "assets 是附件约定目录，改名会让所有图片引用失效，已阻止。"
            return
        }
        let isDirectory = (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        var fileName = name
        if !isDirectory, !target.pathExtension.isEmpty,
           !name.lowercased().hasSuffix("." + target.pathExtension.lowercased()) {
            fileName += "." + target.pathExtension
        }

        let destination = target.deletingLastPathComponent().appendingPathComponent(fileName)
        guard destination != target else { return }

        let wasSelected = selection == target
        do {
            try FileManager.default.moveItem(at: target, to: destination)

            var moves = [target.standardizedFileURL.path: destination.standardizedFileURL.path]
            if isDirectory {
                for newFile in Self.filesUnder(destination) {
                    let suffix = newFile.path.dropFirst(destination.path.count)
                    moves[target.path + suffix] = newFile.path
                }
            }

            let oldTitle = target.deletingPathExtension().lastPathComponent
            let newTitle = destination.deletingPathExtension().lastPathComponent
            let titleChange: (old: String, new: String)? = isDirectory
                ? nil
                : (VaultNode.noteExtensions.contains(target.pathExtension.lowercased())
                   ? (oldTitle, newTitle) : nil)

            rewriteAllLinks(moves: moves, titleChange: titleChange)
            reloadNotes()
            if wasSelected {
                selection = destination
                loadSelected()
            }
        } catch {
            alertMessage = "重命名失败：\(error.localizedDescription)"
        }
    }

    /// assets 是附件约定目录，改名会让所有相对引用失效
    nonisolated static func canRename(_ url: URL) -> Bool {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDirectory, url.lastPathComponent.lowercased() == "assets" { return false }
        return true
    }

    private func refreshReferencedImages() {
        let imageNames = Set(Self.flatten(tree).filter { $0.isImage }.map { $0.name })
        guard !imageNames.isEmpty else {
            if !referencedImageNames.isEmpty { referencedImageNames = [] }
            return
        }
        var referenced = Set<String>()
        for note in notes {
            guard let content = contentCache[note.url]?.text else { continue }
            for name in imageNames where content.contains(name) {
                referenced.insert(name)
            }
        }
        if referenced != referencedImageNames { referencedImageNames = referenced }
    }

    func refreshSearchIndexSize() {
        searchIndexBytes = searchIndex?.sizeBytes ?? 0
    }

    /// 设置页：重建索引
    func rebuildSearchIndex() {
        guard let index = searchIndex else { return }
        let documents = notes.map {
            SearchIndex.Document(path: $0.url.path, title: $0.title, body: contentCache[$0.url]?.text ?? "")
        }
        Task {
            await Task.detached(priority: .utility) { index.replaceAll(documents) }.value
            refreshSearchIndexSize()
            infoMessage = "索引已重建。"
        }
    }

    /// 设置页：压缩索引
    func compactSearchIndex() {
        guard let index = searchIndex else { return }
        Task {
            await Task.detached(priority: .utility) { index.compact() }.value
            let before = searchIndexBytes
            refreshSearchIndexSize()
            let saved = max(0, before - searchIndexBytes)
            infoMessage = "索引已压缩，回收 \(ByteCountFormatter.string(fromByteCount: Int64(saved), countStyle: .file))。"
        }
    }

    private func scheduleReindex() {
        guard let index = searchIndex else { return }
        let documents = notes.map {
            SearchIndex.Document(
                path: $0.url.path,
                title: $0.title,
                body: contentCache[$0.url]?.text ?? ""
            )
        }

        reindexTask?.cancel()
        reindexTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                index.replaceAll(documents)
            }.value
            refreshSearchIndexSize()
        }
    }

    /// ⌘P 结果：空查询显示最近笔记，否则按标题模糊排序
    var quickResults: [Note] {
        let query = quickQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Array(notes.prefix(12)) }

        let byTitle = Dictionary(grouping: notes, by: { $0.title })
        return FuzzyMatch.ranked(query, candidates: notes.map(\.title))
            .compactMap { byTitle[$0]?.first }
            .prefix(12)
            .map { $0 }
    }

    func openQuickResult(_ note: Note) {
        showQuickSwitcher = false
        openNote(note.url)
    }

    var taggedNotes: [Note] {
        guard let tag = activeTag else { return [] }
        return notes.filter { note in
            guard let text = contentCache[note.url]?.text else { return false }
            return TagParser.tags(in: text).contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
    }

    private func refreshTags() {
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        for note in notes {
            guard let text = contentCache[note.url]?.text else { continue }
            for tag in TagParser.tags(in: text) {
                let key = tag.lowercased()
                counts[key, default: 0] += 1
                display[key] = tag
            }
        }
        let sorted = counts.keys
            .sorted { counts[$0]! > counts[$1]! }
            .map { TagCount(name: display[$0] ?? $0, count: counts[$0]!) }
        if sorted != tagCounts { tagCounts = sorted }
        if let active = activeTag,
           !tagCounts.contains(where: { $0.name.caseInsensitiveCompare(active) == .orderedSame }) {
            activeTag = nil
        }
    }

    private func scheduleTagRefresh() {
        tagRefreshTask?.cancel()
        tagRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshTags()
        }
    }

    private func scheduleReferenceRefresh() {
        referenceRefreshTask?.cancel()
        referenceRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshReferencedImages()
        }
    }

    // MARK: - 侧栏文件复制 / 粘贴

    /// ⌘C：把侧栏选中的文件写进剪贴板（Finder 也能接）
    func copySidebarSelection(to pasteboard: NSPasteboard = .general) -> Bool {
        let urls = Array(sidebarSelection)
        guard !urls.isEmpty else { return false }
        flushPendingSave()
        pasteboard.clearContents()
        return pasteboard.writeObjects(urls as [NSURL])
    }

    /// ⌘V：把剪贴板里的文件复制到目标目录（选中的文件夹，或当前笔记所在目录）
    func pasteFilesFromPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else {
            return false
        }
        guard let target = sidebarTargetDirectory() else { return false }

        var copied = 0
        for url in urls {
            let name = url.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let destination = Self.uniqueDestination(for: target.appendingPathComponent(name), isDirectory: false)
            if (try? FileManager.default.copyItem(at: url, to: destination)) != nil {
                copied += 1
            }
        }

        guard copied > 0 else { return false }
        reloadNotes()
        infoMessage = "已复制 \(copied) 个文件到「\(Self.relativePath(of: target, root: vaultURL ?? target))」"
        return true
    }

    private func sidebarTargetDirectory() -> URL? {
        if sidebarSelection.count == 1, let url = sidebarSelection.first {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDirectory ? url : url.deletingLastPathComponent()
        }
        if let selection { return selection.deletingLastPathComponent() }
        return vaultURL
    }

    /// 移动当前侧栏选中的所有条目
    func moveSelection(to folder: URL) {
        let urls = Array(sidebarSelection)
        guard !urls.isEmpty else { return }
        moveItems(urls, to: folder)
    }

    /// 把文件/文件夹移到目标目录；重名自动加序号，不覆盖
    func moveItems(_ urls: [URL], to folder: URL) {
        guard !urls.isEmpty else { return }
        flushPendingSave()

        let target = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else { return }

        var selectionAfterMove: URL?
        var movedFolders: [(from: URL, to: URL)] = []
        var moves: [String: String] = [:]

        for raw in urls {
            let source = raw.standardizedFileURL.resolvingSymlinksInPath()
            guard source.path != target.path else { continue }
            // 不能把文件夹拖进它自己或它的子目录
            if target.path.hasPrefix(source.path + "/") { continue }
            if source.deletingLastPathComponent().path == target.path { continue }

            let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            do {
                guard let destination = try Self.moveItem(at: source, to: target) else { continue }
                if isDirectory {
                    movedFolders.append((source, destination))
                    for newFile in Self.filesUnder(destination) {
                        let suffix = newFile.path.dropFirst(destination.path.count)
                        moves[source.path + suffix] = newFile.path
                    }
                } else {
                    moves[source.path] = destination.path
                }
                if selection == source { selectionAfterMove = destination }
            } catch {
                alertMessage = "移动失败：\(error.localizedDescription)"
            }
        }

        // 当前打开的笔记如果在被移动的文件夹里，跟着换路径
        if let current = selection {
            for mapping in movedFolders where current.path.hasPrefix(mapping.from.path + "/") {
                let suffix = current.path.dropFirst(mapping.from.path.count)
                selectionAfterMove = URL(fileURLWithPath: mapping.to.path + suffix)
            }
        }

        rewriteAllLinks(moves: moves, titleChange: nil)
        reloadNotes()
        if let selectionAfterMove, FileManager.default.fileExists(atPath: selectionAfterMove.path) {
            openNote(selectionAfterMove)
        } else {
            sidebarSelection = []
            loadSelected()
        }
    }

    func trashItem(_ url: URL) {
        flushPendingSave()
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            contentCache.removeValue(forKey: url)
            if selectedAttachment == url { selectedAttachment = nil }
            if let current = selection,
               current.path == url.path || current.path.hasPrefix(url.path + "/") {
                selection = nil
            }
            reloadNotes()
        } catch {
            alertMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    /// 目标是同目录、自己或自己的子目录时返回 nil（不做任何事）
    nonisolated static func moveItem(at source: URL, to folder: URL) throws -> URL? {
        let target = folder.standardizedFileURL.resolvingSymlinksInPath()
        let from = source.standardizedFileURL.resolvingSymlinksInPath()

        guard target.path != from.path else { return nil }
        guard !target.path.hasPrefix(from.path + "/") else { return nil }
        guard from.deletingLastPathComponent().path != target.path else { return nil }

        let isDirectory = (try? from.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let destination = uniqueDestination(
            for: target.appendingPathComponent(from.lastPathComponent),
            isDirectory: isDirectory
        )
        try FileManager.default.moveItem(at: from, to: destination)
        return destination
    }

    nonisolated static func uniqueDestination(for url: URL, isDirectory: Bool) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }

        let parent = url.deletingLastPathComponent()
        let ext = isDirectory ? "" : url.pathExtension
        let base = isDirectory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent

        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = parent.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    // MARK: - 搜索

    private func refreshContentCache() {
        var updated: [URL: (mtime: Date?, text: String)] = [:]
        for note in notes {
            let mtime = Self.modificationDate(of: note.url)
            if let cached = contentCache[note.url], cached.mtime == mtime {
                updated[note.url] = cached
                continue
            }
            guard let data = try? Data(contentsOf: note.url) else { continue }
            updated[note.url] = (mtime, String(decoding: data, as: UTF8.self))
        }
        contentCache = updated
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmed
        guard !query.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true
        searchGeneration &+= 1
        let generation = searchGeneration

        let parsed = SearchQuery.parse(query)
        let filteredNotes = notes.filter { note in
            if !parsed.tags.isEmpty {
                let text = contentCache[note.url]?.text ?? ""
                let tags = TagParser.tags(in: text).map { $0.lowercased() }
                if !parsed.tags.allSatisfy({ tags.contains($0) }) { return false }
            }
            if !parsed.folders.isEmpty {
                let path = note.relativePath.lowercased()
                if !parsed.folders.allSatisfy({ path.contains($0) }) { return false }
            }
            if parsed.before != nil || parsed.after != nil {
                let date = (try? note.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? Date.distantPast
                if let before = parsed.before, date >= before { return false }
                if let after = parsed.after, date < after { return false }
            }
            return true
        }

        let searchTerms = parsed.terms.joined(separator: " ")
        let documents = filteredNotes.map { (note: $0, text: contentCache[$0.url]?.text ?? "") }
        let index = searchIndex

        if searchTerms.isEmpty {
            searchResults = filteredNotes.map { note in
                SearchResult(
                    note: note,
                    score: 0,
                    matches: 0,
                    snippet: note.relativePath
                )
            }
            isSearching = false
            return
        }

        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }

            let results = await Task.detached(priority: .userInitiated) {
                guard let index, index.documentCount > 0 else {
                    return SearchEngine.search(query: searchTerms, in: documents)
                }

                guard let hits = try? index.search(searchTerms) else {
                    return SearchEngine.search(query: searchTerms, in: documents)
                }

                let byPath = Dictionary(
                    uniqueKeysWithValues: documents.map { ($0.note.url.path, $0) }
                )
                let terms = SearchEngine.terms(from: searchTerms)

                return hits.compactMap { hit -> SearchResult? in
                    guard let document = byPath[hit.path] else { return nil }
                    let offset = SearchEngine.firstMatchOffset(of: terms, in: document.text) ?? 0
                    let matches = terms.reduce(0) {
                        $0 + SearchEngine.occurrences(of: $1, in: document.text)
                    }
                    return SearchResult(
                        note: document.note,
                        score: Int(hit.score * 1000),
                        matches: matches,
                        snippet: SearchEngine.snippet(from: document.text, around: offset)
                    )
                }
            }.value

            guard !Task.isCancelled, let self, self.searchGeneration == generation else { return }
            self.searchResults = results
            self.isSearching = false
        }
    }

    // MARK: - 双链

    private func updateBacklinks() {
        guard let url = selection, let current = notes.first(where: { $0.url == url }) else {
            backlinks = []
            return
        }
        let title = current.title
        var found: [Backlink] = []

        for note in notes where note.url != url {
            guard let content = contentCache[note.url]?.text,
                  let regex = try? NSRegularExpression(pattern: WikiLinks.pattern) else { continue }
            let ns = content as NSString
            let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))

            for match in matches {
                let target = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let last = (target as NSString).lastPathComponent
                let hit = target.caseInsensitiveCompare(title) == .orderedSame
                    || last.caseInsensitiveCompare(title) == .orderedSame
                guard hit else { continue }

                let lineRange = ns.lineRange(for: match.range)
                let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
                found.append(Backlink(note: note, excerpt: line, offset: lineRange.location))
                break
            }
        }
        backlinks = found
    }

    func openWikiLink(_ target: String) {
        let needle = target.trimmed
        guard !needle.isEmpty else { return }

        guard let note = resolveWikiTarget(needle) else {
            pendingWikiLink = needle
            return
        }
        if let current = selection, current != note.url {
            navigationHistory.append(current)
        }
        openNote(note.url)
    }

    private func resolveWikiTarget(_ target: String) -> Note? {
        let normalized = target.replacingOccurrences(of: "\\", with: "/").trimmed
        guard !normalized.isEmpty else { return nil }

        if let exact = notes.first(where: { $0.title == normalized }) { return exact }
        if let insensitive = notes.first(where: {
            $0.title.caseInsensitiveCompare(normalized) == .orderedSame
        }) { return insensitive }

        let withExtension = normalized.lowercased().hasSuffix(".md") ? normalized : normalized + ".md"
        if let byPath = notes.first(where: {
            $0.relativePath.caseInsensitiveCompare(withExtension) == .orderedSame
        }) { return byPath }

        let last = (normalized as NSString).lastPathComponent
        return notes.first { $0.title.caseInsensitiveCompare(last) == .orderedSame }
    }

    func createNote(named name: String) {
        guard let vault = vaultURL else {
            showSettings = true
            return
        }
        flushPendingSave()

        var relative = name.trimmed.replacingOccurrences(of: "\\", with: "/")
        if relative.hasPrefix("/") { relative.removeFirst() }
        relative = relative.replacingOccurrences(of: "..", with: "")
        guard !relative.isEmpty else { return }
        if !relative.lowercased().hasSuffix(".md") { relative += ".md" }

        let url = vault.appendingPathComponent(relative)
        let folder = url.deletingLastPathComponent()
        do {
            if folder.path != vault.path {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                let title = url.deletingPathExtension().lastPathComponent
                try "# \(title)\n".write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            alertMessage = "新建失败：\(error.localizedDescription)"
            return
        }

        pendingWikiLink = nil
        reloadNotes()
        openNote(url)
    }

    func goBack() {
        while let previous = navigationHistory.popLast() {
            if FileManager.default.fileExists(atPath: previous.path) {
                openNote(previous)
                return
            }
        }
    }

    // MARK: - 编辑与保存

    func textChanged(_ newValue: String) {
        guard newValue != text else { return }
        text = newValue
        isDirty = true
        scheduleSave()
        schedulePreview()
    }

    private func loadSelected() {
        previewTask?.cancel()

        guard let url = selection, !Self.isImageFile(url), let data = try? Data(contentsOf: url) else {
            text = ""
            previewHTML = ""
            previewBody = ""
            isDirty = false
            loadedMTime = nil
            return
        }
        text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        activeOutlineOffset = nil
        isDirty = false
        loadedMTime = Self.modificationDate(of: url)
        contentCache[url] = (loadedMTime, text)
        renderPreview(url: url, source: text)
        updateBacklinks()
    }

    /// 在 VS Code / Obsidian 里改过当前这篇后切回本 App，看到的是最新内容
    func refreshFromDiskIfNeeded() {
        guard !isDirty, let url = selection else { return }
        guard Self.modificationDate(of: url) != loadedMTime else { return }
        loadSelected()
    }

    nonisolated static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func saveNow() {
        saveTask?.cancel()
        guard let url = selection, isDirty else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
            loadedMTime = Self.modificationDate(of: url)
            contentCache[url] = (loadedMTime, text)
            if isSearchActive { scheduleSearch() }
            scheduleReferenceRefresh()
            scheduleTagRefresh()
            if let index = searchIndex, let note = currentNote {
                let document = SearchIndex.Document(
                    path: note.url.path,
                    title: note.title,
                    body: text
                )
                Task.detached(priority: .utility) { index.upsert(document) }
            }
            scheduleAutoCommit()
            scheduleAutoSync()
        } catch {
            alertMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    func flushPendingSave() {
        if isDirty { saveNow() }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func schedulePreview() {
        previewTask?.cancel()
        guard let url = selection else { return }
        let source = text
        previewTask = Task { [weak self] in
            // 250ms 的停顿才渲染，打字过程中不碰 WebView
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.renderPreview(url: url, source: source)
        }
    }

    private func renderPreview(url: URL, source: String) {
        let body: String
        if url.pathExtension.lowercased() == "txt" {
            body = Markdown.plainBody(source)
        } else {
            body = Markdown.body(from: source, baseDirectory: url.deletingLastPathComponent())
        }
        previewBody = body
        previewHTML = Markdown.document(body: body, fontSize: CGFloat(fontSize) + 1)
    }

    /// 先按焦点分发快捷键，图片直接进入编辑器，侧栏负责文件复制/粘贴。
    private func installClipboardShortcuts() {
        clipboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = NSApp.keyWindow else { return event }
            return self.handleClipboardShortcut(event, in: window) ? nil : event
        }
    }

    /// 返回 true 表示已处理；普通文本操作继续交给系统响应链。
    func handleClipboardShortcut(_ event: NSEvent, in window: NSWindow,
                                 pasteboard: NSPasteboard = .general) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags == .command,
              let key = event.charactersIgnoringModifiers?.lowercased(),
              key == "c" || key == "v" else { return false }

        if let editor = window.firstResponder as? MarkdownTextView {
            return key == "v" && editor.insertPastedImage(from: pasteboard)
        }
        // 搜索框、设置输入框和其它文本视图保持系统的复制/粘贴。
        if window.firstResponder is NSTextView { return false }

        if key == "c" { return copySidebarSelection(to: pasteboard) }
        if pasteFilesFromPasteboard(pasteboard) { return true }
        // Finder 文件只走文件粘贴，避免把未处理的文件误当作截图。
        if pasteboard.types?.contains(.fileURL) == true { return false }
        guard ImageClipboard.containsImage(in: pasteboard),
              let editor = Self.findEditor(in: window.contentView) else { return false }
        return editor.insertPastedImage(from: pasteboard)
    }

    private static func findEditor(in view: NSView?) -> MarkdownTextView? {
        guard let view else { return nil }
        if let editor = view as? MarkdownTextView { return editor }
        for subview in view.subviews {
            if let found = findEditor(in: subview) { return found }
        }
        return nil
    }

    // MARK: - 标签页

    func closeTab(_ url: URL) {
        guard let index = openTabs.firstIndex(of: url) else { return }
        openTabs.remove(at: index)
        guard selection == url else { return }
        if openTabs.isEmpty {
            selection = nil
            sidebarSelection = []
        } else {
            openNote(openTabs[min(index, openTabs.count - 1)])
        }
    }

    func closeActiveTab() {
        if let selection { closeTab(selection) }
    }

    // MARK: - 附件体积

    /// 设置页打开时主动刷一次
    func refreshAttachmentStatsNow() {
        refreshAttachmentStats()
    }

    private func refreshAttachmentStats() {
        lastAttachmentScanAt = Date()
        guard let root = vaultURL else {
            attachmentStats = AttachmentStats()
            return
        }

        var stats = AttachmentStats()
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name == ".git" || name == "node_modules" { enumerator.skipDescendants(); continue }
            let ext = url.pathExtension.lowercased()
            if ["md", "markdown", "txt"].contains(ext) { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            stats.count += 1
            stats.bytes += size
            if size > stats.largestBytes {
                stats.largestBytes = size
                stats.largestName = relativePathString(of: url, root: root)
            }
        }
        attachmentStats = stats
    }

    private func relativePathString(of url: URL, root: URL) -> String {
        var relative = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if relative.hasPrefix(rootPath) { relative = String(relative.dropFirst(rootPath.count)) }
        if relative.hasPrefix("/") { relative = String(relative.dropFirst()) }
        return relative
    }

    // MARK: - 字号

    func increaseFontSize() { fontSize += 1 }
    func decreaseFontSize() { fontSize -= 1 }
    func resetFontSize() { fontSize = 15 }

    // MARK: - 自动提交

    private func scheduleAutoCommit() {
        guard autoCommit, vaultURL != nil else { return }
        commitTask?.cancel()
        commitTask = Task { [weak self] in
            // 8 秒：连续写作期间不要反复起 git 进程
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.commitLocally()
        }
    }

    private func commitLocally() async {
        guard let vault = vaultURL else { return }
        guard !isCommitting else { return }
        isCommitting = true
        defer { isCommitting = false }

        let engine = GitEngine(token: token)
        guard engine.isRepository(vault) else { return }
        do {
            let outcome = try await Self.offMain { try engine.commitIfNeeded("note: 更新笔记", in: vault) }
            if outcome.committed {
                syncState = .ok("已本地提交 \(outcome.hash)")
                updatePendingChanges()
                scheduleAutoSync()
            }
        } catch {
            syncState = .failed(error.localizedDescription)
        }
    }

    // MARK: - 授权

    func openTokenPage() {
        if let url = URL(string: "https://github.com/settings/personal-access-tokens/new") {
            NSWorkspace.shared.open(url)
        }
    }

    func importTokenFromGh() {
        Task {
            do {
                let value = try await Self.offMain { try GhCLI.token() }
                token = Self.normalizeToken(value).value
                syncState = .ok("已从 gh 导入 Token（\(value.count) 字符）")
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    /// 粘贴源里有时给的是十六进制字符串（我们遇到过 210 字符的 hex，解码后才是 github_pat_…）
    nonisolated static func normalizeToken(_ raw: String) -> (value: String, wasHex: Bool) {
        let trimmed = raw.trimmed
        guard trimmed.count > 40, trimmed.allSatisfy({ $0.isHexDigit }) else {
            return (trimmed, false)
        }
        var bytes: [UInt8] = []
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let byte = UInt8(trimmed[index..<next], radix: 16) else { return (trimmed, false) }
            bytes.append(byte)
            index = next
        }
        guard let decoded = String(bytes: bytes, encoding: .utf8),
              looksLikeGitHubToken(decoded) else {
            return (trimmed, false)
        }
        return (decoded, true)
    }

    nonisolated static func looksLikeGitHubToken(_ value: String) -> Bool {
        let prefixes = ["ghp_", "github_pat_", "gho_", "ghu_", "ghs_"]
        return value.count > 20 && prefixes.contains { value.hasPrefix($0) }
    }

    /// 用之前先规范化，顺手把「hex 粘贴」修好
    private func prepareToken() -> Bool {
        let normalized = Self.normalizeToken(token)
        if normalized.wasHex {
            token = normalized.value
            alertMessage = "检测到你粘贴的是十六进制字符串，已自动还原成 Token。请再点一次。"
            return false
        }
        guard Self.looksLikeGitHubToken(token) else {
            alertMessage = "Token 格式不对：应以 ghp_ 或 github_pat_ 开头（可在设置页点「从 gh 导入」）。"
            return false
        }
        return true
    }

    func testConnection() {
        guard prepareToken() else { return }
        let remote = repoURLString.trimmed
        guard !remote.isEmpty else {
            alertMessage = "先填仓库地址，比如 https://github.com/you/notes.git"
            return
        }
        guard !isBusy else { return }

        let engine = GitEngine(token: token)
        syncState = .running("测试连接…")
        Task {
            do {
                let summary = try await Self.offMain { try engine.lsRemote(remote) }
                if let api = Self.apiURL(from: remote) {
                    let canPush = await Self.pushPermission(api: api, token: token)
                    if canPush == false {
                        syncState = .ok("\(summary) · 但没有写权限（Token 只读）")
                        return
                    }
                }
                syncState = .ok(summary)
            } catch {
                syncState = .failed(error.localizedDescription)
            }
        }
    }

    /// https://github.com/owner/repo.git → https://api.github.com/repos/owner/repo
    nonisolated static func apiURL(from remote: String) -> URL? {
        guard let url = URL(string: remote), url.host?.contains("github.com") == true else { return nil }
        var path = url.path
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])")
    }

    nonisolated static func pushPermission(api: URL, token: String) async -> Bool? {
        guard !token.isEmpty else { return nil }
        var request = URLRequest(url: api)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let permissions = json["permissions"] as? [String: Any] else {
            return nil
        }
        return permissions["push"] as? Bool
    }

    /// 菜单入口：不依赖焦点和编辑模式，一定能把剪贴板截图落盘
    func insertScreenshotFromClipboard() {
        if let textView = NSApp.keyWindow?.firstResponder as? MarkdownTextView,
           textView.insertPastedImage(from: .general) {
            return
        }

        guard let url = selection else {
            alertMessage = "先打开一篇笔记，再插入截图。"
            return
        }
        guard let png = ImageClipboard.pngData() else {
            showPasteDiagnostics()
            return
        }
        let base = vaultURL ?? url.deletingLastPathComponent()
        guard let fileURL = AttachmentStore.save(data: png, name: "截图", into: base) else {
            alertMessage = "截图没能写进 assets/，检查这个目录的写入权限。"
            return
        }

        let link = AttachmentStore.relativePath(from: url.deletingLastPathComponent(), to: fileURL)
        let markup = isPlainTextNote ? "\n\(link)\n" : "\n![截图](\(link))\n"
        if mode == .preview { mode = .split }
        textChanged(text + markup)
        saveNow()
        infoMessage = "已插入截图并保存为 \(link)"
    }

    // MARK: - 版本历史

    private func relativePath(_ url: URL, root: URL) -> String {
        let base = root.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        if full.hasPrefix(base + "/") {
            return String(full.dropFirst(base.count + 1))
        }
        return url.lastPathComponent
    }

    func openHistory() {
        openHistory(for: nil)
    }

    /// 侧栏右键可以直接查看某篇笔记的历史，不用先打开它
    func openHistory(for url: URL?) {
        flushPendingSave()
        guard let vault = vaultURL else { return }
        let target = url ?? selection
        guard let target else { return }
        if selection != target {
            openNote(target)
        }

        let engine = GitEngine(token: token)
        guard engine.isRepository(vault), let root = engine.repoRoot(vault) else {
            infoMessage = "当前笔记库还不是 git 仓库，暂时没有版本历史。"
            return
        }

        historyNoteURL = target
        historyEntries = engine.fileLog(relativePath(target, root: root), in: vault)
        historyPreview = ""
        historySelection = historyEntries.first?.id
        showHistory = true
        if let hash = historySelection, historyPreview.isEmpty { loadHistoryPreview(hash) }
    }

    func loadHistoryPreview(_ hash: String) {
        guard let note = historyNoteURL, let vault = vaultURL else { return }
        let engine = GitEngine(token: token)
        guard let root = engine.repoRoot(vault) else { return }
        let path = relativePath(note, root: root)

        historyLoading = true
        Task {
            let text = try? await Self.offMain { try engine.fileContent(path, at: hash, in: vault) }
            historyPreview = text ?? "（这个版本读不出来）"
            historyLoading = false
        }
    }

    func restoreSelectedVersion() {
        guard let note = historyNoteURL,
              let hash = historySelection,
              let vault = vaultURL else { return }
        let engine = GitEngine(token: token)
        guard let root = engine.repoRoot(vault) else { return }
        let path = relativePath(note, root: root)

        do {
            try engine.restoreFile(path, from: hash, in: vault)
            showHistory = false
            reloadNotes()
            if selection == note { loadSelected() }
            infoMessage = "已恢复到 \(String(hash.prefix(7)))，保存后会作为新版本提交。"
        } catch {
            alertMessage = "恢复失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 自动同步

    private func scheduleAutoSync() {
        guard autoSync else { return }
        autoSyncTask?.cancel()
        autoSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard !self.isBusy, !self.token.trimmed.isEmpty else { return }
            guard let vault = self.vaultURL else { return }
            let engine = GitEngine(token: self.token)
            guard engine.isRepository(vault), engine.remoteURL(vault) != nil else { return }
            self.sync(silent: true)
        }
    }

    // MARK: - 导出

    func exportHTML() {
        guard let note = currentNote else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = note.title + ".html"
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let html = Markdown.document(
            from: text,
            baseDirectory: note.url.deletingLastPathComponent(),
            fontSize: fontSize
        )
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
            infoMessage = "已导出 HTML 到 \(url.lastPathComponent)"
        } catch {
            alertMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    func exportPDF() {
        guard let note = currentNote else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = note.title + ".pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let html = Markdown.document(
            from: text,
            baseDirectory: note.url.deletingLastPathComponent(),
            fontSize: fontSize
        )
        let exporter = PDFExporter()
        pdfExporter = exporter
        exporter.render(html: html) { [weak self] data in
            defer { self?.pdfExporter = nil }
            guard let data else {
                self?.alertMessage = "PDF 渲染失败，可以先试试导出 HTML。"
                return
            }
            do {
                try data.write(to: url)
                self?.infoMessage = "已导出 PDF 到 \(url.lastPathComponent)"
            } catch {
                self?.alertMessage = "PDF 写入失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 冲突处理

    func beginConflictResolution(paths: [String], branch: String) {
        guard let vault = vaultURL else { return }
        let engine = GitEngine(token: token)
        guard let root = engine.repoRoot(vault) else { return }

        conflictBranch = branch
        conflicts = paths.map { path in
            let local = (try? String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8
            )) ?? ""
            let remote = engine.remoteFileContent(path, branch: branch, in: vault) ?? ""
            return ConflictFile(path: path, localText: local, remoteText: remote)
        }
        conflictIndex = 0
        mergeDraft = conflicts.first?.localText ?? ""
        showMergeEditor = false
        showConflicts = !conflicts.isEmpty
    }

    var allConflictsResolved: Bool {
        !conflicts.isEmpty && conflicts.allSatisfy(\.resolved)
    }

    func resolveConflictKeepLocal() {
        guard conflicts.indices.contains(conflictIndex) else { return }
        conflicts[conflictIndex].resolved = true
        conflicts[conflictIndex].finalText = nil
        advanceConflict()
    }

    func resolveConflictUseRemote() {
        guard conflicts.indices.contains(conflictIndex) else { return }
        conflicts[conflictIndex].resolved = true
        conflicts[conflictIndex].finalText = conflicts[conflictIndex].remoteText
        advanceConflict()
    }

    func saveConflictMerge() {
        guard conflicts.indices.contains(conflictIndex) else { return }
        conflicts[conflictIndex].resolved = true
        conflicts[conflictIndex].finalText = mergeDraft
        advanceConflict()
    }

    private func advanceConflict() {
        showMergeEditor = false
        if let next = conflicts.firstIndex(where: { !$0.resolved }) {
            conflictIndex = next
            mergeDraft = conflicts[next].localText
        } else {
            conflictIndex = 0
        }
    }

    func cancelConflicts() {
        showConflicts = false
        showMergeEditor = false
    }

    func finishConflicts() {
        guard allConflictsResolved, let vault = vaultURL else { return }
        let engine = GitEngine(token: token)
        guard let root = engine.repoRoot(vault) else { return }

        for file in conflicts {
            guard let text = file.finalText else { continue }
            try? text.write(
                to: root.appendingPathComponent(file.path),
                atomically: true,
                encoding: .utf8
            )
        }

        let branch = conflictBranch
        let pending = conflicts
        Task {
            do {
                _ = try await Self.offMain {
                    try engine.commitIfNeeded("merge: 解决同步冲突", in: vault)
                }
                // 用 ours 策略合并历史：冲突文件保留用户刚才选定的内容
                let pull = try await Self.offMain {
                    try engine.run(
                        ["pull", "--no-rebase", "-X", "ours", "origin", branch],
                        in: vault,
                        network: true
                    )
                }
                guard pull.ok else {
                    throw GitError.command(GitEngine.friendlyMessage(for: pull))
                }
                let push = try await Self.offMain {
                    try engine.run(["push", "-u", "origin", branch], in: vault, network: true)
                }
                guard push.ok else {
                    throw GitError.command(GitEngine.friendlyMessage(for: push))
                }

                await MainActor.run {
                    showConflicts = false
                    conflicts = []
                    reloadNotes()
                    loadSelected()
                    syncState = .ok("冲突已解决并推送（\(pending.count) 个文件）")
                }
            } catch {
                alertMessage = "解决冲突后同步失败：\(error.localizedDescription)"
            }
        }
    }

    func copyCode(_ code: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
    }

    /// 预览里勾选任务清单：改回源文本并保存
    func toggleTask(line: Int, checked: Bool) {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line),
              let updated = Markdown.toggledTaskLine(lines[line], checked: checked) else { return }
        lines[line] = updated
        textChanged(lines.joined(separator: "\n"))
        saveNow()
    }

    /// 排查粘贴问题：报告当前焦点在谁身上、剪贴板里到底有什么类型
    func showPasteDiagnostics() {
        let pasteboard = NSPasteboard.general
        let types = (pasteboard.types ?? []).map(\.rawValue)
        let responder = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "无"
        let hasTIFF = pasteboard.data(forType: .tiff)?.count ?? 0
        let hasPNG = pasteboard.data(forType: .png)?.count ?? 0

        infoMessage = """
        焦点：\(responder)
        TIFF 数据：\(hasTIFF) 字节
        PNG 数据：\(hasPNG) 字节
        剪贴板类型：
        \(types.isEmpty ? "（空）" : types.joined(separator: "\n"))
        """
    }

    func clearToken() {
        token = ""
        syncState = .idle
        alertMessage = "已清除 Token。可以点「从 gh 导入」或在网页创建新的 fine-grained token。"
    }

    // MARK: - 仓库操作

    func cloneRepo() {
        guard prepareToken() else { return }
        let remote = repoURLString.trimmed
        guard !remote.isEmpty else {
            alertMessage = "先填一下仓库地址，比如 https://github.com/you/notes.git"
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "克隆到这里"
        panel.message = "选一个空文件夹（建议 ~/Notes）"
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        let engine = GitEngine(token: token)
        syncState = .running("正在克隆…")
        Task {
            do {
                try await Self.offMain { try engine.clone(remote, into: dir) }
                setVault(dir)
                syncState = .ok("已克隆")
            } catch {
                syncState = .failed(error.localizedDescription)
                alertMessage = error.localizedDescription
            }
        }
    }

    func initRepoHere() {
        guard let vault = vaultURL else {
            alertMessage = "先选择笔记库文件夹"
            return
        }
        let engine = GitEngine(token: token)
        let remote = repoURLString.trimmed
        Task {
            do {
                try await Self.offMain { try engine.initialize(remote: remote, in: vault) }
                refreshBranch()
                syncState = .ok("已初始化本地仓库")
            } catch {
                syncState = .failed(error.localizedDescription)
                alertMessage = error.localizedDescription
            }
        }
    }

    func sync(silent: Bool = false) {
        guard !silent || !token.trimmed.isEmpty else { return }
        guard silent || prepareToken() else { return }
        guard let vault = vaultURL else {
            alertMessage = "先选择笔记库文件夹"
            return
        }
        guard !isBusy else { return }
        flushPendingSave()

        let engine = GitEngine(token: token)
        syncState = .running("同步中…")
        Task {
            do {
                let outcome = try await Self.offMain { try engine.sync(vault) }
                if !outcome.conflicts.isEmpty {
                    beginConflictResolution(paths: outcome.conflicts, branch: outcome.branch)
                    syncState = .failed("有 \(outcome.conflicts.count) 个文件冲突，等待处理")
                    return
                }
                syncState = .ok(outcome.summary)
                branch = outcome.branch
                reloadNotes()
                updatePendingChanges()
            } catch {
                syncState = .failed(error.localizedDescription)
            }
        }
    }

    func refreshBranch() {
        guard let vault = vaultURL else {
            branch = ""
            return
        }
        let engine = GitEngine(token: token)
        Task {
            let name = (try? await Self.offMain { try engine.currentBranch(vault) }) ?? ""
            branch = name
            updatePendingChanges()
        }
    }

    private func updatePendingChanges() {
        lastPendingScanAt = Date()
        guard let vault = vaultURL else {
            pendingChanges = 0
            return
        }
        let engine = GitEngine(token: token)
        Task {
            let count = await (try? Self.offMain { engine.changedFileCount(vault) }) ?? 0
            pendingChanges = count
        }
    }

    // MARK: - 并发工具

    nonisolated static func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try body() }.value
    }
}

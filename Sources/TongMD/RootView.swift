import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 268, max: 380)
        } detail: {
            DetailView()
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showCheatSheet) {
            MarkdownCheatSheet()
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { model.infoMessage != nil },
                set: { if !$0 { model.infoMessage = nil } }
            )
        ) {
            Button("好") { model.infoMessage = nil }
        } message: {
            Text(model.infoMessage ?? "")
        }
        .alert(
            "出错了",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button("好") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // 外部编辑器（VS Code / Obsidian）改过文件后，切回来能看到新内容
            if model.vaultURL != nil, !model.isDirty {
                model.refreshFromDiskIfNeeded()
                model.reloadNotes()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.flushPendingSave()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tongmdPasteFailed)) { note in
            model.alertMessage = note.userInfo?["message"] as? String ?? "图片保存失败"
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            // 退出前把 debounce 里还没写盘的内容落掉
            model.flushPendingSave()
        }
    }
}

// MARK: - 侧栏

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if model.vaultURL == nil {
                VStack(alignment: .leading, spacing: 14) {
                    Text("还没有笔记库")
                        .font(.headline)
                    Text("选一个文件夹作为笔记库，或者把 GitHub 上的仓库克隆下来。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("选择文件夹…") { model.pickVaultFolder() }
                        .buttonStyle(.borderedProminent)
                    Button("从 GitHub 克隆…") { model.showSettings = true }
                }
                .padding(18)
                Spacer()
            } else {
                VStack(spacing: 0) {
                    searchField
                    Divider()
                    if model.isSearchActive {
                        searchResultsList
                    } else {
                        notesList
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 6) {
                    Text(footerText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("新建笔记") { model.createNote() }
                    Button("新建文本文件") { model.createNote(fileExtension: "txt") }
                    Button("新建文件夹") { model.createFolder() }
                } label: {
                    Image(systemName: "plus")
                }
                .help("新建笔记 ⌘N / 新建文件夹 ⇧⌘N")
                .disabled(model.vaultURL == nil)
            }
        }
        .alert("新建文件夹", isPresented: $model.showNewFolderPrompt) {
            TextField("文件夹名称", text: $model.newFolderName)
            Button("创建") { model.commitNewFolder() }
            Button("取消", role: .cancel) { model.showNewFolderPrompt = false }
        } message: {
            Text("将创建在「\(model.newFolderDestination)」。重名会自动加序号，不会覆盖已有文件夹。")
        }
        .alert(
            "重命名",
            isPresented: Binding(
                get: { model.renameTarget != nil },
                set: { if !$0 { model.renameTarget = nil } }
            )
        ) {
            TextField("名称", text: $model.renameText)
            Button("确定") { model.commitRename() }
            Button("取消", role: .cancel) { model.renameTarget = nil }
        }
    }

    // MARK: - 搜索框

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("搜索正文  ⌘F", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onExitCommand { model.searchText = "" }

            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.45))
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .onChange(of: model.searchFocusToken) { _, _ in
            searchFocused = true
        }
    }

    // MARK: - 列表

    private var notesList: some View {
        List(selection: $model.sidebarSelection) {
            vaultRow
            ForEach(model.tree) { node in
                NodeRow(node: node)
            }
        }
        .listStyle(.sidebar)
        // 空白处右键：在根目录新建
        .contextMenu {
            Button("新建笔记") { model.createNote(in: model.vaultURL) }
            Button("新建文本文件") { model.createNote(in: model.vaultURL, fileExtension: "txt") }
            Button("新建文件夹") { if let root = model.vaultURL { model.createFolder(in: root) } }
        }
    }

    /// 笔记库根目录：也是一个拖放目标
    private var vaultRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "books.vertical")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(model.vaultURL?.lastPathComponent ?? "笔记库")
                .lineLimit(1)
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button("新建笔记") { model.createNote() }
            Button("新建文本文件") { model.createNote(fileExtension: "txt") }
            Button("新建文件夹") { if let root = model.vaultURL { model.createFolder(in: root) } }
            Divider()
            Button("在 Finder 中显示") { if let root = model.vaultURL { model.revealInFinder(root) } }
        }
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(model.dropTarget == model.vaultURL ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .onDrop(of: [VaultDrag.multiType, UTType.fileURL.identifier],
                isTargeted: Binding(
                    get: { model.dropTarget == model.vaultURL },
                    set: { targeted in
                        if targeted { model.dropTarget = model.vaultURL }
                        else if model.dropTarget == model.vaultURL { model.dropTarget = nil }
                    }
                )) { providers in
            VaultDrag.urls(from: providers) { urls in
                if let root = model.vaultURL { model.moveItems(urls, to: root) }
                model.dropTarget = nil
            }
            return true
        }
    }

    private var searchResultsList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if model.isSearching {
                    ProgressView().controlSize(.mini)
                    Text("搜索中…")
                } else {
                    Text(model.searchResults.isEmpty ? "没有匹配的笔记" : "\(model.searchResults.count) 篇笔记")
                }
                Spacer()
                if !model.isSearching, !model.searchResults.isEmpty {
                    Text("\(model.searchResults.reduce(0) { $0 + $1.matches }) 处匹配")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.searchResults) { result in
                        Button {
                            model.openSearchResult(result.note)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Image(systemName: result.note.iconName)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                    Text(result.note.title)
                                        .lineLimit(1)
                                }
                                Text(highlighted(result.snippet, terms: SearchEngine.terms(from: model.searchText)))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                model.selection == result.note.url
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.clear
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// 把命中的关键词标出来，长 snippet 里也能一眼看到匹配位置
    private func highlighted(_ snippet: String, terms: [String]) -> AttributedString {
        guard !terms.isEmpty else { return AttributedString(snippet) }

        var result = AttributedString()
        var index = snippet.startIndex

        while index < snippet.endIndex {
            var earliest: Range<String.Index>?
            for term in terms {
                if let range = snippet.range(of: term, options: .caseInsensitive, range: index..<snippet.endIndex) {
                    if earliest == nil || range.lowerBound < earliest!.lowerBound {
                        earliest = range
                    }
                }
            }
            guard let match = earliest else {
                result += AttributedString(String(snippet[index...]))
                break
            }
            if match.lowerBound > index {
                result += AttributedString(String(snippet[index..<match.lowerBound]))
            }
            var piece = AttributedString(String(snippet[match]))
            piece.foregroundColor = .accentColor
            piece.inlinePresentationIntent = .stronglyEmphasized
            result += piece
            index = match.upperBound
        }
        return result
    }

    private var footerText: String {
        guard let vault = model.vaultURL else { return "未选择笔记库" }
        let folder = vault.lastPathComponent
        if model.isDirty {
            return "\(folder) · \(model.notes.count) 篇 · 编辑中"
        }
        return "\(folder) · \(model.notes.count) 篇"
    }
}

/// 拖拽载荷：单选时用标准 file-url（Finder 也能接收），多选时用自定义类型带一组路径
enum VaultDrag {
    static let multiType = "dev.tong.tongmd.paths"

    static func provider(for url: URL, selection: Set<URL>) -> NSItemProvider {
        let urls = selection.contains(url) && selection.count > 1 ? Array(selection) : [url]

        if urls.count == 1, let file = NSItemProvider(contentsOf: urls[0]) {
            return file
        }

        let provider = NSItemProvider()
        provider.registerItem(forTypeIdentifier: multiType) { completion, _, _ in
            let data = (try? JSONEncoder().encode(urls.map(\.path))) ?? Data()
            completion?(data as NSData, nil)
        }
        return provider
    }

    static func urls(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let lock = NSLock()
        var paths: [String] = []
        let group = DispatchGroup()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(multiType) {
                group.enter()
                provider.loadItem(forTypeIdentifier: multiType) { item, _ in
                    let data = item as? Data
                    if let data, let list = try? JSONDecoder().decode([String].self, from: data) {
                        lock.lock(); paths.append(contentsOf: list); lock.unlock()
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    var url: URL?
                    if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else if let value = item as? URL { url = value }
                    else if let string = item as? String { url = URL(string: string) }
                    if let url { lock.lock(); paths.append(url.path); lock.unlock() }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            completion(paths.map { URL(fileURLWithPath: $0) })
        }
    }
}

// MARK: - 树节点

struct NodeRow: View {
    let node: VaultNode
    @EnvironmentObject private var model: AppModel

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { !model.collapsedFolders.contains(node.url) },
            set: { expanded in
                if expanded {
                    model.collapsedFolders.remove(node.url)
                } else {
                    model.collapsedFolders.insert(node.url)
                }
            }
        )
    }

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(node.children ?? []) { child in
                    NodeRow(node: child)
                }
            } label: {
                folderLabel
            }
            .tag(node.url)
        } else {
            noteLabel
        }
    }

    private var folderLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(node.name)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            let expanded = !isExpanded.wrappedValue
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            if modifiers.intersection([.command, .shift]).isEmpty {
                model.sidebarSelection = [node.url]
            }
            isExpanded.wrappedValue = expanded
        })
        .onDrag { VaultDrag.provider(for: node.url, selection: model.sidebarSelection) }
        .contextMenu { folderMenu }
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(model.dropTarget == node.url ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .onDrop(of: [VaultDrag.multiType, UTType.fileURL.identifier], isTargeted: dropBinding(for: node.url)) { providers in
            VaultDrag.urls(from: providers) { urls in
                model.moveItems(urls, to: node.url)
                model.dropTarget = nil
            }
            return true
        }
    }

    private var noteLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: node.iconName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(node.title)
                .lineLimit(1)
        }
        .padding(.vertical, 1)
        .tag(node.url)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { model.openNote(node.url) })
        .onDrag { VaultDrag.provider(for: node.url, selection: model.sidebarSelection) }
        .contextMenu { node.isImage ? AnyView(attachmentMenu) : AnyView(noteMenu) }
    }

    @ViewBuilder
    private var folderMenu: some View {
        Button("新建笔记") { model.createNote(in: node.url) }
        Button("新建文本文件") { model.createNote(in: node.url, fileExtension: "txt") }
        Button("新建文件夹") { model.createFolder(in: node.url) }
        Divider()
        Button("重命名…") { model.beginRename(node.url) }
        Button("在 Finder 中显示") { model.revealInFinder(node.url) }
        Divider()
        Button("移到废纸篓", role: .destructive) { model.trashItem(node.url) }
    }

    /// 多选时移动整批，单选时移动当前这条
    private func dropBinding(for url: URL) -> Binding<Bool> {
        Binding(
            get: { model.dropTarget == url },
            set: { targeted in
                if targeted {
                    model.dropTarget = url
                } else if model.dropTarget == url {
                    model.dropTarget = nil
                }
            }
        )
    }

    @ViewBuilder
    private var attachmentMenu: some View {
        Button("在 Finder 中显示") { model.revealInFinder(node.url) }
        Button("重命名…") { model.beginRename(node.url) }
        Divider()
        Button("移到废纸篓", role: .destructive) { model.requestDeleteAttachment(node.url) }
    }

    private var moveTargets: [URL] {
        model.sidebarSelection.contains(node.url) && model.sidebarSelection.count > 1
            ? Array(model.sidebarSelection)
            : [node.url]
    }

    @ViewBuilder
    private var noteMenu: some View {
        Button("新建笔记（同级）") { model.createNote(in: node.url.deletingLastPathComponent()) }
        Button("新建文本文件（同级）") { model.createNote(in: node.url.deletingLastPathComponent(), fileExtension: "txt") }
        Button("新建文件夹（同级）") { model.createFolder(in: node.url.deletingLastPathComponent()) }
        Divider()
        Button("在 Finder 中显示") { model.revealInFinder(node.url) }
        Button("重命名…") { model.beginRename(node.url) }
        Menu("移动到") {
            ForEach(model.allFolders) { folder in
                Button(folder.relativePath.isEmpty ? folder.name : folder.relativePath) {
                    model.moveItems(moveTargets, to: folder.url)
                }
                .disabled(folder.url == node.url.deletingLastPathComponent())
            }
            if let root = model.vaultURL, node.url.deletingLastPathComponent() != root {
                Divider()
                Button("笔记库根目录") { model.moveItems(moveTargets, to: root) }
            }
        }
        Divider()
        Button("移到废纸篓", role: .destructive) { model.trashItem(node.url) }
    }
}

// MARK: - 详情

struct DetailView: View {
    @EnvironmentObject private var model: AppModel

    private var referenceCount: Int {
        guard let pending = model.pendingAttachmentDeletion else { return 0 }
        return model.referencingNotes(for: pending).count
    }

    var body: some View {
        Group {
            if let attachment = model.selectedAttachment {
                AttachmentPreview(url: attachment)
            } else if model.vaultURL == nil {
                WelcomeView()
            } else if model.selection == nil {
                ContentUnavailableView(
                    "没有选中笔记",
                    systemImage: "doc.text",
                    description: Text("从左侧选一篇，或按 ⌘N 新建")
                )
            } else {
                EditorPane()
            }
        }
        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        .alert(
            "图片正被引用",
            isPresented: Binding(
                get: { model.pendingAttachmentDeletion != nil },
                set: { if !$0 { model.pendingAttachmentDeletion = nil } }
            )
        ) {
            Button("仍然删除", role: .destructive) { model.deleteAttachmentNow() }
            Button("取消", role: .cancel) { model.pendingAttachmentDeletion = nil }
        } message: {
            Text("有 \(referenceCount) 篇笔记引用了这张图片，删除后这些引用会失效。")
        }
        .alert(
            "没有这篇笔记",
            isPresented: Binding(
                get: { model.pendingWikiLink != nil },
                set: { if !$0 { model.pendingWikiLink = nil } }
            )
        ) {
            Button("新建") {
                if let name = model.pendingWikiLink { model.createNote(named: name) }
            }
            Button("取消", role: .cancel) { model.pendingWikiLink = nil }
        } message: {
            Text("「\(model.pendingWikiLink ?? "")」还不存在，要按这个名字新建一篇吗？")
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("TongMD")
                .font(.largeTitle.weight(.semibold))
            Text("本地 Markdown 笔记，用 GitHub 做远端与版本。")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("选择本地文件夹…") { model.pickVaultFolder() }
                    .buttonStyle(.borderedProminent)
                Button("配置 GitHub…") { model.showSettings = true }
            }
            .padding(.top, 6)
        }
        .padding(40)
    }
}

// MARK: - 编辑器面板

struct EditorPane: View {
    @EnvironmentObject private var model: AppModel

    private var textBinding: Binding<String> {
        Binding(
            get: { model.text },
            set: { model.textChanged($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.openTabs.isEmpty {
                TabBar()
                Divider()
            }
            if model.mode != .preview, !model.isPlainTextNote {
                FormatBar()
                Divider()
            }
            content
            backlinksBar
            StatusBar()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("模式", selection: $model.mode) {
                    ForEach(EditorMode.allCases) { mode in
                        Image(systemName: mode.symbol)
                            .help(mode.label)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 132)
                .labelsHidden()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.pendingChanges > 0 {
                    Text("\(model.pendingChanges) 项改动")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    model.sync()
                } label: {
                    if model.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .help("同步到 GitHub ⇧⌘S")
                .disabled(model.isBusy)

                Button {
                    model.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("设置 ⌘,")
            }
        }
        .navigationTitle(model.currentNote?.title ?? "TongMD")
        .navigationSubtitle(model.branch.isEmpty ? "" : model.branch)
    }

    /// 谁引用了当前这篇（双链的反向索引）
    @ViewBuilder
    private var backlinksBar: some View {
        if !model.backlinks.isEmpty {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("被 \(model.backlinks.count) 篇引用")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForEach(model.backlinks.prefix(8)) { note in
                    Button(note.title) {
                        model.openNote(note.url)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .edit:
            MarkdownEditor(
                text: textBinding,
                fontSize: CGFloat(model.fontSize),
                plainText: model.isPlainTextNote,
                noteURL: model.selection,
                fallbackAttachmentDirectory: model.vaultURL,
                scrollTarget: model.pendingScrollRange,
                onScrollHandled: { model.pendingScrollRange = nil }
            )
        case .preview:
            MarkdownPreview(
                document: model.previewHTML,
                body: model.previewBody,
                noteID: model.selection,
                fontSize: CGFloat(model.fontSize) + 1,
                onWikiLink: { model.openWikiLink($0) }
            )
        case .split:
            HSplitView {
                MarkdownEditor(
                text: textBinding,
                fontSize: CGFloat(model.fontSize),
                plainText: model.isPlainTextNote,
                noteURL: model.selection,
                fallbackAttachmentDirectory: model.vaultURL,
                scrollTarget: model.pendingScrollRange,
                onScrollHandled: { model.pendingScrollRange = nil }
            )
                    .frame(minWidth: 300)
                MarkdownPreview(
                document: model.previewHTML,
                body: model.previewBody,
                noteID: model.selection,
                fontSize: CGFloat(model.fontSize) + 1,
                onWikiLink: { model.openWikiLink($0) }
            )
                    .frame(minWidth: 300)
            }
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Circle()
                    .fill(model.syncState.color)
                    .frame(width: 6, height: 6)
                Text(model.syncState.text)
                    .foregroundStyle(model.syncState.isFailure ? .red : .secondary)
                    .lineLimit(1)
                if model.isDirty {
                    Text("· 未保存")
                        .foregroundStyle(.orange)
                }
                Spacer()
                if !model.branch.isEmpty {
                    Text(model.branch)
                        .foregroundStyle(.secondary)
                }
                Text("\(model.text.count) 字")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(.bar)
        }
    }
}

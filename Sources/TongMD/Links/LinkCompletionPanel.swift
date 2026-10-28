import AppKit

/// `[[` 补全浮层：自己管理候选列表，不依赖 NSTextView 的单词补全
final class LinkCompletionController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let tableView = NSTableView()
    private var items: [String] = []

    /// 选中某一行（标题）时回调
    var onCommit: ((String) -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        column.width = 260
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(clickedRow)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: background.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -4)
        ])

        panel.contentView = background
    }

    var isVisible: Bool { panel.isVisible }
    var itemCount: Int { items.count }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// point 是光标左下角的屏幕坐标
    func show(items: [String], at point: NSPoint) {
        guard !items.isEmpty else {
            hide()
            return
        }
        self.items = items
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let width: CGFloat = 268
        let visibleRows = min(items.count, 8)
        let height = CGFloat(visibleRows) * tableView.rowHeight + 8

        var origin = NSPoint(x: point.x, y: point.y - height - 2)
        if let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - width - 8)
            origin.y = max(origin.y, screen.minY + 8)
        }
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: height), display: true)
        panel.orderFront(nil)
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = max(tableView.selectedRow, 0)
        let next = (current + delta + items.count) % items.count
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    @discardableResult
    func commitSelected() -> Bool {
        let row = tableView.selectedRow
        guard items.indices.contains(row) else { return false }
        onCommit?(items[row])
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView

        if let reusable = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            cell = reusable
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12.5)
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        cell.textField?.stringValue = items[row]
        cell.textField?.toolTip = items[row]
        return cell
    }

    @objc private func clickedRow() {
        _ = commitSelected()
    }
}

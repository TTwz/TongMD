import AppKit
import SwiftUI
import WebKit

/// Markdown 编辑器：带语法高亮的 NSTextView。
/// 结构在屏幕上直接可见（标题大、粗体粗、代码等宽），不需要背语法。
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 15
    /// .txt 用纯文本模式：不高亮 Markdown、不自动续列表
    var plainText: Bool = false
    /// 当前笔记路径：粘贴图片时用来决定 assets/ 位置
    var noteURL: URL? = nil
    /// 没有打开笔记时的兜底目录（笔记库根）
    var fallbackAttachmentDirectory: URL? = nil
    /// 从搜索结果跳进来时要滚动并选中的位置
    var scrollTarget: NSRange? = nil
    var onScrollHandled: () -> Void = {}

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .textBackgroundColor

        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        let containerWidth = max(scrollView.contentSize.width, 320)
        let container = NSTextContainer(
            containerSize: NSSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = MarkdownTextView(
            frame: NSRect(x: 0, y: 0, width: containerWidth, height: 400),
            textContainer: container
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: .greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 26, height: 28)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.insertionPointColor = .labelColor

        let highlighter = MarkdownSyntaxHighlighter()
        highlighter.fontSize = fontSize
        highlighter.isPlainText = plainText
        highlighter.textView = textView
        textView.isPlainText = plainText
        textView.attachmentDirectory = noteURL?.deletingLastPathComponent() ?? fallbackAttachmentDirectory
        textView.highlighter = highlighter
        textView.textStorage?.delegate = highlighter
        context.coordinator.highlighter = highlighter

        textView.string = text
        if let storage = textView.textStorage {
            highlighter.highlightAll(storage, caret: textView.selectedRange().location)
            highlighter.updateTypingAttributes(textView)
        }

        scrollView.documentView = textView
        // 高亮会把标题字号变大，先滚到顶，避免第一行被挤出可视区域
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }

        (textView as? MarkdownTextView)?.attachmentDirectory = noteURL?.deletingLastPathComponent() ?? fallbackAttachmentDirectory

        // 纯文本/Markdown 模式切换
        if let highlighter = context.coordinator.highlighter,
           highlighter.isPlainText != plainText {
            highlighter.isPlainText = plainText
            (textView as? MarkdownTextView)?.isPlainText = plainText
            if let storage = textView.textStorage {
                highlighter.highlightAll(storage, caret: textView.selectedRange().location)
            }
        }

        // 字号变了：重新上色（字号是属性的一部分）
        if let highlighter = context.coordinator.highlighter, highlighter.fontSize != fontSize {
            highlighter.fontSize = fontSize
            if let storage = textView.textStorage {
                highlighter.highlightAll(storage, caret: textView.selectedRange().location)
            }
            highlighter.updateTypingAttributes(textView)
        }

        guard textView.string != text else { return }
        // 正在用输入法组字、或者有未提交的输入时，绝不能整段替换缓冲区
        guard !textView.hasMarkedText() else { return }

        // 只会在外部改动（切换笔记、外部编辑）时触发，保留光标位置
        let selected = textView.selectedRange()
        textView.string = text
        if let storage = textView.textStorage {
            context.coordinator.highlighter?.highlightAll(storage, caret: selected.location)
        }
        let length = (text as NSString).length
        let location = min(selected.location, length)
        textView.setSelectedRange(NSRange(location: location, length: 0))

        if let target = scrollTarget {
            let safe = NSRange(
                location: min(target.location, max(0, length - 1)),
                length: min(target.length, max(0, length - min(target.location, max(0, length - 1))))
            )
            textView.scrollRangeToVisible(safe)
            textView.setSelectedRange(safe)
            onScrollHandled()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        var highlighter: MarkdownSyntaxHighlighter?

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            highlighter?.refreshAfterInput()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            highlighter?.updateTypingAttributes(textView)
        }
    }
}

final class NonFocusableWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }
}

struct MarkdownPreview: NSViewRepresentable {
    /// 完整文档，只在首次加载/切换笔记时用
    let document: String
    /// 只含内容的片段，编辑时走 JS 增量替换
    let body: String
    var noteID: URL? = nil
    var fontSize: CGFloat = 16
    /// 预览里点了 [[双链]] 时回调给 AppModel
    var onWikiLink: ((String) -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        // 预览是只读的，不应该抢走编辑器的焦点：否则点了预览再按 ⌘V 会没有任何反应
        let webView = NonFocusableWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onWikiLink = onWikiLink

        if coordinator.loadedBody != nil, coordinator.loadedFontSize != fontSize {
            coordinator.loadedFontSize = fontSize
            webView.evaluateJavaScript("document.documentElement.style.setProperty('--base', '\(Int(fontSize.rounded()))px')")
        }

        if coordinator.noteID != noteID {
            coordinator.noteID = noteID
            coordinator.isReady = false
            coordinator.loadedBody = nil
        }

        // 首次加载、切换笔记、或页面还没就绪：整页加载一次
        guard coordinator.isReady, let loaded = coordinator.loadedBody else {
            coordinator.loadedBody = body
            _ = webView.loadHTMLString(document, baseURL: nil)
            return
        }

        guard loaded != body else { return }
        coordinator.loadedBody = body

        // 只替换 body 内容：不重建文档、不重启排版、滚动位置自然保持
        guard let literal = Self.jsStringLiteral(body) else { return }
        webView.evaluateJavaScript("document.body.innerHTML = \(literal);") { _, error in
            if let error {
                // 注入失败就退回整页重载，宁可慢一点也不能显示旧内容
                coordinator.isReady = false
                _ = webView.loadHTMLString(document, baseURL: nil)
                NSLog("TongMD preview injection failed: \(error.localizedDescription)")
            }
        }
    }

    private static func jsStringLiteral(_ string: String) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: string,
            options: [.fragmentsAllowed]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var noteID: URL?
        var loadedBody: String?
        var loadedFontSize: CGFloat = 16
        var isReady = false
        var onWikiLink: ((String) -> Void)?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url, url.scheme == "tongmd" {
                let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "name" })?
                    .value ?? ""
                onWikiLink?(name)
                decisionHandler(.cancel)
                return
            }
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

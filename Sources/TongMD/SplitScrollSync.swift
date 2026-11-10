import AppKit
import WebKit

/// 分栏模式下让编辑器与预览的滚动位置保持一致。
///
/// 两边内容高度不同（源码 vs 渲染结果），所以按 0…1 的滚动进度映射，而不是行号。
/// 用户滚哪边，另一边就跟到相同进度；由同步器自己发起的滚动会被短暂忽略，
/// 避免「A 滚 → B 跟 → B 上报 → A 再跟」的回声把两边推得来回抖。
final class SplitScrollSync: ObservableObject {
    weak var editorScrollView: NSScrollView?
    weak var previewWebView: WKWebView?

    /// 最近一次由同步器写到某一侧的位置，用来识别回声
    private var appliedToEditor: (progress: Double, at: Date)?
    private var appliedToPreview: (progress: Double, at: Date)?

    /// 回声窗口和容差：程序化滚动后极短时间内的同位置回报不再转发
    private let echoWindow: TimeInterval = 0.15
    private let echoTolerance = 0.01

    /// 程序化跳转（大纲、搜索结果）期间暂停同步，避免两边互相抢位置
    private var suspendedUntil = Date.distantPast

    func attachEditor(_ scrollView: NSScrollView?) {
        editorScrollView = scrollView
    }

    func attachPreview(_ webView: WKWebView?) {
        previewWebView = webView
    }

    /// 只在确实还是自己挂着的视图时才解绑，避免拆旧视图时把新视图的引用清掉
    func detachEditor(_ scrollView: NSScrollView) {
        if editorScrollView === scrollView { editorScrollView = nil }
    }

    func detachPreview(_ webView: WKWebView) {
        if previewWebView === webView { previewWebView = nil }
    }

    /// 大纲跳转一类的主动定位：短时间内不参与同步
    func suspend() {
        suspendedUntil = Date().addingTimeInterval(0.4)
    }

    private var isSuspended: Bool { Date() < suspendedUntil }

    // MARK: - 上报入口

    func editorScrolled(to progress: Double) {
        guard !isSuspended else { return }
        let value = progress.clamped01
        if isEcho(value, of: appliedToEditor) { return }
        applyToPreview(value)
    }

    func previewScrolled(to progress: Double) {
        guard !isSuspended else { return }
        let value = progress.clamped01
        if isEcho(value, of: appliedToPreview) { return }
        applyToEditor(value)
    }

    // MARK: - 应用

    private func applyToEditor(_ progress: Double) {
        guard let scrollView = editorScrollView,
              let documentView = scrollView.documentView else { return }
        let visible = scrollView.contentView.bounds.height
        // 文档视图的原点不一定是 0：在 NavigationSplitView 里可能是负值。
        // 必须用实际的 frame.minY 当作起点，否则会把「滚到底」算成负偏移。
        let documentFrame = documentView.frame
        let maxOffset = max(0, documentFrame.height - visible)
        guard maxOffset > 0 else { return }

        appliedToEditor = (progress, Date())
        let y = documentFrame.minY + CGFloat(progress) * maxOffset
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func applyToPreview(_ progress: Double) {
        guard let webView = previewWebView else { return }
        appliedToPreview = (progress, Date())
        webView.evaluateJavaScript(Self.scrollScript(progress: progress), completionHandler: nil)
    }

    private func isEcho(
        _ progress: Double,
        of applied: (progress: Double, at: Date)?
    ) -> Bool {
        guard let applied else { return false }
        return Date().timeIntervalSince(applied.at) < echoWindow
            && abs(progress - applied.progress) < echoTolerance
    }

    // MARK: - 工具

    /// 供编辑器侧计算进度，也方便自检。
    /// `offset` 是 clip view 的 bounds.origin.y，起点是文档视图真正的 frame.minY。
    static func progress(offset: CGFloat, visible: CGFloat, documentFrame: CGRect) -> Double {
        let maxOffset = documentFrame.height - visible
        guard maxOffset > 0 else { return 0 }
        return Double((offset - documentFrame.minY) / maxOffset).clamped01
    }

    static func scrollScript(progress: Double) -> String {
        """
        (function () {
            var max = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
            window.scrollTo(0, \(progress.clamped01) * max);
        })();
        """
    }
}

extension Double {
    var clamped01: Double { min(max(self, 0), 1) }
}

import AppKit
import WebKit

/// 把预览 HTML 渲染成 PDF（单页长图，保留图片和样式）
final class PDFExporter: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var completion: ((Data?) -> Void)?
    private var finished = false

    override init() {
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 794, height: 1123))
        super.init()
        webView.navigationDelegate = self
    }

    func render(html: String, completion: @escaping (Data?) -> Void) {
        self.completion = completion
        finished = false
        webView.loadHTMLString(html, baseURL: nil)

        // 兜底：渲染失败时不要把界面卡住
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.finished else { return }
            self.finished = true
            self.completion?(nil)
            self.completion = nil
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let configuration = WKPDFConfiguration()
        webView.createPDF(configuration: configuration) { [weak self] result in
            guard let self, !self.finished else { return }
            self.finished = true
            switch result {
            case .success(let data): self.completion?(data)
            case .failure: self.completion?(nil)
            }
            self.completion = nil
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !finished else { return }
        finished = true
        completion?(nil)
        completion = nil
    }
}

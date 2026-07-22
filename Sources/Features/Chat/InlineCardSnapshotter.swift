// WKWebView の DOM スナップショット取得時機と一度きり制御。
// カードの接続・表示モードを担う InlineCardHost から、永続化素材の取得だけを分離する。
import OSLog
import WebKit

@MainActor
final class InlineCardSnapshotter {
    private var capturedOnFirstSizeChange = false
    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "inlinecard-snapshot")

    /// 最初の size-changed 到達時だけ取得する。teardown 時の保険取得はこのフラグに依存しない。
    func captureFirst(from webView: WKWebView, receiver: (@MainActor (String) -> Void)?) {
        guard !capturedOnFirstSizeChange else { return }
        capturedOnFirstSizeChange = true
        capture(from: webView, receiver: receiver)
    }

    /// DOM を outerHTML へ直列化する。input の現在値や canvas は落ちるが、再訪用の静的カードには十分。
    func capture(from webView: WKWebView?, receiver: (@MainActor (String) -> Void)?) {
        guard let webView, let receiver else { return }
        webView.evaluateJavaScript("document.documentElement.outerHTML") { result, error in
            if let html = result as? String {
                // WKWebView の非分離 completion から MainActor の永続化先へ明示的に戻す。
                Task { @MainActor in receiver(html) }
            } else if let error {
                self.logger.error("outerHTML 取得に失敗: \(String(reflecting: error), privacy: .public)")
            }
        }
    }
}

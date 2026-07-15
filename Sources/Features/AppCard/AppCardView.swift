// MCP App カードの WKWebView ホスティング(UIViewRepresentable)+ サイズ連携(設計 §5/§6)。
//
// このファイルは「1枚のツールカード = 1 WKWebView」を SwiftUI に載せる薄い層。ブリッジの
// 頭脳(状態機械)は Services の AppsBridgeSession が持ち、ここは:
//  - WKWebView をサンドボックス設定込みで生成する(§6: ContentRuleList 全遮断・非永続ストア・
//    navigation 封じ・window.open 封じ)、
//  - size-changed で流れてくる高さを @Observable な AppCardState に反映して .frame(height:) を
//    追従させる(§5)、
// の2点だけを担う。生成した WKWebView は ViewModel が保持し、この View は表示するだけにする
// (WKWebView の生成にはコンテンツルールリストのコンパイルという非同期処理が挟まるため、
//  makeUIView の同期文脈で作らず、準備済みインスタンスを受け取る形にする)。
import SwiftUI
import WebKit
import OSLog
import Services

/// カードの可変状態(高さ)。session の onSizeChanged から MainActor で更新される。
@MainActor
final class AppCardState: ObservableObject {
    // 現在の希望高さ。size-changed 未受信の初期値は控えめな 200pt(スケルトン表示ぶん)。
    // 上限は maxHeight(既定 600)でクランプし、チャットを食い潰さない(設計 §5)。
    @Published var desiredHeight: CGFloat = 200
}

/// 準備済みの WKWebView を SwiftUI に載せるだけのラッパ。frame(height:) は呼び出し側が
/// AppCardState を観測して適用する(この View は寸法を決めない)。
struct AppCardView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// WKWebView の navigation / UI デリゲート(設計 §6 のサンドボックス強化)。
///
///  - navigation: 初回の loadHTMLString だけ許可し、それ以降の遷移(リンク・redirect・
///    フォーム送信など)はすべて cancel する。外部遷移は ui/open-link 経由に一本化するため。
///  - UI: createWebViewWith を nil にして window.open(新規 WebView 生成)を封じる。
///
/// ViewModel が強参照で保持する(WKWebView の delegate は weak なので、これを手放すと
/// デリゲートが即 nil 化してしまう)。
@MainActor
final class AppCardWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "appcard")
    // 初回 loadHTMLString の navigation を1度だけ通すためのフラグ。
    private var allowedInitialLoad = false

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if !allowedInitialLoad {
            // 最初の1回(= ホストが loadHTMLString した本体)だけ許可する。
            allowedInitialLoad = true
            decisionHandler(.allow)
            return
        }
        // 2回目以降のあらゆる navigation は封じる(設計 §6: 初回以外は cancel)。
        logger.notice("navigation を cancel(初回以外は遮断) url=\(navigationAction.request.url?.absoluteString ?? "nil", privacy: .public)")
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // window.open / target=_blank を封じる(設計 §6)。リンクは ui/open-link 経由が正。
        logger.notice("createWebViewWith を nil で拒否(window.open 封じ)")
        return nil
    }
}

/// WKWebView をサンドボックス設定込みで生成するファクトリ(設計 §6)。
///
/// ContentRuleList のコンパイルが非同期なので async。呼び出し側(ViewModel)が
/// connect / prefetch と同じ準備フェーズでこれを await し、出来上がった WKWebView を
/// AppCardView に渡す。
@MainActor
enum AppCardWebViewFactory {
    private static let logger = Logger(subsystem: "dev.gigun.mcphost", category: "appcard")

    /// transport の configuration(documentStart インターセプタ入り)にサンドボックス設定を足し、
    /// HTML をロードした WKWebView を返す。
    static func make(
        transport: WebViewTransport,
        html: String,
        coordinator: AppCardWebCoordinator
    ) async -> WKWebView {
        // インターセプタ + 弱参照ハンドラを含む config(WebViewTransport が組む)を土台にする。
        let configuration = transport.makeConfiguration()

        // 非永続ストア(設計 §4): カード間・セッション間で Cookie/Storage を残さない。
        configuration.websiteDataStore = .nonPersistent()

        // 全遮断コンテントルールリスト(設計 §6): 自己完結バンドルはネットワーク不要なので
        // ".*" を block する1ルールで全通信を止める。CSP meta 注入より実効的に厳しい(§4)。
        if let ruleList = await compileBlockAllRuleList() {
            configuration.userContentController.add(ruleList)
            logger.notice("ContentRuleList(全遮断)を適用")
        } else {
            // コンパイル失敗時は遮断なしで続行(スパイクの可観測性優先。P3 で失敗を致命化するか判断)。
            logger.error("ContentRuleList のコンパイルに失敗(遮断なしで続行)")
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        // 高さは常に内容ぴったりに追従するので内部スクロールは不要(設計 §5)。
        webView.scrollView.isScrollEnabled = false
        // 背景を透過にしてカードの角丸/枠と馴染ませる(prefersBorder は P3)。
        webView.isOpaque = false
        webView.backgroundColor = .clear

        // delivery のために transport に webView を渡す(callAsyncJavaScript の宛先)。
        transport.attach(to: webView)
        // baseURL: nil = opaque origin(設計 §4)。postMessage は targetOrigin "*" なので通る。
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    /// ".*" を block する全遮断ルール1本をコンパイルする(設計 §6)。
    private static func compileBlockAllRuleList() async -> WKContentRuleList? {
        let json = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
        return await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "appcard-block-all",
                encodedContentRuleList: json
            ) { ruleList, error in
                if let error {
                    // ここで logger を使うと nonisolated 文脈になるため、結果だけ返して呼び出し側でログる。
                    _ = error
                }
                continuation.resume(returning: ruleList)
            }
        }
    }
}

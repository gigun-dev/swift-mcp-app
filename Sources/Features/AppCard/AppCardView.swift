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
    /// - Parameter scrollEnabled: WKWebView 自身の内部スクロールを許すか。
    ///   本番のチャット内インラインカード(P3)は高さを size-changed で内容ぴったりに
    ///   追従させるので false(内部スクロール不要・設計 §5)。一方スパイクの単カード
    ///   全画面デモは、カードを画面いっぱいに広げて内容をスクロールで見せたいので true。
    ///   (size-changed 追従は「html を max-content で計測した高さ」を返すが、caldav カードの
    ///    ように状態でコンテンツが伸びる場合、単カードデモでは固定枠+内部スクロールの方が素直。)
    static func make(
        transport: WebViewTransport,
        html: String,
        coordinator: AppCardWebCoordinator,
        scrollEnabled: Bool = false
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
        // 【DEBUG: Safari Web Inspector アタッチ許可(iOS 16.4+)】カード iframe(サンドボックス
        // WKWebView)を Simulator/実機からデスクトップ Safari の「開発」メニューで検証できるように
        // する。これが false だと開発メニューに WKWebView が現れない。本番配布(Release)では
        // アタッチ不可のままにするため DEBUG 限定(カード内 JS を第三者に覗かせない)。
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif
        // 内部スクロール可否(引数)。インラインカードは高さ追従で不要、スパイクは可(上記)。
        webView.scrollView.isScrollEnabled = scrollEnabled

        // 【タップ遅延の除去(ズームは殺さない)】WebKit はタップ後 ~350ms、ダブルタップ
        // (ズーム)の可能性を待ってから click を合成しうる。この遅延で「押しても反応しない」
        // と感じて複数回タップしてしまう症状が出た(2026-07-15 観測。docs/log.md)。
        // 対処は「ダブルタップ・ツー・ズームのジェスチャ認識器だけ無効化」に留める。
        // 【ボツ案・重要】当初は minimumZoomScale = maximumZoomScale = 1 でズーム自体を
        // ロックしていたが撤回した: (1) ピンチズーム(アクセシビリティ)まで殺す、
        // (2) 副次的に <16px 入力の focus zoom も止まるが、それは「小さすぎる文字」という
        // 根本原因を対症療法で隠すだけ。focus zoom の正しい対処はカード側で入力欄を 16px 以上に
        // すること(caldav の .d-notes が 13px 等 — docs/caldav-feedback.md に起票)。
        // ダブルタップ認識器の無効化はピンチズームを残すので、この方針と両立する。
        disableDoubleTapGestures(in: webView.scrollView)
        // 背景を透過にしてカードの角丸/枠と馴染ませる(prefersBorder は P3)。
        webView.isOpaque = false
        webView.backgroundColor = .clear

        // delivery のために transport に webView を渡す(callAsyncJavaScript の宛先)。
        transport.attach(to: webView)
        // baseURL: nil = opaque origin(設計 §4)。postMessage は targetOrigin "*" なので通る。
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    /// 履歴再訪用の**静的スナップショット表示**専用 WKWebView を生成する(T6・設計 §5)。
    ///
    /// ライブカード(make)との差:
    ///  - **JS を実行しない**: `defaultWebpagePreferences.allowsContentJavaScript = false`。
    ///    outerHTML に残ったインライン onclick / `<script>` は死んだボタン(ブリッジ無し)なので、
    ///    JS を切って「死んだボタンが JS エラーを吐く」のを防ぎ、純粋な見た目だけを復元する
    ///    (設計 §5「JS 実行自体を切ってロードする」)。
    ///  - **transport/ブリッジ無し**: postMessage インターセプタ(WebViewTransport.makeConfiguration)を
    ///    土台にしない。静的表示専用なので JSON-RPC 会話は一切しない(素の WKWebViewConfiguration から組む)。
    ///  - ContentRuleList 全遮断・非永続ストア・navigation 封じは make と同じ(サンドボックスは緩めない)。
    /// - Parameter coordinator: navigation/UI デリゲート。**呼び出し側が強参照で保持**すること
    ///   (WKWebView の delegate は weak・make と同じ制約。StaticCardHost が保持する)。
    static func makeStatic(html: String, coordinator: AppCardWebCoordinator) async -> WKWebView {
        // 素の config(ブリッジ無し)。ライブと違い transport.makeConfiguration は使わない。
        let configuration = WKWebViewConfiguration()
        // JS 実行自体を切る(設計 §5)。死んだボタンのエラー抑止 + スナップショットの純表示。
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // 非永続ストア(ライブと同じ・カード間で状態を残さない)。
        configuration.websiteDataStore = .nonPersistent()

        // 全遮断ルール(ライブと同じ・自己完結 HTML はネットワーク不要)。
        if let ruleList = await compileBlockAllRuleList() {
            configuration.userContentController.add(ruleList)
            logger.notice("ContentRuleList(全遮断・静的カード)を適用")
        } else {
            logger.error("ContentRuleList のコンパイルに失敗(静的カード・遮断なしで続行)")
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        // 【DEBUG: Safari Web Inspector アタッチ許可(iOS 16.4+)】理由は make(...) の同節参照。
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif
        // 静的カードは size-changed 追従が無い(ブリッジ無し)ので、maxHeight 内に収めて
        // **内部スクロールを許す**(StaticCardView 側でクランプ・高さの判断はそちらのコメント)。
        webView.scrollView.isScrollEnabled = true
        disableDoubleTapGestures(in: webView.scrollView)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        // baseURL: nil = opaque origin(ライブと同じ)。ブリッジ無しなので transport.attach はしない。
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    /// WKWebView(scrollView)に付いている「2回タップ要求」のジェスチャ認識器を無効化する。
    /// これがあると WebKit は単発タップの click 合成を遅延させる(上記コメント参照)。
    /// zoom を 1:1 固定にしても認識器自体は残ることがあるため、明示的に潰す。
    /// iOS のバージョンで認識器構成が変わりうるので「見つかったものを無効化」の防御的実装。
    private static func disableDoubleTapGestures(in scrollView: UIScrollView) {
        for recognizer in scrollView.gestureRecognizers ?? [] {
            if let tap = recognizer as? UITapGestureRecognizer, tap.numberOfTapsRequired == 2 {
                tap.isEnabled = false
            }
        }
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

// WKWebView と Kernel の JSON-RPC 封筒をつなぐトランスポート(設計 §1)。
//
// 何をするか(設計 §1 の写経元。詳細な根拠はすべて docs/design/01-apps-bridge.md §1 にある):
//  - `loadHTMLString` で主フレームに直接ロードした View では `window.parent === window` に
//    なる。View の送信は実質「自分宛ての本物の postMessage」、受信は「event.source === window
//    なら通す」になる。この2性質を使い、View バンドルを1バイトも変えずに双方向を成立させる。
//  - documentStart 注入のインターセプタが `isTrusted` で方向を判別する:
//      * isTrusted === true  → View→Host(本物)。webkit ハンドラへ転送し
//        stopImmediatePropagation で View 自身へのループバックを止める。
//      * isTrusted === false → ホストが dispatchEvent で合成した Host→View 配送。素通しで
//        View に届く(合成イベントは DOM 仕様上必ず isTrusted === false)。
//  - Swift→JS は callAsyncJavaScript(arguments:) でネイティブ直列化に載せる(文字列連結で
//    JS を組み立てるとエスケープ事故 = injection の温床になるため。設計 §1)。
//
// WebKit は macOS でもコンパイル可能なので Services(swift build が macOS でも回る)に置ける。
// UIKit 依存は持ち込まない(UIViewRepresentable でのホスティングは Features 側の責務)。
import Foundation
import OSLog
import WebKit
import Kernel

/// WKScriptMessageHandler の retain cycle を断つための弱参照プロキシ。
///
/// なぜ必要か(定番の WebKit リーク対策): WKUserContentController は
/// `add(_:name:)` で渡した message handler を **強参照** する。もし WebViewTransport 自身を
/// 直接ハンドラに登録すると Transport→(configuration/controller)→Transport の循環ができ、
/// WKWebView を捨てても Transport が解放されない。間にこの弱参照プロキシを挟むことで、
/// controller はプロキシだけを強参照し、本体(Transport)は所有者(Features 側)の寿命で
/// 素直に解放される。
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

/// WKWebView 上の postMessage ⇔ Kernel JSON-RPC を仲介するトランスポート。
///
/// 1 WKWebView = 1 Transport。Features 側が `makeConfiguration()` で得た configuration で
/// WKWebView を作り、生成後に `attach(to:)` で Transport に webView を渡す
/// (delivery の callAsyncJavaScript に webView 参照が要るため)。
public final class WebViewTransport: NSObject {
    // webkit ハンドラ名。documentStart スクリプトの
    // `window.webkit.messageHandlers.appsBridge` と一致させる(定数で二重管理を防ぐ)。
    private static let handlerName = "appsBridge"

    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "appsbridge")

    // 配送先の WKWebView。attach で入る。weak にするのは View の所有権を Transport に
    // 持たせない(Features が持つ)ため。
    private weak var webView: WKWebView?

    // 受信メッセージの発行口。ハーネス/セッションはこのストリームを for await する。
    // Kernel の判別を通した JSONRPCMessage を流す(生文字列も欲しいので tuple で添える)。
    public let incoming: AsyncStream<(message: JSONRPCMessage, raw: String)>
    private let incomingContinuation: AsyncStream<(message: JSONRPCMessage, raw: String)>.Continuation

    public override init() {
        var continuation: AsyncStream<(message: JSONRPCMessage, raw: String)>.Continuation!
        self.incoming = AsyncStream { continuation = $0 }
        self.incomingContinuation = continuation
        super.init()
    }

    // MARK: - documentStart インターセプタ(設計 §1 の概念コードの写経)

    // world は .page(設計 §1 の決定)。理由: コンテンツはホストが自分で load した単一 HTML で、
    // ハンドラ露出のリスクは「View が自分の transport をバイパスできる」程度に留まる。専用
    // WKContentWorld へ隔離すると world 間の stopImmediatePropagation の意味論が文書化薄で
    // スパイクの不確実性を増やすため、堅牢化(P3)に回す。
    private static let interceptorSource = """
    (function () {
      // Host→View 配送関数。ホスト(Swift)が callAsyncJavaScript で
      // __appsBridgeDeliver(jsonString) を呼ぶ。JSON.parse して合成 MessageEvent を投げる。
      // dispatchEvent 由来の合成イベントは DOM 仕様上つねに isTrusted === false になり、
      // これが下の capture リスナーでの方向判別(Host→View の目印)になる。
      // source: window は正当な WindowProxy なので MessageEvent の型制約を満たし、かつ
      // View 側フィルタ(event.source === window なら通す)を自然に通過する。
      window.__appsBridgeDeliver = function (jsonString) {
        var data;
        try { data = JSON.parse(jsonString); } catch (e) { return; }
        window.dispatchEvent(new MessageEvent("message", { data: data, source: window, origin: "" }));
      };

      // capture フェーズの傍受リスナー。documentStart 注入 = どのページスクリプトより先に
      // 登録される = 登録順が常に最初、が stopImmediatePropagation 成立の条件(設計 §1)。
      window.addEventListener("message", function (event) {
        var d = event.data;
        if (!d || d.jsonrpc !== "2.0") return;   // 無関係なイベントは素通し
        if (event.source !== window) return;      // 自フレーム由来のみ対象(parent===window)
        if (event.isTrusted) {
          // View→Host(本物の postMessage)。webkit ハンドラへ転送し、View 自身の
          // transport リスナーへのループバック(自分の送信を自分で受ける事故)を止める。
          try {
            window.webkit.messageHandlers.\(handlerName).postMessage(JSON.stringify(d));
          } catch (e) {}
          event.stopImmediatePropagation();
        }
        // isTrusted === false はホストが合成した Host→View 配送 → 何もせず素通しで View に届く。
      }, true);
    })();
    """

    /// WKWebView 用の configuration を組み立てて返す。Features 側はこれで WKWebView を作る。
    public func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()

        // documentStart・主フレーム限定でインターセプタを注入。forMainFrameOnly: true は
        // 「parent===window が成立するのは主フレームのみ」という前提(設計 §1)と対応する。
        let userScript = WKUserScript(
            source: Self.interceptorSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true)
        let controller = WKUserContentController()
        controller.addUserScript(userScript)

        // message handler は弱参照プロキシ経由で登録(retain cycle 対策・上の型コメント参照)。
        controller.add(WeakScriptMessageHandler(delegate: self), name: Self.handlerName)
        configuration.userContentController = controller

        return configuration
    }

    /// 生成済みの WKWebView を Transport に紐付ける(delivery に webView 参照が要るため)。
    public func attach(to webView: WKWebView) {
        self.webView = webView
    }

    // MARK: - Host→View 配送

    /// JSON-RPC メッセージ(すでに JSON 文字列化済み)を View へ配送する。
    /// 文字列連結ではなく callAsyncJavaScript の arguments に載せる(設計 §1: エスケープ事故回避)。
    ///
    /// nonisolated のまま受けるが、WKWebView 操作は **必ず MainActor で**行う
    /// (下の deliverOnMain に委譲)。理由(S2 申し送りの反映・設計 §2 の MainActor 隔離判断):
    /// この deliver は `AppsBridgeSession`(actor)から呼ばれる。actor のエグゼキュータは
    /// メインスレッドではないため、ここで直に `webView.callAsyncJavaScript` を叩くと WKWebView を
    /// 非メインスレッドから触ることになり未定義動作になる(WebKit は UI スレッド専有)。S2 では
    /// たまたま動いていたが、正しくは MainActor へホップする。deliver を丸ごと @MainActor に
    /// しなかったのは、呼び出し側(actor)に「配送は非同期の投げっぱなし」という素朴な API を
    /// 保つため —— 隔離の詳細は transport の内側に閉じ込める。
    public func deliver(rawJSON: String) async {
        await deliverOnMain(rawJSON: rawJSON)
    }

    /// WKWebView への実配送。MainActor 隔離(上のコメントの根拠)。
    @MainActor
    private func deliverOnMain(rawJSON: String) async {
        guard let webView else {
            logger.error("deliver: webView 未 attach。配送をスキップ")
            return
        }
        do {
            // __appsBridgeDeliver は documentStart スクリプトで定義済み。arguments["json"] は
            // WebKit がネイティブ直列化して JS 側の String として渡すので injection の余地がない。
            // 戻り値(呼び出し JS の評価結果)は使わないので破棄。配送関数は undefined を返す。
            _ = try await webView.callAsyncJavaScript(
                "window.__appsBridgeDeliver(json);",
                arguments: ["json": rawJSON],
                contentWorld: .page)
            logger.notice("Host→View 配送済み")
        } catch {
            logger.error("Host→View 配送失敗: \(String(reflecting: error), privacy: .public)")
        }
    }

    /// JSON-RPC レスポンスを組み立てて配送する薄いヘルパ(ハーネス/セッションから使う)。
    public func deliver(response: JSONRPCResponse) async {
        do {
            let data = try JSONEncoder().encode(response)
            await deliver(rawJSON: String(decoding: data, as: UTF8.self))
        } catch {
            logger.error("response エンコード失敗: \(String(reflecting: error), privacy: .public)")
        }
    }

    /// ストリームを閉じる(webView 破棄時に呼ぶ)。
    public func finish() {
        incomingContinuation.finish()
    }
}

// MARK: - WKScriptMessageHandler(View→Host 受信)

extension WebViewTransport: WKScriptMessageHandler {
    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // インターセプタは JSON.stringify した文字列を postMessage してくるので body は String。
        guard let raw = message.body as? String else {
            logger.error("受信 body が String でない: \(String(describing: message.body), privacy: .public)")
            return
        }
        do {
            let decoded = try JSONRPCMessage.decode(from: Data(raw.utf8))
            // 節目を unified log に .notice で残す(P1 と同様 log show で追える)。method を出す。
            switch decoded {
            case .request(let r):
                logger.notice("View→Host 受信: request method=\(r.method, privacy: .public)")
            case .notification(let n):
                logger.notice("View→Host 受信: notification method=\(n.method, privacy: .public)")
            case .response(let r):
                logger.notice("View→Host 受信: response id=\(String(describing: r.id), privacy: .public)")
            }
            incomingContinuation.yield((message: decoded, raw: raw))
        } catch {
            // malformed(jsonrpc:"2.0" だが判別不能)は握って落とす。上位で onerror 相当に
            // 昇格させるのは S3 の状態機械の仕事(設計 §1: transport は「未知は黙殺」規約)。
            logger.error("View→Host 受信のデコード失敗: \(String(reflecting: error), privacy: .public) raw=\(raw, privacy: .public)")
        }
    }
}

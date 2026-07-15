// P2 スパイク S4/S5 の起動画面: caldav に OAuth 接続 →list-todos カードを1枚描画し、
// カード内 complete の往復まで通す(設計 §6-S4/S5)。起動は MCPHOST_SPIKE=todos。
//
// フロー(設計 §4/§6):
//  1. P1 の OAuth 接続(LoopbackOAuthAuthorizationDelegate + MCPConnection.connect)を再利用して
//     caldav /mcp に繋ぎ、tools/list を得る。
//  2. tools/list から list-todos の _meta.ui.resourceUri を解決(AppsServerProxy)。
//  3. resources/read で ui:// HTML をプリフェッチ(mimeType 検証込み)。
//  4. サンドボックス WKWebView を生成して HTML をロード(AppCardWebViewFactory)。
//  5. AppsBridgeSession を起動 → initialize 握手 → ready で tool-input/tool-result を配送。
//  6. 以降、カード内 complete → tools/call passthrough → tool-result 応答(§5 の往復)は
//     セッションが素通しで捌く。
//
// OAuth の対話(パスワード changeme 入力→許可)は人手が要るため、エージェントは (a) 接続確立
// までコードで到達し、(b) カード描画・往復の最終目視は人間(main)に委ねる(タスク指示)。
import SwiftUI
import OSLog
import WebKit
import Services
import Kernel

@MainActor
final class TodosCardSpikeViewModel: ObservableObject {
    enum Phase {
        case connecting               // OAuth 接続 + 準備中(この間はプログレス表示)。
        case card(WKWebView)          // カード生成済み。AppCardView に載せる。
        case failed(String)
    }

    @Published private(set) var phase: Phase = .connecting
    // status 行(接続中/カード準備中/結果配送済み等)。実機はコンソールが無いので画面に出す。
    @Published private(set) var status: String = "起動"

    // カード高さ(size-changed 追従)。session の onSizeChanged からここへ流し込む。
    let cardState = AppCardState()

    private let serverURLString = "https://caldav.gigun-dev.workers.dev/mcp"
    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "todoscard")

    // 生存させ続ける必要があるオブジェクト群(手放すと delegate が nil 化 / セッションが停止する)。
    private var transport: WebViewTransport?
    private var coordinator: AppCardWebCoordinator?
    private var session: AppsBridgeSession?
    private var proxy: AppsServerProxy?
    private var setupTask: Task<Void, Never>?

    /// 画面表示時に一度だけ全フローを走らせる。
    func startIfNeeded() {
        guard setupTask == nil else { return }
        setupTask = Task { await self.run() }
    }

    private func run() async {
        do {
            // --- 1. OAuth 接続(P1 フローの再利用)-------------------------------------
            setStatus("接続中…(ブラウザのシートが出ます・パスワード changeme)")
            guard let url = URL(string: serverURLString) else {
                fail("URL 不正: \(serverURLString)"); return
            }
            let delegate = LoopbackOAuthAuthorizationDelegate()
            let redirectURI = try delegate.prepareRedirectURI()
            logger.notice("S4 接続開始 \(url.absoluteString, privacy: .public)")
            let connection = try await MCPConnection.connect(
                serverURL: url, redirectURI: redirectURI, authorizationDelegate: delegate)
            logger.notice("S4 接続成功 tools=\(connection.tools.count)")
            setStatus("接続成功(tools=\(connection.tools.count))。カード準備中…")

            // --- 2. list-todos の UI リソース URI を解決 ------------------------------
            let proxy = AppsServerProxy(client: connection.client)
            self.proxy = proxy
            guard let uiURI = proxy.resolveUIResourceURI(in: connection.tools, toolName: "list-todos") else {
                fail("list-todos の _meta.ui.resourceUri が見つからない"); return
            }
            logger.notice("S4 UI リソース解決 uri=\(uiURI, privacy: .public)")

            // --- 3. HTML プリフェッチ + 初回 tools/call を並走(設計 §4)---------------
            // resources/read(HTML)と tools/call(list-todos)を待たずに同時発火する。
            async let htmlFetch = proxy.fetchAppHTML(uri: uiURI)
            async let listResult = proxy.callTool(name: "list-todos", arguments: .object([:]))

            let (html, _) = try await htmlFetch
            logger.notice("S4 HTML プリフェッチ完了 bytes=\(html.utf8.count)")

            // --- 4. サンドボックス WKWebView を生成 ------------------------------------
            let transport = WebViewTransport()
            self.transport = transport
            let coordinator = AppCardWebCoordinator()
            self.coordinator = coordinator
            let webView = await AppCardWebViewFactory.make(
                transport: transport, html: html, coordinator: coordinator)

            // --- 5. セッション起動(initialize 握手)-----------------------------------
            // onSizeChanged: 高さを cardState へ(300ms ease-out・上限 600・設計 §5)。
            let cardState = self.cardState
            let session = AppsBridgeSession(
                transport: transport,
                proxy: proxy,
                containerWidth: 360,   // モバイルのコンパクトカード幅(設計 §5 の 300–360px 指針)
                maxHeight: 600,
                onSizeChanged: { height in
                    await MainActor.run {
                        withAnimation(.easeOut(duration: 0.3)) {
                            cardState.desiredHeight = min(CGFloat(height), 600)
                        }
                    }
                })
            self.session = session
            await session.start()

            // カードを画面に出す(この時点で View は initialize を送ってくる)。
            phase = .card(webView)
            setStatus("カード表示。initialize 握手待ち…")

            // --- 5b. tool-input → tool-result を配送(ready 前なら outbox 経由)---------
            // 先に tool-input(引数)を積み、初回 list-todos の結果が届いたら tool-result を積む。
            // どちらも ready 前は outbox に退避され、initialized 受信で FIFO flush される(設計 §2)。
            await session.sendToolInput(arguments: .object([:]))
            let result = try await listResult
            logger.notice("S4 初回 list-todos 結果取得 → tool-result 配送")
            await session.sendToolResult(result)
            setStatus("tool-result 配送済み。カード内で complete → 往復を試せます(S5)")
        } catch {
            logger.error("S4 セットアップ失敗: \(String(reflecting: error), privacy: .public)")
            fail(String(describing: error))
        }
    }

    /// 明示破棄(画面離脱時)。teardown を投げてから片付ける(設計 §6)。
    func teardown() {
        let session = self.session
        Task { await session?.teardown() }
    }

    private func setStatus(_ s: String) {
        status = s
        logger.notice("status: \(s, privacy: .public)")
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        setStatus("失敗: \(message)")
    }
}

struct TodosCardSpikeView: View {
    @StateObject private var viewModel = TodosCardSpikeViewModel()

    var body: some View {
        VStack(spacing: 12) {
            Text("MCP Apps カードスパイク(S4/S5)")
                .font(.headline)
            Text(viewModel.status)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            switch viewModel.phase {
            case .connecting:
                ProgressView()
                Spacer()

            case let .card(webView):
                // カードは幅ホスト固定・高さ size-changed 追従(設計 §5)。角丸+枠で「カード」らしく。
                AppCardView(webView: webView)
                    .frame(height: viewModel.cardState.desiredHeight)
                    .frame(maxWidth: 360)
                    .background(Color(white: 0.98))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.85)))
                    .padding()
                Spacer()

            case let .failed(message):
                Text(message)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .padding()
                Spacer()
            }
        }
        .padding(.top)
        .onAppear { viewModel.startIfNeeded() }
        .onDisappear { viewModel.teardown() }
    }
}

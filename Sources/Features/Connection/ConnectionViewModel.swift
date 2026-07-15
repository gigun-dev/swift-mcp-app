// P1「接続(MVP フェーズ1)」の状態機械。OAuth 接続〜tools/list 取得のオーケストレーションを
// SwiftUI View から分離しておく(View はこの ObservableObject を描画するだけにする)。
//
// エラーは握りつぶさずそのまま文字列化して画面に出す方針(タスク指示: 「デバッグしやすさ優先」)。
// 本番想定のエラー分類(トークン失効/ネットワーク/ユーザーキャンセル等の出し分け)は
// チャット機能(P3)以降、実際に困ってから設計する。
import Foundation
import OSLog
import Services  // MCPConnection・Tool(@_exported import MCP 経由)

@MainActor
final class ConnectionViewModel: ObservableObject {
    enum State {
        case idle
        case connecting
        case connected(tools: [Tool])
        case failed(String)
    }

    // caldav 本番 /mcp を既定値にしておく(タスク指示: 「サーバー URL 入力欄(既定値 caldav 本番)」)。
    // ただし固定はしない ——「汎用ホスト」方針(CLAUDE.md)を体現するため、テキストフィールドで
    // 任意の MCP サーバー URL に差し替えられるようにしてある。
    @Published var serverURLString = "https://caldav.gigun-dev.workers.dev/mcp"
    @Published private(set) var state: State = .idle

    private var connectionTask: Task<Void, Never>?
    // OAuth フローのような対話+ネットワーク混在の不具合はスクリーンショットの
    // エラー1行では追えないため、unified log に経過を残す(`log stream` で観察する)。
    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "connection")

    /// デバッグ用の自動接続: 起動環境変数 MCPHOST_AUTOCONNECT=1 のとき、画面表示直後に
    /// 接続を開始する。目的は開発者(と Claude Code)が simctl launch --setenv だけで
    /// E2E(OAuth 自動承認〜tools/list)を人手のタップなしで再現・観察できるようにすること。
    /// リリースビルドに残しても発火しない(環境変数は開発時にしか渡せない)が、
    /// 気になるなら P3 の頃に #if DEBUG で囲む。
    func autoConnectIfRequested() {
        if ProcessInfo.processInfo.environment["MCPHOST_AUTOCONNECT"] == "1",
            case .idle = state
        {
            logger.info("MCPHOST_AUTOCONNECT=1: 自動接続を開始")
            startConnecting()
        }
    }

    func connectTapped() {
        guard case .connecting = state else {
            // 二重タップでの多重接続を防ぐ(NWListener がポートを2つ掴んで
            // ASWebAuthenticationSession のシートが2枚重なる不具合を実機で作りかけたため
            // ガードを入れている)。
            startConnecting()
            return
        }
    }

    private func startConnecting() {
        guard let url = URL(string: serverURLString), url.scheme == "https" || url.scheme == "http"
        else {
            state = .failed("URL が不正です: \(serverURLString)")
            return
        }

        connectionTask?.cancel()
        state = .connecting

        connectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // delegate は接続1回につき1インスタンス(loopback リスナーの生存期間を
                // 1回のフローに閉じ込めるため使い回さない — LoopbackOAuthAuthorizationDelegate
                // のコメント参照)。
                let delegate = LoopbackOAuthAuthorizationDelegate()
                let redirectURI = try delegate.prepareRedirectURI()
                logger.info("接続開始: \(url.absoluteString, privacy: .public) redirect=\(redirectURI.absoluteString, privacy: .public)")
                let result = try await MCPConnection.connect(
                    serverURL: url,
                    redirectURI: redirectURI,
                    authorizationDelegate: delegate
                )
                logger.info("接続成功: tools=\(result.tools.count)")
                self.state = .connected(tools: result.tools)
            } catch {
                // String(describing:) は associated value を折りたたむことがあるので、
                // ログには reflecting(デバッグ表現)で全容を残す。画面は従来どおり簡潔に。
                logger.error("接続失敗: \(String(reflecting: error), privacy: .public)")
                self.state = .failed(String(describing: error))
            }
        }
    }
}

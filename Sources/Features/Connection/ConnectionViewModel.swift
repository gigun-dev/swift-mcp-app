// P1「接続(MVP フェーズ1)」の状態機械。OAuth 接続〜tools/list 取得のオーケストレーションを
// SwiftUI View から分離しておく(View はこの ObservableObject を描画するだけにする)。
//
// エラーは握りつぶさずそのまま文字列化して画面に出す方針(タスク指示: 「デバッグしやすさ優先」)。
// 本番想定のエラー分類(トークン失効/ネットワーク/ユーザーキャンセル等の出し分け)は
// チャット機能(P3)以降、実際に困ってから設計する。
import Foundation
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
                let redirectURI = try await delegate.prepareRedirectURI()
                let result = try await MCPConnection.connect(
                    serverURL: url,
                    redirectURI: redirectURI,
                    authorizationDelegate: delegate
                )
                self.state = .connected(tools: result.tools)
            } catch {
                self.state = .failed(String(describing: error))
            }
        }
    }
}

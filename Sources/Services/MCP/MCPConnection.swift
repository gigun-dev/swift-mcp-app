// MCP サーバーへの OAuth 2.1 接続 + tools/list 取得をまとめた層。
//
// caldav 固有の知識を一切持たせない(CLAUDE.md ビジョン2「汎用ホストとしての中立性」・
// docs/next-directions.md 路線B「任意の MCP サーバーに OAuth で繋ぐ汎用ホスト」)。
// 呼び出し側(Features)が任意のサーバー URL を渡せば、そのサーバーが RFC 9728/8414 準拠の
// OAuth 保護リソースである限り同じコードで繋がる。
//
// 認可 UI(ブラウザ提示・ローカルリダイレクト捕捉)は UIKit/AuthenticationServices に依存するため
// このターゲット(Services。`swift test` を macOS でも回す方針 — Package.swift 参照)には置けない。
// `OAuthAuthorizationDelegate`(swift-sdk のプロトコル)の実体・その redirect URI 準備は
// Features 側(iOS のみの XcodeGen ターゲット)の責務とし、ここでは「出来上がった delegate と
// redirect URI を受け取って接続する」ところまでを引き受ける。
import Foundation
import MCP

/// MCP サーバーへの接続結果。
public struct MCPConnectionResult: Sendable {
    /// 接続済みの swift-sdk `Client`(actor)。以後の `callTool` などはこれを介して行う。
    public let client: Client
    /// `tools/list` で取得したツール一覧(1ページ目のみ。P1 はページングまで踏み込まない —
    /// caldav 本番は 2026-07-15 時点で 14〜18 ツール程度でページングが発生しない規模のため)。
    public let tools: [Tool]

    public init(client: Client, tools: [Tool]) {
        self.client = client
        self.tools = tools
    }
}

public enum MCPConnection {
    /// OAuth 2.1 + Streamable HTTP で MCP サーバーに接続し、`tools/list` を1回取得する。
    ///
    /// - Parameters:
    ///   - serverURL: 接続先 MCP エンドポイント(例: `https://caldav.gigun-dev.workers.dev/mcp`)。
    ///   - redirectURI: authorization_code フローのリダイレクト URI。
    ///     swift-sdk の `OAuthURLValidator.validateRedirectURI` が https か
    ///     loopback(`127.0.0.1`/`localhost`/`::1`)の http しか許可しないため
    ///     (Base/Authorization/OAuthURLValidator.swift で実装調査済み)、iOS の定番である
    ///     カスタム URL スキームのリダイレクトは **この SDK では使えない**。
    ///     呼び出し側(Features の `LoopbackOAuthAuthorizationDelegate`)がローカル HTTP
    ///     リスナーを立てて発行した loopback URI を渡す前提。
    ///   - authorizationDelegate: ブラウザ提示〜認可コード捕捉を担う delegate 実装。
    ///   - clientName: DCR(Dynamic Client Registration)の `client_name` および
    ///     MCP `Client(name:)` に使う表示名。
    /// - Returns: 接続済み `Client` と初回の `tools/list` 結果。
    public static func connect(
        serverURL: URL,
        redirectURI: URL,
        authorizationDelegate: any OAuthAuthorizationDelegate,
        clientName: String = "MCPHost"
    ) async throws -> MCPConnectionResult {
        let tokenStorage = KeychainTokenStorage(serverURL: serverURL)

        // 認証方式は `.none(clientID: "")` から開始する。空の clientID は
        // `OAuthAuthorizer.maybeRegisterClient` が「クライアント登録が未実施」と判定する条件
        // (`guard case .none = configuration.authentication`)そのものなので、これにより
        // 初回接続時に自動で DCR(RFC 7591)が走り、caldav 側の契約通り
        // `token_endpoint_auth_method: "none"` で登録される
        // (caldav docs/next-directions.md 方向性 E の暗黙契約: 出典コメントを写経)。
        let oauthConfiguration = OAuthConfiguration(
            grantType: .authorizationCode,
            authentication: .none(clientID: ""),
            authorizationRedirectURI: redirectURI,
            clientName: clientName,
            authorizationDelegate: authorizationDelegate
        )

        let authorizer = OAuthAuthorizer(
            configuration: oauthConfiguration,
            tokenStorage: tokenStorage
        )

        // streaming(SSE) は SDK 既定(true)のまま使う。caldav の `/mcp` は
        // `Accept: text/event-stream` 必須という暗黙契約があり(caldav 側 docs/next-directions.md
        // 方向性 E)、HTTPClientTransport の Streamable HTTP 実装がこれを満たす前提。
        let transport = HTTPClientTransport(
            endpoint: serverURL,
            authorizer: authorizer
        )

        let client = Client(name: clientName, version: "0.1.0")
        _ = try await client.connect(transport: transport)

        let (tools, _) = try await client.listTools()
        return MCPConnectionResult(client: client, tools: tools)
    }
}

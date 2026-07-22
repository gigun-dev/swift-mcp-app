// 複数 MCP サーバーへの同時接続を束ねるマネージャ(M2)。
//
// 【なぜ要るか(ユーザー FB)】「基本 MCP クライアントは複数の remote MCP を繋げる」。M1 までの
// 「1チャット=1サーバー(単一選択)」を廃し、有効な全サーバーへ**同時接続**する。起動時は
// トークンが生きていれば**無言接続**(ブラウザを開かない)、生きていなければ「要認証」で待ち、
// ユーザーがタップしたときだけ対話接続(ブラウザ)を出す。
//
// 【層の位置(Features に置く理由)】接続そのもの(MCPConnection.connect)は Services だが、
// 対話接続のブラウザ提示は LoopbackOAuthAuthorizationDelegate(AuthenticationServices・UIKit 依存)を
// 使うため Features(iOS 専用ターゲット)に置く。ここは「サーバーごとの接続状態機械 + OAuth delegate の
// 使い分け + tools/list の名前空間化」を担い、ChatHomeViewModel がこれを観測してチャットを組む。
//
// 【中立性(CLAUDE.md ビジョン2)】caldav 固有の知識は持たない。任意の MCP サーバーに対して同じ
// 状態機械で振る舞う(slug 生成・前置は ToolNamespacing 純関数に委譲)。
import Foundation
import Observation
import OSLog
import Kernel    // ToolDefinition・ToolNamespacing
import Services  // MCPConnection・AppsServerProxy・prefixedToolDefinitions・Tool(MCP 再エクスポート)

/// 接続済みサーバー1本ぶんの「使える材料」一式(ready 状態の associated value)。
///
/// proxy は tools/call・resources/read の実行口、tools は元の tools/list(設定画面のビューア用)、
/// toolDefs は **前置済み(slug__tool)** の LLM 定義、uiResourceURIs も **前置名キー**。ChatHomeViewModel が
/// 複数の ReadyConnection を合成して1つの ChatViewModel を組む。
public struct ReadyConnection: Identifiable, Sendable {
    public let serverID: UUID
    public var id: UUID { serverID }
    public let name: String
    public let url: URL
    /// このサーバーの名前空間 slug(ToolNamespacing.slug で決定的に生成)。前置名・逆引きの鍵。
    public let slug: String
    public let proxy: AppsServerProxy
    /// 元の tools/list 結果(前置なし)。設定画面の tools ビューア(追加スコープ)がこれを読む。
    public let tools: [Tool]
    /// LLM へ渡す前置済みツール定義(visibility 除外後)。
    public let toolDefs: [ToolDefinition]
    /// 前置名 → ui:// リソース URI のマップ(カード起動用)。
    public let uiResourceURIs: [String: String]
}

@MainActor
@Observable
public final class ConnectionsManager {
    /// サーバーごとの接続状態(タスク指示の状態機械)。
    public enum State {
        case disconnected             // 未接続(無効サーバー・まだ試みていない)。
        case connecting               // 接続試行中(無言 or 対話)。
        case ready(ReadyConnection)   // 接続確立・ツール取得済み。
        case needsAuth                // 無言接続が「対話が必要」で失敗 → ユーザーのタップ待ち。
        case failed(String)           // 対話以外の失敗(ネットワーク・サーバーエラー等)。
    }

    /// serverID → 状態。dict にキーが無い = .disconnected 扱い(state(for:) で吸収)。
    /// @Observable なので SettingsSheet / ChatHomeView がこの変化を観測して状態アイコンを出し分ける。
    public private(set) var states: [UUID: State] = [:]

    /// ready 集合が変わった(接続完了 / 切断)ときに呼ばれる。ChatHomeViewModel が「空の現行チャットを
    /// 最新ツールで組み直す」フックに使う(進行中/発話済みのチャットは差し替えない=タスク指示 §3)。
    public var onReadyConnectionsChanged: (() -> Void)?

    /// serverID → 進行中の接続 Task(再接続で古いものをキャンセルするため保持)。
    private var connectTasks: [UUID: Task<Void, Never>] = [:]
    /// serverID → 割り当て済み slug(決定的・登録順で採番)。前置名・逆引きの鍵。
    private var slugByServer: [UUID: String] = [:]

    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "connections")

    public init() {}

    /// 指定 id の現在状態(dict に無ければ disconnected)。
    public func state(for id: UUID) -> State {
        states[id] ?? .disconnected
    }

    /// いま ready な接続の一覧(登録順は保証しない — 呼び出し側が必要なら並べ替える)。
    public var readyConnections: [ReadyConnection] {
        states.values.compactMap { if case .ready(let rc) = $0 { return rc } else { return nil } }
    }

    // MARK: - slug 採番

    /// サーバー一覧(登録順)から slug を決定的に採番する(名前ベース・衝突は -2 で回避)。
    ///
    /// maxLength を 32 に絞る理由: LLM の name 制約は `slug__tool` 全体で 64 字。slug を 32 に抑えれば
    /// `32 + 2 + 30` でツール名 30 字まで安全に収まる(MCP のツール名は実質これより短い)。名前が長い
    /// サーバーでも前置名が 64 を割らないための保守的な上限(タスク指示「超過は slug 側を切り詰め」)。
    private func reassignSlugs(_ servers: [MCPServerEntry]) {
        var used = Set<String>()
        var map: [UUID: String] = [:]
        for entry in servers {
            let slug = ToolNamespacing.slug(for: entry.name, existing: used, maxLength: 32)
            used.insert(slug)
            map[entry.id] = slug
        }
        slugByServer = map
    }

    // MARK: - 起動時 / トグル ON の無言接続

    /// 有効な全サーバーへ無言接続を試みる(起動時 + トグル ON 時)。既に connecting/ready のものは触らない。
    /// 無効化/削除されたサーバー(enabled=false or 一覧から消えた)は接続を破棄する。
    public func connectEnabled(_ servers: [MCPServerEntry]) {
        reassignSlugs(servers)
        let enabled = servers.filter { $0.enabled }
        for entry in enabled {
            switch state(for: entry.id) {
            case .connecting, .ready:
                continue  // 進行中/接続済みはそのまま(無駄な再接続を起こさない)。
            default:
                startSilentConnect(entry)
            }
        }
        // 有効一覧に居ないサーバー(無効化・削除)の接続を畳む。
        let liveIDs = Set(enabled.map { $0.id })
        for id in states.keys where !liveIDs.contains(id) {
            teardown(id)
        }
    }

    /// 単一サーバーへ無言接続を(再)試行する(トグル ON の直後などに使える薄い口)。
    public func silentConnect(_ entry: MCPServerEntry, servers: [MCPServerEntry]) {
        reassignSlugs(servers)
        startSilentConnect(entry)
    }

    private func startSilentConnect(_ entry: MCPServerEntry) {
        guard let slug = slugByServer[entry.id] else { return }
        states[entry.id] = .connecting
        connectTasks[entry.id]?.cancel()
        connectTasks[entry.id] = Task { [weak self] in
            await self?.performSilentConnect(entry, slug: slug)
        }
    }

    private func performSilentConnect(_ entry: MCPServerEntry, slug: String) async {
        let delegate = SilentOAuthAuthorizationDelegate()
        // 無言接続では対話は起きない(presentAuthorizationURL は即 throw)。redirectURI は
        // OAuthConfiguration が要求するので、loopback の妥当な URL を1つ渡す(実際には使われない)。
        let redirectURI = URL(string: "http://127.0.0.1/callback")!
        do {
            let connection = try await MCPConnection.connect(
                serverURL: entry.url,
                redirectURI: redirectURI,
                authorizationDelegate: delegate
            )
            let ready = try await makeReady(entry: entry, slug: slug, connection: connection)
            guard !Task.isCancelled else { return }
            states[entry.id] = .ready(ready)
            logger.notice("無言接続 成功 \(entry.url.absoluteString, privacy: .public) tools=\(connection.tools.count)")
            onReadyConnectionsChanged?()
        } catch {
            if Task.isCancelled { return }
            if delegate.didRequestInteraction {
                // トークンが生きておらず対話が必要 → 要認証で待つ(ブラウザは勝手に開かない)。
                states[entry.id] = .needsAuth
                logger.notice("無言接続 要認証 \(entry.url.absoluteString, privacy: .public)")
            } else {
                states[entry.id] = .failed(shortError(error))
                logger.error("無言接続 失敗 \(entry.url.absoluteString, privacy: .public): \(String(reflecting: error), privacy: .public)")
            }
        }
    }

    // MARK: - 対話接続(ユーザーのタップ起点)

    /// ユーザーが「要認証」サーバーをタップしたときに呼ぶ。ブラウザ(ASWebAuthenticationSession)を
    /// 出して OAuth を完了させる。成功で ready、失敗で failed。
    public func connectInteractively(_ entry: MCPServerEntry, servers: [MCPServerEntry]) {
        reassignSlugs(servers)
        guard let slug = slugByServer[entry.id] else { return }
        states[entry.id] = .connecting
        connectTasks[entry.id]?.cancel()
        connectTasks[entry.id] = Task { [weak self] in
            await self?.performInteractiveConnect(entry, slug: slug)
        }
    }

    private func performInteractiveConnect(_ entry: MCPServerEntry, slug: String) async {
        // delegate は接続1回につき1インスタンス(loopback リスナーの生存を1フローに閉じる・
        // ChatHomeViewModel の旧 runConnect と同じ作法)。この async 関数が返るまで delegate は生存する。
        let delegate = LoopbackOAuthAuthorizationDelegate()
        do {
            let redirectURI = try delegate.prepareRedirectURI()
            let connection = try await MCPConnection.connect(
                serverURL: entry.url,
                redirectURI: redirectURI,
                authorizationDelegate: delegate
            )
            let ready = try await makeReady(entry: entry, slug: slug, connection: connection)
            guard !Task.isCancelled else { return }
            states[entry.id] = .ready(ready)
            logger.notice("対話接続 成功 \(entry.url.absoluteString, privacy: .public) tools=\(connection.tools.count)")
            onReadyConnectionsChanged?()
        } catch {
            if Task.isCancelled { return }
            states[entry.id] = .failed(shortError(error))
            logger.error("対話接続 失敗 \(entry.url.absoluteString, privacy: .public): \(String(reflecting: error), privacy: .public)")
        }
        _ = delegate  // 明示保持(この行まで delegate を生存させる意図の可視化)。
    }

    // MARK: - 切断 / 破棄

    /// サーバーの接続を破棄する(トグル OFF・削除時)。進行中 Task をキャンセルし、状態を落とす。
    public func disconnect(serverID: UUID) {
        teardown(serverID)
        onReadyConnectionsChanged?()
    }

    private func teardown(_ id: UUID) {
        connectTasks[id]?.cancel()
        connectTasks[id] = nil
        // dict からキーを消す(state(for:) が disconnected を返すようになる)。
        if states[id] != nil {
            states[id] = nil
        }
    }

    // MARK: - 鮮度(#12 staleness): ready 接続の tools/list を取り直す

    /// ready な全接続の tools/list を取り直し、名前空間化した toolDefs / uiResourceURIs を作り直す。
    /// ChatHomeViewModel.newChat から呼ぶ(「新規チャット」の境界でだけ鮮度を取る・AppsServerProxy の
    /// refreshToolsAndInvalidateHTMLCache のコメント参照)。取得失敗したサーバーは既存 ready のまま残す
    /// (鮮度リフレッシュの失敗でチャット全体を殺さない)。
    public func refreshReadyConnections() async {
        for rc in readyConnections {
            do {
                let tools = try await rc.proxy.refreshToolsAndInvalidateHTMLCache()
                let toolDefs = try prefixedToolDefinitions(from: tools, slug: rc.slug, serverName: rc.name)
                var uiMap: [String: String] = [:]
                for tool in tools {
                    if let uri = rc.proxy.resolveUIResourceURI(for: tool) {
                        uiMap[ToolNamespacing.prefixed(slug: rc.slug, tool: tool.name)] = uri
                    }
                }
                states[rc.serverID] = .ready(ReadyConnection(
                    serverID: rc.serverID, name: rc.name, url: rc.url, slug: rc.slug,
                    proxy: rc.proxy, tools: tools, toolDefs: toolDefs, uiResourceURIs: uiMap))
            } catch {
                logger.error("tools/list 再取得 失敗 \(rc.url.absoluteString, privacy: .public): \(String(reflecting: error), privacy: .public)")
            }
        }
    }

    // MARK: - 内部: ReadyConnection の組み立て

    private func makeReady(entry: MCPServerEntry, slug: String, connection: MCPConnectionResult) async throws -> ReadyConnection {
        let proxy = AppsServerProxy(client: connection.client)
        // app 発 tools/call の visibility 判定用に一覧を注入(設計 §7 の 401 MUST)。
        await proxy.setTools(connection.tools)
        // LLM 定義は前置名(slug__tool)+ 出自注記つき(prefixedToolDefinitions)。
        let toolDefs = try prefixedToolDefinitions(from: connection.tools, slug: slug, serverName: entry.name)
        // ui:// マップも前置名キーで作る(ChatViewModel.uiResourceURIs は前置名で引く)。
        var uiMap: [String: String] = [:]
        for tool in connection.tools {
            if let uri = proxy.resolveUIResourceURI(for: tool) {
                uiMap[ToolNamespacing.prefixed(slug: slug, tool: tool.name)] = uri
            }
        }
        return ReadyConnection(
            serverID: entry.id, name: entry.name, url: entry.url, slug: slug,
            proxy: proxy, tools: connection.tools, toolDefs: toolDefs, uiResourceURIs: uiMap)
    }

    /// エラー文言を画面表示用に短くする(全容は logger に String(reflecting:) で残す)。
    private func shortError(_ error: Error) -> String {
        String(describing: error)
    }
}

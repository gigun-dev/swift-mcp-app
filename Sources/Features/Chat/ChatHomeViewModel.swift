// チャット主画面のオーケストレータ(T4-B)。OAuth 接続 → AppsServerProxy 生成 →
// ツール定義変換 → OpenAICompatClient 生成 → ChatViewModel(tool-use ループ)組み立てまでを
// 1本のフローにまとめ、SwiftUI(ChatHomeView)は状態を描画するだけにする。
//
// 接続フローは ConnectionViewModel / TodosCardSpikeView の実装済みパターンを踏襲・再利用する
// (LoopbackOAuthAuthorizationDelegate + MCPConnection.connect + MCPHOST_AUTOCONNECT)。
// T4 のスコープはテキスト往復まで(カードは T5)なので、AppsServerProxy は「ツール実行口
// (MCPToolExecuting)」としてのみ使う。ui:// 解決・HTML プリフェッチ・AppsBridgeSession は
// 呼ばない(T5 でここに足す)。
//
// 中立性(CLAUDE.md ビジョン2): この VM は caldav 固有の知識を持たない。サーバー URL は
// 設定で差し替え可能な既定値にすぎず、systemPrompt も汎用(「MCP ツールを使えるアシスタント」)。
import Foundation
import Observation
import OSLog
import Services  // MCPConnection・AppsServerProxy・OpenAICompatClient・toolDefinitions・ChatViewModel

/// チャット主画面の状態機械 + セッション構築。
///
/// @MainActor @Observable: 状態を SwiftUI(ChatHomeView)が観測する。ChatViewModel も
/// @MainActor @Observable なので、.ready の associated value として保持しても観測が伝播する。
@MainActor
@Observable
public final class ChatHomeViewModel {
    /// 画面の4状態(タスク指示)。
    public enum State {
        case needsSetup           // キー未設定 or 未接続(接続前ゲート)。
        case connecting           // OAuth 接続 + セッション構築中(プログレス表示)。
        case ready(ChatViewModel) // 接続確立・ループ準備完了(チャット本体を出す)。
        case failed(String)       // 接続・構築に失敗(エラー表示 + 再試行)。
    }

    public private(set) var state: State = .needsSetup

    /// BYOK 設定(base URL・モデル・キー)。SettingsSheet と共有する参照。
    /// 接続時にここから OpenAICompatClient と model を組む。
    public let settings: LLMSettingsStore

    /// 接続先 MCP サーバー URL。既定は caldav 本番だが固定しない(汎用ホスト・設定で変更可)。
    /// P3-T4 では設定 UI に露出しないが、コードとしては差し替え可能に保つ(将来サーバー選択 UI)。
    public var serverURLString = "https://caldav.gigun-dev.workers.dev/mcp"

    // 接続で生成したオブジェクトは手放すと delegate が nil 化してフローが壊れるため保持する
    // (TodosCardSpikeView と同じ理由)。proxy は ChatViewModel 内にも保持されるが、
    // ここでも参照を握って生存を確実にする。
    private var connectTask: Task<Void, Never>?
    private var proxy: AppsServerProxy?

    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "chat-home")

    public init(settings: LLMSettingsStore) {
        self.settings = settings
    }

    /// デバッグ用自動接続(MCPHOST_AUTOCONNECT=1)。ConnectionViewModel と同流儀で、
    /// simctl launch --setenv だけでエージェントが接続〜チャット準備まで人手なしに到達できる。
    /// キー未設定だと LLM 呼び出しは失敗するが、それは MCPHOST_LLM_KEY で供給する想定(T4-A)。
    public func autoConnectIfRequested() {
        if ProcessInfo.processInfo.environment["MCPHOST_AUTOCONNECT"] == "1" {
            if case .needsSetup = state {
                logger.info("MCPHOST_AUTOCONNECT=1: チャット自動接続を開始")
                connect()
            }
        }
    }

    /// 接続ボタン(または自動接続)から呼ぶ。二重起動は connectTask のキャンセルで防ぐ。
    public func connect() {
        connectTask?.cancel()
        state = .connecting

        connectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.runConnect()
            } catch {
                // 経緯全容は log(reflecting)へ、画面は簡潔に(ConnectionViewModel と同じ方針)。
                self.logger.error("チャット接続失敗: \(String(reflecting: error), privacy: .public)")
                self.state = .failed(String(describing: error))
            }
        }
    }

    private func runConnect() async throws {
        guard let url = URL(string: serverURLString),
              url.scheme == "https" || url.scheme == "http"
        else {
            state = .failed("MCP サーバー URL が不正です: \(serverURLString)")
            return
        }

        // --- 1. OAuth 接続(P1 フローの再利用)---------------------------------------
        // delegate は接続1回につき1インスタンス(loopback リスナーの生存を1フローに閉じる)。
        let delegate = LoopbackOAuthAuthorizationDelegate()
        let redirectURI = try delegate.prepareRedirectURI()
        logger.notice("接続開始 \(url.absoluteString, privacy: .public)")
        let connection = try await MCPConnection.connect(
            serverURL: url,
            redirectURI: redirectURI,
            authorizationDelegate: delegate
        )
        logger.notice("接続成功 tools=\(connection.tools.count)")

        // --- 2. AppsServerProxy = ツール実行口(MCPToolExecuting)------------------------
        // setTools で visibility 判定用の一覧を注入する(app 発 tools/call 拒否・設計 §7 の 401 MUST。
        // T4 ではカードが無いので app 発呼び出しは起きないが、proxy の契約どおり一覧を渡しておく)。
        let proxy = AppsServerProxy(client: connection.client)
        await proxy.setTools(connection.tools)
        self.proxy = proxy

        // --- 3. LLM に見せるツール定義(visibility 除外込み・設計 §7)---------------------
        // toolDefinitions が visibility:["app"] を落とす(refresh-todos/refresh-events 等)。
        let toolDefs = try toolDefinitions(from: connection.tools)
        logger.notice("LLM ツール定義 \(toolDefs.count) 件(visibility 除外後)")

        // --- 4. OpenAICompatClient(BYOK 設定から)-------------------------------------
        guard let baseURL = URL(string: settings.baseURL) else {
            state = .failed("LLM base URL が不正です: \(settings.baseURL)")
            return
        }
        let llm = OpenAICompatClient(baseURL: baseURL, apiKey: settings.apiKey)

        // --- 5. ChatViewModel(tool-use ループ)を組んで .ready へ ----------------------
        let chatVM = ChatViewModel(
            llm: llm,
            toolExecutor: proxy,
            tools: toolDefs,
            model: settings.model,
            systemPrompt: Self.systemPrompt
        )
        state = .ready(chatVM)
        logger.notice("チャット準備完了 model=\(self.settings.model, privacy: .public)")
    }

    /// 既定 system プロンプト。**痩せさせる理由 = コスト**(設計 §6):
    /// tool-use は毎ターン ≈18 ツールのスキーマ(数千トークン)を送るので、system を長文にすると
    /// そのぶん毎ターンの入力トークンが恒常的に膨らむ。汎用ホストとして中立な最小限の指示に留める
    /// (caldav 固有の語彙を入れない — CLAUDE.md ビジョン2)。
    static let systemPrompt = "あなたは MCP ツールを使えるアシスタントです。必要なときだけツールを呼び、"
        + "結果を踏まえて簡潔に日本語で答えてください。"
}

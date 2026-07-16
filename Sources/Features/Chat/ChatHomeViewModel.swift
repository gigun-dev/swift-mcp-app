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

    /// 接続で生成した AppsServerProxy。**View(ChatBodyView → InlineCardView)がカード構築で使う**
    /// ため公開する(T5)。fetchAppHTML と tools/call 素通しはどのカードからも同じ proxy = 同じ接続に
    /// 流れる(設計 §4「接続は共有」)。.ready へ遷移した時点で必ず非 nil。
    public private(set) var proxy: AppsServerProxy?

    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "chat-home")

    /// チャット履歴の永続化(T6 前半・設計 02 §5)。本番ディレクトリは
    /// `Application Support/chats/`(iOS では FileManager.urls(for: .applicationSupportDirectory)
    /// がアプリのサンドボックス内 Application Support を返す)。
    private let chatStore = ChatStore(baseDirectory: ChatHomeViewModel.defaultChatsDirectory())

    public init(settings: LLMSettingsStore) {
        self.settings = settings
    }

    /// 本番の保存先ディレクトリ。取得に失敗する理論上のケース(サンドボックス外実行等)に備え、
    /// 一時ディレクトリへフォールバックする(履歴保存が失敗してもチャット自体は継続できる方針
    /// ——ChatStore.save の失敗はチャットを止めない、A5 の方針と一貫させる)。
    private static func defaultChatsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("chats", isDirectory: true)
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

        // --- 3b. UI 資源マップ(toolName → ui:// URI)の事前計算(設計 §4・T5)------------------
        // 発見(resolveUIResourceURI)は Features 側でここ1回だけ行い、結果を ChatViewModel へ渡す。
        // ループ本体は AppsServerProxy に依存せずこの precomputed マップだけ見る(MCPToolExecuting 抽象を
        // 保つ・ChatViewModel.uiResourceURIs のコメント参照)。resolveUIResourceURI は nonisolated 純関数
        // なので await 不要。UI を持たないツール(refresh-* 等)は非 nil にならず、マップに載らない。
        var uiResourceURIs: [String: String] = [:]
        for tool in connection.tools {
            if let uri = proxy.resolveUIResourceURI(for: tool) {
                uiResourceURIs[tool.name] = uri
            }
        }
        logger.notice("UI 資源を持つツール \(uiResourceURIs.count) 件")

        // --- 4. OpenAICompatClient(BYOK 設定から)-------------------------------------
        guard let baseURL = URL(string: settings.baseURL) else {
            state = .failed("LLM base URL が不正です: \(settings.baseURL)")
            return
        }
        let llm = OpenAICompatClient(baseURL: baseURL, apiKey: settings.apiKey)

        // --- 5. ChatViewModel(tool-use ループ)を組んで .ready へ ----------------------
        // sessionId は接続1回につき新規発番(T6 前半のスコープは「書き込み」まで ——
        // 過去セッションの読み込み/復元はサイドバー実装と一緒の T6 後半送り・指示どおり)。
        let sessionId = UUID().uuidString
        let store = chatStore
        let sessionLogger = logger
        var chatVM: ChatViewModel!
        chatVM = ChatViewModel(
            llm: llm,
            toolExecutor: proxy,
            tools: toolDefs,
            model: settings.model,
            systemPrompt: Self.systemPrompt,
            uiResourceURIs: uiResourceURIs,
            traceSink: OSLogTraceSink(),
            sessionId: sessionId,
            serverURL: url,
            onTurnSettled: {
                // A5: 各ターン確定時に保存。ChatViewModel は MainActor なのでこのクロージャも
                // MainActor 文脈で呼ばれる(ChatViewModel.send の defer から同期呼び出し)。
                // 保存自体は同期 I/O(ChatStore.save)なので Task に逃がさずそのまま呼ぶ ——
                // JSON ファイル1個分の書き込みは軽量で、チャット UI をブロックするほどではない
                // という判断(設計に明記なし・こう解釈。重くなるようなら後で Task { } に切り出す)。
                do {
                    try store.save(chatVM.currentSession)
                } catch {
                    // 保存失敗はチャットを止めない(A5)。原因追跡のためログだけ残す。
                    sessionLogger.error("チャット履歴の保存に失敗: \(String(reflecting: error), privacy: .public)")
                }
            }
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

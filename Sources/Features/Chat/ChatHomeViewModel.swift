// チャット主画面のオーケストレータ(M2・複数サーバー同時接続)。
//
// M1 までは「1チャット=1サーバー(単一選択)」で、起動時に接続ゲート(「接続」ボタン)を出していた。
// M2 では **登録済みの有効サーバー全てへ同時接続**し、**起動即チャット**にする(ユーザー FB「毎回接続を
// 押すのが違和感」)。接続の状態機械は ConnectionsManager(Features/Connection)に隔離し、この VM は
// 「ready な接続群を合成して1つの ChatViewModel を組む」ことに専念する。
//
// 【途中差し替えをしない設計(タスク指示 §3)】ready 集合が増減しても、進行中/発話済みのチャットは
// 差し替えない。新しいツールは **次の新規チャット(newChat)** で反映する。例外として、まだ1度も発話して
// いない空のチャットは、接続が増えたら黙って組み直す(refreshEmptyChatIfIdle)——空なので何も失われない。
//
// 中立性(CLAUDE.md ビジョン2): この VM は caldav 固有の知識を持たない。名前空間化(slug__tool)は
// ToolNamespacing / ConnectionsManager に閉じ、ここは合成と ChatViewModel 構築だけを担う。
import Foundation
import Observation
import OSLog
import Kernel    // ChatSession・ToolDefinition・ToolNamespacing
import Services  // MCPConnection・AppsServerProxy・MultiServerToolExecutor・OpenAICompatClient・ChatViewModel

@MainActor
@Observable
public final class ChatHomeViewModel {
    /// 画面状態(M2 で接続ゲートを廃止したので2状態に単純化)。
    /// 起動即チャット = 常に .ready(空チャットでも)。.failed は「チャット自体を組めない致命」
    /// (LLM base URL 不正など)に限る。サーバー未接続でも LLM だけのチャット(ツール0件)は撃てる。
    public enum State {
        case ready(ChatViewModel)
        case failed(String)
    }

    public private(set) var state: State = .failed("初期化中")

    /// 表示モード(履歴閲覧との直交軸・M1 から不変)。詳細は旧コメントの意図を踏襲(live / viewingHistory)。
    public enum DisplayMode {
        case live
        case viewingHistory(ChatSession)
    }

    public private(set) var displayMode: DisplayMode = .live
    public private(set) var historyLoadError: String?

    /// BYOK 設定(SettingsSheet と共有)。
    public let settings: LLMSettingsStore
    /// MCP サーバー登録簿(SettingsSheet と共有)。
    public let registry: ServerRegistryStore
    /// 複数サーバー同時接続の状態機械(SettingsSheet / ChatHomeView がサーバー一覧の状態表示に読む)。
    public let connections = ConnectionsManager()

    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "chat-home")

    /// チャット履歴の永続化(サイドバーが loadIndex/delete で読むため公開)。
    public let chatStore = ChatStore(baseDirectory: ChatHomeViewModel.defaultChatsDirectory())
    private let pricingStore = PricingStore(baseDirectory: ChatHomeViewModel.defaultPricingDirectory())

    /// 現在のチャットが握る slug→proxy スナップショット(カード由来サーバーの解決に使う)。
    /// makeChatViewModel のたびに更新する。cardProxy(forToolName:) がここから引く。
    private var currentSlugProxies: [String: AppsServerProxy] = [:]
    /// 短縮 wire 名を含む、現在のチャットの明示 route。カードも実行口と同じ逆引きを使う。
    private var currentToolRoutes: [String: ToolRoute] = [:]

    public init(settings: LLMSettingsStore, registry: ServerRegistryStore) {
        self.settings = settings
        self.registry = registry

        // 接続の ready 集合が変わったら、空チャットなら黙って最新ツールで組み直す(上のクラスコメント)。
        connections.onReadyConnectionsChanged = { [weak self] in
            self?.refreshEmptyChatIfIdle()
        }

        // 初期チャットを即組む(接続がまだ 0 でもツール0件のチャットとして成立させる = 起動即チャット)。
        rebuildChat(using: buildContext())

        // pricing は接続をブロックしない(fire-and-forget・M1 と同じ)。
        Task { [weak self] in
            guard let self else { return }
            await self.pricingStore.load()
            self.applyPricingToCurrentChatVM()
        }
    }

    // MARK: - 起動 / 自動接続

    /// ChatHomeView.onAppear から呼ぶ。有効な全サーバーへ無言接続を開始する(起動即チャット)。
    /// MCPHOST_AUTOCONNECT は M1 の互換用に残す(M2 では常に自動接続するので実質同じ挙動)。
    public func start() {
        connections.connectEnabled(registry.servers)
    }

    // MARK: - 接続コンテキストの合成

    /// ready な全接続を合成した「1チャットぶんの材料」。
    private struct ChatContext {
        let executor: MultiServerToolExecutor
        let toolDefs: [ToolDefinition]
        let uiResourceURIs: [String: String]
        let serverURL: URL          // 代表(最初の ready)。ToolStepRow attribution 等の後方互換に使う。
        let serverURLs: [URL]        // 全 ready(ChatSession.serverURLs へ)。
        let slugProxies: [String: AppsServerProxy]
        let toolRoutes: [ToolRoute]
        let serverNames: [String: String]
        let originalToolNames: [String: String]
        let serverIDs: [String: UUID]
        let serverURLsByTool: [String: URL]
    }

    /// 現在 ready な接続群から ChatContext を組む(ツール定義・ui:// マップ・executor を合成)。
    private func buildContext() -> ChatContext {
        let ready = connections.readyConnections
        var executors: [String: any MCPToolExecuting] = [:]
        var slugProxies: [String: AppsServerProxy] = [:]
        var toolDefs: [ToolDefinition] = []
        var uiMap: [String: String] = [:]
        var urls: [URL] = []
        var toolRoutes: [ToolRoute] = []
        for readyConnection in ready {
            executors[readyConnection.slug] = readyConnection.proxy
            slugProxies[readyConnection.slug] = readyConnection.proxy
            toolDefs.append(contentsOf: readyConnection.toolDefs)
            for (key, value) in readyConnection.uiResourceURIs { uiMap[key] = value }
            urls.append(readyConnection.url)
            let routes = readyConnection.tools.map {
                ToolNamespacing.route(slug: readyConnection.slug, tool: $0.name)
            }
            toolRoutes.append(contentsOf: routes)
        }
        // LLM 定義を正として、executor route とカード帰属も同じ集合へ閉じる。
        // app-only tool は readyConnection.tools / AppsServerProxy には残るため、カード内部の
        // tools/call は引き続き app visibility に従って呼べるが、通常チャットからは実行不能になる。
        let surface = strictModelToolRoutingSurface(
            toolDefinitions: toolDefs,
            routes: toolRoutes,
            uiResourceURIs: uiMap
        )
        let metadata = chatRouteMetadata(routes: surface.routes, connections: ready)
        let originalToolNames = Dictionary(uniqueKeysWithValues: surface.routes.map {
            ($0.wireName, $0.toolName)
        })
        return ChatContext(
            executor: MultiServerToolExecutor(
                executors: executors,
                routes: surface.routes,
                routePolicy: .explicitRoutesOnly
            ),
            toolDefs: surface.toolDefinitions,
            uiResourceURIs: surface.uiResourceURIs,
            serverURL: urls.first ?? ChatViewModel.placeholderServerURL,
            serverURLs: urls,
            slugProxies: slugProxies,
            toolRoutes: surface.routes,
            serverNames: metadata.serverNames,
            originalToolNames: originalToolNames,
            serverIDs: metadata.serverIDs,
            serverURLsByTool: metadata.serverURLs
        )
    }

    /// ChatContext から新しい空セッションの ChatViewModel を組んで state を .ready にする。
    /// LLM base URL 不正のときだけ .failed。currentSlugProxies も更新する(カード由来解決用)。
    private func rebuildChat(using context: ChatContext) {
        guard let baseURL = URL(string: settings.baseURL) else {
            state = .failed("LLM の base URL が不正です: \(settings.baseURL)")
            return
        }
        let llm = OpenAICompatClient(baseURL: baseURL, apiKey: settings.apiKey)
        let sessionId = UUID().uuidString
        let store = chatStore
        let sessionLogger = logger
        var chatVM: ChatViewModel!
        chatVM = ChatViewModel(
            llm: llm,
            toolExecutor: context.executor,
            tools: context.toolDefs,
            model: settings.model,
            systemPrompt: Self.systemPrompt,
            uiResourceURIs: context.uiResourceURIs,
            serverNames: context.serverNames,
            originalToolNames: context.originalToolNames,
            serverIDs: context.serverIDs,
            serverURLsByTool: context.serverURLsByTool,
            traceSink: OSLogTraceSink(),
            sessionId: sessionId,
            serverURL: context.serverURL,
            serverURLs: context.serverURLs.isEmpty ? nil : context.serverURLs,
            onTurnSettled: {
                do {
                    try store.save(chatVM.currentSession)
                } catch {
                    sessionLogger.error("チャット履歴の保存に失敗: \(String(reflecting: error), privacy: .public)")
                }
            }
        )
        currentSlugProxies = context.slugProxies
        // あり得ないハッシュ衝突でも後勝ちにしない。executor と同じ fail-closed に揃え、
        // 衝突した wire 名のカードは proxy を解決できない状態にする。
        var indexedRoutes: [String: ToolRoute] = [:]
        var ambiguousWireNames = Set<String>()
        for route in context.toolRoutes {
            if let existing = indexedRoutes[route.wireName], existing != route {
                indexedRoutes.removeValue(forKey: route.wireName)
                ambiguousWireNames.insert(route.wireName)
            } else if !ambiguousWireNames.contains(route.wireName) {
                indexedRoutes[route.wireName] = route
            }
        }
        currentToolRoutes = indexedRoutes
        state = .ready(chatVM)
        displayMode = .live
        applyPricingToCurrentChatVM()
    }

    /// ready 集合が変わったとき、現行チャットが「空 & 実行中でない」なら最新ツールで組み直す。
    /// 空なので失われるものは無い(発話済み/実行中は差し替えず、次の newChat で反映・タスク指示 §3)。
    private func refreshEmptyChatIfIdle() {
        guard case .ready(let chatVM) = state else { return }
        // 履歴閲覧中は触らない(ライブ state を裏で組み直しても閲覧体験は変えないが、無駄なので避ける)。
        if case .viewingHistory = displayMode { return }
        guard chatVM.turns.isEmpty, !chatVM.isRunning else { return }
        rebuildChat(using: buildContext())
        logger.notice("空チャットを最新接続で組み直し(ready 集合の変化)")
    }

    // MARK: - カード由来サーバーの proxy 解決(M2・カードの由来紐付け)

    /// 前置ツール名(slug__tool)から、そのカードを起動すべき proxy(由来サーバー)を返す。
    /// ChatBodyView → InlineCardView がカード構築時にこれで proxy を選ぶ(tools/call・resources/read が
    /// 由来サーバーへ流れる・タスク指示 §4)。未知の prefix / 切断済みサーバーは nil(カードは描画されない)。
    public func cardProxy(forToolName name: String) -> AppsServerProxy? {
        // 通常チャットのカード帰属も executor と同じ広告済みrouteだけを正とする。
        // `slug__tool` の推測 fallback は app-only tool を再び表へ出すため、ここでは行わない。
        guard let route = currentToolRoutes[name] else { return nil }
        return currentSlugProxies[route.slug]
    }

    // MARK: - 新規チャット

    /// 新規チャット(サイドバー / ナビの compose)。ready 各接続の tools/list を取り直してから組む
    /// (#12 staleness 修正をサーバーごとに実施・ConnectionsManager.refreshReadyConnections)。
    public func newChat() async {
        displayMode = .live
        historyLoadError = nil
        if case .ready(let oldChatVM) = state {
            oldChatVM.cancelActiveSend()  // 旧チャットの進行中送信を打ち切る(M1 と同じ作法)。
        }
        await connections.refreshReadyConnections()
        rebuildChat(using: buildContext())
        logger.notice("新規チャットを開始(接続再利用・tools/list 再取得・新 sessionId)")
    }

    // MARK: - サーバーの有効/無効・接続(SettingsSheet / サーバーメニューから)

    /// SettingsSheet のトグル。ON で無言接続、OFF で切断。登録簿へも反映(永続化)。
    public func setServerEnabled(id: UUID, enabled: Bool) {
        registry.setEnabled(id: id, enabled: enabled)
        if enabled {
            connections.connectEnabled(registry.servers)
        } else {
            connections.disconnect(serverID: id)
        }
    }

    /// 「要認証」サーバーをタップしたとき(サーバーメニュー)。ブラウザで対話接続する。
    public func connectInteractively(serverID: UUID) {
        guard let entry = registry.servers.first(where: { $0.id == serverID }) else { return }
        connections.connectInteractively(entry, servers: registry.servers)
    }

    /// サーバー削除(SettingsSheet)。接続を破棄し、登録簿から消す(トークンも Keychain から消える)。
    public func removeServer(id: UUID) {
        connections.disconnect(serverID: id)
        registry.remove(id: id)
    }

    /// サーバー追加後に呼ぶ(SettingsSheet)。新規登録分を接続対象に含める。
    public func afterServerAddedOrEdited() {
        connections.connectEnabled(registry.servers)
    }

    // MARK: - 履歴閲覧(M1 から不変)

    public func openHistory(id: UUID) {
        do {
            let session = try chatStore.load(id: id)
            historyLoadError = nil
            displayMode = .viewingHistory(session)
            logger.notice("履歴を開いた id=\(id.uuidString, privacy: .public) turns=\(session.turns.count)")
        } catch {
            logger
                .error(
                    "履歴の読み込みに失敗 id=\(id.uuidString, privacy: .public): \(String(reflecting: error), privacy: .public)"
                )
            historyLoadError = "履歴の読み込みに失敗しました。ファイルが壊れている可能性があります。"
        }
    }

    public func clearHistoryLoadError() { historyLoadError = nil }
    public func returnToLive() { displayMode = .live }

    // MARK: - pricing

    private func applyPricingToCurrentChatVM() {
        guard case .ready(let chatVM) = state else { return }
        chatVM.modelPrice = pricingStore.price(for: settings.model)
    }

    private static func defaultChatsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("chats", isDirectory: true)
    }

    private static func defaultPricingDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("pricing", isDirectory: true)
    }

    /// 既定 system プロンプト(痩せさせる理由=コスト・M1 から不変)。
    static let systemPrompt = "あなたは MCP ツールを使えるアシスタントです。必要なときだけツールを呼び、"
        + "結果を踏まえて簡潔に日本語で答えてください。"
}

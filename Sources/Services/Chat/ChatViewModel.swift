// tool-use ループ本体(設計 02-chat-llm.md §3)。ユーザー発話 → LLM 補完(SSE)→
// tool_calls があればツール実行 → 結果をモデルに返して再補完 …… を「.stop で確定」または
// 「最大反復で打ち切り」まで回すオーケストレータ。
//
// 層配置(設計 §0-1): ループは LLMClient(Services)と MCPToolExecuting(= AppsServerProxy・
// Services)に依存するので **Services/Chat** が正(Kernel には置けない — Kernel は依存ゼロ)。
// caldav 非依存(ツール名・structuredContent の形を知らない・CLAUDE.md ビジョン2)。
//
// T3 のスコープ: **カード無しのテキスト往復まで**。ツール結果は LLM へ返す role:"tool"
// テキストとしてのみ扱い、ui:// カード描画(二重配布の (b)・設計 §4)は T5 送り。
// caldav への実接続(OAuth 経由)は Features 未実装のため T3 では行わない — ループは
// MCPToolExecuting 抽象越しにツールを呼ぶだけで、接続の有無を知らない(live 検証は
// フェイク executor で自走を確認する)。
import Foundation
import Observation
import Kernel
import os  // 【診断 2026-07-17】実機で「LLM tool_calls 後に tools/call が発火しない」ハングの位置特定用。
           // 原因確定後にこの診断ログは撤去してよい(chat-diag カテゴリ)。

/// チャット1画面ぶんの状態 + tool-use ループ。
///
/// `@MainActor @Observable`: 公開状態(turns・isRunning・usage・error)を SwiftUI が観測する
/// (T4 の ChatView)。UIKit/SwiftUI 型は一切持たない(Observation は Foundation レベルの
/// 依存で Services に置ける)ので、Services 層の制約(プラットフォーム UI 非依存)を破らない。
///
/// **表示用 turns と wire messages を分ける理由**(重要な設計判断):
///  - `turns`([ChatTurn]・Kernel ドメイン型)は **UI の見せ方**。1ユーザー発話 + それに続く
///    assistant の応答(途中のツールステップ込み)を「人間が読む単位」で持つ。
///  - `wireMessages`([ChatMessage]・OpenAI ワイヤ型)は **LLM へ毎回丸ごと送る履歴**。
///    OpenAI のプロトコルは assistant の tool_calls メッセージと、それに対応する role:"tool"
///    メッセージを厳密なペアで要求する(欠けると 400)。この「機械が要求する厳密な系列」を
///    表示用の粒度に混ぜると、片方の都合でもう片方が壊れる。だから別々に持ち、
///    それぞれの正しさを独立に保つ(設計 §0「wire 型とドメイン型を分ける」の実践)。
@MainActor
@Observable
public final class ChatViewModel {
    // MARK: - 公開状態(UI が観測)

    /// 表示用のターン列。user 発話と assistant 応答が交互に並ぶ。
    /// ストリーミング中は末尾 assistant ターンの text/toolSteps を逐次書き換える。
    public private(set) var turns: [ChatTurn] = []

    /// 「ユーザー発話が turns に積まれた」という**事実の記録**(2026-07-17 スクロール再設計・Fable)。
    ///
    /// 【なぜ turns の形からの推測をやめて明示イベントにするか(バグ機序)】旧実装は View 側で
    /// `onChange(of: turns.count)` を観測し `turns.last?.role == .user` のときだけ「送信された」と
    /// *推測*して user ターンを最上部へスクロールしていた。しかし send() は user ターンを append した
    /// 直後、同じ実行フロー内で(間に await を挟まず)**空の assistant ターンも append** する。
    /// SwiftUI の onChange は1トランザクション内の複数 mutation を合体した最終値でしか発火しないため、
    /// 観測時点では `turns.last` が既に `.assistant` になっており、guard が常に弾いて**一度もスクロール
    /// しなかった**。配列の形から送信イベントを復元するのは append 2連発・retry(縮んで伸びる)・
    /// LazyVStack 遅延生成に対して原理的に脆い。そこで「送信が起きた」ことを VM が事実として1点に記録し、
    /// View はそれを観測する(推測しない)。
    ///
    /// seq(単調増加)を持つ理由: retry では**同じ turnIndex**へ再送されることがあり、turnIndex だけだと
    /// Equatable 上の変化が起きず onChange が発火しない。seq を毎回 +1 することで再送でも必ず変化を作る。
    ///
    /// 命名に "scroll" を含めないのは、VM が View の使途を知らない中立設計(CLAUDE.md ビジョン2・
    /// onTurnSettled と同じ「事実の通知であって UI 指示ではない」思想)。
    public struct UserSubmission: Equatable, Sendable {
        /// 積まれた user ターンの turns 内 index。
        public let turnIndex: Int
        /// 単調増加のシーケンス番号(同一 index への retry でも Equatable 変化を保証)。
        public let seq: Int
    }
    public private(set) var lastSubmission: UserSubmission?

    /// ループ実行中フラグ(送信ボタンの無効化・スピナー表示に使う)。
    public private(set) var isRunning: Bool = false

    /// 直近ターンの usage(入力欄上の「このターン ≈ N tok」表示・設計 §6)。
    public private(set) var lastUsage: Usage?

    /// セッション累計 usage(将来の累計コスト表示・設計 §6)。プロバイダが usage を
    /// 返さないターンがあっても壊れないよう、届いたぶんだけ足す。
    public private(set) var cumulativeUsage: Usage?

    /// ユーザーに見せるエラー(最大反復超過・ストリーム失敗など)。次の send で消える。
    public private(set) var errorMessage: String?

    /// モデルの単価(設計 §6・T7)。**settable・既定 nil**。pricing(litellm データ)は
    /// PricingStore が async で後から取得するため、ChatViewModel の構築時点では未確定なことが
    /// 普通にある(§6「不明なら非表示」と同じ姿勢で、届くまでは lastCostUSD/cumulativeCostUSD が
    /// nil になるだけで壊れない)。ChatHomeViewModel が接続時・モデル変更時に代入する。
    public var modelPrice: ModelPrice?

    /// このターンの概算コスト(USD)。modelPrice か lastUsage のどちらかが nil なら nil
    /// (**未知モデル/pricing 未ロードなら nil のまま**——設計 §6「嘘の金額を出さない」)。
    public var lastCostUSD: Double? {
        guard let usage = lastUsage, let modelPrice else { return nil }
        return estimatedCostUSD(usage: usage, price: modelPrice)
    }

    /// セッション累計の概算コスト(USD)。lastCostUSD と同じく nil 伝播。
    public var cumulativeCostUSD: Double? {
        guard let usage = cumulativeUsage, let modelPrice else { return nil }
        return estimatedCostUSD(usage: usage, price: modelPrice)
    }

    // MARK: - 依存(注入)

    private let llm: any LLMClient
    private let toolExecutor: any MCPToolExecuting

    /// 【診断 2026-07-17】実機ハング位置特定用の一時ロガー(chat-diag)。原因確定後に撤去可。
    static let diagLogger = Logger(subsystem: "dev.gigun.mcphost", category: "chat-diag")
    /// LLM に見せるツール定義。**呼び出し側が ToolConversion.toolDefinitions で visibility 除外
    /// 済みのものを渡す**前提(設計 §7 の除外は変換時に済む — ループは再判定しない)。
    private let tools: [ToolDefinition]
    private let model: String
    private let maxIterations: Int

    /// toolName → ui:// リソース URI の事前計算マップ(設計 §3-4・§4)。
    ///
    /// 【なぜ AppsServerProxy を握らず precomputed マップだけ見るか(重要な設計判断)】
    /// ループの依存は MCPToolExecuting(1メソッド抽象)に絞る方針(MCPToolExecuting.swift の
    /// 冒頭コメント・CLAUDE.md ビジョン2 の中立性)。ui:// リソースの「発見」は AppsServerProxy の
    /// resolveUIResourceURI が担うが、それをループに持ち込むと (1) テストが actor Proxy を必要とし
    /// (2) ループが「カードを持つツール」という MCP Apps 固有の関心に踏み込む。そこで
    /// **発見は Features 側(ChatHomeViewModel)で接続直後に一度だけ resolveUIResourceURI して
    /// [name: uri] に畳み、その結果だけをループに注入する**。ループは「実行成功したツール名が
    /// このマップに在れば、その URI でカードを1枚起こす」以上のことを知らない(素通しの JSONValue
    /// 方針と対称)。空マップ = カードを持たないホスト(テキスト往復のみ)で後方互換。
    private let uiResourceURIs: [String: String]

    /// 観測 sink(設計 03 §3・T6 前半)。既定 nil で T3/T5 の既存呼び出し・テストを壊さない
    /// (fire-and-forget: nil なら emit 自体を呼ばずスキップする=コストゼロ)。
    private let traceSink: (any TraceSink)?

    /// このチャットセッションの識別子(ChatTraceEvent.chatId・ChatSession.id の元)。
    /// 文字列で受け取る理由は「呼び出し側(ChatHomeViewModel)がどんな ID 生成方式を選んでも
    /// 素通しできるようにする」(設計に型の指定は無い・こう解釈)。ChatSession.id は UUID 型なので、
    /// 有効な UUID 文字列でなければランダム UUID にフォールバックする(壊れた文字列で
    /// currentSession の構築自体が失敗しないように)。
    private let sessionId: String
    private let sessionUUID: UUID
    /// currentSession に積む接続先(設計 §5 ChatSession.serverURL)。既定は placeholder
    /// (T3/T5 の既存呼び出し・テストが serverURL を渡さなくても initializer が壊れないように)。
    /// 実運用(ChatHomeViewModel)は必ず実サーバー URL を渡す。
    private let sessionServerURL: URL
    private let sessionCreatedAt = Date()

    /// 1ユーザーターン(send 呼び出し)が確定(.stop 到達 or 最大反復打ち切り)したときに呼ばれる。
    /// **ストリーム失敗による早期 return を含め、send() が返る直前に必ず呼ぶ**(defer)。
    /// 置き場の判断(設計に明記なし・こう解釈): ChatHomeViewModel が ChatStore.save を
    /// ここから呼ぶ想定(A5)。保存の成否はこのコールバック内で ChatViewModel の外側が扱う
    /// (ループを保存の成否でブロックしない・TraceSink と同じ fire-and-forget の思想)。
    private let onTurnSettled: (() -> Void)?

    // MARK: - 内部状態

    /// LLM へ送る厳密な履歴(上のクラスコメント参照)。system をあれば先頭に据える。
    private var wireMessages: [ChatMessage] = []

    /// 現在実行中の send/retryLastTurn を追跡する Task(監査 2026-07-18 MEDIUM 対応)。
    ///
    /// 【なぜ VM 自身が Task を持つ形に寄せたか(既存欠陥の機序)】従来は View 側が
    /// `Task { await chatVM.send(text) }` で起動するだけで、その Task 自体は誰も保持しなかった。
    /// newChat() で ChatHomeViewModel が新しい ChatViewModel を作って state を差し替えても、
    /// 旧 chatVM の送信 Task は誰にもキャンセルされず裏で完走を続け、旧チャットの LLM ストリーミングと
    /// MCP tools/call(サーバー副作用あり)が新チャット開始後も走り続けていた。ここで submit/submitRetry
    /// が Task を自前で起こして保持し、cancelActiveSend() でキャンセルできるようにする。
    private var activeSendTask: Task<Void, Never>?

    // MARK: - init

    /// - Parameters:
    ///   - llm: 中立 LLM クライアント(本番は OpenAICompatClient、テストはスタブ)。
    ///   - toolExecutor: MCP ツール実行口(本番は AppsServerProxy、テストはスタブ)。
    ///   - tools: visibility 除外済みの LLM ツール定義(空可 = ツールなしのテキスト往復)。
    ///   - model: モデル ID(リクエストの model フィールド)。
    ///   - systemPrompt: あれば履歴先頭に system メッセージとして固定注入。
    ///   - maxIterations: tool-use の最大反復。既定 8(設計 §3・暴走とコスト暴発の防止)。
    ///   - uiResourceURIs: toolName → ui:// URI の事前計算マップ(設計 §4)。UI 資源を持つツールが
    ///     成功したとき、そのターンの cards に CardEmbed を積む。既定 [:]（カード無し・T3 互換）。
    ///   - traceSink: 観測 sink(設計 03 §3)。既定 nil(観測なし・既存呼び出しを壊さない)。
    ///   - sessionId: このチャットの識別子。既定は新規 UUID 文字列(呼び出し側が省略しても
    ///     currentSession が破綻しない)。
    ///   - serverURL: currentSession.serverURL に積む接続先。既定 placeholder(T3/T5 互換)。
    ///   - onTurnSettled: 1ユーザーターン確定時のコールバック(A5・永続化のトリガ)。既定 nil。
    public init(
        llm: any LLMClient,
        toolExecutor: any MCPToolExecuting,
        tools: [ToolDefinition],
        model: String,
        systemPrompt: String?,
        maxIterations: Int = 8,
        uiResourceURIs: [String: String] = [:],
        traceSink: (any TraceSink)? = nil,
        sessionId: String = UUID().uuidString,
        serverURL: URL = ChatViewModel.placeholderServerURL,
        onTurnSettled: (() -> Void)? = nil
    ) {
        self.llm = llm
        self.toolExecutor = toolExecutor
        self.tools = tools
        self.model = model
        self.maxIterations = maxIterations
        self.uiResourceURIs = uiResourceURIs
        self.traceSink = traceSink
        self.sessionId = sessionId
        self.sessionUUID = UUID(uuidString: sessionId) ?? UUID()
        self.sessionServerURL = serverURL
        self.onTurnSettled = onTurnSettled

        if let systemPrompt {
            // system は履歴の不変の先頭。毎リクエストで送られる(設計に system の扱いの
            // 明示は無いが、OpenAI 標準どおり履歴先頭に固定するのが自然 — こう解釈)。
            wireMessages.append(ChatMessage(role: .system, content: systemPrompt))
        }
    }

    /// serverURL 省略時の既定値。"about:blank" は実在のスキームを持つ有効な URL でありながら
    /// 「未設定」を明示できる値として選んだ(nil を許すと currentSession の型が Optional になり
    /// 呼び出し側全体に伝播するため・設計に無い判断)。
    public nonisolated static let placeholderServerURL = URL(string: "about:blank")!

    /// 現在のチャット状態を ChatSession(永続化 DTO)として組み立てる(A3・設計 §5)。
    /// title は最初の user ターンの text 先頭 40 文字(空文字なら "新規チャット")。
    /// updatedAt はアクセス時点の Date(呼ぶたびに「今」を積む — 保存タイミング=各ターン確定時
    /// に呼ばれる想定なので、その時刻が実質の updatedAt になる)。
    public var currentSession: ChatSession {
        ChatSession(
            id: sessionUUID,
            title: Self.deriveTitle(from: turns),
            serverURL: sessionServerURL,
            createdAt: sessionCreatedAt,
            updatedAt: Date(),
            turns: turns,
            model: model
        )
    }

    // MARK: - カードスナップショットの書き戻し(T6 後半・設計 §5「カードの履歴再訪問題」)

    /// ライブカード(WKWebView)から取得した outerHTML スナップショットを、対応する
    /// CardEmbed へ書き戻して再保存をトリガする(設計 §5「最後のスナップショット HTML を保存」)。
    ///
    /// 呼び出し元は Features 側(InlineCardView → InlineCardHost が
    /// `document.documentElement.outerHTML` を取得し、その identity=(turnIndex, cardIndex) を
    /// 添えてここへ届ける)。スナップショットは **ターン確定後に非同期で届く**(size-changed
    /// 到達やカード離脱を合図に取得されるため、send() の defer(onTurnSettled)よりあとに来うる)。
    /// そこで、書き戻した直後に onTurnSettled を「汎用の永続トリガ」として叩き直し、
    /// snapshotHTML を含んだ最新の currentSession を ChatStore.save させる。
    ///
    /// 【onPersistNeeded を新設せず onTurnSettled を転用した判断(タスク指示で裁量とされた点)】
    /// onTurnSettled は既に「currentSession を保存する」以上の意味を持たない fire-and-forget の
    /// 汎用フック(ChatHomeViewModel が store.save に落としている)。スナップショット到達も
    /// 「保存すべき状態変化が起きた」という同じ事象なので、フックを増やさず再利用するのが素直
    /// (フックが増えるほど呼び出し側の配線ミスの余地が増える)。名前が turn 由来なのは経緯だが、
    /// 実体は「永続化が必要になった」通知として扱う(このコメントで意図を残す)。
    ///
    /// 範囲外 index は安全に無視する(ガード)。スナップショットは非同期で届くため、届いた時点で
    /// 対象ターン/カードが(理論上)もう存在しない・作り替えられている可能性を型で否定できない
    /// ——落とさず黙って捨てる(履歴の見た目が1枚欠けるだけで、チャットは壊れない)。
    /// 同一 HTML の重複書き戻し(size-changed 到達時 + teardown 時の2回取得)は、値が同じなら
    /// 実質 no-op だが save は走る(冪等・コストは JSON 1ファイル書き込みぶんで許容・設計 §5)。
    ///
    /// 【監査 2026-07-18 LOW: card 同一性チェックを追加した理由】index 範囲チェックだけでは
    /// 「範囲内だが別のカード」を区別できない——retry で該当ターン以降が巻き戻された後、同じ
    /// (turnIndex, cardIndex) の位置に**別のツールのカード**が新しく積まれるケースが理論上ありうる
    /// (低確率レース・反証検証済み)。スナップショットは WKWebView 側から非同期に届くため、
    /// 「呼び出し側が期待していたカード」と「今その位置に実際にあるカード」が index だけでは
    /// 一致するとは限らない。呼び出し元(ChatBodyView)にその場で card.resourceUri を閉じ込めて
    /// もらい、書き戻し直前に一致を確認する——不一致は範囲外 index と同じ思想で黙って捨てる
    /// (旧カードの遅延スナップショットが別カードへ誤って書き込まれる事故を防ぐだけで、
    /// 正常系である「同じ card が同じ位置にい続ける通常の書き戻し」には一切影響しない)。
    public func setCardSnapshot(turnIndex: Int, cardIndex: Int, expectedResourceUri: String, html: String) {
        guard turns.indices.contains(turnIndex),
              turns[turnIndex].cards.indices.contains(cardIndex)
        else { return }
        guard turns[turnIndex].cards[cardIndex].resourceUri == expectedResourceUri else { return }
        // 値が変わらないなら保存を走らせない(size-changed が複数回来ても DOM が同じなら無駄書きを避ける)。
        guard turns[turnIndex].cards[cardIndex].snapshotHTML != html else { return }
        turns[turnIndex].cards[cardIndex].snapshotHTML = html
        onTurnSettled?()
    }

    private static func deriveTitle(from turns: [ChatTurn]) -> String {
        guard let firstUserText = turns.first(where: { $0.role == .user })?.text else {
            return "新規チャット"
        }
        let trimmed = firstUserText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "新規チャット" }
        // 40 文字はサイドバー1行に収まる程度の目安(設計にタイトル長の指定は無い・こう解釈)。
        return String(trimmed.prefix(40))
    }

    // MARK: - ループのエントリ

    /// View から呼ぶ送信入口(監査 2026-07-18 MEDIUM 対応)。send() 自身を Task で包んで
    /// activeSendTask に保持し、直前に走っていた send/retryLastTurn があればキャンセルしてから始める
    /// (同一 VM への連打・retry→send の取り違え防止。newChat/画面破棄からの cancelActiveSend とも同じ
    /// 変数を使うので、どちらが先でも二重実行にはならない)。
    ///
    /// send()/retryLastTurn() 自体は引き続き public のまま残す(既存の単体テストが
    /// `await vm.send(...)` / `await vm.retryLastTurn()` を直接同期的に await する形に多数依存しており、
    /// Task 経由に統一すると完了待ちの足場が別途要る=無用な変更コストになるため。View 側だけを
    /// submit/submitRetry 経由に寄せ、キャンセル対象を1本の activeSendTask に揃えるのが最小の修正)。
    public func submit(_ text: String) {
        activeSendTask?.cancel()
        activeSendTask = Task { [weak self] in
            await self?.send(text)
        }
    }

    /// View の再生成ボタンから呼ぶ入口。submit と同じ理由で Task を包んで activeSendTask に保持する。
    public func submitRetry() {
        activeSendTask?.cancel()
        activeSendTask = Task { [weak self] in
            await self?.retryLastTurn()
        }
    }

    /// 進行中の send/retryLastTurn を打ち切る。newChat()(ChatHomeViewModel)や画面破棄
    /// (ChatBodyView.onDisappear)から呼ぶ。activeSendTask が nil(実行中の送信が無い)なら no-op。
    ///
    /// キャンセルの伝播(実装確認 2026-07-18): AsyncThrowingStream(OpenAICompatClient.stream)は
    /// 消費側 Task のキャンセルを言語機構として観測し、for-await ループが打ち切られる
    /// (Swift の AsyncStream 系列は Task キャンセルと協調する——独自実装の AsyncSequence と違い
    /// 明示チェック不要)。runToolCalls の withTaskGroup は構造化並行の子タスクなので、外側 Task の
    /// キャンセルは自動的に子(tools/call)へ伝播する(URLSession 呼び出し自体がキャンセルされ中断する)。
    /// send() 側にも Task.isCancelled の明示チェックを要所に置き、ループの継続判断を早める(下記参照)。
    public func cancelActiveSend() {
        activeSendTask?.cancel()
    }

    /// ユーザー発話を1つ受けて、tool-use ループを .stop / 最大反復まで回す。
    ///
    /// 例外を throw しない(UI からは `submit(text)` 経由で叩く。テストは `await vm.send(text)` を
    /// 直接呼べる)。失敗は errorMessage に載せる——ただし **cancelActiveSend() 由来のキャンセルでは
    /// errorMessage を出さない**(監査 2026-07-18 MEDIUM)。旧チャットが newChat/画面破棄で捨てられた後の
    /// VM にエラー文言を積んでも誰にも見せられず意味が無く、「キャンセルされた」を「失敗した」と
    /// 混同させないための判断。wire/turns の整合を巻き戻す必要も無い(旧 VM は破棄される運命——
    /// 「それ以上進めない」だけで良い・タスク指示どおり)。
    public func send(_ userText: String) async {
        errorMessage = nil
        isRunning = true
        defer { isRunning = false }

        // 観測(設計 03 §3 注入点1: send ループ開始)。turnId は「この1ユーザー発話に対する
        // 一連の反復」全体を指す(反復1周ごとの ID ではない)。
        let turnId = UUID().uuidString
        traceSink?.emit(.turnStarted(chatId: sessionId, turnId: turnId, model: model))
        // A5: 1ユーザーターンの処理が(成功でも失敗でも)終わったら必ず呼ぶ。ストリーム失敗による
        // 早期 return を含めて確実に発火させたいので defer にする(「確定」の厳密な意味は
        // tool-use ループの settled だが、ここでは「この send 呼び出しの処理が終わった」を指す
        // ——設計に無い判断: 部分的な進捗も失わず保存できるほうが観測の目的に適う)。
        defer { onTurnSettled?() }

        // 1) user を wire と表示の両方へ積む。
        wireMessages.append(ChatMessage(role: .user, content: userText))
        turns.append(ChatTurn(role: .user, text: userText))
        // 送信イベントを事実として記録(スクロール再設計・Fable / lastSubmission の宣言コメント参照)。
        // この直後に空 assistant ターンが append されて turns.last が .assistant になっても、
        // この記録は「どの index の user が今積まれたか」を確定させるので View 側が正しく追える。
        lastSubmission = UserSubmission(
            turnIndex: turns.count - 1,
            seq: (lastSubmission?.seq ?? 0) + 1)

        // 2) 反復。各周で assistant ターンを1つ起こし、そこへ text/toolSteps を書き込む。
        var settled = false
        var iterations = 0
        for _ in 0..<maxIterations {
            // 周の頭でキャンセルを確認する(監査 2026-07-18 MEDIUM)。cancelActiveSend() が
            // 前周の tool 実行中〜次周開始までの間に呼ばれた場合、ここで static に打ち切る
            // ——新しい assistant ターンを起こさない・新しいストリームを開かない・エラーも出さない
            // (「それ以上進めない」だけで良い・上のクラスコメント参照)。
            if Task.isCancelled { return }
            iterations += 1
            // 今周の assistant 表示ターンを起こす(空テキストで append し、以降 index で書き換える)。
            let assistantIndex = turns.count
            turns.append(ChatTurn(role: .assistant, text: ""))

            let request = ChatCompletionRequest(
                model: model,
                messages: wireMessages,
                // tools が空なら nil を送る(空配列 tools を嫌うプロバイダがある・OpenAI は
                // 空でも許すが、無用なフィールドは付けない)。
                tools: tools.isEmpty ? nil : tools,
                stream: true
            )

            // --- ストリーム消費: textDelta を逐次表示に反映、completed で確定情報を得る ---
            var accumulatedText = ""
            var finishReason: FinishReason = .other("no_completed")
            var calls: [ToolCall] = []
            var usage: Usage?

            do {
                for try await event in llm.stream(request) {
                    switch event {
                    case .textDelta(let delta):
                        accumulatedText += delta
                        turns[assistantIndex].text = accumulatedText
                    case .completed(let reason, let toolCalls, let turnUsage):
                        finishReason = reason
                        calls = toolCalls
                        usage = turnUsage
                        // 観測(設計 03 §3 注入点2: .completed 受領)。usage 計上(下)と同所。
                        traceSink?.emit(.llmCompleted(turnId: turnId, finishReason: reason.wireValue, usage: turnUsage))
                    }
                }
            } catch is CancellationError {
                // cancelActiveSend() 由来の打ち切り(監査 2026-07-18 MEDIUM)。上のクラスコメントどおり
                // errorMessage は出さない——ユーザーが意図して離れた(newChat/画面破棄)後の旧 VM に
                // エラーを積んでも誰にも見せられない。this周の途中テキストだけ turns に残して終える
                // (turns の巻き戻しは行わない——旧 VM は破棄される運命なので復旧不要)。
                turns[assistantIndex].text = accumulatedText
                return
            } catch {
                // ストリーム自体の失敗(ネットワーク・HTTP・デコード)。この周の assistant ターンに
                // エラーを載せてループを止める(モデルに投げ返せる相手がいない = 継続不能)。
                turns[assistantIndex].text = accumulatedText
                errorMessage = "LLM ストリームに失敗しました: \(error)"
                return
            }

            // ストリームは正常完了したが、その直後にキャンセルされていた場合(監査 2026-07-18 MEDIUM)。
            // tool_calls を実行してしまうと副作用のある MCP 呼び出しが「捨てられたはずのチャット」で
            // 走ってしまうため、次のツール実行に入る前にもう一度確認する。
            if Task.isCancelled { return }

            // usage は分岐によらず毎ターン計上する(設計 §6)。
            if let usage {
                lastUsage = usage
                cumulativeUsage = Self.add(cumulativeUsage, usage)
                turns[assistantIndex].usage = usage
            }

            // 3) assistant メッセージを wire に積む。tool_calls のみのターンは content=null
            //    (ChatCompletion.swift のコメント通り OpenAI は tool_calls だけのとき content: null)。
            wireMessages.append(ChatMessage(
                role: .assistant,
                content: accumulatedText.isEmpty ? nil : accumulatedText,
                toolCalls: calls.isEmpty ? nil : calls
            ))

            // 4) tool_calls が無ければ(=.stop 等)このターンで確定。
            guard finishReason == .toolCalls, !calls.isEmpty else {
                settled = true
                break
            }

            // 5) 各 tool_call を並行実行し、結果を role:"tool" として wire に積み戻して次周へ。
            // 【tools/call のキャンセル伝播(監査 2026-07-18 MEDIUM)】withTaskGroup の子タスクは
            // 構造化並行の子なので、この send() の外側 Task がキャンセルされれば自動的に子(tools/call)へ
            // 伝播し、URLSession 呼び出し自体が中断される(サーバー副作用が「もう見ていないチャット」で
            // 走り続ける事故を防ぐ・タスク指示)。
            await runToolCalls(calls, assistantIndex: assistantIndex, turnId: turnId)
            if Task.isCancelled { return }
            // continue(次の反復へ) — モデルがツール結果を見て次を判断する(設計 §3-5)。
        }

        // 6) 最大反復を使い切ってもまだ .toolCalls で回り続けた = 打ち切り(設計 §3-6)。
        //    暴走・コスト暴発の防止。ユーザーにエラーを見せる(嘘の「完了」を見せない)。
        if !settled {
            errorMessage = "ツール呼び出しが最大反復(\(maxIterations)回)を超えたため打ち切りました。"
        }

        // 観測(設計 03 §3 注入点5: settled)。ストリーム失敗による早期 return はここを通らない
        // (「.stop 到達 or 最大反復打ち切り」のどちらでもない = 反復自体が完結していないため)。
        // cumulativeUsage が一度も届いていない(usage 非対応プロバイダ等)場合は 0 埋めの Usage を積む
        // — turnSettled.cumulativeUsage が非 optional(設計 03 §3 のコードブロックどおり)なので
        // 欠損を「ゼロ」として表現する(設計に明記なし・こう解釈)。
        traceSink?.emit(.turnSettled(
            turnId: turnId,
            iterations: iterations,
            cumulativeUsage: cumulativeUsage ?? Usage(promptTokens: 0, completionTokens: 0)
        ))
    }

    // MARK: - 再生成(retry・ユーザー要望 2026-07-17)

    /// 直近の user ターン以降を巻き戻して同じ内容で再送する(ChatGPT/claude.ai の「再生成」相当)。
    ///
    /// **表示(turns)と wire(wireMessages)を別々に巻き戻す理由**: クラス冒頭コメントのとおり両者は
    /// 別の正しさ基準を持つ。turns は「最後の user ターン以降(user 含む)を削除」するだけでよいが、
    /// wireMessages は system が先頭に残るため「最後の role:.user のインデックス以降を削除」で対応する。
    /// send() が user メッセージを turns/wireMessages へ**同時に** append する(1) 節)ため、
    /// 「turns の最後の user」と「wireMessages の最後の user」は常に同じ発話を指す = この2つの
    /// 巻き戻しは常に整合する(片方だけ削って系列がズレることはない)。
    ///
    /// **OpenAI の assistant(tool_calls)/role:"tool" 厳密ペア(400 対策)を壊さない理由**:
    /// 巻き戻しは「最後の user 以降を丸ごと」落とすので、途中の反復で積まれた
    /// assistant(tool_calls)+role:"tool" のペアも(存在すれば)まとめて削除される。ペアの片方だけが
    /// 残る状態には原理的にならない(ペアは必ず「最後の user より後」に積まれるため)。
    ///
    /// usage(lastUsage/cumulativeUsage)はあえてリセットしない: retry も実際に LLM を叩き直す =
    /// 実トークンを消費するので、cumulativeUsage に足し続けるのが「嘘の金額を出さない」(設計 §6)と
    /// 整合する(リセットすると「このセッションで実際に使った合計」より少ない額を見せてしまう)。
    ///
    /// カード(CardEmbed)は削除された turns ごと消える。ライブカード(WKWebView)の後始末は
    /// このメソッドの関知するところではない(Kernel/Services は WKWebView を知らない・レイヤー分離)。
    /// Features 側(ChatBodyView の retry アクション)が cardRegistry.teardownAll() で対処する。
    /// 巻き戻し後に setCardSnapshot(turnIndex:cardIndex:) が古い index で遅延到着しても、
    /// index ガード(turns.indices.contains / cards.indices.contains)で安全に無視される
    /// (turns が短くなった/該当 index の中身が入れ替わった場合を型で弾けないぶん、実行時ガードで守る)。
    public func retryLastTurn() async {
        guard !isRunning else { return }

        // turns 側: 最後の user ターンの index を探す。
        guard let lastUserTurnIndex = turns.lastIndex(where: { $0.role == .user }) else { return }
        let retryText = turns[lastUserTurnIndex].text

        // wire 側: 最後の role:.user の index を探す(system は先頭に残るので同じ探索を独立に行う)。
        guard let lastUserWireIndex = wireMessages.lastIndex(where: { $0.role == .user }) else { return }

        // 表示・wire それぞれを「最後の user 以降(user 含む)」まで切り詰める。
        turns.removeSubrange(lastUserTurnIndex...)
        wireMessages.removeSubrange(lastUserWireIndex...)

        errorMessage = nil
        await send(retryText)
    }

    // MARK: - ツール実行(1ターンぶんの tool_calls をまとめて)

    /// 1ターンで返ってきた tool_calls をすべて実行し、結果を wire に積む。
    /// - 表示: 各 tool_call を assistant ターンの toolSteps に pending→running→done/failed で反映。
    /// - wire: 結果を role:"tool"(tool_call_id 付き)として積む。**tool_call_id 順で安定化**
    ///   (設計 §3「messages には tool_call_id 順で積む」)。
    private func runToolCalls(_ calls: [ToolCall], assistantIndex: Int, turnId: String) async {
        // 表示ステップを call 順で先に起こす(running まで進める)。UI に「今このツール群を
        // 呼んでいる」を即見せる。argumentsJSON は可視化用にそのまま持つ(設計 §3 の可視化)。
        turns[assistantIndex].toolSteps = calls.map {
            ToolCallStep(toolName: $0.function.name, state: .running, argumentsJSON: $0.function.arguments)
        }

        // 並行実行(TaskGroup)。self を group 内に持ち込まない(MainActor 再入を避ける)ため、
        // 実行に要る値(executor・id・name・arguments)だけを渡す。結果は元の index を添えて返し、
        // 表示ステップとの対応を保つ。
        let executor = self.toolExecutor
        let sink = self.traceSink
        // 【診断 2026-07-17】実機ハングの挟み撃ちログ(chat-diag)。実機ログで llmCompleted 後に
        // toolCallStarted も tools/call 素通しも出ない=TaskGroup の子が走っていない疑いを確定させる。
        Self.diagLogger.notice("runToolCalls: withTaskGroup 開始 calls=\(calls.count, privacy: .public)")
        let results: [ToolExecResult] = await withTaskGroup(of: ToolExecResult.self) { group in
            for (index, call) in calls.enumerated() {
                group.addTask {
                    Self.diagLogger.notice("runToolCalls: 子タスク開始 index=\(index, privacy: .public) name=\(call.function.name, privacy: .public)")
                    let r = await Self.execute(call: call, index: index, executor: executor, traceSink: sink, turnId: turnId)
                    Self.diagLogger.notice("runToolCalls: 子タスク完了 index=\(index, privacy: .public) failed=\(r.failed, privacy: .public)")
                    return r
                }
            }
            var collected: [ToolExecResult] = []
            for await r in group { collected.append(r) }
            return collected
        }
        Self.diagLogger.notice("runToolCalls: withTaskGroup 完了 results=\(results.count, privacy: .public)")

        // 表示ステップの状態を確定(index で対応づけ)。r.content は role:"tool" に積み戻すのと
        // 同じ文字列(成功時は結果 JSON、失敗時はエラー文言)なので、そのまま resultJSON に転記して
        // 「リクエスト/レスポンス」展開 UI(ChatBodyView.ToolStepRow)の元データにする。
        for r in results {
            turns[assistantIndex].toolSteps[r.index].state = r.failed ? .failed : .done
            turns[assistantIndex].toolSteps[r.index].resultJSON = r.content
        }

        // カードの記録(設計 §3-4・§4「二重配布の (b)」)。
        //
        // 成功したツールのうち **uiResourceURIs に URI が在る**ものだけ、このターンの cards に
        // CardEmbed を積む(失敗ツールはカードを作らない — 描画すべき結果が無い)。structuredContent は
        // callTool が返した生 JSONValue をそのまま入れ、arguments はその tool_call の引数を入れる
        // (どちらも Features 側の InlineCardView が sendToolResult / sendToolInput にそのまま渡せる形)。
        //
        // 【順序の安定化】TaskGroup の完了順は非決定的なので、表示 index 昇順(= call 順)で cards を
        // 積む。複数カードが1ターンに並ぶのは稀(設計 §3)だが、並んだときも表示ステップと同じ
        // 順序で並ぶよう固定する(履歴・再現性のため。wire 積み戻しを id 順で安定化しているのと同趣旨)。
        //
        // 【二重配布は維持】role:"tool" テキスト配布(下の wire 積み戻し)は UI 資源ツールでも
        // 従来どおり JSON を LLM へ返す(設計 §4「(a) LLM へ (b) カードへ」の両方)。カードを持つ
        // ツールでも LLM は結果 JSON を見て次の発話を組む必要がある。
        // 【トークン最適化の候補(未実装・設計 §4 は「要約 or JSON」で JSON 採用中)】UI 資源ツールは
        // カードが結果を見せるので、LLM へは短い要約(件数等)で足りる可能性がある。ただし要約の
        // 正しさ担保が要る(モデルが結果本体を参照して回答するケースがある)ので T5 ではやらず候補に留める。
        for r in results.sorted(by: { $0.index < $1.index }) {
            guard !r.failed, let uri = Self.resourceURI(forResult: r.result, toolName: r.toolName, fallback: uiResourceURIs) else { continue }
            // 【設計 03 §2 決定2】isError:true の CallToolResult ではカードを起こさない。
            // caldav が使う TS SDK は失敗を throw ではなく `isError:true` の**正常応答**として
            // 返す(zod バリデーション失敗など・一次資料は設計 03 §1)。r.failed(throw 由来)
            // だけでは拾えないので、成功結果 JSONValue の `isError` フィールドも見る。エラーの
            // role:"tool" 配布(下の wire 積み戻し)には影響しない ——
            // isError 結果でもモデルには JSON がそのまま渡り、モデルがリトライを判断できる。
            // isError の toolStep 表示を failed に寄せる改善は本修正のスコープ外(設計コメント参照)。
            if r.result?["isError"]?.boolValue == true { continue }
            turns[assistantIndex].cards.append(CardEmbed(
                toolName: r.toolName,
                resourceUri: uri,
                snapshotHTML: nil,          // スナップショットは T6(履歴永続化)で埋める。ライブ時は nil。
                structuredContent: r.result, // callTool が返した生 JSONValue(sendToolResult にそのまま渡す)。
                arguments: r.arguments       // この tool_call の引数(sendToolInput にそのまま渡す)。
            ))
        }

        // wire への積み戻しは **tool_call_id 順で安定**(TaskGroup の完了順は非決定的なので、
        // ここで必ずソートする)。順序が毎回変わると履歴の再現性・デバッグ性が損なわれる。
        for r in results.sorted(by: { $0.toolCallId < $1.toolCallId }) {
            wireMessages.append(ChatMessage(
                role: .tool,
                content: r.content,
                toolCallId: r.toolCallId,
                name: r.toolName
            ))
        }
    }

    /// カードの resourceUri を解決する: **tools/call 結果 JSONValue の `_meta.ui.resourceUri`
    /// (後方互換キー `_meta["ui/resourceUri"]` も見る)を優先し、無ければ事前計算マップ
    /// (`uiResourceURIs`・接続時の tools/list 由来)へフォールバック**する。
    ///
    /// 【一次資料の確認結果(2026-07-18・タスク指示の前提を検証)】ext-apps 仕様
    /// (`~/ghq/github.com/modelcontextprotocol/ext-apps/specification/2026-01-26/apps.mdx`
    /// "Resource Discovery" 節・行 321-388)と caldav の実装(`registerAppTool` = ext-apps
    /// `src/server/index.js` の `K3`)を確認したところ、**`_meta.ui.resourceUri` は
    /// `tools/list` が返す `Tool` 定義に載る値であって、個々の `tools/call` の `CallToolResult`
    /// には載らない**(caldav の `toTodosToolResponse` 等・server.ts 1758 行は
    /// `{content, structuredContent}` のみを返し `_meta` を付けない)。つまり
    /// 「ツール結果の _meta から優先解決する」という当初の前提は caldav 実装上は成立しない
    /// ——**実際の staleness 原因は「マップの再解決タイミング」**(ChatHomeViewModel が
    /// 接続時に一度だけ resolve し、以降アプリ再起動まで使い回していたこと)だった。これは
    /// `ChatHomeViewModel.newChat()` が `AppsServerProxy.refreshToolsAndInvalidateHTMLCache()` で
    /// tools/list を取り直すよう修正済み(そちらが本丸の修正)。
    ///
    /// このメソッドはそれでも**仕様の拡張余地に対して前方互換**にしておく: apps.mdx は
    /// `CallToolResult` の `_meta` フィールド自体は "Additional metadata... not intended for
    /// model context"(apps.mdx 1475 行)とだけ定義しており、将来 or 他サーバーが
    /// `_meta.ui.resourceUri` を結果側にも載せてくる可能性を否定していない。載っていれば
    /// それを信頼する(サーバーが「この呼び出し結果は別のカードで描画してほしい」と明示的に
    /// 上書きしてきた、と解釈できる)方が自然なので、優先順位はそちらを先にする。
    /// caldav 実運用では常にフォールバック(事前計算マップ)側が使われる——今はこの経路が
    /// 実質 no-op であることを承知の上での前方互換コードである。
    static func resourceURI(forResult result: JSONValue?, toolName: String, fallback: [String: String]) -> String? {
        if let meta = result?["_meta"] {
            // 新形式: _meta.ui.resourceUri(AppsServerProxy.resolveUIResourceURI と同じ優先順位)。
            if let uri = meta["ui"]?["resourceUri"]?.stringValue {
                return uri
            }
            // 後方互換: フラットキー _meta["ui/resourceUri"](apps.mdx 342 行「deprecated」表記)。
            if let uri = meta["ui/resourceUri"]?.stringValue {
                return uri
            }
        }
        return fallback[toolName]
    }

    /// 1本の tool_call を実行して結果文字列に落とす(TaskGroup の子タスク本体)。
    ///
    /// **ツール実行が throw してもループは止めない**(設計に明記が無いのでこう解釈):
    /// エラーを role:"tool" の content に文言として載せ、モデルに「そのツールは失敗した」ことを
    /// 見せて回復(別ツール・別引数・ユーザーへの謝罪)を委ねる。ここで throw を上に伝播させると
    /// 1本のツール失敗でチャット全体が死ぬ — LLM エージェントの通常運用ではエラーもモデルへの
    /// 入力として扱うのが定石。該当ステップは failed 表示にする。
    private static func execute(
        call: ToolCall,
        index: Int,
        executor: any MCPToolExecuting,
        traceSink: (any TraceSink)?,
        turnId: String
    ) async -> ToolExecResult {
        // 【設計 03 §1 決定(c)】壊れた JSON はツールを呼ばずに失敗として返す。
        // 「パース不能→nil→引数なしで実行」は、モデルが意図した引数(例: 文字列が途中で
        // 切れた `{"calendarId": ...`)と**別の呼び出し**を誤って成功させてしまう
        // (誤データで会話が進む)。ここで止めて role:"tool" にエラー文言を返し、モデル自身に
        // リトライを委ねる(execute の throw 経路と同じく、ここでも上位ループは止めない)。
        switch decodeArguments(call.function.arguments) {
        case .invalid(let message):
            // 【観測の判断(設計に明記なし・こう解釈)】ツールは実際には呼ばれていないので
            // toolCallStarted/Finished は emit しない — 「ツール呼び出しの観測」であって
            // 「tool_call という LLM 出力自体の観測」ではないため(実行しなかったものを
            // 実行1回として数えると resultBytes/durationMs が意味を持たない)。
            return ToolExecResult(
                index: index,
                toolCallId: call.id,
                toolName: call.function.name,
                content: message,
                failed: true,
                // ツール未実行なのでカード用の結果も無い。
                result: nil,
                arguments: nil
            )
        case .value(let arguments):
            // 観測(設計 03 §3 注入点3: execute の callTool 前)。
            traceSink?.emit(.toolCallStarted(turnId: turnId, callId: call.id, name: call.function.name, arguments: arguments))
            let startedAt = Date()
            do {
                let result = try await executor.callTool(name: call.function.name, arguments: arguments)
                // 結果 JSONValue を JSON 文字列に落として role:"tool" content にする(設計 §3-4a
                //「structuredContent を要約 or JSON 文字列」の JSON 文字列側)。要約は T5 以降の課題。
                let data = (try? JSONEncoder().encode(result)) ?? Data("null".utf8)
                let isError = result["isError"]?.boolValue == true
                // 観測(設計 03 §3 注入点4: callTool 後)。durationMs は実測(Date().timeIntervalSince)。
                // resultBytes は role:"tool" に積む JSON 文字列そのものの UTF-8 バイト数
                // (「結果 JSON の utf8 バイト数」の指示どおり)。
                traceSink?.emit(.toolCallFinished(
                    turnId: turnId,
                    callId: call.id,
                    isError: isError,
                    resultBytes: data.count,
                    durationMs: Int(Date().timeIntervalSince(startedAt) * 1000)
                ))
                return ToolExecResult(
                    index: index,
                    toolCallId: call.id,
                    toolName: call.function.name,
                    content: String(decoding: data, as: UTF8.self),
                    failed: false,
                    // カード配送用に生の結果と引数を持ち帰る(runToolCalls が CardEmbed に載せる)。
                    result: result,
                    arguments: arguments
                )
            } catch {
                traceSink?.emit(.toolCallFinished(
                    turnId: turnId,
                    callId: call.id,
                    isError: true,
                    resultBytes: 0,
                    durationMs: Int(Date().timeIntervalSince(startedAt) * 1000)
                ))
                return ToolExecResult(
                    index: index,
                    toolCallId: call.id,
                    toolName: call.function.name,
                    // モデルが読める形でエラーを渡す。JSON にせず素の文言でよい(role:"tool" の
                    // content は任意文字列)。
                    content: "ツール実行エラー: \(error)",
                    failed: true,
                    // 失敗ツールはカードを作らない(runToolCalls が failed を弾く)ので nil でよい。
                    result: nil,
                    arguments: arguments
                )
            }
        }
    }

    /// `decodeArguments` の結果。パース不能を「無」に握りつぶさず区別する(設計 03 §1 決定(c))。
    /// internal(private でなく)にしているのは AppsServerProxy.mcpArguments と同じ理由 ——
    /// 「nil の畳み込みを止めた」こと自体が今回のバグ修正の要なので、単体テストで直接固定したい
    /// (Tests/ServicesTests/ChatViewModelTests.swift)。
    enum ArgumentsDecodeResult: Equatable {
        case value(JSONValue)
        case invalid(String)
    }

    /// OpenAI の tool_call.arguments(JSON 文字列)を JSONValue へ復元する(設計 03 §1 決定(b)(c))。
    ///
    /// - 空文字/空白のみ(引数なしのツールで "" や " " が来る)は `.object([:])` を返す
    ///   (「モデルが引数なしを表明した」の正規形。nil ではなく空 object にすることで
    ///   「値が無い」と「空だと確認した」を区別する — JSONValue 素通し方針(02)との整合)。
    /// - `"{}"` などの空オブジェクトは**畳み込まずそのまま** `.object([:])` として素通しする
    ///   (以前は「引数なしと等価」として nil に潰していたが、モデル出力を情報落ちなく下流へ
    ///   渡す層責務としてこれをやめた — 空文字と空オブジェクトはどちらも `.object([:])` に
    ///   収束するので、AppsServerProxy.mcpArguments 側の nil→`[:]` 正規化と結果的に一致する)。
    /// - パース不能な文字列は `.invalid` にして「引数なしで実行」に化けさせない
    ///   (execute がツールを呼ばず role:"tool" エラーを返す)。
    static func decodeArguments(_ raw: String) -> ArgumentsDecodeResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .value(.object([:])) }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else {
            // モデルへ返すエラー文言に raw の先頭だけを載せる(長大な壊れ JSON をそのまま
            // 積むと role:"tool" が肥大化するため・N=200 は他ログの先頭切り詰めと揃えた値)。
            let prefix = String(trimmed.prefix(200))
            return .invalid("tool call arguments が JSON として不正: \(prefix)")
        }
        return .value(value)
    }

    /// usage の加算(cumulative 用)。片方 nil を吸収する。totalTokens は両方あれば足す。
    private static func add(_ lhs: Usage?, _ rhs: Usage) -> Usage {
        guard let lhs else { return rhs }
        let total: Int?
        switch (lhs.totalTokens, rhs.totalTokens) {
        case let (l?, r?): total = l + r
        case let (l?, nil): total = l
        case let (nil, r?): total = r
        default: total = nil
        }
        return Usage(
            promptTokens: lhs.promptTokens + rhs.promptTokens,
            completionTokens: lhs.completionTokens + rhs.completionTokens,
            totalTokens: total
        )
    }
}

/// TaskGroup の子タスクから戻す1ツール実行結果(内部専用)。
/// index = 表示ステップ(call 順)との対応キー、toolCallId = wire 積み戻しの安定ソートキー。
private struct ToolExecResult: Sendable {
    let index: Int
    let toolCallId: String
    let toolName: String
    let content: String
    let failed: Bool
    /// callTool が返した生 JSONValue(成功時のみ)。カード配送(sendToolResult)の元データ。
    let result: JSONValue?
    /// この tool_call の引数(decodeArguments 済み)。カード配送(sendToolInput)の元データ。
    let arguments: JSONValue?
}

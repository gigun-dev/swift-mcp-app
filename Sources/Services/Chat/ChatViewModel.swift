// LLM補完とMCP tool callを.stopまたは最大反復まで仲介する、接続先に中立な会話状態機械。
// MCP実行とカード組立はToolCallRunnerへ分離し、ここは表示/wire履歴の整合を担う。
import Foundation
import Observation
import Kernel
import os // tools/call診断ログ(chat-diag)。原因確定後は撤去可能。

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

    /// userと空assistantが同一トランザクションで追加されても失われない、明示的な送信イベント。
    /// retryで同じindexを再利用してもseqを増やすため、Viewは配列形状を推測せず変化を観測できる。
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
    private let toolCallRunner: ToolCallRunner

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
    /// currentSession.serverURLs に積む全接続先(M2・複数サーバー同時接続)。nil = 単一/未設定
    /// (ChatSession.serverURLs の後方互換 nil と同義)。ChatHomeViewModel が ready 全サーバーの URL を渡す。
    private let sessionServerURLs: [URL]?
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

    /// send/retryを1本に制限し、画面破棄後のLLM・MCP処理継続を防ぐ。
    private let sendTaskController = ChatSendTaskController()

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
        serverURLs: [URL]? = nil,
        onTurnSettled: (() -> Void)? = nil
    ) {
        self.llm = llm
        self.toolCallRunner = ToolCallRunner(
            executor: toolExecutor,
            resourceURIs: uiResourceURIs,
            traceSink: traceSink
        )
        self.tools = tools
        self.model = model
        self.maxIterations = maxIterations
        self.traceSink = traceSink
        self.sessionId = sessionId
        self.sessionUUID = UUID(uuidString: sessionId) ?? UUID()
        self.sessionServerURL = serverURL
        self.sessionServerURLs = serverURLs
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

    public var currentSession: ChatSession {
        ChatPersistenceAssembler.makeSession(.init(
            id: sessionUUID,
            serverURL: sessionServerURL,
            serverURLs: sessionServerURLs,
            createdAt: sessionCreatedAt,
            turns: turns,
            model: model
        ))
    }

    public func setCardSnapshot(
        turnIndex: Int,
        cardIndex: Int,
        expectedResourceUri: String,
        html: String
    ) {
        let changed = ChatPersistenceAssembler.updateSnapshot(
            in: &turns,
            turnIndex: turnIndex,
            cardIndex: cardIndex,
            expectedResourceURI: expectedResourceUri,
            html: html
        )
        if changed { onTurnSettled?() }
    }

    // MARK: - ループのエントリ

    /// View用の送信入口。同期的に完了を待つテスト向けにsend自体もpublicのまま保つ。
    public func submit(_ text: String) {
        sendTaskController.submit { [weak self] in
            await self?.send(text)
        }
    }

    /// Viewの再生成ボタンから呼ぶ入口。
    public func submitRetry() {
        sendTaskController.submit { [weak self] in
            await self?.retryLastTurn()
        }
    }

    /// 進行中のsend/retryを打ち切る。構造化並行のtool callにもキャンセルが伝播する。
    public func cancelActiveSend() {
        sendTaskController.cancel()
    }

    /// ユーザー発話を1つ受けて、tool-use ループを .stop / 最大反復まで回す。
    ///
    /// 失敗はerrorMessageへ載せるが、ユーザー操作によるキャンセルは失敗として表示しない。
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
            seq: (lastSubmission?.seq ?? 0) + 1
        )

        // 2) 反復。各周で assistant ターンを1つ起こし、そこへ text/toolSteps を書き込む。
        var settled = false
        var iterations = 0
        for _ in 0 ..< maxIterations {
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

            guard let completion = await receiveCompletion(request, assistantIndex: assistantIndex) else { return }

            let finishReason = completion.finishReason
            let calls = completion.toolCalls
            recordCompletion(completion, assistantIndex: assistantIndex, turnId: turnId)

            // ストリームは正常完了したが、その直後にキャンセルされていた場合(監査 2026-07-18 MEDIUM)。
            // tool_calls を実行してしまうと副作用のある MCP 呼び出しが「捨てられたはずのチャット」で
            // 走ってしまうため、次のツール実行に入る前にもう一度確認する。
            if Task.isCancelled { return }

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
            turns[assistantIndex].toolSteps = ToolCallRunner.runningSteps(for: calls)
            let toolBatch = await toolCallRunner.run(calls, turnId: turnId)
            recordToolBatch(toolBatch, assistantIndex: assistantIndex)
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

    public func retryLastTurn() async {
        guard !isRunning,
              let retryText = ChatRetryPlanner.rewind(turns: &turns, wireMessages: &wireMessages)
        else { return }

        errorMessage = nil
        await send(retryText)
    }

    private func receiveCompletion(
        _ request: ChatCompletionRequest,
        assistantIndex: Int
    ) async -> ChatCompletionStreamConsumer.Completion? {
        do {
            return try await ChatCompletionStreamConsumer.consume(llm.stream(request)) { text in
                turns[assistantIndex].text = text
            }
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = "LLM ストリームに失敗しました: \(error)"
            return nil
        }
    }

    private func recordCompletion(
        _ completion: ChatCompletionStreamConsumer.Completion,
        assistantIndex: Int,
        turnId: String
    ) {
        traceSink?.emit(.llmCompleted(
            turnId: turnId,
            finishReason: completion.finishReason.wireValue,
            usage: completion.usage
        ))
        if let usage = completion.usage {
            lastUsage = usage
            cumulativeUsage = UsageAccumulator.add(cumulativeUsage, usage)
            turns[assistantIndex].usage = usage
        }
        wireMessages.append(ChatMessage(
            role: .assistant,
            content: completion.text.isEmpty ? nil : completion.text,
            toolCalls: completion.toolCalls.isEmpty ? nil : completion.toolCalls
        ))
    }

    private func recordToolBatch(_ batch: ToolCallRunner.Batch, assistantIndex: Int) {
        turns[assistantIndex].toolSteps = batch.steps
        turns[assistantIndex].cards.append(contentsOf: batch.cards)
        wireMessages.append(contentsOf: batch.wireMessages)
    }

    typealias ArgumentsDecodeResult = ToolCallRunner.ArgumentsDecodeResult

    static func decodeArguments(_ raw: String) -> ArgumentsDecodeResult {
        ToolCallRunner.decodeArguments(raw)
    }
}

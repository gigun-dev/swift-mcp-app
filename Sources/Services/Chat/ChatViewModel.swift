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

    /// ループ実行中フラグ(送信ボタンの無効化・スピナー表示に使う)。
    public private(set) var isRunning: Bool = false

    /// 直近ターンの usage(入力欄上の「このターン ≈ N tok」表示・設計 §6)。
    public private(set) var lastUsage: Usage?

    /// セッション累計 usage(将来の累計コスト表示・設計 §6)。プロバイダが usage を
    /// 返さないターンがあっても壊れないよう、届いたぶんだけ足す。
    public private(set) var cumulativeUsage: Usage?

    /// ユーザーに見せるエラー(最大反復超過・ストリーム失敗など)。次の send で消える。
    public private(set) var errorMessage: String?

    // MARK: - 依存(注入)

    private let llm: any LLMClient
    private let toolExecutor: any MCPToolExecuting
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

    // MARK: - 内部状態

    /// LLM へ送る厳密な履歴(上のクラスコメント参照)。system をあれば先頭に据える。
    private var wireMessages: [ChatMessage] = []

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
    public init(
        llm: any LLMClient,
        toolExecutor: any MCPToolExecuting,
        tools: [ToolDefinition],
        model: String,
        systemPrompt: String?,
        maxIterations: Int = 8,
        uiResourceURIs: [String: String] = [:]
    ) {
        self.llm = llm
        self.toolExecutor = toolExecutor
        self.tools = tools
        self.model = model
        self.maxIterations = maxIterations
        self.uiResourceURIs = uiResourceURIs

        if let systemPrompt {
            // system は履歴の不変の先頭。毎リクエストで送られる(設計に system の扱いの
            // 明示は無いが、OpenAI 標準どおり履歴先頭に固定するのが自然 — こう解釈)。
            wireMessages.append(ChatMessage(role: .system, content: systemPrompt))
        }
    }

    // MARK: - ループのエントリ

    /// ユーザー発話を1つ受けて、tool-use ループを .stop / 最大反復まで回す。
    ///
    /// 例外を throw しない(UI から `Task { await vm.send(text) }` で気軽に叩ける)。
    /// 失敗は errorMessage に載せる。
    public func send(_ userText: String) async {
        errorMessage = nil
        isRunning = true
        defer { isRunning = false }

        // 1) user を wire と表示の両方へ積む。
        wireMessages.append(ChatMessage(role: .user, content: userText))
        turns.append(ChatTurn(role: .user, text: userText))

        // 2) 反復。各周で assistant ターンを1つ起こし、そこへ text/toolSteps を書き込む。
        var settled = false
        for _ in 0..<maxIterations {
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
                    }
                }
            } catch {
                // ストリーム自体の失敗(ネットワーク・HTTP・デコード)。この周の assistant ターンに
                // エラーを載せてループを止める(モデルに投げ返せる相手がいない = 継続不能)。
                turns[assistantIndex].text = accumulatedText
                errorMessage = "LLM ストリームに失敗しました: \(error)"
                return
            }

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
            await runToolCalls(calls, assistantIndex: assistantIndex)
            // continue(次の反復へ) — モデルがツール結果を見て次を判断する(設計 §3-5)。
        }

        // 6) 最大反復を使い切ってもまだ .toolCalls で回り続けた = 打ち切り(設計 §3-6)。
        //    暴走・コスト暴発の防止。ユーザーにエラーを見せる(嘘の「完了」を見せない)。
        if !settled {
            errorMessage = "ツール呼び出しが最大反復(\(maxIterations)回)を超えたため打ち切りました。"
        }
    }

    // MARK: - ツール実行(1ターンぶんの tool_calls をまとめて)

    /// 1ターンで返ってきた tool_calls をすべて実行し、結果を wire に積む。
    /// - 表示: 各 tool_call を assistant ターンの toolSteps に pending→running→done/failed で反映。
    /// - wire: 結果を role:"tool"(tool_call_id 付き)として積む。**tool_call_id 順で安定化**
    ///   (設計 §3「messages には tool_call_id 順で積む」)。
    private func runToolCalls(_ calls: [ToolCall], assistantIndex: Int) async {
        // 表示ステップを call 順で先に起こす(running まで進める)。UI に「今このツール群を
        // 呼んでいる」を即見せる。argumentsJSON は可視化用にそのまま持つ(設計 §3 の可視化)。
        turns[assistantIndex].toolSteps = calls.map {
            ToolCallStep(toolName: $0.function.name, state: .running, argumentsJSON: $0.function.arguments)
        }

        // 並行実行(TaskGroup)。self を group 内に持ち込まない(MainActor 再入を避ける)ため、
        // 実行に要る値(executor・id・name・arguments)だけを渡す。結果は元の index を添えて返し、
        // 表示ステップとの対応を保つ。
        let executor = self.toolExecutor
        let results: [ToolExecResult] = await withTaskGroup(of: ToolExecResult.self) { group in
            for (index, call) in calls.enumerated() {
                group.addTask {
                    await Self.execute(call: call, index: index, executor: executor)
                }
            }
            var collected: [ToolExecResult] = []
            for await r in group { collected.append(r) }
            return collected
        }

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
            guard !r.failed, let uri = uiResourceURIs[r.toolName] else { continue }
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

    /// 1本の tool_call を実行して結果文字列に落とす(TaskGroup の子タスク本体)。
    ///
    /// **ツール実行が throw してもループは止めない**(設計に明記が無いのでこう解釈):
    /// エラーを role:"tool" の content に文言として載せ、モデルに「そのツールは失敗した」ことを
    /// 見せて回復(別ツール・別引数・ユーザーへの謝罪)を委ねる。ここで throw を上に伝播させると
    /// 1本のツール失敗でチャット全体が死ぬ — LLM エージェントの通常運用ではエラーもモデルへの
    /// 入力として扱うのが定石。該当ステップは failed 表示にする。
    private static func execute(call: ToolCall, index: Int, executor: any MCPToolExecuting) async -> ToolExecResult {
        // 【設計 03 §1 決定(c)】壊れた JSON はツールを呼ばずに失敗として返す。
        // 「パース不能→nil→引数なしで実行」は、モデルが意図した引数(例: 文字列が途中で
        // 切れた `{"calendarId": ...`)と**別の呼び出し**を誤って成功させてしまう
        // (誤データで会話が進む)。ここで止めて role:"tool" にエラー文言を返し、モデル自身に
        // リトライを委ねる(execute の throw 経路と同じく、ここでも上位ループは止めない)。
        switch decodeArguments(call.function.arguments) {
        case .invalid(let message):
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
            do {
                let result = try await executor.callTool(name: call.function.name, arguments: arguments)
                // 結果 JSONValue を JSON 文字列に落として role:"tool" content にする(設計 §3-4a
                //「structuredContent を要約 or JSON 文字列」の JSON 文字列側)。要約は T5 以降の課題。
                let data = (try? JSONEncoder().encode(result)) ?? Data("null".utf8)
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

// チャットのドメイン型(純 Codable)。docs/design/02-chat-llm.md §5。
//
// これらは画面表示のモデルであると同時に**永続化 DTO も兼ねる**(§5 決定:
// SQLite でなく JSON ファイル・1 ChatSession = 1 ファイル)。そのため Codable が
// 素直に効くよう enum は rawValue String で持ち、配列はデフォルト空配列にして
// 「保存後に読み直しても同じ形」であることをテストで担保する(Tests/ChatModelTests.swift)。
//
// Kernel はここでも swift-sdk / UIKit 等に触れない。structuredContent の値は
// Kernel/AppsProtocol/JSONValue を再利用する(新しい JSON 表現を作らない方針・冒頭参照)。
import Foundation

/// 1チャットセッション(サイドバーの1項目・JSON ファイル1個に対応)。
public struct ChatSession: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var serverURL: URL
    public var createdAt: Date
    public var updatedAt: Date
    public var turns: [ChatTurn]
    /// 使用した LLM モデル ID。
    ///
    /// 【設計 §5 の ChatSession フィールド列挙には無いが T6 実装時にこう解釈して追加】
    /// index.json のレコードが「id・title・プレビュー・updatedAt・serverURL・model」を持つ
    /// (設計 03 §3 の隣接記述・02 §5 のサイドバー要件)以上、model はどこかから供給が要る。
    /// ChatTurn.usage には prompt/completion トークン数はあっても model 文字列は無いため、
    /// セッション単位で1個持つのが自然(1チャット中でモデルを切り替える機能は無い前提・
    /// 将来切替に対応するなら ChatTurn 側に移す判断もありうるが今回はスコープ外)。
    /// デフォルト値を与えず必須にしたのは「保存時に model を忘れる」事故を型で防ぐため
    /// (既存の round-trip テストは呼び出し側で明示的に埋める)。
    public var model: String

    public init(
        id: UUID = UUID(),
        title: String,
        serverURL: URL,
        createdAt: Date,
        updatedAt: Date,
        turns: [ChatTurn] = [],
        model: String
    ) {
        self.id = id
        self.title = title
        self.serverURL = serverURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.turns = turns
        self.model = model
    }
}

/// チャット内の1ターン(ユーザー発話 or assistant の応答1回ぶん)。
/// tool-use ループで assistant が複数回ツールを呼んでも、UI 上は「1ターン」として
/// ツールステップ列・カード列をまとめて持つ(§3 のモック仕様に合わせた粒度)。
public struct ChatTurn: Codable, Equatable, Sendable {
    public var role: ChatMessage.Role
    public var text: String
    public var toolSteps: [ToolCallStep]
    public var cards: [CardEmbed]
    public var usage: Usage?

    public init(
        role: ChatMessage.Role,
        text: String,
        toolSteps: [ToolCallStep] = [],
        cards: [CardEmbed] = [],
        usage: Usage? = nil
    ) {
        self.role = role
        self.text = text
        self.toolSteps = toolSteps
        self.cards = cards
        self.usage = usage
    }
}

/// ツール呼び出し1回ぶんの進捗表示用ステップ。
/// 「何のツールを呼んでいるか隠さない」(§3)ため、pending→running→done/failed の
/// 状態遷移をそのまま UI に出す想定。
public struct ToolCallStep: Codable, Equatable, Sendable {
    public var toolName: String
    public var state: State
    /// tool_call の引数(JSON 文字列。ToolCall.function.arguments と同じ形)。
    /// 表示用途(デバッグ・「こういう引数で呼んだ」の可視化)なので optional。
    public var argumentsJSON: String?
    /// tool_call の結果(role:"tool" に積み戻す文字列と同じもの。成功時は結果 JSON 文字列、
    /// 失敗時はエラー文言)。argumentsJSON と対で「リクエスト/レスポンス」を成す表示用途フィールド。
    /// pending/running 中はまだ確定していないので nil のまま(ChatViewModel.runToolCalls が
    /// 状態確定と同時に埋める)。永続化 DTO 兼用(T6 履歴・観測)なので、ここに残せば履歴再訪でも
    /// 「何を渡して何が返ったか」が追える。デフォルト nil で既存の round-trip テスト・
    /// argumentsJSON のみの既存データとの後方互換を保つ。
    public var resultJSON: String?

    public init(toolName: String, state: State, argumentsJSON: String? = nil, resultJSON: String? = nil) {
        self.toolName = toolName
        self.state = state
        self.argumentsJSON = argumentsJSON
        self.resultJSON = resultJSON
    }

    public enum State: String, Codable, Equatable, Sendable {
        case pending
        case running
        case done
        case failed
    }
}

/// チャットにインライン埋め込まれる MCP App カード1枚ぶんの記録。
/// ライブ表示中は AppsBridgeSession が別途状態を持つが、ここは**履歴永続化用**の
/// スナップショット(§5「カードの履歴再訪問題」)。snapshotHTML は tool-result 配送後に
/// `document.documentElement.outerHTML` を取得したもの(取得タイミングは Services 側の責務)。
public struct CardEmbed: Codable, Equatable, Sendable {
    public var toolName: String
    public var resourceUri: String
    /// 履歴再訪時に静的表示するための HTML スナップショット。
    /// ライブ表示中(まだ一度も size-changed に到達していない等)は nil を許容する。
    public var snapshotHTML: String?
    /// ツール結果の structuredContent(LLM への配送・カードへの配送の双方の元データ)。
    public var structuredContent: JSONValue?
    /// カードへ配送する tool-input(その tool_call の引数)。
    ///
    /// 【設計 §5 の CardEmbed には無いフィールドを足した理由(T5)】
    /// P2 のカード起動フローは tool-result の前に `sendToolInput(arguments:)` で「どんな引数で
    /// 呼んだか」をカードへ渡す(caldav の todos カードは tool-input を状態初期化に使う・
    /// TodosCardSpikeView の run() 参照)。ChatViewModel はツール実行時にこの引数を持っている
    /// ので、カード構築時(Features 側)に再現できるようここへ保存する。永続化 DTO 兼用だが、
    /// 履歴再訪はスナップショット静的表示(§5・ブリッジ無し)なので arguments は再訪では未使用。
    /// あくまでライブ構築(T5)のための持ち回りデータ。デフォルト nil で後方互換(既存の
    /// round-trip テスト・スナップショットのみのカードを壊さない)。
    public var arguments: JSONValue?

    public init(
        toolName: String,
        resourceUri: String,
        snapshotHTML: String? = nil,
        structuredContent: JSONValue? = nil,
        arguments: JSONValue? = nil
    ) {
        self.toolName = toolName
        self.resourceUri = resourceUri
        self.snapshotHTML = snapshotHTML
        self.structuredContent = structuredContent
        self.arguments = arguments
    }
}

/// サイドバー一覧(T6 後半で作る ChatHistorySidebar)の1項目。ChatStore.loadIndex() が返す
/// 軽量ビュー(index.json の1レコード相当・設計 §5「軽量な一覧インデックス」)。
///
/// 【置き場の判断(T6 前半・設計に明記なし・こう解釈)】Kernel/ChatModel に置く。
/// サイドバーが読む一覧項目は ChatSession と同じ「純データの永続化 DTO」であり、
/// ChatStore(Services)はこれを組み立てて JSON へ書くだけ・UI(Features)はこれを読むだけ。
/// ChatSession・ChatTurn 等の他のドメイン型と同じ Kernel に置くのが素直(swift-sdk 等の
/// 外部依存を一切持ち込まない Kernel の制約にも抵触しない)。
public struct ChatSessionSummary: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    /// 一覧のプレビュー文言(最後のターンの text 先頭 N 文字。空なら "")。
    public var preview: String
    public var updatedAt: Date
    public var serverURL: URL
    public var model: String

    public init(id: UUID, title: String, preview: String, updatedAt: Date, serverURL: URL, model: String) {
        self.id = id
        self.title = title
        self.preview = preview
        self.updatedAt = updatedAt
        self.serverURL = serverURL
        self.model = model
    }
}

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

    public init(
        id: UUID = UUID(),
        title: String,
        serverURL: URL,
        createdAt: Date,
        updatedAt: Date,
        turns: [ChatTurn] = []
    ) {
        self.id = id
        self.title = title
        self.serverURL = serverURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.turns = turns
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

    public init(toolName: String, state: State, argumentsJSON: String? = nil) {
        self.toolName = toolName
        self.state = state
        self.argumentsJSON = argumentsJSON
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

    public init(
        toolName: String,
        resourceUri: String,
        snapshotHTML: String? = nil,
        structuredContent: JSONValue? = nil
    ) {
        self.toolName = toolName
        self.resourceUri = resourceUri
        self.snapshotHTML = snapshotHTML
        self.structuredContent = structuredContent
    }
}

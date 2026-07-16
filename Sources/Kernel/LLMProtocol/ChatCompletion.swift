// OpenAI 互換 chat/completions の非ストリーミング部分のワイヤ型(純 Codable)。
//
// 出典・設計: docs/design/02-chat-llm.md §1/§6。JSON Schema の値は
// Kernel/AppsProtocol/JSONValue(P2 で作った素通し JSON 型)をそのまま再利用する
// (新しい JSON 表現を作らない・冒頭 JSONValue.swift のコメント参照)。
//
// snake_case の JSON キー(model・tool_calls・tool_call_id 等)はすべて OpenAI API の
// リファレンス(https://developers.openai.com/api/reference/resources/chat)通り。
// CodingKeys で Swift 側は camelCase に寄せる。
import Foundation

/// chat/completions へのリクエスト本体。
///
/// - `tools`: MCP tools/list を visibility フィルタ(§7)してから変換したもの。
///   Kernel はこの変換ロジック(MCP.Value→JSONValue)には触れない(Services/LLM の役目)。
/// - `stream`: 設計 §2 の決定でホストは常に true を使う想定だが、型としては
///   任意値(将来 false の単発補完を足しても壊れないように optional にはしない — OpenAI 側の
///   既定は false なので明示指定を必須にしておくほうが事故が少ない)。
/// - `streamOptions.includeUsage`: SSE で usage チャンクを受け取るために必須(§6)。
public struct ChatCompletionRequest: Codable, Equatable, Sendable {
    public var model: String
    public var messages: [ChatMessage]
    public var tools: [ToolDefinition]?
    public var stream: Bool
    public var temperature: Double?
    public var streamOptions: StreamOptions?

    public init(
        model: String,
        messages: [ChatMessage],
        tools: [ToolDefinition]? = nil,
        stream: Bool,
        temperature: Double? = nil,
        streamOptions: StreamOptions? = nil
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.stream = stream
        self.temperature = temperature
        self.streamOptions = streamOptions
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, stream, temperature
        case streamOptions = "stream_options"
    }

    public struct StreamOptions: Codable, Equatable, Sendable {
        public var includeUsage: Bool

        public init(includeUsage: Bool) {
            self.includeUsage = includeUsage
        }

        enum CodingKeys: String, CodingKey {
            case includeUsage = "include_usage"
        }
    }
}

/// chat/completions の1メッセージ(リクエストの messages 配列要素・レスポンスの
/// choices[].message にも共用できる形)。
///
/// `content` が `String?` なのは、assistant が tool_calls のみを返すターンでは
/// OpenAI は `content: null` を返す(本文が空文字ではなく本当に無い)ため。
/// `toolCallId`/`name` は role が `.tool` のとき(ツール実行結果を積み戻すメッセージ)に使う
/// OpenAI の仕様(tool メッセージは対応する tool_call_id が必須)。
public struct ChatMessage: Codable, Equatable, Sendable {
    public var role: Role
    public var content: String?
    public var toolCalls: [ToolCall]?
    public var toolCallId: String?
    public var name: String?

    public init(
        role: Role,
        content: String? = nil,
        toolCalls: [ToolCall]? = nil,
        toolCallId: String? = nil,
        name: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }

    public enum Role: String, Codable, Equatable, Sendable {
        case system
        case user
        case assistant
        case tool
    }
}

/// LLM に渡すツール定義(OpenAI の function-calling 形式)。type は現状 "function" 固定
/// (OpenAI は将来 type を増やす余地を残しているが、今回作る経路はここだけなので
/// リテラルで持たず decode 時にそのまま受け取る素朴な String にしておく)。
public struct ToolDefinition: Codable, Equatable, Sendable {
    public var type: String
    public var function: Function

    public init(function: Function) {
        self.type = "function"
        self.function = function
    }

    public struct Function: Codable, Equatable, Sendable {
        public var name: String
        public var description: String?
        /// JSON Schema(MCP Tool.inputSchema 相当)。JSONValue で素通しする
        /// (§1 決定:JSON Schema の値は JSONValue 再利用)。
        public var parameters: JSONValue

        public init(name: String, description: String? = nil, parameters: JSONValue) {
            self.name = name
            self.description = description
            self.parameters = parameters
        }
    }
}

/// 完成した tool_call(非ストリーミング応答、またはストリーミングを ToolCallAccumulator で
/// 確定させた後の形)。ドメイン層(ChatModel/ToolCallStep)でも同じ形が要るので Kernel に置く
/// (§1「ToolCall はドメインでも使うので Kernel に」)。
/// `function.arguments` は JSON オブジェクトではなく JSON 文字列である点に注意
/// (OpenAI は引数を常に文字列でシリアライズして返す。呼び出し側で JSONDecoder に通す)。
public struct ToolCall: Codable, Equatable, Sendable {
    public var id: String
    public var type: String
    public var function: FunctionCall

    public init(id: String, function: FunctionCall) {
        self.id = id
        self.type = "function"
        self.function = function
    }

    public struct FunctionCall: Codable, Equatable, Sendable {
        public var name: String
        public var arguments: String

        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }
}

/// トークン使用量。`totalTokens` は OpenAI 互換プロバイダによっては省略されることがある
/// ため optional にしておく(未知プロバイダの互換性を過信しない・§6 の「不明なら非表示」方針と
/// 同じ姿勢)。prompt/completion は仕様上ほぼ必ず載るので non-optional。
public struct Usage: Codable, Equatable, Sendable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int?

    public init(promptTokens: Int, completionTokens: Int, totalTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

/// ストリーム終端の理由。OpenAI の JSON 値は snake_case ("tool_calls" など)なので
/// rawValue の自動マッピングでは合わず、カスタム init で読み替える。
/// `.other` は将来プロバイダが独自の finish_reason を返しても落ちないための保険
/// (未知トークンを吸収して呼び出し側で分岐させる・過剰なエラー化をしない)。
public enum FinishReason: Equatable, Sendable {
    case stop
    case toolCalls
    case length
    case contentFilter
    case other(String)

    public init(wireValue: String) {
        switch wireValue {
        case "stop": self = .stop
        case "tool_calls": self = .toolCalls
        case "length": self = .length
        case "content_filter": self = .contentFilter
        default: self = .other(wireValue)
        }
    }

    public var wireValue: String {
        switch self {
        case .stop: return "stop"
        case .toolCalls: return "tool_calls"
        case .length: return "length"
        case .contentFilter: return "content_filter"
        case .other(let value): return value
        }
    }
}

extension FinishReason: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(wireValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

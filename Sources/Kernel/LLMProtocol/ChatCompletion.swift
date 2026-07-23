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

/// streaming時にusage専用チャンクを要求するOpenAI wire option。
///
/// 以前は `ChatCompletionRequest` 内に実体をネストしていたが、その中の `CodingKeys` が
/// さらに深い型階層を作っていた。実体をfile scopeへ出し、下のtypealiasで従来APIを保つ。
public struct ChatCompletionStreamOptions: Codable, Equatable, Sendable {
    public var includeUsage: Bool

    public init(includeUsage: Bool) {
        self.includeUsage = includeUsage
    }

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

/// chat/completions へのリクエスト本体。
///
/// - `tools`: MCP tools/list を visibility フィルタ(§7)してから変換したもの。
///   Kernel はこの変換ロジック(MCP.Value→JSONValue)には触れない(Services/LLM の役目)。
/// - `stream`: 設計 §2 の決定でホストは常に true を使う想定だが、型としては
///   任意値(将来 false の単発補完を足しても壊れないように optional にはしない — OpenAI 側の
///   既定は false なので明示指定を必須にしておくほうが事故が少ない)。
/// - `streamOptions.includeUsage`: SSE で usage チャンクを受け取るために必須(§6)。
public struct ChatCompletionRequest: Codable, Equatable, Sendable {
    /// `ChatCompletionRequest.StreamOptions` という既存の公開APIを維持する互換alias。
    public typealias StreamOptions = ChatCompletionStreamOptions

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

        /// MCP `tool.annotations`(readOnlyHint 等)を R4 の許可ゲート判定へ運ぶための additive フィールド。
        ///
        /// **wire へ出さない**: ToolDefinition は OpenAI chat/completions のリクエストへそのまま
        /// エンコードされる型なので、OpenAI が知らない annotations を載せると無用なフィールドが混じる
        /// (プロバイダによっては 400 になりうる)。annotations はホスト内部で HITL ゲート
        /// (ToolPermissionPolicy)にだけ使うので、下の手書き Codable で encode/decode 対象から外し、
        /// ToolConversion(MCP.Tool → ToolDefinition)でだけ埋める。decode 時は常に nil に戻す
        /// (wire から復元しない。ホスト内で改めて注入する運用)。
        public var annotations: ToolAnnotations?

        public init(
            name: String,
            description: String? = nil,
            parameters: JSONValue,
            annotations: ToolAnnotations? = nil
        ) {
            self.name = name
            self.description = description
            self.parameters = parameters
            self.annotations = annotations
        }

        // 手書き Codable(合成でなく)にした理由: annotations を wire から除外するには CodingKeys で
        // 列挙キーを絞る必要があるが、Function は既に ToolDefinition 内にネストしており、その中へ
        // さらに CodingKeys を入れると nesting 違反(2階層)になる。そこで keys を file scope の
        // ToolFunctionCodingKeys(下)に出し、init(from:)/encode(to:) だけをここに書く。
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: ToolFunctionCodingKeys.self)
            self.name = try container.decode(String.self, forKey: .name)
            self.description = try container.decodeIfPresent(String.self, forKey: .description)
            self.parameters = try container.decode(JSONValue.self, forKey: .parameters)
            self.annotations = nil  // wire には無い。ホスト内で ToolConversion が別途注入する。
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: ToolFunctionCodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encode(parameters, forKey: .parameters)
            // annotations は意図的にエンコードしない(上のプロパティコメント参照)。
        }
    }
}

/// `ToolDefinition.Function` の手書き Codable キー(annotations を wire から除外するため file scope に置く。
/// Function 内へネストすると nesting 違反になる・Function 側コメント参照)。
private enum ToolFunctionCodingKeys: String, CodingKey {
    case name, description, parameters
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

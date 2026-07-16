// OpenAI 互換 chat/completions のストリーミング(SSE)チャンクのワイヤ型。
//
// 出典・裏取り(docs/design/02-chat-llm.md §2):
// https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events
// 「`stream_options:{include_usage:true}` を付けると、通常の delta チャンク群の後に
//  **`choices: []`(空配列)の追加チャンクとして usage が1回だけ届く**」。
// つまりパーサは `choices[0]` の存在を無条件に仮定してはならない
// (usage チャンクでは choices が空・delta を読もうとすると添字アウトオブレンジになる)。
// このファイルの型はその事実を反映して `choices: [ChunkChoice]`(空配列を許す)にしてある。
import Foundation

/// SSE の1行(`data: {...}`)をデコードした形。
public struct ChatCompletionChunk: Codable, Equatable, Sendable {
    public var id: String
    public var choices: [ChunkChoice]
    public var usage: Usage?

    public init(id: String, choices: [ChunkChoice], usage: Usage? = nil) {
        self.id = id
        self.choices = choices
        self.usage = usage
    }
}

public struct ChunkChoice: Codable, Equatable, Sendable {
    public var index: Int
    public var delta: ChunkDelta
    public var finishReason: FinishReason?

    public init(index: Int, delta: ChunkDelta, finishReason: FinishReason? = nil) {
        self.index = index
        self.delta = delta
        self.finishReason = finishReason
    }

    enum CodingKeys: String, CodingKey {
        case index, delta
        case finishReason = "finish_reason"
    }
}

/// 1チャンクぶんの増分。content デルタ・tool_calls デルタのどちらも optional
/// (両方 nil のチャンク——role だけ載る最初のチャンク等——も仕様上ありうる)。
public struct ChunkDelta: Codable, Equatable, Sendable {
    public var role: ChatMessage.Role?
    public var content: String?
    public var toolCalls: [ToolCallDelta]?

    public init(role: ChatMessage.Role? = nil, content: String? = nil, toolCalls: [ToolCallDelta]? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
    }

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
    }
}

/// tool_calls デルタの1要素。§2 の蓄積規則の裏取り:
/// 「各要素は `index` を持ち、最初の delta に `id` と `function.name` が丸ごと載り、
///  以降の delta は `function.arguments` の断片だけが届く」
/// (OpenAI function-calling ガイド streaming セクションのリファレンス実装と同じ挙動)。
/// そのため id・function.name・function.arguments はすべて optional にしてある
/// (継続 delta では id/name が欠け、初回 delta でも arguments が空/欠けることがある)。
public struct ToolCallDelta: Codable, Equatable, Sendable {
    public var index: Int
    public var id: String?
    public var function: FunctionDelta?

    public init(index: Int, id: String? = nil, function: FunctionDelta? = nil) {
        self.index = index
        self.id = id
        self.function = function
    }

    public struct FunctionDelta: Codable, Equatable, Sendable {
        public var name: String?
        public var arguments: String?

        public init(name: String? = nil, arguments: String? = nil) {
            self.name = name
            self.arguments = arguments
        }
    }
}

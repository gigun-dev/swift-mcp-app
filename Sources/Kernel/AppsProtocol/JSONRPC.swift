// JSON-RPC 2.0 の封筒(envelope)。AppsBridge は postMessage 上を流れる JSON-RPC 2.0 の
// メッセージを仲介するので、request / response / notification の3種を Codable で表す。
//
// 設計 §3-1「JSON-RPC 封筒を Kernel に置く」。ペイロード(params/result)は原則
// JSONValue のまま持ち、ui/* の一部だけを上位(UIMessages.swift)で型付けする(§3-2/§3-3)。
import Foundation

// MARK: - RequestID

// JSON-RPC の id は「string | number(整数) | null」を取りうる(仕様 5.1)。
// null id は notification と紛らわしいので受けるが送らない運用にする。ここでは
// 実務で来る string と int の2ケースを表現する(number の非整数は MCP では使われない)。
public enum RequestID: Hashable, Sendable {
    case string(String)
    case int(Int)
}

extension RequestID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // int を先に試す。"1"(文字列)と 1(数値)は JSON で別物なので取り違えは起きない。
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "RequestID は string か int のみ対応(null id は非対応)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        }
    }
}

// MARK: - Request

/// id を持つ JSON-RPC リクエスト(応答が期待される)。
public struct JSONRPCRequest: Codable, Hashable, Sendable {
    public let jsonrpc: String
    public let id: RequestID
    public let method: String
    // params は省略可(仕様上 optional)。素通しプロキシでは中身を解釈せず JSONValue で持つ。
    public let params: JSONValue?

    public init(id: RequestID, method: String, params: JSONValue? = nil, jsonrpc: String = "2.0") {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }
}

// MARK: - Notification

/// id を持たない JSON-RPC 通知(応答を期待しない)。id の有無が request との唯一の判別点。
public struct JSONRPCNotification: Codable, Hashable, Sendable {
    public let jsonrpc: String
    public let method: String
    public let params: JSONValue?

    public init(method: String, params: JSONValue? = nil, jsonrpc: String = "2.0") {
        self.jsonrpc = jsonrpc
        self.method = method
        self.params = params
    }
}

// MARK: - Response

/// JSON-RPC のエラーオブジェクト(仕様 5.1)。
public struct JSONRPCError: Codable, Hashable, Sendable, Error {
    public let code: Int
    public let message: String
    // data は任意の付加情報。素通しなので JSONValue のまま。
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    // よく使う定数。設計 §2「未知メソッドの request には -32601」。
    public static func methodNotFound(_ method: String) -> JSONRPCError {
        // -32601 は JSON-RPC 仕様の "Method not found" 予約コード。
        JSONRPCError(code: -32601, message: "Method not found: \(method)")
    }
}

/// JSON-RPC レスポンス。result と error は排他(どちらか一方のみが存在する)。
public struct JSONRPCResponse: Codable, Hashable, Sendable {
    public let jsonrpc: String
    public let id: RequestID
    // result と error は「片方だけ」。両方 nil や両方 non-nil は仕様違反だが、
    // 送信側では init を2系統に分けて構造的に片方しか作れないようにする。
    public let result: JSONValue?
    public let error: JSONRPCError?

    /// 成功レスポンス。
    public init(id: RequestID, result: JSONValue, jsonrpc: String = "2.0") {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = result
        self.error = nil
    }

    /// 失敗レスポンス。
    public init(id: RequestID, error: JSONRPCError, jsonrpc: String = "2.0") {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = nil
        self.error = error
    }
}

// MARK: - 受信メッセージの判別

/// postMessage 経由で View から届いた「どれか分からない」JSON-RPC メッセージ。
/// Codable ではなく手書きデコードで、id / method / result / error の有無から3種を判別する。
///
/// なぜ手書きか: Swift の自動合成 Codable は「id が無い=notification」「method が無い=
/// response」という JSON-RPC の判別規約を表現できない(全部同じキー集合を舐めるだけ)。
/// 判別は封筒層の責務なので Kernel でやりきる。
public enum JSONRPCMessage: Sendable {
    case request(JSONRPCRequest)
    case notification(JSONRPCNotification)
    case response(JSONRPCResponse)

    private enum CodingKeys: String, CodingKey {
        case id, method, result, error
    }

    /// 生の JSON データから判別してデコードする。ブリッジの受信口はまずこれを通す。
    public static func decode(from data: Data) throws -> JSONRPCMessage {
        try JSONDecoder().decode(JSONRPCMessage.self, from: data)
    }
}

extension JSONRPCMessage: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasID = container.contains(.id)
        let hasMethod = container.contains(.method)

        // 判別規約(JSON-RPC 2.0):
        //  - method あり + id あり  → request
        //  - method あり + id なし  → notification
        //  - method なし + id あり  → response(result か error のどちらかを持つ)
        // View は本来この3種しか送ってこないが、崩れた JSON は上位の onerror 相当に回す。
        let single = try decoder.singleValueContainer()
        if hasMethod, hasID {
            self = .request(try single.decode(JSONRPCRequest.self))
        } else if hasMethod {
            self = .notification(try single.decode(JSONRPCNotification.self))
        } else if hasID {
            self = .response(try single.decode(JSONRPCResponse.self))
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "method も id も無い JSON-RPC メッセージは判別できません"
                )
            )
        }
    }
}

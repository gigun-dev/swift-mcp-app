// AppsBridge の「型を付けない JSON」を表す最小の代数的データ型。
//
// なぜ自前 JSONValue を持つのか(swift-sdk の `MCP.Value` を流用しない判断)——
// 設計文書 §3-1 の但し書き「swift-sdk の Value が再利用できればそれを typealias」を
// 実際に検討した結果、**採らない**。理由は2つ:
//
//  1. Kernel は外部依存ゼロが CLAUDE.md の絶対制約(「Kernel はプラットフォーム非依存 …
//     外部依存(swift-sdk・UIKit・SwiftUI)を一切持ち込まない」)。`MCP.Value` を
//     typealias するには Kernel が `import MCP` する必要があり、この制約に反する。
//     Services 層でだけ MCP.Value と相互変換すればよく、契約層(Kernel)は純粋に保つ。
//  2. `MCP.Value` は Codable の decode 時に「data URL に見える文字列」を
//     `.data(mimeType:,Data)` ケースへ自動変換する(swift-sdk
//     Sources/MCP/Base/Value.swift:98-104)。ブリッジの本質は tools/call の params や
//     structuredContent を **1バイトも変えずに素通し**することであり(設計 §3 ボツ案
//     「tool-result を CallTool.Result に型付け」を却下した理由と同根)、文字列を勝手に
//     Data 種別へ寄せる挙動は「素通し」の保証を弱める。ここでは string は string のまま持つ。
//
// indirect enum にするのは array/object が自分自身を含む再帰型のため(Swift の値型 enum は
// 再帰ケースを持つとき indirect が必須)。
import Foundation

public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    // JSON の number は仕様上ひとつだが、Swift では整数と浮動小数を分けて持つ。
    // こうしておくと「1」を "1.0" に化けさせずに round-trip でき(JSON-RPC の id など
    // 整数性が意味を持つ場面がある)、Codable の decode も Int→Double の順で素直に書ける。
    case int(Int)
    case double(Double)
    case string(String)
    indirect case array([JSONValue])
    // object のキー順序は JSON では非保証だが、Swift の Dictionary も順序を保証しない。
    // round-trip テストは「意味的な一致(== )」で判定するのでキー順は問題にならない。
    indirect case object([String: JSONValue])
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // decode の順序が挙動を決める。null → bool → int → double → string →
        // array → object の順で試す。int を double より先に試すのは整数性を保つため
        // (上のコメント参照)。MCP.Value と違い data URL の特別扱いはしない(素通し優先)。
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSONValue にデコードできない JSON トークンです")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

// MARK: - 便利アクセサ

// 状態機械や配送コードから「この JSON の hello フィールドは?」を素直に引けるように
// 最小限のアクセサだけ用意する。網羅的な subscript 群は必要になってから足す(可逆)。
extension JSONValue {
    public var objectValue: [String: JSONValue]? {
        if case .object(let dict) = self { return dict }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    public var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    /// bool 値の取り出し(設計 03 §2: CallToolResult.isError の判定に使う)。
    /// bool でなければ nil(存在しないフィールドと型違いを区別しない — 呼び出し側は
    /// 「true 以外は false 扱い」で十分なユースケースのみ使う)。
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// object の子要素をキーで引く。object でなければ nil。
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

// MARK: - 型付きへの橋渡し

extension JSONValue {
    /// この JSONValue を、指定の Decodable 型へ「JSON を経由して」変換する。
    /// params(JSONValue)→ InitializeParams などの型付き struct への変換に使う。
    /// JSONEncoder/Decoder を1往復させるだけの素朴実装 —— ホットパスではない
    /// (メッセージ1本ごとに1回)ので最適化はしない。
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }

    /// 逆方向: Encodable を JSONValue に取り込む(配送メッセージ組み立て用)。
    public init<T: Encodable>(encoding value: T) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

// MARK: - リテラル生成(テスト fixture と配送メッセージ組み立てを読みやすくする)

// 例: `let msg: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "echo"]` と書けるようにする。
extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

// MCP Apps の visibility 判定を行う純関数(docs/design/02-chat-llm.md §7)。
//
// 出典: ~/ghq/github.com/modelcontextprotocol/ext-apps/specification/2026-01-26/apps.mdx:395-401
// - 397: visibility 省略時の既定は `["model", "app"]`。
// - 400 (MUST): Host は visibility が "model" を含まないツール(例: visibility:["app"])を
//   エージェントのツール一覧(LLM に渡す tools)に含めてはならない。→ `isModelVisible`。
// - 401 (MUST): Host は visibility に "app" を含まないツールへの、app 発の tools/call
//   リクエストを拒否しなければならない。→ `isAppCallable`。
//
// Kernel はここで MCP.Value(swift-sdk 型)に一切触れない。Services 側が
// `Tool._meta?["ui"]`(MCP.Value)を JSONValue に変換してから渡す設計
// (§7「実装点」・CLAUDE.md の Kernel 依存ゼロ制約)。
import Foundation

/// tool の `_meta.ui`(JSONValue に変換済み)を受け取り、LLM のツール一覧に載せてよいか判定する。
/// - Parameter uiMeta: `_meta.ui` オブジェクト。`_meta` 自体が無い/`ui` が無いツールは nil。
public func isModelVisible(uiMeta: JSONValue?) -> Bool {
    visibilityContains(uiMeta: uiMeta, role: "model")
}

/// tool の `_meta.ui` を受け取り、app(カード内 UI)から直接 tools/call してよいか判定する。
/// apps.mdx:401 の MUST を満たすための拒否判定に使う(Services/AppsServerProxy が呼ぶ)。
public func isAppCallable(uiMeta: JSONValue?) -> Bool {
    visibilityContains(uiMeta: uiMeta, role: "app")
}

/// `uiMeta.visibility` が配列なら role を含むかどうかで判定し、配列でなければ
/// 既定 `["model", "app"]`(apps.mdx:397)扱いとして常に true を返す。
/// 「配列でない」には (a) uiMeta 自体が nil、(b) uiMeta はあるが visibility キーが無い、
/// (c) visibility はあるが配列でない値(仕様違反データ)——のいずれも含む。
/// 仕様違反データを弾いてツールを一覧から消してしまうより、既定側に倒すほうが
/// 「ツールが理由不明に使えなくなる」事故を避けられる(保守的なフェイルセーフ)。
private func visibilityContains(uiMeta: JSONValue?, role: String) -> Bool {
    guard let visibility = uiMeta?["visibility"]?.arrayValue else {
        return true
    }
    return visibility.contains { $0.stringValue == role }
}

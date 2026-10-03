// クライアント観測(テレメトリ)の **プラットフォーム非依存な出力ポート**(queue 11・2026-07-24)。
//
// 【なぜこの抽象を Kernel に置くか】
// 実機のみで再現する「履歴カードが接続解決に失敗しプレースホルダへ落ちる」バグの根因掴みに、
// 実機の永続 JSON をシミュレータ経由で漁る必要があった。「カード解決が resolved-live /
// snapshot-fallback / placeholder のどれに落ちたか + 理由(serverID mismatch 等)」を
// クライアントが構造化イベントで吐いていれば一撃だった —— という反省から入れる観測基盤。
//
// 初版はOSLogだけを実装し、その後、公式OpenTelemetry Swift SDKによるOTLP送信を追加した。
// このポートはKernel/FeaturesをSDK型や観測バックエンドへ依存させず、OSLogとOTLPを同じ
// ドメインイベントから併用・テストできる境界として維持する（ADR 0003）。
// TraceSink(設計 03 §3・ChatViewModel 専用の tool-use ループ観測)とは別レイヤー: あちらは
// 「1ターンの LLM/ツール往復」を追う専用 seam、こちらは「クライアント固有のローカル解決の成否」を
// 汎用イベント名 + fields で吐く横断ポート。将来 TraceSink をこのポート上に載せ替える余地はあるが、
// 今回はスコープを広げず両立させる。
import Foundation

/// テレメトリ 1 イベントの重大度。OSLog の OSLogType(debug/info/default/error)へ実装側で写像する
/// (Kernel は OSLog に依存しないので、ここでは純粋な列挙のまま持つ)。notice は OSLog の
/// `.default`(= "notice")に対応させる想定 —— card.resolve のような「常に残したい運用イベント」は
/// notice で出す(debug/info は既定で永続化されないため実機吸い出しで取りこぼす・OSLog の仕様)。
public enum TelemetryLevel: String, Sendable {
    case debug
    case info
    case notice
    case error
}

/// クライアント観測イベントの出力ポート。**fire-and-forget**——`event` は同期に呼ばれ、呼び出し側
/// (UI 描画・ローカル解決)を絶対にブロックしてはならない。重い処理を伴う実装は内部で非同期に逃がす。
///
/// fields は「相関 ID・outcome・reason・tool 名・server URL」など **grep/parse しやすい構造化 KV** を想定。
/// ADR 0001によりLLM/MCPのinput/outputもOTLP向けフィールドとして通るため、出力先ごとの秘匿・整形は
/// Services側adapterが担う。name はイベント種別(例: "card.resolve")で、OSLogのcategoryへ写像してよい。
public protocol TelemetryPort: Sendable {
    func event(_ name: String, fields: [String: String], level: TelemetryLevel)
    /// 後から発生する操作を元のtraceへ関連付けるためのopaqueなW3C traceparent。
    /// 対応しない実装はnilでよい。
    func correlationContext(for operationID: String) -> String?
}

public extension TelemetryPort {
    func correlationContext(for operationID: String) -> String? { nil }
}

/// 何もしない no-op 実装。**テスト/プレビュー/注入省略時の無害な既定**として使う
/// (AllowAllToolPermissionStore と同じ「注入省略時は無害」パターン・ToolPermissionStore 冒頭コメント参照)。
/// 本番の合成ルート(ChatHomeViewModel)はOSLogと設定済みOTLPを束ねるTelemetryRouterを注入する。
public struct NullTelemetry: TelemetryPort {
    public init() {}
    public func event(_ name: String, fields: [String: String], level: TelemetryLevel) {}
}

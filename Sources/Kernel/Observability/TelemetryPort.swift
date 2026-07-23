// クライアント観測(テレメトリ)の **プラットフォーム非依存な出力ポート**(queue 11・2026-07-24)。
//
// 【なぜこの抽象を Kernel に置くか】
// 実機のみで再現する「履歴カードが接続解決に失敗しプレースホルダへ落ちる」バグの根因掴みに、
// 実機の永続 JSON をシミュレータ経由で漁る必要があった。「カード解決が resolved-live /
// snapshot-fallback / placeholder のどれに落ちたか + 理由(serverID mismatch 等)」を
// クライアントが構造化イベントで吐いていれば一撃だった —— という反省から入れる観測基盤。
//
// この規模で OpenTelemetry Swift のフルスタックは過剰(依存が重く、この用途はローカル分岐の
// 成否ログで足りる)。よってポートだけを Kernel に純粋な抽象として置き、第一実装は Services 側の
// OSLog(Unified Logging)にする。将来 OTLP エクスポータ実装を足すだけでフル OTel へ移行できる
// (ビジョン1「LLM 呼び出しはエンドポイント1箇所に抽象」の観測版・ビジョン2 中立性を壊さない)。
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
/// 引数本文などのユーザーデータは載せない方針(載せる必要が出たら実装側で hash 化する。OSLogTelemetry の
/// コメント参照)。name はイベント種別(例: "card.resolve")で、OSLog の category へ写像してよい。
public protocol TelemetryPort: Sendable {
    func event(_ name: String, fields: [String: String], level: TelemetryLevel)
}

/// 何もしない no-op 実装。**テスト/プレビュー/注入省略時の無害な既定**として使う
/// (AllowAllToolPermissionStore と同じ「注入省略時は無害」パターン・ToolPermissionStore 冒頭コメント参照)。
/// 本番の合成ルート(ChatHomeViewModel)は必ず OSLogTelemetry を注入するので、実機では常に観測が効く。
public struct NullTelemetry: TelemetryPort {
    public init() {}
    public func event(_ name: String, fields: [String: String], level: TelemetryLevel) {}
}

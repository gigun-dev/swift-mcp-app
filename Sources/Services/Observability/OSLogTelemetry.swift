// TelemetryPort の第一実装(queue 11・2026-07-24)。Kernel の観測ポートを OSLog(Unified Logging)へ
// 落とす。iOS 15+ の OSLogStore で実機からプログラム吸い出しでき、`log show` / `log stream` の predicate で
// subsystem/category を絞れる —— 実機のみ再現する履歴カード解決バグを、シミュレータ経由の JSON 漁りなしに
// 一撃で追えるようにするのが狙い(TelemetryPort 冒頭コメントの経緯)。
//
// TraceSink(OSLogTraceSink)と同じ subsystem `dev.gigun.mcphost` に揃え、category はイベント名にする
// (`log show --predicate 'subsystem == "dev.gigun.mcphost" && category == "card.resolve"'` で絞れる)。
// 将来 OTLP エクスポータ実装(OTelTelemetry 等)を足すだけでフル OpenTelemetry へ移行できる —— ポートが
// Kernel 側の純抽象なので、この OSLog 実装はいつでも差し替え/併設できる。
import Foundation
import Kernel
import OSLog

/// Unified Logging へ1行 notice で構造化イベントを出す TelemetryPort 実装。
///
/// 【相関 ID・outcome・reason を `.public` で刻む理由(重要)】
/// OSLog は既定で動的文字列を private マスクする(`<private>` になり吸い出しで読めない)。相関のために
/// 出す ID・outcome・reason・tool 名・server URL は、機微でない運用メタデータなので **必ず `privacy: .public`** で
/// 刻む。逆に言えばここに機微値(引数本文・トークン等)は載せない前提でこの実装を組む —— 将来そうした値を
/// 載せるなら public のまま出さず、呼び出し側で hash 化してから fields へ入れること。
///
/// 【1行 KV に自前整形する理由】OSLog の構造化 interpolation はメタデータ扱いで `log show` の素の出力に
/// 出にくい。ここでは人間が log show でそのまま読める・grep しやすい `key=value key=value` の1行へ自前整形する
/// (OSLogTraceSink と同じ流儀)。キーは sortedKeys で安定させ、diff/parse を楽にする。
public struct OSLogTelemetry: TelemetryPort {
    public init() {}

    public func event(_ name: String, fields: [String: String], level: TelemetryLevel) {
        // category をイベント名にして predicate で1種類のイベントだけ拾えるようにする。Logger は生成が軽い
        // (内部でキャッシュされる)ので都度生成で問題ない。
        let logger = Logger(subsystem: "dev.gigun.mcphost", category: name)

        // fields を安定順(キー昇順)の `key=value` 1行へ。空白/改行混入で行が壊れないよう value は
        // whitespace を潰す(相関 ID や URL は本来 whitespace を含まないが、防御的に正規化しておく)。
        let line = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(sanitize($0.value))" }
            .joined(separator: " ")

        // level を OSLog レベルへ写像し、値全体を .public で1行出す。line は動的文字列なので privacy を
        // 明示しないと丸ごと <private> にマスクされる —— ここが「相関 ID を実機から読める」ための肝。
        switch level {
        case .debug:
            logger.debug("\(name, privacy: .public) \(line, privacy: .public)")
        case .info:
            logger.info("\(name, privacy: .public) \(line, privacy: .public)")
        case .notice:
            logger.notice("\(name, privacy: .public) \(line, privacy: .public)")
        case .error:
            logger.error("\(name, privacy: .public) \(line, privacy: .public)")
        }
    }

    /// value 内の空白類を "_" に潰す。key=value の1行フォーマットを空白でトークン分割する読み手を壊さないため。
    private func sanitize(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: "_")
    }
}

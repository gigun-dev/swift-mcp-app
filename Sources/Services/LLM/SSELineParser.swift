// SSE(Server-Sent Events)の行ストリームを「1イベント分の data ペイロード」に組み立てる純関数。
//
// なぜネットワーク I/O(URLSession.bytes)から切り離すのか(設計 §2 / T2 指示 B):
// OpenAICompatClient の SSE 解釈は「行を読む」「data: を剥がす」「空行でイベント確定」「[DONE] で
// 終端」の4つのステップに分かれるが、このうちネットワークに触れるのは「行を読む」だけ。残り3つは
// 純粋な文字列処理なので、ここに閉じ込めて swift-testing でフィクスチャ検証できるようにする
// (実 OpenAI レスポンスの行列を投入して LLMEvent 列を確かめる T2-E のため)。I/O とパースを分ける。
//
// SSE の仕様(https://html.spec.whatwg.org/multipage/server-sent-events.html)のうち、
// OpenAI chat/completions が使う部分文法だけを実装する:
//  - 各行は "field: value" 形式。今回関心がある field は `data` のみ(`event`/`id`/`retry` は無視)。
//  - `data:` の後に先頭スペース1つがあれば剥がす(仕様: value は最初のスペース1つを除去)。
//  - **空行**がイベントの区切り。1イベントに複数の `data:` 行があれば改行(\n)で連結する
//    (仕様の「dispatch the event」手順どおり。OpenAI は通常 data 1行だが、稀な複数行に備える —
//     T2 指示 B「複数行 data の稀ケース」)。
//  - コメント行(`:` で始まる行。SSE のハートビート等)は無視する。
import Foundation

/// SSE 行を1つずつ食わせると、イベント境界(空行)で確定した data ペイロードを返す逐次パーサ。
///
/// 使い方: URLSession.bytes の各行を `consume(line:)` に渡す。返り値が非 nil ならそれが
/// 1イベント分の完成した data 文字列(`data: ` 接頭辞は剥がし済み・複数行は \n 連結済み)。
/// nil の間はイベントがまだ完成していない(data 行の途中 or 無関係な行)。
///
/// struct(値型)にして状態(蓄積中の data バッファ)を明示的に持つ。これにより
/// 「行を渡す→イベントが出たら処理」というループが呼び出し側で素直に書け、テストでも
/// 行列を順に食わせるだけで検証できる。
public struct SSELineParser {
    // 現在のイベントで蓄積中の data 行(複数行対応のため配列で持ち、確定時に \n 連結する)。
    private var dataLines: [String] = []

    public init() {}

    /// 1行を取り込む。イベント境界(空行)に到達したら、そこまでに集めた data を1つの
    /// 文字列にして返す。data 行が1つも無いまま空行が来た場合は nil(空イベントは無視)。
    ///
    /// 注意: ここで渡す `line` は改行文字を含まない「1行」であること
    /// (URLSession.bytes の `.lines` は改行で分割済みの行を返すのでそのまま渡せる)。
    public mutating func consume(line: String) -> String? {
        // 空行 = イベント境界。蓄積した data 行を確定して返す。
        if line.isEmpty {
            guard !dataLines.isEmpty else {
                // data を1つも見ていない空行(連続する空行・先頭の空行)は区切りとして無意味。
                return nil
            }
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            return payload
        }

        // コメント行(":" で始まる)は無視。SSE のキープアライブ(": ping" 等)がこれ。
        if line.hasPrefix(":") {
            return nil
        }

        // "data:" 行だけを拾う。それ以外の field(event:/id:/retry:)は今回使わないので捨てる。
        if let value = Self.fieldValue(line: line, field: "data") {
            dataLines.append(value)
        }
        return nil
    }

    /// ストリームが空行で終わらずに途切れた場合、蓄積途中の data を取り出す最終フラッシュ。
    /// OpenAI は各チャンクを空行で区切るので通常は空だが、末尾に空行が無いまま接続が閉じる
    /// 実装揺れに備える(保険。握りつぶすと最後のチャンクを取り逃す)。
    public mutating func flush() -> String? {
        guard !dataLines.isEmpty else { return nil }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        return payload
    }

    /// "field: value" 行から、指定 field の value を取り出す(接頭辞不一致なら nil)。
    /// SSE 仕様に従い、コロンの後に先頭スペースが1つあれば1つだけ剥がす
    /// (value 内の以降のスペースは保持する — JSON ペイロードのスペースを壊さないため)。
    static func fieldValue(line: String, field: String) -> String? {
        let prefix = field + ":"
        guard line.hasPrefix(prefix) else { return nil }
        var value = String(line.dropFirst(prefix.count))
        // 先頭スペース1つだけ除去(SSE 仕様: "If value starts with a U+0020 SPACE, remove it")。
        if value.hasPrefix(" ") {
            value.removeFirst()
        }
        return value
    }
}

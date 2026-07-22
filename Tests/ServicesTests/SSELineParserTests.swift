// Services/LLM(T2) A.1 SSELineParser の純関数テスト。
import Testing

@testable import Services

@Suite struct SSELineParserTests {
    // 単一 data 行 + 空行 → 1 payload が返る(最も基本の1イベント)。
    @Test func data1行と空行で1payloadを返す() {
        var parser = SSELineParser()
        #expect(parser.consume(line: "data: {\"a\":1}") == nil)
        #expect(parser.consume(line: "") == "{\"a\":1}")
    }

    // 複数 data 行は \n 連結されて1 payload になる(SSE 仕様の dispatch 手順)。
    @Test func 複数data行は改行連結される() {
        var parser = SSELineParser()
        #expect(parser.consume(line: "data: line1") == nil)
        #expect(parser.consume(line: "data: line2") == nil)
        #expect(parser.consume(line: "") == "line1\nline2")
    }

    // コメント行(":" で始まる。SSE のキープアライブ)は無視され、後続の data には影響しない。
    @Test func コメント行は無視される() {
        var parser = SSELineParser()
        #expect(parser.consume(line: ": ping") == nil)
        #expect(parser.consume(line: "data: hello") == nil)
        #expect(parser.consume(line: "") == "hello")
    }

    // data: [DONE] は "data:" 接頭辞を剥がした "[DONE]" が payload として返る
    // (OpenAICompatClient 側がこの文字列で終端判定する契約)。
    @Test func DONE行はDONE文字列を返す() {
        var parser = SSELineParser()
        #expect(parser.consume(line: "data: [DONE]") == nil)
        #expect(parser.consume(line: "") == "[DONE]")
    }

    // 空行のみ連続(data 行を1つも見ていない)場合は nil(空イベントは無視・意味的な区切りなし)。
    @Test func data無しの空行はnilを返す() {
        var parser = SSELineParser()
        #expect(parser.consume(line: "") == nil)
        #expect(parser.consume(line: "") == nil)
    }

    // fieldValue: 先頭スペース1つだけを剥がす(SSE 仕様どおり。値内の以降のスペースは保持)。
    @Test func fieldValueは先頭スペース1つだけ剥がす() {
        #expect(SSELineParser.fieldValue(line: "data:  x", field: "data") == " x")
        #expect(SSELineParser.fieldValue(line: "data:x", field: "data") == "x")
        #expect(SSELineParser.fieldValue(line: "event: foo", field: "data") == nil)
    }

    // flush(): 空行で締めずに data が残留したまま終端した場合、flush がその残留分を返す
    // (末尾に空行が無いまま接続が閉じる実装揺れへの保険)。
    @Test func flushは空行未確定のdataを返す() {
        var parser = SSELineParser()
        #expect(parser.consume(line: "data: tail") == nil)
        #expect(parser.flush() == "tail")
        // flush 後はバッファがクリアされるので再度呼んでも nil。
        #expect(parser.flush() == nil)
    }
}

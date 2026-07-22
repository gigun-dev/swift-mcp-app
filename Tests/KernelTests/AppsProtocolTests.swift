// AppsProtocol(S1)の round-trip テスト。
//
// テスト方針(CLAUDE.md「テスト = What」): fixture JSON は ext-apps spec.types.ts に
// 出てくる形(なければ仕様に忠実な最小 JSON)を使い、decode→encode→再 decode で
// 意味的一致(==)することを確かめる。特に設計 §3 のロスレス要件
// (tool-result の structuredContent 内の未知フィールドを落とさない)を明示ケースにする。
import Foundation
import Testing
@testable import Kernel

// JSON 文字列 → 型 T へデコードするヘルパ。テストを読みやすくするだけ。
private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

// 値 → JSON Data → 再デコードの round-trip。encode 経路の健全性込みで検証する。
private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
}

// MARK: - JSONValue の基本 round-trip

@Test("JSONValue は各種プリミティブ/入れ子を round-trip する")
func jsonValueRoundTrip() throws {
    let value: JSONValue = [
        "n": JSONValue.null,
        "b": true,
        "i": 42,
        "d": 3.5,
        "s": "hello",
        "arr": [1, 2, 3],
        "obj": ["nested": "yes"]
    ]
    #expect(try roundTrip(value) == value)
}

@Test("JSONValue は整数を double に化けさせない(id の整数性維持)")
func jsonValueKeepsIntegers() throws {
    let decoded = try decode(JSONValue.self, "1")
    #expect(decoded == .int(1))
    // MCP.Value と違い data URL 風の文字列も string のまま保つ(素通し保証)。
    let dataURLish = try decode(JSONValue.self, "\"data:text/plain;base64,QQ==\"")
    #expect(dataURLish == .string("data:text/plain;base64,QQ=="))
}

// MARK: - JSON-RPC 封筒の判別

@Test("JSONRPCMessage は request/notification/response を id・method の有無で判別する")
func jsonRPCMessageClassification() throws {
    // request: method + id
    let req = try JSONRPCMessage.decode(from: Data(
        #"{"jsonrpc":"2.0","id":1,"method":"ui/initialize","params":{}}"#.utf8))
    guard case .request(let request) = req else { Issue.record("request 判別失敗"); return }
    #expect(request.method == "ui/initialize")
    #expect(request.id == .int(1))

    // notification: method, id なし
    let notif = try JSONRPCMessage.decode(from: Data(
        #"{"jsonrpc":"2.0","method":"ui/notifications/initialized"}"#.utf8))
    guard case .notification(let notification) = notif else { Issue.record("notification 判別失敗"); return }
    #expect(notification.method == "ui/notifications/initialized")

    // response: id, method なし
    let resp = try JSONRPCMessage.decode(from: Data(
        #"{"jsonrpc":"2.0","id":"abc","result":{"ok":true}}"#.utf8))
    guard case .response(let response) = resp else { Issue.record("response 判別失敗"); return }
    #expect(response.id == .string("abc"))
    #expect(response.error == nil)
}

@Test("RequestID は string と int を両方 round-trip する")
func requestIDRoundTrip() throws {
    #expect(try roundTrip(RequestID.int(7)) == .int(7))
    #expect(try roundTrip(RequestID.string("x")) == .string("x"))
}

// MARK: - ui/initialize の型 round-trip

@Test("ui/initialize Request/Result が型を通って round-trip する")
func initializeRoundTrip() throws {
    // spec.types.ts:554 に忠実な最小 params。
    let params = try decode(InitializeParams.self, #"""
    {
      "appInfo": { "name": "caldav-todos", "version": "3.0.0" },
      "appCapabilities": { "availableDisplayModes": ["inline"] },
      "protocolVersion": "2025-11-21"
    }
    """#)
    #expect(params.appInfo.name == "caldav-todos")
    #expect(params.protocolVersion == "2025-11-21")
    #expect(try roundTrip(params) == params)

    let result = InitializeResult(
        protocolVersion: "2025-11-21",
        hostInfo: Implementation(name: "MCPHost", version: "0.1.0"),
        hostCapabilities: ["openLinks": [:]],
        hostContext: HostContext(
            theme: .dark,
            locale: "ja-JP",
            displayMode: .inline,
            availableDisplayModes: [.inline],
            containerDimensions: ContainerDimensions(width: 340, maxHeight: 600)))
    #expect(try roundTrip(result) == result)
}

// MARK: - #5 テーマ / スタイル(host-context の theme / styles)

@Test("HostContext は theme と styles.variables を round-trip する")
func hostContextThemeStylesRoundTrip() throws {
    let ctx = HostContext(
        theme: .dark,
        styles: HostStyles(variables: [
            UIStyleVariableKey.colorBackgroundPrimary: "rgba(0, 0, 0, 1.000)",
            UIStyleVariableKey.colorTextPrimary: "rgba(255, 255, 255, 1.000)"
        ]),
        displayMode: .inline)
    let back = try roundTrip(ctx)
    #expect(back == ctx)
    #expect(back.theme == .dark)
    #expect(back.styles?.variables?[UIStyleVariableKey.colorBackgroundPrimary] == "rgba(0, 0, 0, 1.000)")
}

@Test("HostContext の部分更新は載せないフィールドを JSON から省く(spec の Partial context)")
func hostContextPartialOmitsNilFields() throws {
    // notifyThemeChanged が送る patch 相当: theme と styles だけ。
    let patch = HostContext(
        theme: .dark,
        styles: HostStyles(variables: ["--color-text-primary": "rgba(1, 2, 3, 1.000)"])
    )
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Any]
    #expect(json?["theme"] as? String == "dark")
    // displayMode / containerDimensions / locale / availableDisplayModes は nil なので書き出さない。
    #expect(json?["displayMode"] == nil)
    #expect(json?["containerDimensions"] == nil)
    #expect(json?["locale"] == nil)
    #expect(json?["availableDisplayModes"] == nil)
}

@Test("UIStyleVariableKey の綴りは spec の McpUiStyleVariableKey にバイト一致する")
func styleVariableKeySpelling() {
    // spec.types.ts:31 McpUiStyleVariableKey の該当キーと1文字も違わないこと(カード CSS が参照する)。
    #expect(UIStyleVariableKey.colorBackgroundPrimary == "--color-background-primary")
    #expect(UIStyleVariableKey.colorBackgroundSecondary == "--color-background-secondary")
    #expect(UIStyleVariableKey.colorTextPrimary == "--color-text-primary")
    #expect(UIStyleVariableKey.colorTextSecondary == "--color-text-secondary")
    #expect(UIStyleVariableKey.colorBorderPrimary == "--color-border-primary")
    #expect(UIStyleVariableKey.colorRingPrimary == "--color-ring-primary")
}

// MARK: - #6 prefersBorder(resources/read の _meta.ui からの読み取り)

@Test("prefersBorder は _meta.ui から三値(true/false/未指定)で読める")
func prefersBorderReadFromUiMeta() throws {
    // AppsServerProxy.fetchAppHTML は content-level _meta の "ui" を JSONValue で持ち帰る。
    // InlineCardHost はそこから ["prefersBorder"]?.boolValue を読む(spec.types.ts:590)。
    let uiTrue = try decode(JSONValue.self, #"{"resourceUri":"ui://x","prefersBorder":true}"#)
    #expect(uiTrue["prefersBorder"]?.boolValue == true)
    let uiFalse = try decode(JSONValue.self, #"{"prefersBorder":false}"#)
    #expect(uiFalse["prefersBorder"]?.boolValue == false)
    // 未指定 → nil(= ホスト既定「枠+背景あり」に倒す)。
    let uiOmitted = try decode(JSONValue.self, #"{"resourceUri":"ui://x"}"#)
    #expect(uiOmitted["prefersBorder"]?.boolValue == nil)
}

// MARK: - ロスレス素通し(設計 §3 の要求)

@Test("tool-result の structuredContent 内の未知フィールドがロスレスに保存される")
func toolResultPreservesUnknownFields() throws {
    // caldav todos カードの structuredContent には _meta や将来拡張フィールドが混じりうる。
    // ブリッジがこれを decode→encode で落とすと View 側の applyStructuredContent が壊れる
    // (設計 §3 ボツ案「CallTool.Result に型付け」を却下した理由)。JSONValue 素通しなら
    // 未知フィールド(futureField・_meta.custom)も保持されることを明示的に確認する。
    let json = #"""
    {
      "content": [{ "type": "text", "text": "ok" }],
      "structuredContent": {
        "todos": [{ "id": "t1", "title": "牛乳", "done": false, "futureField": 123 }],
        "_meta": { "custom": { "deep": [true, null] } }
      },
      "isError": false
    }
    """#
    let value = try decode(JSONValue.self, json)
    let back = try roundTrip(value)
    #expect(back == value)
    // 未知フィールドがピンポイントで生きていることも確認(== だけだと見落としやすいので明示)。
    let future = back["structuredContent"]?["todos"]?.arrayValue?.first?["futureField"]
    #expect(future == .int(123))
    let deep = back["structuredContent"]?["_meta"]?["custom"]?["deep"]
    #expect(deep == .array([.bool(true), .null]))
}

// MARK: - 2レーン分類(§3-3)

@Test("classify: ui/initialize は typed レーンへ")
func classifyInitialize() throws {
    let message = try JSONRPCMessage.decode(from: Data(#"""
    {"jsonrpc":"2.0","id":1,"method":"ui/initialize","params":{
      "appInfo":{"name":"a","version":"1"},
      "appCapabilities":{},
      "protocolVersion":"2025-11-21"}}
    """#.utf8))
    guard case .typed(.initialize(let id, let params)) = try IncomingViewMessage.classify(message)
    else { Issue.record("initialize が typed に落ちなかった"); return }
    #expect(id == .int(1))
    #expect(params.appInfo.name == "a")
}

@Test("classify: tools/call は passthrough レーンへ(素通し)")
func classifyToolsCall() throws {
    let message = try JSONRPCMessage.decode(from: Data(#"""
    {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"complete-todo","arguments":{"id":"t1"}}}
    """#.utf8))
    guard case .passthrough(let method, let id, let params) = try IncomingViewMessage.classify(message)
    else { Issue.record("tools/call が passthrough に落ちなかった"); return }
    #expect(method == "tools/call")
    #expect(id == .int(5))
    // params は解釈せず素通し(arguments.id が生きている)。
    #expect(params?["arguments"]?["id"] == .string("t1"))
}

@Test("classify: initialized 通知と size-changed 通知")
func classifyNotifications() throws {
    let initialized = try JSONRPCMessage.decode(from: Data(
        #"{"jsonrpc":"2.0","method":"ui/notifications/initialized"}"#.utf8))
    guard case .typed(.initialized) = try IncomingViewMessage.classify(initialized)
    else { Issue.record("initialized が typed.initialized にならない"); return }

    let sizeChanged = try JSONRPCMessage.decode(from: Data(
        #"{"jsonrpc":"2.0","method":"ui/notifications/size-changed","params":{"height":420}}"#.utf8))
    guard case .typed(.sizeChanged(let params)) = try IncomingViewMessage.classify(sizeChanged)
    else { Issue.record("size-changed が typed にならない"); return }
    #expect(params.height == 420)
}

// MARK: - ui/request-display-mode(P4-DM・設計 04 §5 H2)

@Test("classify: ui/request-display-mode は typed レーンへ(id・mode を保持)")
func classifyRequestDisplayMode() throws {
    let message = try JSONRPCMessage.decode(from: Data(#"""
    {"jsonrpc":"2.0","id":9,"method":"ui/request-display-mode","params":{"mode":"fullscreen"}}
    """#.utf8))
    guard case .typed(.requestDisplayMode(let id, let params)) = try IncomingViewMessage.classify(message)
    else { Issue.record("request-display-mode が typed に落ちなかった"); return }
    #expect(id == .int(9))
    #expect(params.mode == .fullscreen)
}

@Test("classify: request-display-mode は params 欠落だと malformed として throw する")
func classifyRequestDisplayModeMissingParams() throws {
    // params 自体を省略(mode は必須フィールドなので空 object でも decode 失敗する)。
    let message = try JSONRPCMessage.decode(from: Data(
        #"{"jsonrpc":"2.0","id":9,"method":"ui/request-display-mode"}"#.utf8))
    #expect(throws: (any Error).self) {
        _ = try IncomingViewMessage.classify(message)
    }
}

@Test("classify: request-display-mode は mode が不正な文字列だと malformed として throw する")
func classifyRequestDisplayModeInvalidMode() throws {
    // "modal" は UIDisplayMode の3値(inline/fullscreen/pip)のどれでもない不正値。
    let message = try JSONRPCMessage.decode(from: Data(#"""
    {"jsonrpc":"2.0","id":9,"method":"ui/request-display-mode","params":{"mode":"modal"}}
    """#.utf8))
    #expect(throws: (any Error).self) {
        _ = try IncomingViewMessage.classify(message)
    }
}

@Test("RequestDisplayModeParams/Result は inline/fullscreen/pip すべてで round-trip する")
func requestDisplayModeParamsAndResultRoundTrip() throws {
    for mode in [UIDisplayMode.inline, .fullscreen, .pip] {
        #expect(try roundTrip(RequestDisplayModeParams(mode: mode)) == RequestDisplayModeParams(mode: mode))
        #expect(try roundTrip(RequestDisplayModeResult(mode: mode)) == RequestDisplayModeResult(mode: mode))
    }
}

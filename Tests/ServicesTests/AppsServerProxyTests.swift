// AppsServerProxy の UI リソース発見(_meta.ui.resourceUri 解決)の単体テスト。
//
// ここが S4 の「発見」の要: tools/list の各ツールの _meta から ui:// URI を引く純関数
// (resolveUIResourceURI)。新形式 `_meta.ui.resourceUri` と後方互換キー `_meta["ui/resourceUri"]`
// の両方、および UI を持たないツールで nil になることを、実サーバー(caldav)なしで固定する。
// 出典: ext-apps app-bridge.ts:126-133 / caldav server.ts の両キー併記。
import Foundation
import Testing
import MCP

@testable import Services

@Suite struct AppsServerProxyTests {
    // Client は接続前でも生成できる(actor の初期化に接続は不要)。resolveUIResourceURI は
    // nonisolated な純関数で actor 状態にも Client にも触れないので、これで十分テストできる。
    private func makeProxy() -> AppsServerProxy {
        AppsServerProxy(client: Client(name: "test", version: "0"))
    }

    // caldav の list-todos 相当: _meta.ui.resourceUri(新形式・ネスト)を解決できる。
    @Test func 新形式_metaUiResourceUriを解決する() {
        let proxy = makeProxy()
        let tool = Tool(
            name: "list-todos",
            description: "test",
            inputSchema: .object([:]),
            _meta: Metadata(additionalFields: [
                "ui": .object(["resourceUri": .string("ui://caldav/todos.html")]),
            ]))
        #expect(proxy.resolveUIResourceURI(for: tool) == "ui://caldav/todos.html")
    }

    // 後方互換キー _meta["ui/resourceUri"](フラット)しか無いサーバーでも解決できる。
    @Test func 後方互換フラットキーを解決する() {
        let proxy = makeProxy()
        let tool = Tool(
            name: "legacy-tool",
            description: "test",
            inputSchema: .object([:]),
            _meta: Metadata(additionalFields: [
                "ui/resourceUri": .string("ui://legacy/card.html"),
            ]))
        #expect(proxy.resolveUIResourceURI(for: tool) == "ui://legacy/card.html")
    }

    // 新形式が優先される(両方あるとき ui.resourceUri を採る・caldav は両併記)。
    @Test func 新形式が後方互換キーより優先される() {
        let proxy = makeProxy()
        let tool = Tool(
            name: "both",
            description: "test",
            inputSchema: .object([:]),
            _meta: Metadata(additionalFields: [
                "ui": .object(["resourceUri": .string("ui://new.html")]),
                "ui/resourceUri": .string("ui://old.html"),
            ]))
        #expect(proxy.resolveUIResourceURI(for: tool) == "ui://new.html")
    }

    // UI を持たないツール(get-current-time 等・registerTool で _meta なし)は nil。
    @Test func UI無しツールはnil() {
        let proxy = makeProxy()
        let tool = Tool(name: "get-current-time", description: "test", inputSchema: .object([:]))
        #expect(proxy.resolveUIResourceURI(for: tool) == nil)
    }

    // 名前引きの薄いヘルパ: 一覧から名前で引いて解決 / 未知名は nil。
    @Test func 名前引きで解決と未知名nil() {
        let proxy = makeProxy()
        let tools = [
            Tool(name: "get-current-time", description: "test", inputSchema: .object([:])),
            Tool(
                name: "list-todos",
                description: "test",
                inputSchema: .object([:]),
                _meta: Metadata(additionalFields: [
                    "ui": .object(["resourceUri": .string("ui://caldav/todos.html")]),
                ])),
        ]
        #expect(proxy.resolveUIResourceURI(in: tools, toolName: "list-todos") == "ui://caldav/todos.html")
        #expect(proxy.resolveUIResourceURI(in: tools, toolName: "does-not-exist") == nil)
    }
}

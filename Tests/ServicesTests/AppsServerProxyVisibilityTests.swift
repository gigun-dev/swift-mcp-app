// Services/LLM(T2) A.4 AppsServerProxy の app 発 tools/call 拒否テスト。
import Testing
import MCP

@testable import Kernel
@testable import Services

@Suite struct AppsServerProxyVisibilityTests {
    private func makeProxy() -> AppsServerProxy {
        AppsServerProxy(client: Client(name: "test", version: "0"))
    }

    // visibility ["model"] のみ(app 不可)のツールへの app 発 tools/call は
    // toolNotAppCallable で拒否される(apps.mdx:401 MUST)。
    @Test func appを含まないツールはtoolNotAppCallableで拒否される() async {
        let proxy = makeProxy()
        let modelOnlyTool = Tool(
            name: "delete-todo",
            description: "test",
            inputSchema: .object([:]),
            _meta: Metadata(additionalFields: [
                "ui": .object(["visibility": .array([.string("model")])])
            ]))
        await proxy.setTools([modelOnlyTool])

        let params: JSONValue = ["name": "delete-todo", "arguments": [:]]
        await #expect(throws: AppsServerProxyError.self) {
            _ = try await proxy.passthroughToolsCall(params: params)
        }
    }

    // _meta 省略(既定 visibility に "app" を含む)のツール名は判定を通過する
    // (この先の callTool 実行で Client 未接続エラーになるはずなので、それを検知できれば
    // 「visibility 判定では拒否されなかった」ことの傍証になる。toolNotAppCallable **ではない**
    // 別種のエラーで失敗することを確認する)。
    @Test func meta省略のツールは判定を通過する() async {
        let proxy = makeProxy()
        let noMetaTool = Tool(name: "list-todos", description: "test", inputSchema: .object([:]))
        await proxy.setTools([noMetaTool])

        let params: JSONValue = ["name": "list-todos", "arguments": [:]]
        do {
            _ = try await proxy.passthroughToolsCall(params: params)
            Issue.record("接続していない Client への callTool は成功しないはず")
        } catch let error as AppsServerProxyError {
            if case .toolNotAppCallable = error {
                Issue.record("visibility 判定で拒否されるべきではない: \(error)")
            }
            // missingField 等それ以外の AppsServerProxyError は許容(判定は通過している)。
        } catch {
            // Client 未接続による MCPError 等はここに落ちる。visibility 判定は通過している。
        }
    }

    // 一覧に無い名前は(visibility を根拠にした)拒否をしない。この分岐は Client の実行結果を
    // 問わないので、toolNotAppCallable **ではない**理由で失敗することだけを確認する。
    @Test func 一覧に無い名前はvisibilityでは拒否しない() async {
        let proxy = makeProxy()
        await proxy.setTools([])

        let params: JSONValue = ["name": "unknown-tool", "arguments": [:]]
        do {
            _ = try await proxy.passthroughToolsCall(params: params)
            Issue.record("接続していない Client への callTool は成功しないはず")
        } catch let error as AppsServerProxyError {
            if case .toolNotAppCallable = error {
                Issue.record("一覧に無い名前を visibility で拒否してはいけない: \(error)")
            }
        } catch {
            // Client 未接続による例外はここに落ちる。想定どおり。
        }
    }

    // 一覧未注入(setTools を呼ばない)は後方互換で全許可 → visibility 判定では拒否しない。
    @Test func 一覧未注入は全許可で判定を通過する() async {
        let proxy = makeProxy()
        let params: JSONValue = ["name": "anything", "arguments": [:]]
        do {
            _ = try await proxy.passthroughToolsCall(params: params)
            Issue.record("接続していない Client への callTool は成功しないはず")
        } catch let error as AppsServerProxyError {
            if case .toolNotAppCallable = error {
                Issue.record("一覧未注入は全許可のはず: \(error)")
            }
        } catch {
            // Client 未接続による例外はここに落ちる。想定どおり。
        }
    }
}

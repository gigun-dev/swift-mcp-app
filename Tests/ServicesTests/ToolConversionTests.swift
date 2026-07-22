// Services/LLM(T2) A.3 ToolConversion の単体テスト。
import Testing
import MCP

@testable import Services

@Suite struct ToolConversionTests {
    // _meta.ui.visibility に "model" を含まないツール(["app"] のみ)は結果から落ちる
    // (apps.mdx:400 MUST)。
    @Test func visibilityがappのみのツールは除外される() throws {
        let tool = Tool(
            name: "refresh-todos",
            description: "internal refresh",
            inputSchema: .object(["type": .string("object")]),
            _meta: Metadata(additionalFields: [
                "ui": .object(["visibility": .array([.string("app")])])
            ]))
        let definitions = try toolDefinitions(from: [tool])
        #expect(definitions.isEmpty)
    }

    // _meta 省略・["model","app"]・["model"] を含むツールはいずれも結果に残る。
    @Test func modelを含むまたはmeta省略のツールは残る() throws {
        let noMeta = Tool(name: "get-current-time", description: "test", inputSchema: .object([:]))
        let modelAndApp = Tool(
            name: "list-todos",
            description: "test",
            inputSchema: .object([:]),
            _meta: Metadata(additionalFields: [
                "ui": .object(["visibility": .array([.string("model"), .string("app")])])
            ]))
        let modelOnly = Tool(
            name: "delete-todo",
            description: "test",
            inputSchema: .object([:]),
            _meta: Metadata(additionalFields: [
                "ui": .object(["visibility": .array([.string("model")])])
            ]))

        let definitions = try toolDefinitions(from: [noMeta, modelAndApp, modelOnly])
        let names = Set(definitions.map { $0.function.name })
        #expect(names == ["get-current-time", "list-todos", "delete-todo"])
    }

    // inputSchema(MCP.Value の object)が ToolDefinition.function.parameters に
    // JSON Schema としてそのまま移り、properties/required が保たれる。
    @Test func inputSchemaがJSONSchemaとして移る() throws {
        let tool = Tool(
            name: "get_weather",
            description: "weather lookup",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "city": .object(["type": .string("string")])
                ]),
                "required": .array([.string("city")])
            ]))

        let definitions = try toolDefinitions(from: [tool])
        #expect(definitions.count == 1)
        let parameters = definitions[0].function.parameters
        #expect(parameters["type"]?.stringValue == "object")
        #expect(parameters["properties"]?["city"]?["type"]?.stringValue == "string")
        #expect(parameters["required"]?.arrayValue == [.string("city")])
    }
}

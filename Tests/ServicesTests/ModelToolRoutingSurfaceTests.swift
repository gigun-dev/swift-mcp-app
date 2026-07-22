// ChatHome の新規チャット境界で、広告定義・executor route・カード帰属を同じ集合へ閉じるテスト。
import Testing
import Kernel

@testable import Services

@Suite struct ModelToolRoutingSurfaceTests {
    private func definition(_ name: String) -> ToolDefinition {
        ToolDefinition(function: .init(name: name, description: nil, parameters: [:]))
    }

    @Test("モデル広告集合とexecutor許可routeは完全一致しapp-only相当は帰属にも残らない")
    func advertisedDefinitionsExactlyMatchRoutes() {
        let modelRoute = ToolNamespacing.route(slug: "caldav", tool: "list-todos")
        let appOnlyRoute = ToolNamespacing.route(slug: "caldav", tool: "refresh-todos")
        let surface = strictModelToolRoutingSurface(
            toolDefinitions: [definition(modelRoute.wireName)],
            routes: [modelRoute, appOnlyRoute],
            uiResourceURIs: [
                modelRoute.wireName: "ui://todos/card.html",
                appOnlyRoute.wireName: "ui://todos/refresh.html"
            ]
        )

        let definitionNames = Set(surface.toolDefinitions.map(\.function.name))
        let routeNames = Set(surface.routes.map(\.wireName))
        #expect(definitionNames == routeNames)
        #expect(definitionNames == [modelRoute.wireName])
        #expect(Set(surface.uiResourceURIs.keys) == [modelRoute.wireName])
    }

    @Test("route欠落とwire衝突は広告前にfail-closedで除外する")
    func missingAndAmbiguousRoutesAreNotAdvertised() {
        let missingName = "missing__tool"
        let surface = strictModelToolRoutingSurface(
            toolDefinitions: [definition("same"), definition(missingName)],
            routes: [
                ToolRoute(wireName: "same", slug: "a", toolName: "one"),
                ToolRoute(wireName: "same", slug: "b", toolName: "two")
            ],
            uiResourceURIs: ["same": "ui://same", missingName: "ui://missing"]
        )

        #expect(surface.toolDefinitions.isEmpty)
        #expect(surface.routes.isEmpty)
        #expect(surface.uiResourceURIs.isEmpty)
    }
}

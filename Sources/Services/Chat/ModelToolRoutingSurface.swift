// 新規チャットへ公開する tool の三つの表面を、同じ wire-name 集合へ正規化する。
//
// LLM の tool 定義だけ visibility で絞り、executor route を tools/list 全件から作ると、
// app-only tool も名前を推測すれば実行できてしまう。カード帰属(uiResourceURIs)だけ全件を
// 残す場合も同じく、モデルに非公開の tool が通常チャットのカードとして解決されうる。
// そこで ChatHome の構築直前に三者を原子的に交差させる。カード内部の tools/call は
// AppsServerProxy が app visibility を独立判定するため、このモデル向け表面とは分離されたままである。
import Kernel

public struct ModelToolRoutingSurface: Sendable {
    public let toolDefinitions: [ToolDefinition]
    public let routes: [ToolRoute]
    public let uiResourceURIs: [String: String]
}

/// モデルへ広告する定義を正として、明示的かつ一意な route を持つ tool だけを残す。
///
/// route 欠落・同一 wire 名の衝突は「広告するが実行不能」へ倒さず、広告前に fail-closed で除外する。
/// definition の重複も OpenAI tools 配列へ二重掲載しない。返却三者のキー集合は常に一致する
/// (uiResourceURIs はカードを持つ tool の部分集合なので、値が元から無いものは追加しない)。
public func strictModelToolRoutingSurface(
    toolDefinitions: [ToolDefinition],
    routes: [ToolRoute],
    uiResourceURIs: [String: String]
) -> ModelToolRoutingSurface {
    var routeByName: [String: ToolRoute] = [:]
    var ambiguousNames = Set<String>()
    for route in routes {
        if let existing = routeByName[route.wireName], existing != route {
            routeByName.removeValue(forKey: route.wireName)
            ambiguousNames.insert(route.wireName)
        } else if !ambiguousNames.contains(route.wireName) {
            routeByName[route.wireName] = route
        }
    }

    var seenNames = Set<String>()
    var definitions: [ToolDefinition] = []
    var allowedRoutes: [ToolRoute] = []
    for definition in toolDefinitions {
        let name = definition.function.name
        guard seenNames.insert(name).inserted,
              !ambiguousNames.contains(name),
              let route = routeByName[name]
        else { continue }
        definitions.append(definition)
        allowedRoutes.append(route)
    }

    let allowedNames = Set(allowedRoutes.map(\.wireName))
    return ModelToolRoutingSurface(
        toolDefinitions: definitions,
        routes: allowedRoutes,
        uiResourceURIs: uiResourceURIs.filter { allowedNames.contains($0.key) }
    )
}

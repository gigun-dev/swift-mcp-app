// 履歴カードを現在の MCP 接続へ戻すための provenance 解決。
// UI 描画と接続同定を分け、ChatHomeViewModel 本体の「ライブ会話を組む」責務を膨らませない。
import Foundation
import Kernel
import Services

/// buildContext が ToolCallRunner へ焼き付ける route ごとの生成元情報。
struct ChatRouteMetadata {
    let serverNames: [String: String]
    let serverIDs: [String: UUID]
    let serverURLs: [String: URL]
}

/// strict surface に残った route だけへ provenance を付ける。app-only tool は surface.routes に無いため、
/// ここで誤って通常チャット由来カードとして永続化されない。
func chatRouteMetadata(routes: [ToolRoute], connections: [ReadyConnection]) -> ChatRouteMetadata {
    let bySlug = Dictionary(uniqueKeysWithValues: connections.map { ($0.slug, $0) })
    return ChatRouteMetadata(
        serverNames: Dictionary(uniqueKeysWithValues: routes.compactMap { route in
            bySlug[route.slug].map { (route.wireName, $0.name) }
        }),
        serverIDs: Dictionary(uniqueKeysWithValues: routes.compactMap { route in
            bySlug[route.slug].map { (route.wireName, $0.serverID) }
        }),
        serverURLs: Dictionary(uniqueKeysWithValues: routes.compactMap { route in
            bySlug[route.slug].map { (route.wireName, $0.url) }
        })
    )
}

/// 履歴カード1枚を現在の接続へ復元するために HistoryDetailView へ渡す、解決済みの組。
/// internal に留め、Kernel の永続 DTO や Services のプロトコル面へ UI ライフサイクルを漏らさない。
struct HistoricalCardConnection {
    let proxy: AppsServerProxy
    let card: CardEmbed
    let registryIdentity: String
}

extension ChatHomeViewModel {
    /// 保存済みカードを、現在 ready な**同一 MCP サーバー**へ安全に再接続する。
    ///
    /// 元 tool はこの経路では再実行せず、InlineCardView が保存済み arguments / structuredContent を
    /// 新しい app HTML へ配送する。返す resourceUri は現在 tools/list が広告する値へ差し替えるため、
    /// content hash 付き URI がデプロイで変わっても古い HTML を要求し続けない。
    ///
    /// 新履歴は serverID + serverURL + originalToolName の全一致を要求する。旧履歴(provenance 無し)は
    /// 現在の model-visible route の wireName が一意かつ厳密一致するときだけ best-effort で許可する。
    /// 文字列から slug を推測する fallback は、hash 短縮・衝突・app-only tool の表面化を招くため行わない。
    func historicalCardConnection(for savedCard: CardEmbed) -> HistoricalCardConnection? {
        let resolved = resolveHistoricalSource(savedCard)
        guard let resolved else { return nil }
        var liveCard = savedCard
        liveCard.toolName = resolved.wireName
        liveCard.resourceUri = resolved.resourceURI
        return HistoricalCardConnection(
            proxy: resolved.connection.proxy,
            card: liveCard,
            // 同じ serverID/URI でも再接続で proxy actor が交換されたら別 host を作り、古い bridge を
            // registry から再利用しない。古い host は画面終了時 teardownAll でまとめて破棄される。
            registryIdentity: "\(resolved.connection.serverID.uuidString)-"
                + "\(ObjectIdentifier(resolved.connection.proxy))-\(resolved.resourceURI)"
        )
    }

    private func resolveHistoricalSource(_ card: CardEmbed) -> HistoricalSource? {
        if let serverID = card.serverID {
            return resolveProvenanceCard(card, serverID: serverID)
        }
        // 旧履歴は保存時 slug しか手掛かりがない。現在の広告 surface に同じ wireName がある
        // connection がちょうど1本の場合だけ許可し、0件/複数件は別サーバー誤配送を避け静的表示へ戻す。
        let candidates = connections.readyConnections.compactMap { connection -> HistoricalSource? in
            guard connection.toolDefs.contains(where: { $0.function.name == card.toolName }) else {
                return nil
            }
            return connection.uiResourceURIs[card.toolName].map {
                HistoricalSource(connection: connection, wireName: card.toolName, resourceURI: $0)
            }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func resolveProvenanceCard(_ card: CardEmbed, serverID: UUID) -> HistoricalSource? {
        guard let originalToolName = card.originalToolName,
              let connection = connections.readyConnections.first(where: { $0.serverID == serverID }),
              card.matchesSource(
                  serverID: connection.serverID,
                  serverURL: connection.url,
                  originalToolName: originalToolName
              )
        else { return nil }
        let wireName = ToolNamespacing.wireName(slug: connection.slug, tool: originalToolName)
        // uiResourceURIs は全広告tool由来なので、それだけではapp-only toolも通る。現在のstrict surface
        // にwireNameが残っていることも要求し、過去のsource toolを権限の広い経路へ復活させない。
        guard connection.toolDefs.contains(where: { $0.function.name == wireName }),
              connection.tools.contains(where: { $0.name == originalToolName }),
              let resourceURI = connection.uiResourceURIs[wireName]
        else { return nil }
        return HistoricalSource(connection: connection, wireName: wireName, resourceURI: resourceURI)
    }
}

private struct HistoricalSource {
    let connection: ReadyConnection
    let wireName: String
    let resourceURI: String
}

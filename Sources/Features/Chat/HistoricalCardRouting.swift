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

/// 履歴カード解決の結果を、live 再接続用の connection と **理由**の両方で HistoryDetailView へ返す組
/// (queue 11・2026-07-24)。connection が nil のとき、なぜ live 解決できなかったかを reason が説明し、
/// View 側が card.resolve 観測イベントへ載せる(実機バグ調査の主目的「なぜ placeholder か」)。
struct HistoricalCardResolution {
    let connection: HistoricalCardConnection?
    let reason: CardResolutionReason
}

extension ChatHomeViewModel {
    /// 保存済みカードを、現在 ready な**同一 MCP サーバー**へ安全に再接続する。
    ///
    /// 元 tool はこの経路では再実行せず、InlineCardView が保存済み arguments / structuredContent を
    /// 新しい app HTML へ配送する。返す resourceUri は現在 tools/list が広告する値へ差し替えるため、
    /// content hash 付き URI がデプロイで変わっても古い HTML を要求し続けない。
    ///
    /// 新履歴は serverID + serverURL + originalToolName の全一致を第一優先で要求し、外したときだけ
    /// serverURL(canonical identity)一致の一意候補へフォールバックする(OAuth 再追加で serverID が
    /// 変わっても URL 同一なら復元できる・2026-07-24)。旧履歴(provenance 無し)は現在の model-visible
    /// route の wireName が一意かつ厳密一致するときだけ best-effort で許可する。文字列から slug を推測する
    /// fallback は、hash 短縮・衝突・app-only tool の表面化を招くため行わない。同定判定そのものは Kernel の
    /// 純関数 HistoricalCardResolver に切り出し(テスト可能化)、ここは projection と引き戻しだけを担う。
    /// 履歴カードの解決を connection + reason で返す(queue 11)。connection は従来どおり live 再接続に使い、
    /// 失敗時の reason も同時に返して View 側が card.resolve 観測へ載せられるようにする(旧 historicalCardConnection は
    /// これへ統合。呼び出し側は connection だけ要れば `.connection` を取ればよい)。
    func historicalCardResolution(for savedCard: CardEmbed) -> HistoricalCardResolution {
        let resolved = resolveHistoricalSource(savedCard)
        guard let source = resolved.surface else {
            return HistoricalCardResolution(connection: nil, reason: resolved.reason)
        }
        var liveCard = savedCard
        liveCard.toolName = source.wireName
        liveCard.resourceUri = source.resourceURI
        let connection = HistoricalCardConnection(
            proxy: source.connection.proxy,
            card: liveCard,
            // 同じ serverID/URI でも再接続で proxy actor が交換されたら別 host を作り、古い bridge を
            // registry から再利用しない。古い host は画面終了時 teardownAll でまとめて破棄される。
            registryIdentity: "\(source.connection.serverID.uuidString)-"
                + "\(ObjectIdentifier(source.connection.proxy))-\(source.resourceURI)"
        )
        return HistoricalCardResolution(connection: connection, reason: resolved.reason)
    }

    /// 解決結果を「実 ReadyConnection を引き戻した surface(あれば)+ reason」で返す。
    private func resolveHistoricalSource(
        _ card: CardEmbed
    ) -> (surface: HistoricalSource?, reason: CardResolutionReason) {
        // ReadyConnection(proxy 等を抱える Services 依存の重い型)を、同定に必要な面だけ射影した
        // HistoricalCardSurface へ落とす。判定は Kernel の純関数へ委ね、ここは projection と
        // 「返った surfaceIndex → 実 ReadyConnection の引き戻し」だけを担う(順序は一致させる)。
        let ready = connections.readyConnections
        let surfaces = ready.map { connection in
            HistoricalCardSurface(
                serverID: connection.serverID,
                url: connection.url,
                slug: connection.slug,
                wireNames: Set(connection.toolDefs.map(\.function.name)),
                originalToolNames: Set(connection.tools.map(\.name)),
                uiResourceURIs: connection.uiResourceURIs
            )
        }
        // resolve から resolveDetailed へ切り替え、失敗理由も引き取る(観測の主目的)。
        let resolution = HistoricalCardResolver.resolveDetailed(card: card, surfaces: surfaces)
        guard let resolved = resolution.surface else {
            return (nil, resolution.reason)
        }
        return (
            HistoricalSource(
                connection: ready[resolved.surfaceIndex],
                wireName: resolved.wireName,
                resourceURI: resolved.resourceURI
            ),
            resolution.reason
        )
    }
}

private struct HistoricalSource {
    let connection: ReadyConnection
    let wireName: String
    let resourceURI: String
}

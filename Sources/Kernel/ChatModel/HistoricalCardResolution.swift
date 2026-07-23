// 履歴カードを「現在 ready な MCP サーバー」へ live 再接続するための **純粋な同定ロジック**。
//
// 【なぜ Kernel に純関数として置くか(2026-07-24・履歴カードの正しさ slice)】
// 旧実装は同定を Features(ChatHomeViewModel)の private メソッド(resolveProvenanceCard /
// resolveHistoricalSource)に閉じていたが、そこは ReadyConnection(= AppsServerProxy を抱える
// Services 依存の重い型)前提でユニットテストできなかった。同定は「serverID/serverURL/tool 名の
// 突き合わせ」という純データ判定なので、接続の投影(HistoricalCardSurface)に対する純関数へ切り出し、
// Kernel の swift-testing で「再追加(serverID 変化)に強い」ことを固定できるようにする。
// Features 側は ReadyConnection → HistoricalCardSurface の projection と、返った index → 実接続の
// 引き戻しだけを担う薄いアダプタになる。
import Foundation

/// 現在 ready な1接続の、同定に必要な面だけを射影した値(proxy 等の実行時オブジェクトは含めない)。
/// Features 側で ReadyConnection から組み立て、この純関数へ渡す。
public struct HistoricalCardSurface: Sendable, Equatable {
    /// ローカル DB 行 ID(ServerRegistry.id)。再追加・再認証のたびに新規 UUID になる —— つまり
    /// これは protocol identity ではない(canonical identity は url。下 resolve のコメント参照)。
    public let serverID: UUID
    /// canonical identity(resource URI 相当・scheme+host+path)。再追加・再認証でも不変。
    public let url: URL
    /// 現在の名前空間 slug。wireName(slug__tool)の再構成に使う。
    public let slug: String
    /// tools/list が広告する **前置済み**関数名(toolDefs の function.name)。strict surface 検査に使う。
    public let wireNames: Set<String>
    /// 現在の tools/list の素の tool 名(前置前)。app-only tool の復活を防ぐ strict surface 検査に使う。
    public let originalToolNames: Set<String>
    /// 前置名キーの ui:// リソース URI 表。resourceURI の引き当てに使う。
    public let uiResourceURIs: [String: String]

    public init(
        serverID: UUID,
        url: URL,
        slug: String,
        wireNames: Set<String>,
        originalToolNames: Set<String>,
        uiResourceURIs: [String: String]
    ) {
        self.serverID = serverID
        self.url = url
        self.slug = slug
        self.wireNames = wireNames
        self.originalToolNames = originalToolNames
        self.uiResourceURIs = uiResourceURIs
    }
}

/// resolve が返す「どの接続の・どの wireName・どの resourceURI へ復元するか」。
/// surfaceIndex は渡した surfaces 配列上の位置で、Features 側が実 ReadyConnection を引き戻すのに使う。
public struct ResolvedHistoricalSurface: Sendable, Equatable {
    public let surfaceIndex: Int
    public let wireName: String
    public let resourceURI: String

    public init(surfaceIndex: Int, wireName: String, resourceURI: String) {
        self.surfaceIndex = surfaceIndex
        self.wireName = wireName
        self.resourceURI = resourceURI
    }
}

/// resolve の詳細結果。surface(非 nil なら解決成功)に加え、**なぜその結果になったか**の reason を持つ
/// (queue 11・2026-07-24)。従来は Optional だけを返していたが、実機のみ再現する「なぜ placeholder に
/// 落ちたか」を観測へ載せるため、失敗理由も呼び出し側へ渡せるようにした。reason は成功経路(serverIDMatch /
/// urlFallback / legacyUnique)と失敗経路(serverURLMismatch / ambiguousURL / appOnlyToolFiltered …)の
/// どちらも表す。CardResolutionReason は Kernel/Observability に定義(観測整形と同居させる)。
public struct CardResolution: Sendable, Equatable {
    public let surface: ResolvedHistoricalSurface?
    public let reason: CardResolutionReason

    public init(surface: ResolvedHistoricalSurface?, reason: CardResolutionReason) {
        self.surface = surface
        self.reason = reason
    }
}

/// 保存済み履歴カードを、現在 ready な接続群の中の1本へ安全に同定する純関数。
public enum HistoricalCardResolver {
    /// - Parameters:
    ///   - card: 保存済みカード(serverID/serverURL/originalToolName は旧履歴では nil でありうる)。
    ///   - surfaces: 現在 ready な接続の射影(順序は Features 側 readyConnections と一致させる)。
    /// - Returns: 一意に安全へ同定できたときだけ非 nil。曖昧・不一致・strict surface 落ちは nil。
    ///
    /// 【後方互換 wrapper(queue 11)】理由付きの resolveDetailed を薄く包み、従来の Optional 面を保つ。
    /// 既存の呼び出し側(Features のアダプタ・既存テスト)を壊さないためのショートハンド。理由が要る観測経路は
    /// resolveDetailed を直接使う。
    ///
    /// 【解決の優先順位(2026-07-24・OAuth 再追加バグの修正)】
    /// 1. **serverID 一致(厳密経路)を第一優先**にする。従来どおり serverID + serverURL +
    ///    originalToolName の完全一致(matchesSource)+ strict surface 検査を要求する。これは
    ///    「同じサーバーが同じ ID のまま生きている」通常ケースの最速・最安全経路。
    /// 2. serverID 一致で見つからないときだけ **serverURL(canonical identity)フォールバック**へ落ちる。
    ///    根因: MCP サーバーの canonical identity は resource URI(= url。RFC 8707 resource indicators /
    ///    RFC 9728 protected resource metadata の考え方)であって、ローカルの serverID は DB 行 ID に
    ///    すぎない。OAuth デバッグ等でコネクタを再追加すると serverID は新 UUID になるが url は不変 ——
    ///    旧 serverID を握る履歴カードが URL 同一なのに全解決不能になっていた(実機バグ・JSON 裏取り済み)。
    ///    フォールバックは url == card.serverURL かつ strict surface(下)を満たす候補が **ちょうど1本**の
    ///    ときだけ許可する(0件/複数件は誤配送を避け nil。旧履歴経路 legacy の candidates.count==1 と流儀を揃える)。
    ///    serverID を要求しないのが肝だが、それ以外の strict surface 検査は厳密経路と完全に同じにして、
    ///    app-only tool の復活や別 tool への誤経路を防ぐ。
    /// 3. serverID が無い**旧履歴**(provenance 未記録)は、card.toolName(= 保存時 wireName)が現在の
    ///    広告 surface にちょうど1本だけ残っているときに best-effort で許可する(従来の legacy 経路を踏襲)。
    ///
    /// なお live 解決に失敗した場合の最後の砦(保存 snapshotHTML の静的表示)は呼び出し側 HistoryDetailView が
    /// 持つ。本関数は「ライブ解決を再追加に強くする」だけで、フォールバック除去はしない。
    public static func resolve(card: CardEmbed, surfaces: [HistoricalCardSurface]) -> ResolvedHistoricalSurface? {
        resolveDetailed(card: card, surfaces: surfaces).surface
    }

    /// 理由付きの解決(queue 11・2026-07-24)。resolve と同じ判定木を通り、成功/失敗の理由も返す。
    /// 観測(card.resolve イベント)の「なぜ placeholder か」を埋めるために呼ぶ。判定ロジックの正典はこちらで、
    /// resolve はこの .surface を取り出すだけの薄い wrapper。
    public static func resolveDetailed(card: CardEmbed, surfaces: [HistoricalCardSurface]) -> CardResolution {
        // 接続が1本も無いのは「カードの良し悪し以前」の状態。ここで noReadyConnection と明示しておくと、
        // 実機ログで「未接続で開いただけ」と「接続はあるが解決に失敗」を吸い出し側が一発で切り分けられる。
        guard !surfaces.isEmpty else {
            return CardResolution(surface: nil, reason: .noReadyConnection)
        }
        if let serverID = card.serverID, let originalToolName = card.originalToolName {
            return resolveProvenance(
                card: card, serverID: serverID, originalToolName: originalToolName, surfaces: surfaces
            )
        }
        return resolveLegacy(card: card, surfaces: surfaces)
    }

    // MARK: - provenance あり(serverID 厳密 → serverURL フォールバック)

    private static func resolveProvenance(
        card: CardEmbed,
        serverID: UUID,
        originalToolName: String,
        surfaces: [HistoricalCardSurface]
    ) -> CardResolution {
        // (1) 厳密経路: serverID 一致 + matchesSource(serverURL/originalToolName も一致)+ strict surface。
        //     first(where:) 相当を index 付きで回す(返す surfaceIndex が必要なため enumerated を使う)。
        for (index, surface) in surfaces.enumerated()
        where surface.serverID == serverID
            && card.matchesSource(
                serverID: surface.serverID,
                serverURL: surface.url,
                originalToolName: originalToolName
            ) {
            if let resolved = strictSurface(index: index, surface: surface, originalToolName: originalToolName) {
                return CardResolution(surface: resolved, reason: .serverIDMatch)
            }
            // serverID は一致するが strict surface を満たさない(現在の広告から source tool が消えた等)。
            // ここで URL フォールバックへ落ちても同じ surface は url 一致で再評価されるが、strict surface を
            // 満たさないので候補にならない —— つまり素直に下のフォールバックへ流して問題ない。
        }

        // (2) serverURL(canonical identity)フォールバック: serverID を問わず url 一致 + strict surface の
        //     候補を集め、ちょうど1本のときだけ許可する(0件/複数件は曖昧回避で nil)。
        guard let serverURL = card.serverURL else {
            return CardResolution(surface: nil, reason: .missingServerURL)  // url 記録が無ければ突き合わせ不能。
        }
        let candidates = surfaces.enumerated().compactMap { index, surface -> ResolvedHistoricalSurface? in
            guard surface.url == serverURL else { return nil }
            return strictSurface(index: index, surface: surface, originalToolName: originalToolName)
        }
        if candidates.count == 1 {
            return CardResolution(surface: candidates[0], reason: .urlFallback)
        }
        if candidates.count > 1 {
            return CardResolution(surface: nil, reason: .ambiguousURL)
        }
        // candidates == 0 の「なぜ」を分けて返す: URL 自体が一致する接続すら無いのか(serverURLMismatch)、
        // URL は一致したが strict surface(素の tool が現在の tools/list に無い等)で全部弾かれたのか
        // (appOnlyToolFiltered)。これは実機バグ調査でまさに知りたかった区別(placeholder の原因特定)。
        let urlPresent = surfaces.contains { $0.url == serverURL }
        return CardResolution(surface: nil, reason: urlPresent ? .appOnlyToolFiltered : .serverURLMismatch)
    }

    /// strict surface 検査(厳密経路・URL フォールバック共通)。app-only tool の復活や別経路への
    /// 誤配送を防ぐため、uiResourceURIs だけでなく現在の広告面(wireNames / originalToolNames)にも
    /// 残っていることを要求する。満たせば復元先(wireName/resourceURI)を返す。
    private static func strictSurface(
        index: Int,
        surface: HistoricalCardSurface,
        originalToolName: String
    ) -> ResolvedHistoricalSurface? {
        let wireName = ToolNamespacing.wireName(slug: surface.slug, tool: originalToolName)
        guard surface.wireNames.contains(wireName),                 // toolDefs に前置名がある
              surface.originalToolNames.contains(originalToolName),  // tools に素の tool がある(app-only 除外)
              let resourceURI = surface.uiResourceURIs[wireName]     // ui:// が引ける
        else { return nil }
        return ResolvedHistoricalSurface(surfaceIndex: index, wireName: wireName, resourceURI: resourceURI)
    }

    // MARK: - 旧履歴(provenance 無し)

    private static func resolveLegacy(
        card: CardEmbed,
        surfaces: [HistoricalCardSurface]
    ) -> CardResolution {
        // 保存時 slug しか手掛かりがない。現在の広告 surface に同じ wireName(= card.toolName)がある接続が
        // ちょうど1本の場合だけ許可し、0件/複数件は別サーバー誤配送を避け静的表示へ戻す(従来踏襲)。
        let candidates = surfaces.enumerated().compactMap { index, surface -> ResolvedHistoricalSurface? in
            guard surface.wireNames.contains(card.toolName),
                  let resourceURI = surface.uiResourceURIs[card.toolName]
            else { return nil }
            return ResolvedHistoricalSurface(surfaceIndex: index, wireName: card.toolName, resourceURI: resourceURI)
        }
        if candidates.count == 1 {
            return CardResolution(surface: candidates[0], reason: .legacyUnique)
        }
        // 0件(どこにも無い)と複数件(曖昧)を分けて返す(観測での切り分けのため)。
        return CardResolution(
            surface: nil,
            reason: candidates.isEmpty ? .noWireNameMatch : .ambiguousWireName
        )
    }
}

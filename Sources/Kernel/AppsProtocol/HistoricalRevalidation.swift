/// 保存済み MCP App を現在の接続へ戻すときの、host/app 間の拡張契約。
///
/// MCP Apps 標準には「この tool-result は履歴由来なので現在状態へ更新してほしい」という通知がない。
/// host が refresh tool 名を推測して呼ぶと汎用性と権限境界を壊すため、CallToolResult の `_meta` に
/// namespaced hint だけを載せる。対応 App はこの hint を見て、自分が知る read-only refresh tool を
/// 呼ぶ。未知 `_meta` を無視する App の標準挙動は変わらない。
public enum HistoricalRevalidation {
    public static let metadataKey = "dev.gigun.mcphost/historical-revalidation"

    /// CallToolResult が object のときだけ既存 `_meta` を保ったまま hint を追加する。
    /// 非 object は CallToolResult 契約外なので形を捏造せず、そのまま返して fail-closed gate に任せる。
    public static func marking(_ result: JSONValue) -> JSONValue {
        guard case .object(var root) = result else { return result }
        var metadata = root["_meta"]?.objectValue ?? [:]
        metadata[metadataKey] = .object([
            "required": .bool(true),
            "reason": .string("history"),
            "version": .int(1)
        ])
        root["_meta"] = .object(metadata)
        return .object(root)
    }
}

/// 履歴 App の操作ゲート。UI と非同期 timer から同じ遷移規則を使える純粋な状態機械にする。
public enum HistoricalRevalidationState: Equatable, Sendable {
    case notRequired
    case waiting
    case ready
    case failed

    public func applying(_ event: HistoricalRevalidationEvent) -> Self {
        switch (self, event) {
        case (_, .begin):
            return .waiting
        case (.waiting, .toolCallCompleted(let succeeded)):
            return succeeded ? .ready : .failed
        case (.waiting, .timedOut):
            return .failed
        default:
            // 遅着した旧 request や二重 callback で ready/failed を巻き戻さない。
            return self
        }
    }
}

public enum HistoricalRevalidationEvent: Equatable, Sendable {
    case begin
    case toolCallCompleted(succeeded: Bool)
    case timedOut
}

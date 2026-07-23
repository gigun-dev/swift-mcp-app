// 履歴カード解決(HistoricalCardResolver)の結果を **観測イベントへ整形する純データ + 純関数**
// (queue 11・2026-07-24)。outcome/reason の enum とその fields マップ化はプラットフォーム非依存の
// 純粋な整形なので Kernel に置き、swift-testing で「outcome/reason → fields」を固定する
// (What はテストに書く方針・CLAUDE.md「テスト = What」)。実際に OSLog へ流す配線は Services 側。

import Foundation

/// カード1枚が最終的にどの表示形態へ落ちたか。HistoryDetailView.cardView の3分岐に1対1で対応する。
/// - resolvedLive: 現在 ready な同一 MCP へ live 再接続できた(理想形)。
/// - snapshotFallback: live 解決に失敗したが保存 snapshotHTML の静的表示に落ちた(閲覧は可能)。
/// - placeholder: snapshot も無く、プレースホルダ(toolName + structuredContent)だけに落ちた(最悪形)。
public enum CardResolutionOutcome: String, Sendable, Equatable {
    case resolvedLive = "resolved-live"
    case snapshotFallback = "snapshot-fallback"
    case placeholder
}

/// live 解決が成功/失敗した「理由」。実機バグ調査の主目的そのもの ——「なぜ placeholder に落ちたか」を
/// 一撃で分かるようにするため、HistoricalCardResolver の分岐で実際に区別できる粒度で enum 化する。
/// 成功理由(どの経路で解決したか)と失敗理由(どこで弾かれたか)の両方を持つ。
public enum CardResolutionReason: String, Sendable, Equatable {
    // --- 成功理由(surface を返せたケース) ---
    /// serverID 一致の厳密経路で解決(同じサーバーが同じ ID のまま生きている通常ケース)。
    case serverIDMatch = "server-id-match"
    /// serverID は変わったが serverURL(canonical identity)一致の一意候補へフォールバックで解決
    /// (OAuth 再追加で serverID が新 UUID になった実機バグの救済経路)。
    case urlFallback = "url-fallback"
    /// provenance 無しの旧履歴を、現在の広告 surface に wireName が一意に残っていたので best-effort 解決。
    case legacyUnique = "legacy-unique"

    // --- 失敗理由(nil を返したケース) ---
    /// 現在 ready な接続が1本も無い(未接続・全切断)。カードの良し悪し以前の状態。
    case noReadyConnection = "no-ready-connection"
    /// provenance の serverURL が、現在 ready などの接続 URL のどれとも一致しない(別サーバーへ誤配送しない)。
    case serverURLMismatch = "server-url-mismatch"
    /// 同一 serverURL の接続が複数 ready で、どれへ復元すべきか断定できない(曖昧回避)。
    case ambiguousURL = "ambiguous-url"
    /// URL は一致する接続があるが、strict surface 検査(素の tool 名が現在の tools/list に無い等)で
    /// 弾かれた —— app-only tool 化した等で「見えないツール」を復活させないためのフィルタ。
    case appOnlyToolFiltered = "app-only-tool-filtered"
    /// provenance に serverID/originalToolName はあるが serverURL が記録されておらず突き合わせ不能
    /// (部分記録の旧履歴)。安全側で解決しない。
    case missingServerURL = "missing-server-url"
    /// 旧履歴で同じ wireName を広告する接続が複数あり曖昧(legacy 経路の曖昧回避)。
    case ambiguousWireName = "ambiguous-wire-name"
    /// 旧履歴で wireName に一致する広告がどこにも無い(tool が消えた・別サーバーしかない)。
    case noWireNameMatch = "no-wire-name-match"
}

/// card.resolve 観測イベントの整形(純関数)。TelemetryPort.event(name:fields:level:) へ渡す name/fields を
/// 組み立てる。ここを純関数にすることで「outcome/reason → fields マップ」を Kernel テストで固定できる。
public enum CardResolutionTelemetry {
    /// 観測イベント名。OSLog の category へ写像してよい(grep/predicate の的にする)。中立な汎用名にする
    /// (caldav 固有の語を入れない・ビジョン2 中立性)。
    public static let eventName = "card.resolve"

    /// outcome/reason と相関材料から、安定した KV マップを組む。値は OSLog 側で `.public` で刻む前提なので
    /// ユーザーデータ(引数本文等)は載せない —— tool 名・server URL・相関 ID など「相関に必要な非機微値」だけ。
    ///
    /// - Parameters:
    ///   - outcome: 3分岐のどれに落ちたか。
    ///   - reason: なぜその outcome になったか(特に placeholder/snapshot の理由が調査の主目的)。
    ///   - card: 対象カード。tool 名・生成元 serverID/serverURL(mismatch 調査用の相関材料)をここから引く
    ///     (個別引数に展開せず CardEmbed を渡すのは、パラメータ数を抑えつつ相関材料を一箇所に束ねるため)。
    ///   - session: per-launch のセッション相関 ID(将来 W3C traceparent 互換へ差し替え可能・呼び出し側コメント参照)。
    /// - Returns: nil の optional は落として詰めた安定マップ(欠損キーは「記録が無い」を意味する)。
    public static func resolveFields(
        outcome: CardResolutionOutcome,
        reason: CardResolutionReason,
        card: CardEmbed,
        session: String
    ) -> [String: String] {
        // outcome/reason/session/tool は常に載せる。server 系は旧履歴だと欠けるので nil のとき省く
        // (キー自体を出さないことで「provenance 未記録」を吸い出し側が区別できる)。
        var fields: [String: String] = [
            "outcome": outcome.rawValue,
            "reason": reason.rawValue,
            "tool": card.toolName,
            "session": session
        ]
        if let expectedServerID = card.serverID {
            fields["expectedServerID"] = expectedServerID.uuidString
        }
        if let serverURL = card.serverURL {
            fields["serverURL"] = serverURL.absoluteString
        }
        return fields
    }
}

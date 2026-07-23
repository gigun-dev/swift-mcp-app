// OAuth アクセストークンの「先回り refresh(proactive refresh)」窓を決める純関数。
//
// 【正典】docs/design/08-oauth-token-lifecycle.md 原則1(ハイブリッド refresh)。
// 送信直前に `expires_at - スキュー` を過ぎていたら先回りで refresh する、その「スキュー(窓)」を
// ここで決める。Claude 公式コネクタ実装形(design/08 §規範)が「失効の5分前から先回り refresh」を
// 参照ベスプラとしているのに合わせ、既定は 300 秒(5分)。
//
// 【なぜ Kernel(純関数層)に置くか】この計算はプラットフォームにも swift-sdk にも一切依存しない
// (TimeInterval の四則演算だけ)。design/08 の「スキュー境界」判定を Xcode 無しの `swift test` で
// 固定したい(タスク完了条件のテスト§「expiry 判定(スキュー境界)」)ので、MCP 型に触らない
// ここ(Kernel)へ隔離する。Services 側(MCPConnection)がこの定数/関数を読んで
// swift-sdk の `OAuthConfiguration(proactiveRefreshWindowSeconds:)` に流し込む。
//
// 【中立性(CLAUDE.md ビジョン2)】caldav 固有の TTL(3600s)をこの型はハードコードしない。
// TTL を引数で受け取る純関数にして、任意の MCP サーバーの TTL に同じ規則を適用する。
import Foundation

/// 先回り refresh の窓(スキュー秒)を決める規則。design/08 原則1 の実装形。
public enum OAuthProactiveRefreshPolicy {
    /// TTL が分からない時点(接続確立前・swift-sdk へ固定窓を渡すとき)に使う既定スキュー。
    ///
    /// 300 秒 = 5分。出典: design/08 §規範「失効の5分前から先回り refresh」(Claude 公式コネクタ docs)。
    ///
    /// 【なぜ固定値も要るか(swift-sdk の API 制約・報告対象)】swift-sdk の
    /// `OAuthConfiguration.proactiveRefreshWindowSeconds` は接続時に**一度だけ固定する
    /// スカラ**で、トークンごとの `expires_in`(= TTL)を見て動的に窓を変える口が無い
    /// (Base/Authorization/OAuthAuthorizer.swift `prepareAuthorization` は
    /// `isExpired(skewSeconds: proactiveRefreshWindowSeconds)` を固定窓で呼ぶだけ)。
    /// よって MCPConnection.connect はこの固定 300 を渡す。design/08 が併記する
    /// 「TTL の10%」動的版(下の window(forTTLSeconds:))は、TTL が判明する層
    /// (将来の SSE 再接続・自前トークンプロバイダ)でだけ使える——現状 swift-sdk 経由では
    /// 適用できない旨を明示しておく。
    public static let defaultWindowSeconds: TimeInterval = 300

    /// TTL(access token の有効秒数 = token response の `expires_in`)から先回り窓を決める。
    ///
    /// design/08 原則1 の規則を厳密に写す:
    ///   スキュー = 5分(300s)。ただし **TTL の10% が5分未満ならそちら**を採る。
    ///   すなわち `min(300, TTL * 0.10)`。
    ///
    /// - なぜ TTL*10% の下限が要るか: 短命トークン(例 TTL 60s)に 300s 窓を当てると、
    ///   発行直後から常に「窓の中」= 毎リクエスト refresh の暴発になる。窓を TTL に比例させて
    ///   縮めることで「発行直後は使い、末尾10%で先回り」という一定の挙動比を保つ。
    /// - caldav 本番(TTL 3600s)では TTL*10% = 360s > 300s なので 300s(5分)が選ばれる。
    ///   これは design/08 が caldav について想定するスキューと一致する(境界テストで固定)。
    ///
    /// - Parameter ttlSeconds: access token の有効秒数。0 以下(不明・無期限)は既定窓へ倒す。
    /// - Returns: 先回り refresh を始める「失効前スキュー秒」。
    public static func window(forTTLSeconds ttlSeconds: TimeInterval) -> TimeInterval {
        // 0 以下(= expires_in 無し/不明)は動的計算が意味を持たないので既定 300 に倒す。
        guard ttlSeconds > 0 else { return defaultWindowSeconds }
        // min(300, TTL*0.10)。TTL が 3000s(50分)を超えると 10% が 300 を上回るので 300 で頭打ち。
        return min(defaultWindowSeconds, ttlSeconds * 0.10)
    }
}

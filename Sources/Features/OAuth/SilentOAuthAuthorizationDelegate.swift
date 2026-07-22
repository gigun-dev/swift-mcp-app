// 無言(サイレント)OAuth 認可 delegate(M2・起動時の自動接続)。
//
// 【なぜ要るか(ユーザー FB)】「毎回接続を押すのが違和感・押しただけで繋がることもある(=トークンが
// 生きてる)」。トークンが Keychain に生きていれば swift-sdk は presentAuthorizationURL を呼ばずに
// 無言で接続を完了させる。生きていなければブラウザ提示(= presentAuthorizationURL)が必要になる。
// この delegate は presentAuthorizationURL を**即 throw**することで「対話が必要なら失敗させる」——
// 呼び出し側(ConnectionsManager)はこの失敗を「needsAuth(要認証)」として扱い、成功なら「ready」に
// する。これで起動時に全サーバーへ並列に無言接続を試み、トークンが生きているサーバーだけが黙って
// 繋がり、そうでないサーバーはブラウザを勝手に開かず「要認証」バッジで待つ、という体験になる。
//
// 対話(ブラウザ提示)が要るときは LoopbackOAuthAuthorizationDelegate(ユーザーのタップ起点)を使う。
// この2つを delegate 差し替えで切り替えるのが M2 の自動接続の肝(接続コード=MCPConnection.connect は共通)。
import Foundation
import Services  // OAuthAuthorizationDelegate(@_exported import MCP 経由)

/// presentAuthorizationURL を即 throw する delegate。トークンが生きていれば呼ばれず接続成功、
/// 対話が要るときだけ呼ばれて `NeedsInteraction` を投げる(= 呼び出し側が needsAuth と判定する材料)。
public final class SilentOAuthAuthorizationDelegate: NSObject, OAuthAuthorizationDelegate,
    @unchecked Sendable
{
    /// 「ブラウザ提示(対話)が必要だった」ことを表すエラー。ConnectionsManager がこの型かどうかでは
    /// なく、下の `didRequestInteraction` フラグで needsAuth を判定する(swift-sdk がエラーを
    /// ラップして別の型で再送出しても取りこぼさないため — 失敗の分類はフラグに一本化する)。
    public struct NeedsInteraction: Error {}

    /// presentAuthorizationURL が呼ばれたか(= トークンが生きておらず対話が必要だった)。
    /// 接続失敗後にこれを見て needsAuth / failed を切り分ける。
    public private(set) var didRequestInteraction = false

    public override init() {}

    public func presentAuthorizationURL(_ url: URL) async throws -> URL {
        // ここに来た時点で「無言では繋がらない」= 対話が必要。ブラウザは開かず即失敗させる。
        didRequestInteraction = true
        throw NeedsInteraction()
    }
}

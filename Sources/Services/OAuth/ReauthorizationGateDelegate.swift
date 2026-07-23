// 対話セッション確立後の「その場ブラウザ再認可」を封じるための delegate ラッパ。
//
// 【なぜ要るか(design/08 §残課題)】swift-sdk 0.12.1 の OAuthAuthorizer は 401 受信時に
// refresh を試み、refresh token が失効(invalid_grant)して refresh に失敗すると、そのまま
// フル再認可(acquireToken → presentAuthorizationURL)へフォールスルーする
// (.build/checkouts/swift-sdk/.../OAuthAuthorizer.swift handleChallenge:296 acquireToken 到達で確認)。
// この delegate が対話用 LoopbackOAuthAuthorizationDelegate のままだと、tools/call や
// resources/read の最中に**会話中に突然ブラウザ(ASWebAuthenticationSession)が開く**——
// これは claude.ai iOS の「サイレント 401 ループ」と対をなす悪い UX で、design/08 原則4
// 「invalid_grant(恒久失効)→ 自動 refresh を諦めて再認可導線を明示表示」に反する。
//
// 【方針】初回認可フロー(ユーザーのタップ起点)の間だけ内側 delegate(ブラウザ提示)を通し、
// **接続確立後**(markEstablished 済み)に presentAuthorizationURL が呼ばれたら = refresh 失効起因の
// 再認可要求とみなして、ブラウザは開かず throw する。加えて呼び出し側(ConnectionsManager)へ
// コールバックで通知し、接続を「要再認可(needsAuth)」状態へ載せ替えさせる。ユーザーの明示操作
// (接続画面からの再認可)は新しい接続=新しい gate(established=false)なので従来どおりブラウザが出る。
//
// 【なぜ Services に置くか】ブラウザ提示は Features 依存(AuthenticationServices/UIKit)だが、
// 「確立前=提示許可・確立後=throw」という状態遷移そのものはプラットフォーム非依存の純ロジックなので、
// 任意の内側 delegate を包める形で Services に置き、swift test で状態遷移を固定する
// (Loopback を注入する Features 側の配線は ConnectionsManager が行う)。
import Foundation
import MCP  // OAuthAuthorizationDelegate

/// 内側 delegate を包み、接続確立後の presentAuthorizationURL を「再認可要求」として遮断するラッパ。
///
/// 使い方: `OAuthConfiguration.authorizationDelegate` にこれを渡し、`MCPConnection.connect` が
/// 成功して接続が確立した直後に `markEstablished()` を呼ぶ。以後 SDK が(refresh 失効で)
/// presentAuthorizationURL を呼んでも、ブラウザは出ず `ReauthorizationRequired` を throw し、
/// `onReauthorizationRequired` が発火する。
public final class ReauthorizationGateDelegate: NSObject, OAuthAuthorizationDelegate,
    @unchecked Sendable {
    /// 接続確立後に再認可(ブラウザ提示)が要求されたことを表すエラー。
    /// この throw により SDK の当該リクエスト(tools/call 等)は失敗し、呼び出し元へ伝播する
    /// (会話側にはツールエラーとして出るが、サーバーバッジは onReauthorizationRequired で needsAuth に落ちる)。
    public struct ReauthorizationRequired: Error {}

    /// 実際のブラウザ提示(初回認可)を担う内側 delegate。確立前だけこれへ委譲する。
    private let inner: any OAuthAuthorizationDelegate

    /// 確立後の再認可要求を検知したときに1回発火するコールバック(状態載せ替え用)。
    /// transport(actor)の背後スレッドから呼ばれうるため @Sendable。ConnectionsManager 側で
    /// MainActor へ hop して states[id] = .needsAuth に落とす。
    private let onReauthorizationRequired: @Sendable () -> Void

    /// presentAuthorizationURL は async で任意スレッドから呼ばれ、markEstablished は MainActor から
    /// 呼ばれる。established / didRequestReauthorization の読み書きを直列化するための軽量ロック
    /// (@unchecked Sendable の責務を果たすのはこのロック)。
    private let lock = NSLock()
    private var established = false
    /// 確立後の再認可要求が起きたか(テスト・診断用の観測点)。
    private var _didRequestReauthorization = false

    public var didRequestReauthorization: Bool {
        lock.lock(); defer { lock.unlock() }
        return _didRequestReauthorization
    }

    public init(
        wrapping inner: any OAuthAuthorizationDelegate,
        onReauthorizationRequired: @escaping @Sendable () -> Void = {}
    ) {
        self.inner = inner
        self.onReauthorizationRequired = onReauthorizationRequired
    }

    /// 接続確立(MCPConnection.connect 成功)を記録する。これ以降の presentAuthorizationURL は
    /// 「初回認可」ではなく「refresh 失効起因の再認可」なので遮断対象になる。
    public func markEstablished() {
        lock.lock(); defer { lock.unlock() }
        established = true
    }

    public func presentAuthorizationURL(_ url: URL) async throws -> URL {
        lock.lock()
        let alreadyEstablished = established
        if alreadyEstablished {
            _didRequestReauthorization = true
        }
        lock.unlock()

        if alreadyEstablished {
            // 確立後の提示要求 = refresh token 失効。ブラウザは開かず、要再認可へ載せ替えさせて throw。
            onReauthorizationRequired()
            throw ReauthorizationRequired()
        }
        // 確立前(初回認可フロー)は内側 delegate に委譲してブラウザを出す。
        return try await inner.presentAuthorizationURL(url)
    }
}

// swift-sdk の `OAuthAuthorizationDelegate`(Base/Authorization/OAuthConfiguration.swift)実装。
//
// 設計判断の経緯(重要・P1 タスク指示からの変更点):
// 当初案は ASWebAuthenticationSession + カスタム URL スキーム(`mcphost://oauth/callback`)
// だったが、実装前に swift-sdk 側を読んだところ
// `OAuthURLValidator.validateRedirectURI`(Base/Authorization/OAuthURLValidator.swift)が
// リダイレクト URI のスキームを **https、または loopback(127.0.0.1/localhost/::1)の http のみ**
// に制限していることが判明した(カスタムスキームは `invalidRedirectURI` で弾かれる)。
// iOS のネイティブアプリ向け定石(RFC 8252)はカスタムスキーム or Universal Links だが、
// この SDK は前者を受け付けず、後者は Associated Domains(自前ドメインの AASA 配信)が要る
// ため今回のスコープ外。よって **loopback リダイレクト**(SDK が実際にサポートする方式)を採用する。
//
// loopback リダイレクトは本来デスクトップ/CLI 向け(ローカル HTTP サーバーでリダイレクトを
// 受ける)だが、iOS でも動く: `ASWebAuthenticationSession` を `callbackURLScheme: nil` で使うと
// 自動検出(＝アプリを離れる遷移)は行われず、認可画面はアプリ内モーダルシートとして
// 表示され続ける。コールバックをローカル HTTP サーバーで受け止めた時点で
// `session.cancel()` してシートを閉じる。ブラウザ(Safari)へ本当に離脱しないので、
// カスタムスキームで「アプリに戻ってくる」ためのトランポリンや Info.plist の
// CFBundleURLTypes 登録が不要になる副産物もある。
//
// 【ボツ案: NWListener】初版はローカルサーバーを Network framework の NWListener で
// 実装したが、実機で POSIXErrorCode 22(EINVAL)により .failed(ポート .any → 明示
// ポートに変えても同じ)。macOS の最小再現で素の NWListener まで全滅する一方
// BSD ソケット直は成功したため、Services/OAuth/LoopbackCallbackServer.swift
// (BSD ソケット + DispatchSource、swift test で実挙動テスト済み)に乗り換えた。
// 経緯の生記録は docs/log.md 2026-07-15。
import AuthenticationServices
import Foundation
import OSLog
import Services  // `@_exported import MCP` 経由で OAuthAuthorizationDelegate 等が見える
import UIKit

/// loopback HTTP リダイレクトで OAuth 2.1 authorization_code フローを仲介する delegate。
///
/// 使い方: 1接続につき1インスタンス。まず `prepareRedirectURI()` で
/// `OAuthConfiguration.authorizationRedirectURI` に渡す URI を発行し(この時点でローカル
/// サーバーが起動する)、そのあと `MCPConnection.connect` に self を渡す。
/// swift-sdk はトークン取得が必要になったタイミングで `presentAuthorizationURL(_:)` を呼ぶ。
public final class LoopbackOAuthAuthorizationDelegate: NSObject, OAuthAuthorizationDelegate,
    @unchecked Sendable
{
    enum DelegateError: LocalizedError {
        case redirectURINotPrepared
        case presentationFailed
        case userCancelled

        var errorDescription: String? {
            switch self {
            case .redirectURINotPrepared:
                return "prepareRedirectURI() を呼ぶ前に presentAuthorizationURL が呼ばれました。"
            case .presentationFailed:
                return "認可画面を提示できませんでした(ASWebAuthenticationSession.start() が false)。"
            case .userCancelled:
                return "認可がキャンセルされました。"
            }
        }
    }

    private var server: LoopbackCallbackServer?
    // ASWebAuthenticationSession は completion handler を保持している間だけ生存すればよいはずだが、
    // 実機観測で早期に解放されるとシートが即座に閉じる不具合報告があるため(Apple 標準の
    // 既知の落とし穴)、明示的にプロパティで保持してシートの生存期間を delegate の生存期間に紐づける。
    private var webAuthSession: ASWebAuthenticationSession?

    public override init() {}

    /// ローカル HTTP サーバーを 127.0.0.1 の一時ポートで起動し、
    /// `OAuthConfiguration.authorizationRedirectURI` に渡すべき URI を返す。
    /// 接続フローの中で `MCPConnection.connect` より前に呼ぶ必要がある
    /// (OAuthConfiguration はリダイレクト URI を接続開始時に確定させるため)。
    public func prepareRedirectURI() throws -> URL {
        let server = LoopbackCallbackServer()
        let uri = try server.start()
        self.server = server
        return uri
    }

    // 認可フローの観察用(unified log)。swift-sdk が認可を何回・いつ要求したかを
    // `log show --predicate 'subsystem == "dev.gigun.mcphost"'` で追えるようにする。
    // .notice はデフォルトで永続化される(.info はメモリのみで log show に出ない罠がある)。
    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "oauth")

    public func presentAuthorizationURL(_ url: URL) async throws -> URL {
        guard let server else { throw DelegateError.redirectURINotPrepared }
        logger.notice("認可ラウンド開始: \(url.host ?? "?", privacy: .public)")

        // 認可シートの提示はメインスレッドで。セッションの completion はローカルサーバー経由の
        // 正規完了とは別経路(ユーザーの手動キャンセル)なので、server.cancel に流して
        // waitForCallback 側の continuation に一本化する(二重 resume は server 側が防ぐ)。
        await MainActor.run {
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) {
                _, error in
                if error != nil {
                    server.cancel(with: DelegateError.userCancelled)
                }
            }
            session.presentationContextProvider = self
            // アプリをまたいだ Cookie 共有を避ける(認可のたびにクリーンな状態から始めたいので)。
            session.prefersEphemeralWebBrowserSession = true
            self.webAuthSession = session
            if !session.start() {
                server.cancel(with: DelegateError.presentationFailed)
            }
        }

        let redirectURL = try await server.waitForCallback()
        logger.notice("認可コールバック受信")
        await MainActor.run {
            self.webAuthSession?.cancel()  // 認可完了 → シートを閉じる
            self.webAuthSession = nil
        }
        return redirectURL
    }
}

extension LoopbackOAuthAuthorizationDelegate: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor
    {
        // このアプリはシングルシーン構成(project.yml に UIScene 構成は無く SwiftUI 既定の
        // 単一 WindowGroup)なので、最初に見つかった key window を使えば十分。
        // 複数シーン対応が必要な規模になったら呼び出し元から明示的にウィンドウを渡す形に直す。
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

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
// 表示され続ける。これを Network framework の `NWListener` で 127.0.0.1 の一時ポートに
// 立てたローカル HTTP サーバーで受け止め、コールバック URL を捕まえた時点で
// `session.cancel()` してシートを閉じる。ブラウザ(Safari)へ本当に離脱しないので、
// カスタムスキームで「アプリに戻ってくる」ためのトランポリンや Info.plist の
// CFBundleURLTypes 登録が不要になる副産物もある(project.yml は今回変更していない —
// 詳細は最終報告のオープン論点を参照)。
import AuthenticationServices
import Foundation
import Network
import Services  // `@_exported import MCP` 経由で OAuthAuthorizationDelegate 等が見える
import UIKit

/// loopback HTTP リダイレクトで OAuth 2.1 authorization_code フローを仲介する delegate。
///
/// 使い方: 1接続につき1インスタンス。まず `prepareRedirectURI()` で
/// `OAuthConfiguration.authorizationRedirectURI` に渡す URI を発行し(この時点でローカル
/// リスナーが起動する)、そのあと `MCPConnection.connect` に self を渡す。
/// swift-sdk はトークン取得が必要になったタイミングで `presentAuthorizationURL(_:)` を呼ぶ。
public final class LoopbackOAuthAuthorizationDelegate: NSObject, OAuthAuthorizationDelegate,
    @unchecked Sendable
{
    enum DelegateError: LocalizedError {
        case redirectURINotPrepared
        case malformedCallbackRequest
        case presentationFailed

        var errorDescription: String? {
            switch self {
            case .redirectURINotPrepared:
                return "prepareRedirectURI() を呼ぶ前に presentAuthorizationURL が呼ばれました。"
            case .malformedCallbackRequest:
                return "ローカルコールバックの HTTP リクエストを解釈できませんでした。"
            case .presentationFailed:
                return "認可画面を提示できませんでした(ASWebAuthenticationSession.start() が false)。"
            }
        }
    }

    private var listener: NWListener?
    // ASWebAuthenticationSession は completion handler を保持している間だけ生存すればよいはずだが、
    // 実機観測で早期に解放されるとシートが即座に閉じる不具合報告があるため(Apple 標準の
    // 既知の落とし穴)、明示的にプロパティで保持してシートの生存期間を delegate の生存期間に紐づける。
    private var webAuthSession: ASWebAuthenticationSession?

    public override init() {}

    /// ローカル HTTP リスナーを 127.0.0.1 の一時ポートで起動し、
    /// `OAuthConfiguration.authorizationRedirectURI` に渡すべき URI を返す。
    /// 接続フローの中で `MCPConnection.connect` より前に呼ぶ必要がある
    /// (OAuthConfiguration はリダイレクト URI を接続開始時に確定させるため)。
    public func prepareRedirectURI() async throws -> URL {
        let parameters = NWParameters.tcp
        // 127.0.0.1 以外(Wi-Fi インターフェース等)からの接続を受け付けないよう明示的に固定する。
        // ポートは `.any`(0)= OS に空きポートを選ばせる(固定ポートだと他プロセスと衝突しうる)。
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let port = listener.port?.rawValue ?? 0
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(port)/callback")!)
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
    }

    public func presentAuthorizationURL(_ url: URL) async throws -> URL {
        guard let listener else { throw DelegateError.redirectURINotPrepared }

        return try await withCheckedThrowingContinuation { continuation in
            // ローカルリスナー経由の正規完了と、ユーザーによる手動キャンセル(ASWebAuthenticationSession
            // 側の completion handler)の2経路が競合しうるので、二重 resume を防ぐガード。
            var didResume = false
            func resumeOnce(_ result: Result<URL, Error>) {
                guard !didResume else { return }
                didResume = true
                switch result {
                case .success(let redirectURL): continuation.resume(returning: redirectURL)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                    data, _, _, error in
                    // 後始末は各分岐で明示的に行う。当初は defer でまとめて
                    // connection.cancel()/listener.cancel() していたが、成功パスでは
                    // connection.send() の完了前に receive クロージャが返る(send は非同期)ため、
                    // defer だと応答送信中のコネクションを cancel してしまい、
                    // 200 応答が届かない/最悪 .contentProcessed が発火せず
                    // continuation が resume されないままハングする恐れがあった。
                    // 成功パスの cancel は send 完了ハンドラ内に移す。
                    func failAndCleanup(_ error: Error) {
                        connection.cancel()
                        listener.cancel()
                        resumeOnce(.failure(error))
                    }

                    if let error {
                        failAndCleanup(error)
                        return
                    }
                    guard let data,
                        let requestLine = String(data: data, encoding: .utf8)?
                            .split(separator: "\r\n").first,
                        let redirectURL = Self.redirectURL(
                            fromRequestLine: String(requestLine),
                            listenerPort: listener.port?.rawValue ?? 0
                        )
                    else {
                        failAndCleanup(DelegateError.malformedCallbackRequest)
                        return
                    }

                    // ブラウザ(実際はアプリ内シート)に一言返してから閉じる。
                    // ここで応答を返さないと Safari 系エンジンがコネクションのハングを
                    // ユーザーに見せてしまうことがあるため、簡素でも明示的に 200 を返す。
                    let body =
                        "<html><body>MCPHost: \u{8a8d}\u{53ef}\u{304c}\u{5b8c}\u{4e86}\u{3057}\u{307e}\u{3057}\u{305f}\u{3002}</body></html>"
                    let response =
                        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(
                        content: Data(response.utf8),
                        completion: .contentProcessed { _ in
                            // 応答が(成否によらず)処理し終わってから後始末する。
                            // 送信エラーでも認可コード自体は既に手元にあるので成功として resume する。
                            connection.cancel()
                            listener.cancel()
                            DispatchQueue.main.async {
                                self?.webAuthSession?.cancel()
                                resumeOnce(.success(redirectURL))
                            }
                        }
                    )
                }
            }

            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) {
                _, error in
                // 上のローカルリスナー経路が正規の完了パス。ここに到達するのは基本的に
                // ユーザーがシートを手動キャンセルした場合(error == .canceledLogin)のみ。
                if let error {
                    resumeOnce(.failure(error))
                }
            }
            session.presentationContextProvider = self
            // アプリをまたいだ Cookie 共有を避ける(認可のたびにクリーンな状態から始めたいので)。
            session.prefersEphemeralWebBrowserSession = true
            self.webAuthSession = session

            guard session.start() else {
                resumeOnce(.failure(DelegateError.presentationFailed))
                return
            }
        }
    }

    /// `"GET /callback?code=...&state=... HTTP/1.1"` 形式のリクエストラインから
    /// 完全なリダイレクト URL(`http://127.0.0.1:<port>/callback?...`)を組み立てる。
    /// swift-sdk 側の `OAuthAuthorizationCodeFlow.extractCode` がスキーム/ホスト/ポート/パスを
    /// `authorizationRedirectURI` と突き合わせるため、ここで正確に再構成する必要がある。
    private static func redirectURL(fromRequestLine requestLine: String, listenerPort: UInt16)
        -> URL?
    {
        let components = requestLine.split(separator: " ")
        guard components.count >= 2 else { return nil }
        let pathAndQuery = String(components[1])
        return URL(string: "http://127.0.0.1:\(listenerPort)\(pathAndQuery)")
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

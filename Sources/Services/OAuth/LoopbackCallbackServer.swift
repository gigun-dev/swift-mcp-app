// OAuth 2.1 loopback リダイレクト(RFC 8252 §7.3)の受け口となる極小 HTTP サーバー。
//
// 【なぜ NWListener でなく BSD ソケットか(経緯・重要)】
// 当初は Network framework の NWListener で実装した(Features/OAuth/
// LoopbackOAuthAuthorizationDelegate.swift の旧実装)が、実機で
// POSIXErrorCode 22(EINVAL)により listener が .failed になった。
// ポート .any が原因と仮説を立てて明示ポート指定に直しても同じエラー。
// さらに macOS 上の最小再現で「素の NWListener(using: .tcp, on: 55556)」まで
// 全パターン EINVAL になる一方、**BSD ソケット直(socket/bind/listen)は成功**する
// ことを確認した(2026-07-15、docs/log.md)。NWListener の失敗原因は特定できて
// いないが、受け口は「127.0.0.1 で1リクエスト受けて 200 を返すだけ」なので、
// 最下層で動作実証済みの BSD ソケット + DispatchSourceRead に乗り換えるのが
// 確実と判断した。副産物として UIKit 非依存になり Services 層に置けるため、
// swift test で bind→GET→URL 復元の実挙動をテストできる(NWListener 版は
// Features 層にあり自動テスト不能だった)。
//
// 【スコープ外のこと】汎用 HTTP サーバーではない。コネクション1本・リクエスト1個・
// GET のリクエストラインだけ読めれば十分(OAuth のリダイレクトは単発の GET)。
// Keep-Alive・複数同時接続・POST ボディ等は意図的に扱わない。
import Foundation

/// 127.0.0.1 の一時ポートで OAuth コールバック(GET /callback?code=...)を
/// 1回だけ受け取り、リダイレクト URL を復元して返すサーバー。
///
/// 使い方: `start()` → 返った URL を `OAuthConfiguration.authorizationRedirectURI` に
/// 渡す → 認可画面をユーザーが完了すると `waitForCallback()` が URL を返す。
/// 1インスタンス1回使い切り(OAuth フロー1回と生存期間を揃える)。
public final class LoopbackCallbackServer: @unchecked Sendable {
    public enum ServerError: LocalizedError {
        case socketFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case malformedRequest
        case notStarted

        public var errorDescription: String? {
            switch self {
            case .socketFailed(let e): return "socket() に失敗しました(errno \(e))"
            case .bindFailed(let e): return "bind() に失敗しました(errno \(e))"
            case .listenFailed(let e): return "listen() に失敗しました(errno \(e))"
            case .malformedRequest: return "コールバックの HTTP リクエストを解釈できませんでした"
            case .notStarted: return "start() 前に waitForCallback() が呼ばれました"
            }
        }
    }

    private var listenFD: Int32 = -1
    private var acceptSource: (any DispatchSourceRead)?
    private let queue = DispatchQueue(label: "dev.gigun.mcphost.oauth-callback")
    private var port: UInt16 = 0
    // waitForCallback の continuation。accept ハンドラと cancel の二重 resume を防ぐため
    // queue 上でのみ触る。
    private var pendingContinuation: CheckedContinuation<URL, Error>?

    public init() {}

    /// 127.0.0.1 の空きポートで listen を開始し、リダイレクト URI を返す。
    /// ポートは bind(port=0)で OS に選ばせる(BSD レイヤではこれが普通に通る —
    /// NWListener の requiredLocalEndpoint が拒否した組み合わせも socket API では合法)。
    public func start() throws -> URL {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socketFailed(errno) }

        // close 直後の再起動で TIME_WAIT に阻まれないように。
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // 0 = OS にエフェメラルポートを選ばせる
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")  // loopback 以外からは到達不能に固定
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let e = errno
            close(fd)
            throw ServerError.bindFailed(e)
        }
        guard listen(fd, 1) == 0 else {
            let e = errno
            close(fd)
            throw ServerError.listenFailed(e)
        }

        // OS が選んだポートを取得
        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &len)
            }
        }
        port = UInt16(bigEndian: boundAddr.sin_port)
        listenFD = fd
        return URL(string: "http://127.0.0.1:\(port)/callback")!
    }

    /// コールバック(1リクエスト)を待ち、`http://127.0.0.1:<port><path?query>` を返す。
    /// swift-sdk の `OAuthAuthorizationCodeFlow.extractCode` がスキーム/ホスト/ポート/パスを
    /// `authorizationRedirectURI` と突き合わせるため、リクエストラインから正確に再構成する。
    public func waitForCallback() async throws -> URL {
        guard listenFD >= 0 else { throw ServerError.notStarted }

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                pendingContinuation = continuation
                let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
                acceptSource = source
                source.setEventHandler { [self] in
                    var clientAddr = sockaddr()
                    var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
                    let clientFD = accept(listenFD, &clientAddr, &clientLen)
                    guard clientFD >= 0 else { return }  // 次の readable イベントを待つ

                    // リクエストラインは単発 GET なので先頭 4KB で必ず収まる。
                    // (recv が 1 パケット目でリクエストライン全体を含む前提は、
                    // ローカルループバック + ブラウザの GET では実用上崩れない)
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    let n = recv(clientFD, &buffer, buffer.count, 0)
                    let requestLine =
                        n > 0
                        ? String(decoding: buffer[0..<n], as: UTF8.self)
                            .split(separator: "\r\n").first.map(String.init)
                        : nil

                    let redirectURL = requestLine.flatMap { line -> URL? in
                        let parts = line.split(separator: " ")
                        guard parts.count >= 2 else { return nil }
                        return URL(string: "http://127.0.0.1:\(port)\(parts[1])")
                    }

                    // ブラウザ(アプリ内シート)に完了を一言返す。応答を返さないと
                    // レンダラがハング表示になることがあるため、失敗時も 400 を返す。
                    let (status, body) =
                        redirectURL != nil
                        ? ("200 OK", "<html><body>MCPHost: 認可が完了しました。</body></html>")
                        : ("400 Bad Request", "<html><body>MCPHost: 不正なリクエストです。</body></html>")
                    let response =
                        "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    _ = response.withCString { send(clientFD, $0, strlen($0), 0) }
                    close(clientFD)

                    if let url = redirectURL {
                        finish(.success(url))
                    } else {
                        finish(.failure(ServerError.malformedRequest))
                    }
                }
                source.resume()
            }
        }
    }

    /// ユーザーが認可シートを手動で閉じた等、コールバックが来ないまま中断する場合の後始末。
    public func cancel(with error: Error) {
        queue.async { [self] in finish(.failure(error)) }
    }

    // queue 上でのみ呼ぶ。二重 resume 防止は pendingContinuation の nil 化で行う。
    private func finish(_ result: Result<URL, Error>) {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        switch result {
        case .success(let url): continuation.resume(returning: url)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    deinit {
        if listenFD >= 0 { close(listenFD) }
    }
}

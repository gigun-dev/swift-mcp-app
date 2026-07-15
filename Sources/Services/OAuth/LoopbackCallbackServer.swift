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
    // 【重要】コールバックが waitForCallback() の登録より先に届いた場合の保持箱。
    // caldav は承認済みクライアントの認可を対話なしで即時リダイレクトするため、
    // 認可 URL をシートが読み込んだ瞬間にコールバックが着弾し、アプリ側の
    // waitForCallback() 登録と競争になる(シミュレータで実際に発生:
    // 「start() 前に waitForCallback() が呼ばれました」という誤エラーに化けた。
    // docs/log.md 2026-07-15)。先着した結果はここに置き、後から来た
    // waitForCallback() が即座に受け取る。
    private var finishedResult: Result<URL, Error>?

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

        // 【重要】accept ループは start() 時点で起動する。初版は waitForCallback() の中で
        // 起動していたため、waitForCallback() 登録前に届いたリクエストが応答されないまま
        // ブラウザを 60 秒ハングさせる穴があった(テストが検出)。caldav は承認済み
        // クライアントの認可を対話なしで即時リダイレクトするので、この「先着」は
        // 理論上の話ではなく通常フローで起きる。
        queue.async { [self] in startAcceptLoop() }
        return URL(string: "http://127.0.0.1:\(port)/callback")!
    }

    // queue 上でのみ呼ぶ。listen ソケットの readable イベントごとに accept して
    // 1リクエストを処理する。正規コールバックを受けたら finish(.success) で全体を畳む。
    private func startAcceptLoop() {
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

            // 【重要】Safari/WebKit は本命リクエストの前に投機的な事前接続
            // (preconnect)を張ることがある。その接続はデータを送らずに
            // 閉じられる(recv が 0)。初版はこれを「不正リクエスト」として
            // サーバーごと畳んでいたため、直後に来る本命の GET が
            // 「サーバに接続できなかった」で死ぬシミュレータ障害になった
            // (docs/log.md 2026-07-15)。空・不正なコネクションはその1本だけ
            // 閉じて listen を継続し、サーバーを畳むのは正規コールバック受信
            // または明示キャンセルのときだけにする。
            guard n > 0 else {
                close(clientFD)
                return
            }

            let requestLine = String(decoding: buffer[0..<n], as: UTF8.self)
                .split(separator: "\r\n").first.map(String.init)
            let redirectURL = requestLine.flatMap { line -> URL? in
                let parts = line.split(separator: " ")
                guard parts.count >= 2 else { return nil }
                return URL(string: "http://127.0.0.1:\(port)\(parts[1])")
            }

            guard let url = redirectURL else {
                // 解釈不能なリクエスト(favicon 取得等の可能性もある)。
                // 400 を返してその接続だけ閉じ、本命を待ち続ける。
                let body = "<html><body>MCPHost: 不正なリクエストです。</body></html>"
                let response =
                    "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                _ = response.withCString { send(clientFD, $0, strlen($0), 0) }
                close(clientFD)
                return
            }

            // ブラウザ(アプリ内シート)に完了を一言返す。応答を返さないと
            // レンダラがハング表示になることがあるため明示的に 200 を返す。
            let body = "<html><body>MCPHost: 認可が完了しました。</body></html>"
            let response =
                "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            _ = response.withCString { send(clientFD, $0, strlen($0), 0) }
            close(clientFD)
            finish(.success(url))
        }
        source.resume()
    }

    /// コールバック(1リクエスト)を待ち、`http://127.0.0.1:<port><path?query>` を返す。
    /// swift-sdk の `OAuthAuthorizationCodeFlow.extractCode` がスキーム/ホスト/ポート/パスを
    /// `authorizationRedirectURI` と突き合わせるため、リクエストラインから正確に再構成する。
    public func waitForCallback() async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                // コールバック(または cancel)が先着していたら即座に返す(上記の競合対策)。
                if let result = finishedResult {
                    finishedResult = nil
                    switch result {
                    case .success(let url): continuation.resume(returning: url)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                    return
                }
                // start() 前に呼ばれた(コーディングエラー)場合のみのガード。
                guard listenFD >= 0 else {
                    continuation.resume(throwing: ServerError.notStarted)
                    return
                }
                pendingContinuation = continuation
            }
        }
    }

    /// ユーザーが認可シートを手動で閉じた等、コールバックが来ないまま中断する場合の後始末。
    /// こちらはサーバーごと畳む(以後の認可ラウンドは無い)。
    public func cancel(with error: Error) {
        queue.async { [self] in
            teardown()
            finish(.failure(error))
        }
    }

    // queue 上でのみ呼ぶ。二重 resume 防止は pendingContinuation の nil 化で行う。
    //
    // 【重要】成功時にサーバーを畳まない。swift-sdk(OAuthAuthorizer)は1回の接続の中で
    // 認可フローを複数回実行することがある(Streamable HTTP は POST と SSE GET の2経路が
    // それぞれ 401 を返しうる・トークン交換失敗時のリトライもある)。初版は1回目の
    // コールバックで listen ソケットまで閉じていたため、2回目の認可が
    // notStarted(「start() 前に waitForCallback() が呼ばれました」)に化けて失敗した
    // (シミュレータの caldav 認可で実際に発生 — docs/log.md 2026-07-15)。
    // リダイレクト URI(ポート込み)は OAuthConfiguration に固定で渡っているので、
    // 同じポートで listen し続けることが複数ラウンド対応の唯一の正解。
    // サーバーを畳むのは cancel(認可シートの手動クローズ等)と deinit のみ。
    private func finish(_ result: Result<URL, Error>) {
        guard let continuation = pendingContinuation else {
            // waitForCallback() がまだ登録されていない(即時リダイレクトで先着した)。
            // 結果を保持し、後から来る waitForCallback() に渡す。既に結果があれば
            // 最初の1件を優先(次の waitForCallback がまず先着分を消費する)。
            if finishedResult == nil { finishedResult = result }
            return
        }
        pendingContinuation = nil
        switch result {
        case .success(let url): continuation.resume(returning: url)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    // cancel・deinit 時のみサーバーを畳む(上記コメント参照)。queue 上でのみ呼ぶ。
    private func teardown() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
    }

    deinit {
        if listenFD >= 0 { close(listenFD) }
    }
}

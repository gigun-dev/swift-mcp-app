import Foundation
import MCP
import Testing

@testable import Services

// SDKはASにHTTPSを要求する。テスト専用の転送だけでHTTPS loopback URLを同portの
// HTTP fixtureへ写し、実TCPのdiscovery/DCR/token要求を測る。TLS品質はこの試験の対象外。
private class OAuthLoopbackProtocol: URLProtocol {
    private var forwardingTask: URLSessionDataTask?
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && request.url?.scheme == "https"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var forwarded = request
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.scheme = "http"
        forwarded.url = components.url
        forwarded.httpBody = Self.requestBody(request)
        forwardingTask = URLSession.shared.dataTask(with: forwarded) { [weak self] data, response, error in
            guard let self else { return }
            if let error { client?.urlProtocol(self, didFailWithError: error); return }
            guard let response = response as? HTTPURLResponse else { return }
            // SDKはresponse.urlも検査するので、schemeだけを広告URLへ戻す。
            let restored = HTTPURLResponse(
                url: request.url!, statusCode: response.statusCode, httpVersion: nil,
                headerFields: response.allHeaderFields as? [String: String])!
            client?.urlProtocol(self, didReceive: restored, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
        forwardingTask?.resume()
    }
    override func stopLoading() { forwardingTask?.cancel() }

    // OAuth回帰は他のLLM回帰のdirty helperへ依存させない。URLSessionの実配送は
    // httpBodyStreamの場合もあるため、bodyとstreamの双方をこのfixture内で扱う。
    private static func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

// 実Keychainの署名/entitlementの成否とOAuth reconnectの欠落を混同しない。
// 同一fileを別instanceから再読込して、メモリcacheだけで成功する抜け道を塞ぐ。
private final class OAuthFixtureStorage: TokenStorage, @unchecked Sendable {
    let file: URL
    init(file: URL) { self.file = file }
    func save(_ token: OAuthAccessToken) {
        do { try JSONEncoder().encode(token).write(to: file, options: .atomic) } catch { Issue.record(error) }
    }
    func load() -> OAuthAccessToken? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(OAuthAccessToken.self, from: data)
    }
    func clear() { try? FileManager.default.removeItem(at: file) }
}

private final class OAuthFixtureDelegate: OAuthAuthorizationDelegate, @unchecked Sendable {
    private(set) var calls = 0
    func presentAuthorizationURL(_ url: URL) async throws -> URL {
        calls += 1
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let state = query.first { $0.name == "state" }!.value!
        var redirect = URLComponents(string: "http://127.0.0.1/callback")!
        redirect.queryItems = [.init(name: "code", value: "fixture-code"), .init(name: "state", value: state)]
        return redirect.url!
    }
}

private final class OAuthFixtureServer {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oauth-reconnect-\(UUID())")
    let process = Process()
    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", Self.script, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
    func stop() {
        if process.isRunning { process.terminate() }
        // macOS 27のswift-testing workerでは終了済みProcessのwaitUntilExitがrunloop待ちに
        // 留まるため同期waitをしない。SIGTERMの既定handlerで所有fixtureだけを終了する。
        try? FileManager.default.removeItem(at: directory)
    }
    func endpoint() async throws -> URL {
        for _ in 0 ..< 100 {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("port")),
               let port = String(data: data, encoding: .utf8),
               let url = URL(string: "https://127.0.0.1:\(port)/mcp") { return url }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.fileReadNoSuchFile)
    }
    func observations() throws -> [[String: String]] {
        let data = try Data(contentsOf: directory.appendingPathComponent("observations"))
        return try JSONDecoder().decode([[String: String]].self, from: data)
    }
    // port0 / loopback / テスト生成文字列のみ。サーバーはclientIDを必須にして
    // caldavと同じinvalid_clientを返し、refreshとcodeの交換を区別する。
    private static let script = #"""
import http.server, json, pathlib, signal, sys, time, urllib.parse
signal.signal(signal.SIGTERM, signal.SIG_DFL)
root = pathlib.Path(sys.argv[1])
observations = []
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, status, value):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def record(self, value):
        observations.append(value)
        (root / 'observations').write_text(json.dumps(observations))
    def do_GET(self):
        base = 'https://127.0.0.1:' + str(self.server.server_port)
        self.record({'path': self.path})
        if 'oauth-protected-resource' in self.path:
            self.reply(200, {'resource': base + '/mcp', 'authorization_servers': [base]})
        else:
            self.reply(200, {'issuer': base, 'authorization_endpoint': base + '/authorize',
                            'token_endpoint': base + '/token', 'registration_endpoint': base + '/register',
                            'response_types_supported': ['code'], 'code_challenge_methods_supported': ['S256']})
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', 0))).decode()
        if self.path == '/register':
            self.record({'path': self.path})
            self.reply(201, {'client_id': 'registered-fixture', 'token_endpoint_auth_method': 'none'})
            return
        body = {k: v[0] for k, v in urllib.parse.parse_qs(raw, keep_blank_values=True).items()}
        self.record({'path': self.path, 'client_id': body.get('client_id', ''),
                     'grant_type': body.get('grant_type', '')})
        if not body.get('client_id'):
            self.reply(401, {'error': 'invalid_client'})
        elif (root / 'timeout').exists():
            time.sleep(1)
            self.reply(503, {'error': 'temporarily_unavailable'})
        elif (root / 'invalidgrant').exists():
            self.reply(400, {'error': 'invalid_grant'})
        elif (root / 'fail').exists():
            self.reply(503, {'error': 'temporarily_unavailable'})
        elif body.get('grant_type') == 'refresh_token':
            if body.get('client_id') != 'saved-fixture':
                self.reply(400, {'error': 'invalid_grant'})
            else:
                self.reply(200, {'access_token': 'access-refreshed', 'token_type': 'Bearer',
                                 'expires_in': 3600, 'refresh_token': 'refresh-rotated'})
        else:
            self.reply(200, {'access_token': 'access-initial', 'token_type': 'Bearer',
                             'expires_in': 3600, 'refresh_token': 'refresh-initial'})
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
(root / 'port').write_text(str(server.server_port))
(root / 'observations').write_text('[]')
server.serve_forever()
"""#
}

@Suite(.serialized)
struct OAuthReconnectRefreshTests {
    private func configuration(clientID: String, delegate: OAuthFixtureDelegate) -> OAuthConfiguration {
        .init(grantType: .authorizationCode, authentication: .none(clientID: clientID),
              authorizationRedirectURI: URL(string: "http://127.0.0.1/callback")!,
              authorizationDelegate: delegate, proactiveRefreshWindowSeconds: 300)
    }
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthLoopbackProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func seed(_ storage: OAuthFixtureStorage, expired: Bool) {
        storage.save(.init(
            value: "access-saved", tokenType: "Bearer", expiresAt: Date().addingTimeInterval(expired ? -1 : 3600),
            scopes: [], authorizationServer: nil, refreshToken: "refresh-saved", clientID: "saved-fixture"))
    }

    @Test("旧来の空clientIDでは再接続refreshがinvalid_clientとなり再認可する")
    func oldConfigurationReauthorizes() async throws {
        let server = try OAuthFixtureServer()
        defer { server.stop() }
        let endpoint = try await server.endpoint()
        let file = server.directory.appendingPathComponent("token")
        seed(OAuthFixtureStorage(file: file), expired: true)
        let storage = OAuthFixtureStorage(file: file)
        let delegate = OAuthFixtureDelegate()
        let authorizer = OAuthAuthorizer(
            configuration: configuration(clientID: "", delegate: delegate), tokenStorage: storage)
        let session = session()
        defer { session.invalidateAndCancel() }
        _ = try await authorizer.handleChallenge(
                statusCode: 401, headers: [:], endpoint: endpoint, session: session)
        let observations = try server.observations()
        #expect(observations.first { $0["grant_type"] == "refresh_token" }?["client_id"] == "")
        #expect(observations.contains { $0["path"] == "/register" })
        #expect(delegate.calls == 1)
    }

    @Test("新authorizerは永続storageのclientIDで更新しブラウザとDCRを呼ばない")
    func restoredClientRefreshesWithoutBrowser() async throws {
        let server = try OAuthFixtureServer()
        defer { server.stop() }
        let endpoint = try await server.endpoint()
        let file = server.directory.appendingPathComponent("token")
        seed(OAuthFixtureStorage(file: file), expired: true)
        let storage = OAuthFixtureStorage(file: file)
        let delegate = OAuthFixtureDelegate()
        let auth = MCPConnection.tokenEndpointAuthentication(storage: storage)
        let config = OAuthConfiguration(grantType: .authorizationCode, authentication: auth,
                                       authorizationDelegate: delegate)
        let authorizer = PreservingOAuthAuthorizer(configuration: config, store: OAuthTokenStore(storage: storage))
        let session = session()
        defer { session.invalidateAndCancel() }
        #expect(authorizer.authorizationHeader(for: endpoint) == nil)
        #expect(try await authorizer.handleChallenge(
            statusCode: 401, headers: [:], endpoint: endpoint, session: session))
        #expect(authorizer.authorizationHeader(for: endpoint) == "Bearer access-refreshed")
        let persisted = OAuthFixtureStorage(file: file).load()
        #expect(persisted?.refreshToken == "refresh-rotated")
        #expect(persisted?.clientID == "saved-fixture")
        #expect(delegate.calls == 0)
        let observations = try server.observations()
        #expect(observations.filter { $0["grant_type"] == "refresh_token" }.count == 1)
        #expect(observations.first { $0["grant_type"] == "refresh_token" }?["client_id"] == "saved-fixture")
        #expect(!observations.contains { $0["path"] == "/register" })
    }

    @Test("保存token不在は初回DCRと認可を維持する")
    func firstAuthorizationStillWorks() async throws {
        let server = try OAuthFixtureServer()
        defer { server.stop() }
        let endpoint = try await server.endpoint()
        let storage = OAuthFixtureStorage(file: server.directory.appendingPathComponent("token"))
        let delegate = OAuthFixtureDelegate()
        let config = OAuthConfiguration(grantType: .authorizationCode,
            authentication: MCPConnection.tokenEndpointAuthentication(storage: storage),
            authorizationRedirectURI: URL(string: "http://127.0.0.1/callback")!, authorizationDelegate: delegate)
        let authorizer = PreservingOAuthAuthorizer(configuration: config, store: OAuthTokenStore(storage: storage))
        let session = session()
        defer { session.invalidateAndCancel() }
        #expect(try await authorizer.handleChallenge(
            statusCode: 401, headers: [:], endpoint: endpoint, session: session))
        #expect(authorizer.authorizationHeader(for: endpoint) == "Bearer access-initial")
        #expect(delegate.calls == 1)
        #expect(try server.observations().contains { $0["path"] == "/register" })
    }

    @Test("有効tokenは再接続後も認可やrefreshせずヘッダへ載る")
    func validTokenDoesNotRefresh() async throws {
        let server = try OAuthFixtureServer()
        defer { server.stop() }
        let endpoint = try await server.endpoint()
        let file = server.directory.appendingPathComponent("token")
        seed(OAuthFixtureStorage(file: file), expired: false)
        let storage = OAuthFixtureStorage(file: file)
        let delegate = OAuthFixtureDelegate()
        let config = OAuthConfiguration(grantType: .authorizationCode,
            authentication: MCPConnection.tokenEndpointAuthentication(storage: storage),
            authorizationDelegate: delegate)
        let authorizer = PreservingOAuthAuthorizer(configuration: config, store: OAuthTokenStore(storage: storage))
        let session = session()
        defer { session.invalidateAndCancel() }
        try await authorizer.prepareAuthorization(for: endpoint, session: session)
        #expect(authorizer.authorizationHeader(for: endpoint) == "Bearer access-saved")
        #expect(try server.observations().isEmpty)
        #expect(delegate.calls == 0)
    }

    @Test("503の反応型refresh失敗後も旧refresh tokenを永続storageに保持する")
    func transientFailurePreservesToken() async throws {
        let server = try OAuthFixtureServer()
        defer { server.stop() }
        let endpoint = try await server.endpoint()
        try Data().write(to: server.directory.appendingPathComponent("fail"))
        let file = server.directory.appendingPathComponent("token")
        seed(OAuthFixtureStorage(file: file), expired: true)
        let storage = OAuthFixtureStorage(file: file)
        let delegate = OAuthFixtureDelegate()
        let config = OAuthConfiguration(grantType: .authorizationCode,
            authentication: MCPConnection.tokenEndpointAuthentication(storage: storage),
            authorizationDelegate: delegate)
        let authorizer = PreservingOAuthAuthorizer(configuration: config, store: OAuthTokenStore(storage: storage))
        let session = session()
        defer { session.invalidateAndCancel() }
        await #expect(throws: OAuthAuthorizationError.self) {
            _ = try await authorizer.handleChallenge(
                statusCode: 401, headers: [:], endpoint: endpoint, session: session)
        }
        #expect(delegate.calls == 0)
        #expect(OAuthFixtureStorage(file: file).load()?.refreshToken == "refresh-saved")
    }
    @Test("timeoutでも旧refresh tokenを保持し次の試行で更新できる")
    func timeoutPreservesTokenAndCanRetry() async throws {
        let server = try OAuthFixtureServer()
        defer { server.stop() }
        let endpoint = try await server.endpoint()
        let marker = server.directory.appendingPathComponent("timeout")
        try Data().write(to: marker)
        let file = server.directory.appendingPathComponent("token")
        seed(OAuthFixtureStorage(file: file), expired: true)
        let storage = OAuthFixtureStorage(file: file)
        let delegate = OAuthFixtureDelegate()
        let config = OAuthConfiguration(grantType: .authorizationCode,
            authentication: MCPConnection.tokenEndpointAuthentication(storage: storage),
            authorizationDelegate: delegate)
        let authorizer = PreservingOAuthAuthorizer(configuration: config, store: OAuthTokenStore(storage: storage))
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [OAuthLoopbackProtocol.self]
        settings.timeoutIntervalForRequest = 0.1
        settings.timeoutIntervalForResource = 0.2
        let timedSession = URLSession(configuration: settings)
        defer { timedSession.invalidateAndCancel() }
        await #expect(throws: URLError.self) {
            _ = try await authorizer.handleChallenge(
                statusCode: 401, headers: [:], endpoint: endpoint, session: timedSession)
        }
        #expect(OAuthFixtureStorage(file: file).load()?.refreshToken == "refresh-saved")
        #expect(delegate.calls == 0)
        try FileManager.default.removeItem(at: marker)
        let retrySession = session()
        defer { retrySession.invalidateAndCancel() }
        #expect(try await authorizer.handleChallenge(
            statusCode: 401, headers: [:], endpoint: endpoint, session: retrySession))
        #expect(OAuthFixtureStorage(file: file).load()?.refreshToken == "refresh-rotated")
    }

    @Test("真正invalid_grantは旧tokenを削除し確立済み接続を再認可へ戻す")
    func invalidGrantCommitsClear() async throws {
        let server = try OAuthFixtureServer()
        defer { server.stop() }
        let endpoint = try await server.endpoint()
        try Data().write(to: server.directory.appendingPathComponent("invalidgrant"))
        let file = server.directory.appendingPathComponent("token")
        seed(OAuthFixtureStorage(file: file), expired: true)
        let storage = OAuthFixtureStorage(file: file)
        let delegate = OAuthFixtureDelegate()
        let gate = ReauthorizationGateDelegate(wrapping: delegate)
        gate.markEstablished()
        let config = OAuthConfiguration(grantType: .authorizationCode,
            authentication: MCPConnection.tokenEndpointAuthentication(storage: storage), authorizationDelegate: gate)
        let authorizer = PreservingOAuthAuthorizer(configuration: config, store: OAuthTokenStore(storage: storage))
        let session = session()
        defer { session.invalidateAndCancel() }
        await #expect(throws: ReauthorizationGateDelegate.ReauthorizationRequired.self) {
            _ = try await authorizer.handleChallenge(
                statusCode: 401, headers: [:], endpoint: endpoint, session: session)
        }
        #expect(gate.didRequestReauthorization)
        #expect(delegate.calls == 0)
        #expect(OAuthFixtureStorage(file: file).load() == nil)
    }
}

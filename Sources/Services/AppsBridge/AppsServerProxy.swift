// View→サーバーの素通しプロキシ + UI リソース(ui:// HTML)の発見・取得・キャッシュ(設計 §4)。
//
// このファイルの責務は「ブリッジが caldav 非依存で任意の MCP Apps サーバーを相手にできる」
// 中立性を保ったまま、swift-sdk の `Client`(actor)を次の3つの用途に薄く包むこと:
//
//  1. **UI リソース URI の解決**(発見): tools/list の各ツールの `_meta.ui.resourceUri`
//     (新形式)→ `_meta["ui/resourceUri"]`(後方互換)の順で ui:// URI を引く。
//     出典: ext-apps `src/app-bridge.ts:126-133 getToolUiResourceUri`。caldav は両キーを
//     併記する(server.ts:1389 のコメント「_meta の2キー併記」)。
//  2. **resources/read 素通し + HTML プリフェッチ**: ui:// を読み、mimeType が
//     `text/html;profile=mcp-app`(MUST・apps.mdx:268)であることを検証して HTML を得る。
//     結果は接続(= このプロキシ1インスタンス)単位でキャッシュする(同じ URI を 9 ツールが
//     共有する — server.ts。無効化は接続破棄=プロキシ破棄時のみ)。
//  3. **tools/call 素通し**: View が送った tools/call をそのままサーバーへ流し、
//     `CallToolResult` を **ロスレスに** JSON へ戻す(structuredContent の未知フィールドや
//     _meta を落とさない — 設計 §3 のロスレス要件)。
//
// なぜ actor か: `Client` が actor なので await 境界が必ず入る。キャッシュ dict への
// 競合アクセスを避けるためプロキシ自身も actor にして、キャッシュ更新を直列化する。
import Foundation
import OSLog
import MCP
import Kernel

/// 発見〜取得〜素通しをまとめた、接続1本ぶんのサーバープロキシ。
///
/// caldav 固有の知識は持たない(ツール名も structuredContent の形も知らない)。
/// 知っているのは ext-apps の `_meta.ui.resourceUri` 契約と `text/html;profile=mcp-app` だけ。
public actor AppsServerProxy {
    /// ext-apps が MCP App の HTML に要求する MIME(MUST・apps.mdx:268)。
    /// これ以外の mimeType のリソースは「MCP App ではない」ものとして扱い、ロードしない。
    public static let appHTMLMimeType = "text/html;profile=mcp-app"

    private let client: Client
    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "appsproxy")

    // ui:// リソースの接続内キャッシュ。key=uri。値は取得済み HTML と content-level の
    // `_meta.ui`(あれば)。同一 URI を list-todos / complete-todo など複数ツールが共有するため、
    // 2枚目以降のカードは resources/read を省ける。無効化はプロキシ破棄(=接続破棄)時のみ。
    private var htmlCache: [String: (html: String, uiMeta: JSONValue?)] = [:]

    public init(client: Client) {
        self.client = client
    }

    // MARK: - 発見: tools/list から ui:// URI を解決

    /// 指定ツールの UI リソース URI を `_meta` から解決する(設計 §4・app-bridge.ts:126-133)。
    ///
    /// nonisolated + 純粋: 引数の `Tool`(tools/list の結果)だけを見るので actor 状態に触れない。
    /// 新形式 `_meta.ui.resourceUri` を優先し、無ければ後方互換キー `_meta["ui/resourceUri"]`。
    /// どちらも無ければ nil(= このツールは UI を持たない)。
    public nonisolated func resolveUIResourceURI(for tool: Tool) -> String? {
        guard let meta = tool._meta else { return nil }
        // 新形式: _meta.ui.resourceUri。ui はネストしたオブジェクト。
        if let uiObject = meta["ui"]?.objectValue,
           let uri = uiObject["resourceUri"]?.stringValue {
            return uri
        }
        // 後方互換: フラットキー _meta["ui/resourceUri"]。caldav は両方を併記するので
        // 通常は上で取れるが、他サーバー互換のためフォールバックを残す。
        if let uri = meta["ui/resourceUri"]?.stringValue {
            return uri
        }
        return nil
    }

    /// tools 一覧から名前でツールを引き、その UI リソース URI を返す薄いヘルパ。
    public nonisolated func resolveUIResourceURI(in tools: [Tool], toolName: String) -> String? {
        guard let tool = tools.first(where: { $0.name == toolName }) else { return nil }
        return resolveUIResourceURI(for: tool)
    }

    // MARK: - HTML プリフェッチ(resources/read + mimeType 検証 + キャッシュ)

    /// ui:// リソースを読み、HTML 本体を返す(検証・キャッシュ込み・設計 §4)。
    ///
    /// - mimeType が `text/html;profile=mcp-app` でない content は MCP App ではないので弾く。
    /// - content-level の `_meta.ui`(あれば)も一緒に返す(listing-level フォールバックは
    ///   スパイクでは扱わない — caldav は content 側にも同じ _meta.ui を載せる)。
    /// - 2回目以降は htmlCache から即返す。
    public func fetchAppHTML(uri: String) async throws -> (html: String, uiMeta: JSONValue?) {
        if let cached = htmlCache[uri] {
            logger.notice("ui:// キャッシュヒット uri=\(uri, privacy: .public)")
            return cached
        }

        logger.notice("resources/read 開始 uri=\(uri, privacy: .public)")
        // swift-sdk の readResource は result-level の _meta を落とす(contents だけ返す)が、
        // content-level の _meta は Resource.Content._meta として保持される。MCP App の
        // _meta.ui は content 側に載る契約(caldav server.ts の read ハンドラ)なので実用上十分。
        let contents = try await client.readResource(uri: uri)

        // text かつ mimeType が MCP App の HTML であるものを探す。
        guard let htmlContent = contents.first(where: {
            $0.mimeType == Self.appHTMLMimeType && $0.text != nil
        }), let html = htmlContent.text else {
            // mimeType 不一致 = MUST 違反。設計 §4 のとおり「MCP App ではない」として弾く。
            let mimes = contents.map { $0.mimeType ?? "nil" }.joined(separator: ",")
            throw AppsServerProxyError.invalidAppMimeType(uri: uri, found: mimes)
        }

        // content-level の _meta を JSONValue に落として持ち帰る(prefersBorder 等は将来使う)。
        let uiMeta = try htmlContent._meta.map { try JSONValue(encoding: $0.fields)["ui"] } ?? nil
        let entry = (html: html, uiMeta: uiMeta)
        htmlCache[uri] = entry
        logger.notice("resources/read 完了 uri=\(uri, privacy: .public) htmlBytes=\(html.utf8.count)")
        return entry
    }

    // MARK: - tools/call 素通し(ロスレス)

    /// ツールを名前+引数で呼び、`CallToolResult` を **JSON へロスレス変換**して返す(設計 §3)。
    ///
    /// swift-sdk には2つの `callTool` オーバーロードがある:
    ///  - `(content:isError:)` タプル版 → **structuredContent と _meta を落とす**ので使えない。
    ///  - `RequestContext<CallTool.Result>` 版 → 完全な `Result`(content/structuredContent/
    ///    isError/_meta 全部)が取れる。todos カードは structuredContent を丸ごと欲しがる
    ///    (todos-entry.ts:2333 applyStructuredContent)ので、必ずこちらを使う。
    ///
    /// オーバーロード解決は戻り値型注釈(`RequestContext<CallTool.Result>`)で強制する
    /// (`await client.callTool(...)` はタプル版とも一致しうるため、型注釈が無いと曖昧)。
    public func callTool(name: String, arguments: JSONValue?) async throws -> JSONValue {
        // JSONValue の arguments(object)を swift-sdk の [String: Value] へ橋渡し。
        // JSON を1往復させるだけ(ホットパスではない)。MCP.Value は data URL に見える文字列を
        // .data 種別へ寄せる自動変換を持つ(Value.swift:98-104)が、todos の引数(id 文字列等)に
        // data URL は現れないので実害なし。もし将来 data URL 文字列を引数に流す契約が出たら
        // ここが化ける可能性がある(設計 §3 のロスレス懸念の残り火。P3 で send() 直叩きに寄せる)。
        let mcpArguments = try mcpArguments(from: arguments)

        logger.notice("tools/call 素通し name=\(name, privacy: .public)")
        let context: RequestContext<CallTool.Result> =
            try await client.callTool(name: name, arguments: mcpArguments)
        let result = try await context.value

        // CallTool.Result(Codable)を JSON へ。structuredContent/_meta を落とさない。
        return try JSONValue(encoding: result)
    }

    /// JSON-RPC の tools/call params({name, arguments})をパースして callTool を呼ぶ素通し口。
    /// View から届いた passthrough リクエストの params をそのまま渡す。
    public func passthroughToolsCall(params: JSONValue?) async throws -> JSONValue {
        guard let name = params?["name"]?.stringValue else {
            throw AppsServerProxyError.missingField("tools/call params.name")
        }
        return try await callTool(name: name, arguments: params?["arguments"])
    }

    // MARK: - resources/read 素通し

    /// JSON-RPC の resources/read params({uri})をパースして読む素通し口。
    /// 返すのは `{ "contents": [...] }` 形の JSON(View の readServerResource が期待する CallResult 形)。
    /// mimeType 検証はしない(素通しなので任意リソースを許す。HTML 検証は fetchAppHTML の役目)。
    public func passthroughResourcesRead(params: JSONValue?) async throws -> JSONValue {
        guard let uri = params?["uri"]?.stringValue else {
            throw AppsServerProxyError.missingField("resources/read params.uri")
        }
        logger.notice("resources/read 素通し uri=\(uri, privacy: .public)")
        let contents = try await client.readResource(uri: uri)
        // ReadResource.Result 相当({contents:[...]})を組み立てる。swift-sdk が落とす
        // result-level _meta はスパイクでは使わないので省略(View 側も content で足りる)。
        let contentsJSON = try contents.map { try JSONValue(encoding: $0) }
        return .object(["contents": .array(contentsJSON)])
    }

    // MARK: - 内部ヘルパ

    /// JSONValue(arguments オブジェクト)→ swift-sdk の [String: Value]? 変換。
    private func mcpArguments(from arguments: JSONValue?) throws -> [String: Value]? {
        guard let arguments else { return nil }
        guard case .object = arguments else {
            // arguments は object 以外を取らない契約(tools/call の arguments は Record)。
            throw AppsServerProxyError.missingField("tools/call arguments は object でなければならない")
        }
        let data = try JSONEncoder().encode(arguments)
        return try JSONDecoder().decode([String: Value].self, from: data)
    }
}

/// プロキシ層のエラー。すべて「サーバー応答/View 入力が契約から外れた」ことを表す。
public enum AppsServerProxyError: Error, CustomStringConvertible {
    case invalidAppMimeType(uri: String, found: String)
    case missingField(String)

    public var description: String {
        switch self {
        case let .invalidAppMimeType(uri, found):
            return "ui:// リソース \(uri) が MCP App の mimeType(\(AppsServerProxy.appHTMLMimeType))を持たない(found=\(found))"
        case let .missingField(field):
            return "必須フィールド欠落: \(field)"
        }
    }
}

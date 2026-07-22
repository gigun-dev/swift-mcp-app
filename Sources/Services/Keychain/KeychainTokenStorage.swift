// swift-sdk の `TokenStorage` プロトコル(Base/Authorization/TokenStorage.swift)を
// iOS Keychain(kSecClassGenericPassword)で実装する。
//
// なぜ Keychain か: `InMemoryTokenStorage`(SDK 既定)はプロセス終了で失効するため、
// アプリを再起動するたびに毎回ブラウザでの認可(DCR→authorize→token)をやり直すことになる。
// 「繋がった」を毎回作り直さず維持するのが P1 マイルストーンの実用上の前提。
//
// 汎用ホストとしての中立性(CLAUDE.md ビジョン2): このアプリは caldav 専用クライアントではなく
// 「任意の MCP サーバーに繋がる汎用ホスト」を目指す(docs/next-directions.md 路線B)。
// 将来複数サーバーに同時接続する可能性を見込み、Keychain のアカウント(kSecAttrAccount)に
// サーバーのエンドポイント URL を刻んで複数サーバー分のトークンを共存させられるようにする
// (今回接続するのは caldav 本番1台のみだが、この型自体には caldav 固有の知識を持たせない)。
//
// `OAuthAccessToken`(swift-sdk Base/Authorization/OAuthModels.swift)はそれ自体 Codable
// 準拠なので、独自の写し型を介さずそのまま JSON エンコード/デコードして Keychain の
// value データに詰める(SDK 型を signature で公開してしまうが、TokenStorage プロトコル自体が
// 既に SDK 型 `OAuthAccessToken` を要求しているのでここでの追加の結合は無い)。
import Foundation
import MCP
import OSLog
import Security

/// swift-sdk の `TokenStorage` を Keychain で実装したもの。
/// `OAuthAuthorizer(tokenStorage:)` に渡すことで、取得したアクセストークン/リフレッシュトークンを
/// Keychain に永続化する(SDK デフォルトの `InMemoryTokenStorage` はメモリのみ・プロセス終了で消える)。
public final class KeychainTokenStorage: TokenStorage, @unchecked Sendable {
    // Keychain のサービス名(kSecAttrService)。バンドル ID を接頭辞にして
    // 同一デバイス上の他アプリの Keychain 項目と衝突しないようにする。
    private let service: String

    // Keychain のアカウント名(kSecAttrAccount)。接続先サーバーの URL をそのまま使う ——
    // 複数の MCP サーバーに接続する将来(汎用ホスト方針)を見込み、サーバーごとに
    // トークンを分離して保存できるようにするための最小限のキー設計。
    private let account: String

    /// - Parameters:
    ///   - serverURL: 接続先 MCP サーバーのエンドポイント URL。このインスタンスが保存/読込する
    ///     トークンはこの URL に紐づく(同じ Keychain サービス内で複数サーバー分を account で書き分ける)。
    ///   - bundleIdentifier: kSecAttrService の接頭辞。project.yml の
    ///     PRODUCT_BUNDLE_IDENTIFIER と同じ値を既定にしている。
    // 【重要】メモリ上のトークンを一次層にし、Keychain は「再起動をまたぐ永続化」の
    // ベストエフォート層に格下げする。
    // 経緯: シミュレータの無署名ビルド(make app の CODE_SIGNING_ALLOWED=NO)では
    // SecItemAdd が entitlement エラーで失敗する。初版は SecItemAdd の結果を
    // 握りつぶしていたため、保存が無言で失敗 → load() が常に nil → swift-sdk は
    // トークン無しで /mcp を叩く → 401 → 再認可…の無限ループになった
    // (トークン交換自体は毎回 200 — curl 再現と Workers ログで裏取り済み。
    // 実機は署名済みで Keychain が動くため発症しなかった。docs/log.md 2026-07-15)。
    // メモリ層があれば Keychain が死んでいても「そのプロセス内の接続」は成立する。
    private var cachedToken: OAuthAccessToken?
    private let cacheLock = NSLock()
    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "keychain")

    public init(serverURL: URL, bundleIdentifier: String = "dev.gigun.mcphost") {
        self.service = "\(bundleIdentifier).oauth-token"
        self.account = serverURL.absoluteString
    }

    public func save(_ token: OAuthAccessToken) {
        cacheLock.lock()
        cachedToken = token
        cacheLock.unlock()

        guard let data = try? JSONEncoder().encode(token) else { return }

        // Keychain には「upsert」API が無いため、SecItemUpdate を先に試し、
        // 項目が無ければ(errSecItemNotFound)SecItemAdd にフォールバックする定型パターン。
        let query = baseQuery()
        let updateStatus = SecItemUpdate(
            query as CFDictionary, [kSecValueData: data] as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            // バックグラウンドでの OAuth リフレッシュ(prepareAuthorization)がデバイスロック中にも
            // 走り得るため、端末アンロック後にのみアクセス可にする属性(afterFirstUnlock)を指定。
            // thisDeviceOnly を付けて iCloud Keychain 同期対象外にする
            // (トークンは端末固有の認可なので同期は不要・むしろ避けたい)。
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                // 失敗しても致命ではない(メモリ層で接続は成立する)が、
                // 「再起動したら再認可になる」症状の手がかりとしてログに残す。
                logger.notice("Keychain 保存失敗(status \(addStatus)): 永続化なしで続行")
            }
        } else if updateStatus != errSecSuccess {
            logger.notice("Keychain 更新失敗(status \(updateStatus)): 永続化なしで続行")
        }
    }

    public func load() -> OAuthAccessToken? {
        cacheLock.lock()
        let cached = cachedToken
        cacheLock.unlock()
        if let cached { return cached }

        var query = baseQuery()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthAccessToken.self, from: data)
    }

    public func clear() {
        cacheLock.lock()
        cachedToken = nil
        cacheLock.unlock()
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }
}

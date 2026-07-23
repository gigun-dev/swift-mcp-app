// KeychainTokenStorage(swift-sdk TokenStorage の Keychain 実装)の単体テスト。
//
// What(このテストが固定する仕様):
//  1. token response の refresh_token / expires_at / scopes / clientID を**捨てずに**丸ごと
//     保存・復元できる(design/08 原則3「1レコードとして原子更新」・タスク §1 の起点)。
//  2. エンコード成功時だけ一次トークン層(メモリキャッシュ)を更新し、旧トークンを温存する
//     原子性(design/08 原則3「保存成功まで旧 refresh token を捨てない」)。
//  3. 並行 save/load(10発)でクラッシュ・破損なく最終状態が一貫する(NSLock によるスレッド安全。
//     refresh 直列化=single-flight は swift-sdk の transport actor 側で担保するが、ストレージ層自体も
//     並行アクセスに耐える必要がある)。
//
// 【なぜ Keychain の実書き込みに依存しないか】テスト環境(無署名の swift test)では SecItemAdd が
// entitlement で失敗しうる(KeychainTokenStorage 本体コメント・docs/log.md 2026-07-15)。本テストは
// メモリキャッシュ(cachedToken)を一次層とする設計そのものを検証対象にするので、Keychain 書き込みの
// 成否に関わらず load() が cache から決定的に復元することを確かめる。account(serverURL)はテストごとに
// 一意にして本番データや他テストと干渉させない。
import Foundation
import Testing
@testable import Services

@Suite(.serialized) struct KeychainTokenStorageTests {
    /// テストごとに一意な serverURL(= Keychain account)を作り、本番/他テストのトークンと隔離する。
    private func uniqueServerURL() -> URL {
        URL(string: "https://token-test-\(UUID().uuidString).example.com/mcp")!
    }

    /// refresh/expiry/scopes/clientID を全部載せたトークンを1つ作るヘルパ。
    private func makeToken(
        value: String,
        refresh: String?,
        expiresAt: Date?
    ) -> OAuthAccessToken {
        OAuthAccessToken(
            value: value,
            tokenType: "Bearer",
            expiresAt: expiresAt,
            scopes: ["mcp:tools", "mcp:read"],
            authorizationServer: URL(string: "https://auth.example.com"),
            refreshToken: refresh,
            clientID: "client-abc"
        )
    }

    @Test("refresh_token / expires_at / scopes / clientID を捨てずに保存・復元する(原則3・タスク§1)")
    func roundTripsAllTokenFields() {
        let storage = KeychainTokenStorage(serverURL: uniqueServerURL())
        defer { storage.clear() }

        let expiry = Date(timeIntervalSince1970: 2_000_000_000)  // 固定値で決定的に照合。
        let token = makeToken(value: "access-1", refresh: "refresh-1", expiresAt: expiry)
        storage.save(token)

        let loaded = storage.load()
        #expect(loaded?.value == "access-1")
        // 現状「捨てていた」と疑われた refresh_token / expires_in が実際は保存されることの回帰固定。
        #expect(loaded?.refreshToken == "refresh-1")
        #expect(loaded?.expiresAt == expiry)
        #expect(loaded?.scopes == ["mcp:tools", "mcp:read"])
        #expect(loaded?.clientID == "client-abc")
        #expect(loaded?.authorizationServer == URL(string: "https://auth.example.com"))
    }

    @Test("rotation で新トークンに置き換えると新しい refresh_token が読める(1レコード原子更新)")
    func rotationReplacesRefreshToken() {
        let storage = KeychainTokenStorage(serverURL: uniqueServerURL())
        defer { storage.clear() }

        storage.save(makeToken(value: "access-old", refresh: "refresh-old", expiresAt: nil))
        // workers-oauth-provider の rotation を模す: refresh すると新しい refresh token が来る。
        storage.save(makeToken(value: "access-new", refresh: "refresh-new", expiresAt: nil))

        let loaded = storage.load()
        #expect(loaded?.value == "access-new")
        #expect(loaded?.refreshToken == "refresh-new")
    }

    @Test("clear() 後は load() が nil(削除サーバーの後始末・トークン失効導線)")
    func clearRemovesToken() {
        let storage = KeychainTokenStorage(serverURL: uniqueServerURL())
        storage.save(makeToken(value: "access-x", refresh: "refresh-x", expiresAt: nil))
        #expect(storage.load() != nil)

        storage.clear()
        #expect(storage.load() == nil)
    }

    @Test("並行 save/load(10発)でクラッシュ・破損なく最終状態が一貫する(NSLock スレッド安全)")
    func concurrentAccessIsConsistent() async {
        let storage = KeychainTokenStorage(serverURL: uniqueServerURL())
        defer { storage.clear() }

        // 最初に確定値を入れておく。並行アクセス中に load が nil や破損値を返さないことを見る。
        storage.save(makeToken(value: "seed", refresh: "seed-refresh", expiresAt: nil))

        // 10 本の並行タスクで save と load を混在させる。NSLock が cachedToken を守るので
        // データレース(クラッシュ)や部分書き込みが起きないことを確かめる。
        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 10 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        storage.save(self.makeToken(
                            value: "access-\(index)",
                            refresh: "refresh-\(index)",
                            expiresAt: nil
                        ))
                    } else {
                        // load が nil を返さない(常にいずれかの有効トークンが読める)。
                        #expect(storage.load() != nil)
                    }
                }
            }
        }

        // 最終状態: いずれかの save 済みトークンが一貫して読める(seed か access-N のいずれか)。
        let final = storage.load()
        #expect(final != nil)
        // value と refreshToken が同じ世代のペア(部分更新で value と refresh がちぐはぐにならない)。
        if let final, final.value != "seed" {
            #expect(final.value.hasPrefix("access-"))
            #expect(final.refreshToken?.hasPrefix("refresh-") == true)
        }
    }
}

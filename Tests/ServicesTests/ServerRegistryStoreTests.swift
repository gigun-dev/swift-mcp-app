// ServerRegistryStore(MCP サーバー登録簿・M1)の単体テスト。
//
// 使い捨ての UserDefaults suite を注入して本番の .standard を汚さず検証する
// (ChatStore が baseDirectory を注入して一時ディレクトリで回すのと同流儀の
// 「テスト可能性のために外部リソースを注入で切り離す」パターン)。
// swift-sdk・OAuth・ネットワークは一切使わない(UserDefaults の read/write のみ)。
//
// @MainActor: ServerRegistryStore は @MainActor なのでテストも合わせる。
// .serialized: 同一 suiteName を再利用しないよう毎テスト UUID で分けるので競合はしないが、
// 他の Services テスト群(ChatViewModelTests 等)の直列方針に揃えておく(保守的)。
import Foundation
import Testing
@testable import Services

@Suite(.serialized) @MainActor struct ServerRegistryStoreTests {
    /// テストごとに使い捨ての UserDefaults を作る(前後テストの状態を持ち越さない)。
    /// suiteName にランダム UUID を使い、defer で removePersistentDomain して後始末する。
    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "ServerRegistryStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, suiteName)
    }

    @Test("初回(キー未存在)は caldav 本番を1件シードし、既定は有効")
    func firstLaunchSeedsCaldav() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ServerRegistryStore(defaults: defaults)
        #expect(store.servers.count == 1)
        #expect(store.servers[0].name == ServerRegistryStore.caldavSeedName)
        #expect(store.servers[0].url.absoluteString == ServerRegistryStore.caldavSeedURLString)
        // シードは有効(起動時の無言接続対象になる)。
        #expect(store.servers[0].enabled)
        #expect(store.enabledServers.count == 1)
    }

    @Test("シード後に永続化され、別インスタンスで復元される(再シードされない)")
    func seedIsPersistedAndRestored() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = ServerRegistryStore(defaults: defaults)
        let seededID = first.servers[0].id

        // 別インスタンス(= アプリ再起動相当)。同じ id が復元される = 再シードで別 id にならない。
        let second = ServerRegistryStore(defaults: defaults)
        #expect(second.servers.count == 1)
        #expect(second.servers[0].id == seededID)
    }

    @Test("add はエントリを追加し(有効で入る)、永続化する")
    func addAppendsAndPersists() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ServerRegistryStore(defaults: defaults)
        let added = store.add(name: "local", url: URL(string: "https://example.com/mcp")!)
        #expect(store.servers.count == 2)
        #expect(added.enabled)  // 追加は有効で入る(すぐ接続を試みる)。

        // 永続化の確認: 別インスタンスで2件とも復元される。
        let restored = ServerRegistryStore(defaults: defaults)
        #expect(restored.servers.count == 2)
        #expect(restored.servers.contains(added))
    }

    @Test("setEnabled で有効/無効を切り替え、enabledServers に反映・永続化される")
    func setEnabledTogglesAndPersists() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ServerRegistryStore(defaults: defaults)
        let id = store.servers[0].id
        store.setEnabled(id: id, enabled: false)
        #expect(store.servers[0].enabled == false)
        #expect(store.enabledServers.isEmpty)

        // 別インスタンスでも無効のまま復元される。
        let restored = ServerRegistryStore(defaults: defaults)
        #expect(restored.servers[0].enabled == false)
    }

    @Test("enabled キーの無い旧 JSON は有効(true)にデコードされる(後方互換)")
    func legacyServersDecodeEnabledTrue() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        // enabled キーを持たない旧スキーマの JSON を直接書き込む。
        let id = UUID().uuidString
        let legacy = """
        [{"id":"\(id)","name":"legacy","url":"https://legacy.example.com/mcp"}]
        """
        defaults.set(Data(legacy.utf8), forKey: "mcp.servers.v1")

        let store = ServerRegistryStore(defaults: defaults)
        #expect(store.servers.count == 1)
        #expect(store.servers[0].name == "legacy")
        #expect(store.servers[0].enabled)  // 無ければ有効。
    }

    @Test("update は id 不変で name/URL を書き換える")
    func updateRenamesKeepingID() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ServerRegistryStore(defaults: defaults)
        let id = store.servers[0].id
        store.update(id: id, name: "renamed", url: URL(string: "https://new.example.com/mcp")!)
        #expect(store.servers[0].id == id)  // id は不変。
        #expect(store.servers[0].name == "renamed")
        #expect(store.servers[0].url.absoluteString == "https://new.example.com/mcp")
    }

    @Test("remove は一覧から消し、永続化する。トークン後始末は呼ばれても落ちない")
    func removeDropsEntry() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ServerRegistryStore(defaults: defaults)
        let seedID = store.servers[0].id
        let second = store.add(name: "b", url: URL(string: "https://b.example.com/mcp")!)
        store.remove(id: second.id)
        #expect(store.servers.count == 1)
        #expect(store.servers[0].id == seedID)

        // 永続化の確認(削除が別インスタンスにも反映)。
        let restored = ServerRegistryStore(defaults: defaults)
        #expect(restored.servers.count == 1)
        #expect(restored.servers[0].id == seedID)
    }

    @Test("全削除すると servers は空になり、別インスタンスでも空のまま(再シードしない)")
    func removeAllEmpties() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ServerRegistryStore(defaults: defaults)
        for entry in store.servers { store.remove(id: entry.id) }
        #expect(store.servers.isEmpty)

        // 永続化: 別インスタンスでも空のまま(空一覧は再シードしない ——
        // ユーザーが意図して全消しした状態を尊重する。キー未存在=初回のみ再シード)。
        let restored = ServerRegistryStore(defaults: defaults)
        #expect(restored.servers.isEmpty)
    }

    @Test("壊れた servers JSON は caldav シードで復旧する(空で固めない)")
    func corruptedServersRecoversToSeed() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        // 壊れた JSON を直接書き込む(キーは存在するがデコード不能)。
        defaults.set(Data("{ not valid json".utf8), forKey: "mcp.servers.v1")

        let store = ServerRegistryStore(defaults: defaults)
        #expect(store.servers.count == 1)
        #expect(store.servers[0].name == ServerRegistryStore.caldavSeedName)
    }
}

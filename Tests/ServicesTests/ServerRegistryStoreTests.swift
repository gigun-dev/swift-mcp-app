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

    @Test("同一 URL を2回 add しても件数は増えず、返る id が同一(冪等 add)")
    func addIsIdempotentForSameURL() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ServerRegistryStore(defaults: defaults)
        let url = URL(string: "https://example.com/mcp")!
        let first = store.add(name: "local", url: url)
        let second = store.add(name: "local", url: url)
        // シード(caldav)1件 + local 1件 = 2件のまま(2回目は再利用)。
        #expect(store.servers.count == 2)
        #expect(first.id == second.id)
    }

    @Test("末尾スラッシュ/host 大文字違いの同一 canonical URL は既存を再利用し、url 文字列は最初のものを温存する")
    func addReusesOnCanonicalMatchAndPreservesURLString() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ServerRegistryStore(defaults: defaults)
        // 最初に登録する url 文字列(この文字列が温存される ——Keychain キー/provenance 厳密等価のため)。
        let first = store.add(name: "local", url: URL(string: "https://example.com/mcp")!)
        // 末尾スラッシュ + host 大文字違い = canonical 一致。
        let reused = store.add(name: "local", url: URL(string: "https://Example.com/mcp/")!)

        #expect(store.servers.count == 2)  // シード + local(増えない)。
        #expect(reused.id == first.id)
        // url 文字列は最初のものが温存され、2回目の(スラッシュ付き・大文字)では上書きされない。
        #expect(reused.url.absoluteString == "https://example.com/mcp")
    }

    @Test("別 URL を add すると新規追加される")
    func addAppendsForDifferentURL() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ServerRegistryStore(defaults: defaults)
        store.add(name: "a", url: URL(string: "https://a.example.com/mcp")!)
        store.add(name: "b", url: URL(string: "https://b.example.com/mcp")!)
        // シード + a + b = 3件。
        #expect(store.servers.count == 3)
    }

    @Test("無効化したサーバーを同一 URL で再 add すると enabled が true に戻る")
    func reAddReenablesDisabledServer() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ServerRegistryStore(defaults: defaults)
        let url = URL(string: "https://example.com/mcp")!
        let added = store.add(name: "local", url: url)
        store.setEnabled(id: added.id, enabled: false)
        #expect(store.servers.first { $0.id == added.id }?.enabled == false)

        let reused = store.add(name: "local", url: url)
        #expect(reused.id == added.id)
        #expect(reused.enabled)  // 再追加 = 使う意図なので有効に戻る。
    }

    @Test("name を変えて同一 URL を再 add すると既存エントリの name が更新される")
    func reAddUpdatesName() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ServerRegistryStore(defaults: defaults)
        let url = URL(string: "https://example.com/mcp")!
        let added = store.add(name: "old-label", url: url)
        let reused = store.add(name: "new-label", url: url)
        #expect(reused.id == added.id)
        #expect(reused.name == "new-label")
        #expect(store.servers.first { $0.id == added.id }?.name == "new-label")
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

    @Test("enabledServers は無効項目を除外し、登録順を保持する")
    func enabledServersFiltersWithoutReordering() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ServerRegistryStore(defaults: defaults)
        let seedID = store.servers[0].id
        store.setEnabled(id: seedID, enabled: false)
        let firstEnabled = store.add(name: "first", url: URL(string: "https://first.example.com/mcp")!)
        let secondEnabled = store.add(name: "second", url: URL(string: "https://second.example.com/mcp")!)

        // TodosCardSpikeView は先頭を選ぶため、filter が元配列の順序を維持する契約を固定する。
        #expect(store.enabledServers.map(\.id) == [firstEnabled.id, secondEnabled.id])
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

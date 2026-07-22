// ChatStore(履歴永続化)の単体テスト。設計 02 §5。
//
// 一時ディレクトリを baseDirectory に注入して実行する(KeychainTokenStorage 同様の
// 「テスト可能性のために外部リソースを注入で切り離す」流儀)。ディスク I/O のみで
// swift-sdk・OAuth・ネットワークは一切使わない。
//
// .serialized の理由: ChatViewModelTests と同じスイート内 teardown crash 対策が本質的には
// 不要(@MainActor 型を扱わない)だが、ファイル I/O テストを並列に走らせても得るものが薄く、
// 同ファイル群を触るテスト間の意図しない競合を避けるためここでも直列にしておく
// (設計に明記なし・保守的判断)。
import Foundation
import Testing
@testable import Kernel
@testable import Services

@Suite(.serialized) struct ChatStoreTests {
    /// テストごとに使い捨てのディレクトリを作る(前後のテストの状態を持ち越さない)。
    private func makeTempStore() -> (store: ChatStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (ChatStore(baseDirectory: dir), dir)
    }

    private func makeSession(
        id: UUID = UUID(),
        title: String = "テストセッション",
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> ChatSession {
        ChatSession(
            id: id,
            title: title,
            serverURL: URL(string: "https://caldav.gigun-dev.workers.dev/mcp")!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: updatedAt,
            turns: [
                ChatTurn(role: .user, text: "今日の予定を見せて"),
                ChatTurn(role: .assistant, text: "今日の予定はこちらです。")
            ],
            model: "gpt-5-mini"
        )
    }

    @Test("save → loadIndex → load の round-trip")
    func saveLoadIndexLoadRoundTrip() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = makeSession()
        try store.save(session)

        let index = store.loadIndex()
        #expect(index.count == 1)
        #expect(index[0].id == session.id)
        #expect(index[0].title == "テストセッション")
        #expect(index[0].preview == "今日の予定はこちらです。")
        #expect(index[0].model == "gpt-5-mini")
        #expect(index[0].serverURL == session.serverURL)

        let loaded = try store.load(id: session.id)
        #expect(loaded == session)
    }

    @Test("複数セッションの index は updatedAt 降順")
    func indexOrderedByUpdatedAtDescending() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let older = makeSession(title: "古い方", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = makeSession(title: "新しい方", updatedAt: Date(timeIntervalSince1970: 1_700_001_000))
        try store.save(older)
        try store.save(newer)

        let index = store.loadIndex()
        #expect(index.map(\.title) == ["新しい方", "古い方"])
    }

    @Test("pin は通常履歴より先、各グループ内は updatedAt 降順に並ぶ")
    func pinnedFirstThenUpdatedAtDescending() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let oldestPinned = makeSession(title: "固定・古", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let newestNormal = makeSession(title: "通常・新", updatedAt: Date(timeIntervalSince1970: 1_700_003_000))
        let newestPinned = makeSession(title: "固定・新", updatedAt: Date(timeIntervalSince1970: 1_700_002_000))
        let oldestNormal = makeSession(title: "通常・古", updatedAt: Date(timeIntervalSince1970: 1_700_001_000))
        for session in [oldestPinned, newestNormal, newestPinned, oldestNormal] {
            try store.save(session)
        }
        try store.setPinned(id: oldestPinned.id, isPinned: true)
        try store.setPinned(id: newestPinned.id, isPinned: true)

        #expect(store.loadIndex().map(\.title) == ["固定・新", "固定・古", "通常・新", "通常・古"])
    }

    @Test("pin と unpin は再読込後も保持される")
    func pinAndUnpinPersist() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = makeSession()
        try store.save(session)
        try store.setPinned(id: session.id, isPinned: true)
        #expect(store.loadIndex().first?.isPinned == true)

        // 同じディレクトリを読む別インスタンスでも persisted index が正になる。
        let reloadedStore = ChatStore(baseDirectory: dir)
        #expect(reloadedStore.loadIndex().first?.isPinned == true)
        try reloadedStore.setPinned(id: session.id, isPinned: false)
        #expect(store.loadIndex().first?.isPinned == false)
    }

    @Test("rename は空白を trim し、index とセッション本体へ保持する")
    func renamePersistsTrimmedTitle() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = makeSession(title: "自動タイトル")
        try store.save(session)
        try store.rename(id: session.id, title: "  ユーザー指定名\n")

        let summary = try #require(store.loadIndex().first)
        #expect(summary.title == "ユーザー指定名")
        #expect(summary.hasCustomTitle)
        #expect(try store.load(id: session.id).title == "ユーザー指定名")
        #expect(throws: ChatStoreMutationError.emptyTitle) {
            try store.rename(id: session.id, title: " \n\t")
        }
    }

    @Test("将来の session save は pin とユーザー指定名を保ち、他メタデータは更新する")
    func futureSavePreservesUserMetadata() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = makeSession(title: "自動タイトル")
        try store.save(original)
        try store.setPinned(id: original.id, isPinned: true)
        try store.rename(id: original.id, title: "残す名前")

        // ViewModel が rename 前から握っている stale session を後で保存する状況を再現する。
        var staleSession = original
        staleSession.title = "後から生成された名前"
        staleSession.updatedAt = Date(timeIntervalSince1970: 1_700_009_999)
        staleSession.model = "gpt-future"
        staleSession.turns.append(ChatTurn(role: .assistant, text: "更新後プレビュー"))
        try store.save(staleSession)

        let summary = try #require(store.loadIndex().first)
        #expect(summary.title == "残す名前")
        #expect(summary.isPinned)
        #expect(summary.hasCustomTitle)
        #expect(summary.model == "gpt-future")
        #expect(summary.preview == "更新後プレビュー")
        let loaded = try store.load(id: original.id)
        #expect(loaded.title == "残す名前")
        #expect(loaded.model == "gpt-future")
    }

    @Test("旧 index.json は pin/custom-title キー無しでも既定値 false で読める")
    func legacyIndexDecodesWithoutNewMetadata() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID()
        let legacyJSON = """
        [{
          "id": "\(id.uuidString)",
          "title": "旧履歴",
          "preview": "旧プレビュー",
          "updatedAt": "2023-11-14T22:13:20Z",
          "serverURL": "https://example.com/mcp",
          "model": "legacy-model"
        }]
        """
        try Data(legacyJSON.utf8).write(to: dir.appendingPathComponent("index.json"))

        let summary = try #require(store.loadIndex().first)
        #expect(summary.id == id)
        #expect(!summary.isPinned)
        #expect(!summary.hasCustomTitle)
        #expect(summary.title == "旧履歴")
    }

    @Test("同じ id で再 save すると index のレコードが更新される(重複しない)")
    func saveTwiceUpdatesExistingIndexRecord() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID()
        try store.save(makeSession(id: id, title: "v1", updatedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        try store.save(makeSession(id: id, title: "v2", updatedAt: Date(timeIntervalSince1970: 1_700_000_100)))

        let index = store.loadIndex()
        #expect(index.count == 1)
        #expect(index[0].title == "v2")
    }

    @Test("delete でファイルと index レコードの両方が消える")
    func deleteRemovesFileAndIndexRecord() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = makeSession()
        try store.save(session)
        #expect(store.loadIndex().count == 1)

        try store.delete(id: session.id)
        #expect(store.loadIndex().isEmpty)
        #expect(throws: (any Error).self) {
            try store.load(id: session.id)
        }
    }

    @Test("index.json が破損していても loadIndex は落ちず空配列を返す")
    func corruptedIndexIsToleratedAsEmpty() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // ディレクトリ作成は ChatStore.init が担う。破損 index.json を直接書き込む。
        let indexURL = dir.appendingPathComponent("index.json")
        try Data("{ this is not valid json".utf8).write(to: indexURL)

        // 破損状態でも loadIndex は握りつぶして空を返す(アプリを落とさない・「握りつぶさず
        // 適切に扱う」= ログへは残すが呼び出し側の型は空配列のまま、という設計の折衷)。
        #expect(store.loadIndex().isEmpty)

        // 破損状態からの save も成功する(壊れた index を新しい正しい index で上書きする)。
        let session = makeSession()
        try store.save(session)
        #expect(store.loadIndex().count == 1)
    }

    @Test("存在しない id の load は throw する")
    func loadMissingIdThrows() throws {
        let (store, dir) = makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: (any Error).self) {
            try store.load(id: UUID())
        }
    }
}

// MCP サーバーの「登録簿」(M1・汎用クライアント化)。複数の MCP サーバーを登録しておき、
// チャットごとに1つを選んで接続する。caldav 本番は「シード済みの初期エントリの1つ」に
// 格下げされる(= もはやハードコードされた唯一の接続先ではない)。
//
// 【中立性(CLAUDE.md ビジョン2)】この型は caldav 固有の知識を持たない。caldav 本番 URL は
// あくまで「初回のシード値」であって、この型のロジック(add/remove/rename/select)は
// 任意の MCP サーバーに対して同一に振る舞う。シード定数(caldavSeed*)だけが唯一の caldav 参照で、
// それも「既存ユーザーの体験を変えない」ための移行措置にすぎない。
//
// 【永続化の保存先が UserDefaults で足りる理由】このレジストリが持つのは name / URL / id と
// 「最後に使ったサーバー id」だけで、**秘密情報を一切含まない**。OAuth のアクセストークンは
// KeychainTokenStorage が接続先 URL 単位で別に持つ(kSecAttrAccount = serverURL)ので、
// レジストリ側は「どのサーバーが登録されているか」の非機密メタデータだけを扱う。
// 非機密メタデータに Keychain の重い API を使う必要はなく、@AppStorage 的に軽く読み書きできる
// UserDefaults が素直(LLMSettingsStore が base URL / model を UserDefaults に置くのと同じ判断)。
//
// 【なぜ ObservableObject でなく @Observable か(タスク指示からの逸脱・報告対象)】
// タスク指示は「@MainActor final class ... : ObservableObject」だったが、このリポジトリの
// 設定ストア(LLMSettingsStore)も画面 VM(ChatHomeViewModel)も iOS 17 の Observation
// (@Observable)で統一されている。ChatHomeViewModel(@Observable)がこのレジストリを
// 保持して「選択中サーバー」を観測する構成上、レジストリを旧 Combine の ObservableObject に
// すると @Observable 側からの変更観測が自動伝播しない(@Observable は ObservableObject の
// @Published を購読しない)。整合と観測伝播のため @Observable を選ぶ。SwiftUI 側は
// @State/@Bindable でそのまま束縛できる(LLMSettingsStore と同じ扱い)。
import Foundation
import Observation
import OSLog

/// 登録された MCP サーバー1件(name + URL + 安定 id)。
///
/// Codable: UserDefaults に JSON 配列として永続化する。Identifiable: SwiftUI の ForEach と
/// 「選択中サーバー id」参照のため。Equatable: 差分判定・テストの #expect のため。
/// id は UUID を「登録時に一度だけ」発番して固定する ——name/URL はユーザーが編集しても、
/// 「最後に使ったサーバー」参照や過去チャットとの対応付けが id で安定して追えるようにするため
/// (URL をキーにすると rename/URL 変更で参照が切れる)。
public struct MCPServerEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var url: URL

    public init(id: UUID = UUID(), name: String, url: URL) {
        self.id = id
        self.name = name
        self.url = url
    }
}

/// MCP サーバー登録簿ストア。一覧の保持・永続化・選択状態・トークン後始末を担う。
///
/// @MainActor: SettingsSheet / ChatHomeViewModel(いずれも MainActor)からのみ触る。
/// UserDefaults / Keychain 呼び出しは同期 API だが一瞬なので MainActor で許容(LLMSettingsStore と同流儀)。
@MainActor
@Observable
public final class ServerRegistryStore {
    // MARK: - シード定数(唯一の caldav 参照・移行措置)

    /// 初回シードする caldav 本番の表示名。
    public static let caldavSeedName = "caldav"
    /// 初回シードする caldav 本番のエンドポイント URL 文字列。
    /// 【既存ユーザーの体験を変えない】M1 以前はこの URL がハードコードされた唯一の接続先だった。
    /// キー未存在(= このデバイスで初めて起動した / M1 以前から使っている)のときに1件だけ
    /// シードすることで、アップデート後も「起動→接続で caldav に繋がる」体験が変わらない。
    public static let caldavSeedURLString = "https://caldav.gigun-dev.workers.dev/mcp"

    // MARK: - UserDefaults キー

    // v1 サフィックス: 将来スキーマ(name/URL 以外のフィールド追加等)が変わったら v2 に上げて
    // マイグレーションを分岐できるようにしておく(壊れた JSON で全消しにしないための版管理)。
    private static let serversKey = "mcp.servers.v1"
    private static let selectedKey = "mcp.selectedServer.v1"

    // MARK: - 公開状態

    /// 登録済みサーバー一覧(SettingsSheet が一覧表示・ChatHomeView がサーバー選択メニューで使う)。
    /// private(set): 変更は add/remove/rename の API 経由に限る(永続化と対で行うため直接書き換え禁止)。
    public private(set) var servers: [MCPServerEntry]

    /// 最後に使った(= 新規チャットの既定にする)サーバー id。
    /// nil はあり得る(全削除直後)。その場合の解決は selectedEntry のコメント参照。
    public private(set) var selectedServerID: UUID?

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "server-registry")

    /// - Parameter defaults: 永続化先。既定は .standard。**テストは使い捨ての suiteName を注入**して
    ///   本番の UserDefaults を汚さずシード/永続化/選択を検証する(ChatStore の baseDirectory 注入と同流儀)。
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // --- 一覧のロード or 初回シード ---------------------------------------------
        // キー未存在(data == nil)= 初回。caldav 本番を1件だけシードする(移行措置・上のコメント)。
        // 存在するがデコード失敗(壊れた JSON)= 握りつぶさずシードにフォールバックする ——
        //   空一覧で「接続先ゼロ」に固めるより、既定の caldav に戻す方が復旧が素直
        //   (ChatStore が壊れた index.json を空で握りつぶすのと同じ「落とさない」方針の応用)。
        if let data = defaults.data(forKey: Self.serversKey) {
            if let decoded = try? JSONDecoder().decode([MCPServerEntry].self, from: data) {
                self.servers = decoded
            } else {
                // 壊れていたらシードで復旧(下の共通シード生成を使う)。
                self.servers = Self.seededServers()
                Self.logDecodeFailure(logger)
            }
        } else {
            self.servers = Self.seededServers()
        }

        // --- 選択中 id のロード ------------------------------------------------------
        // 保存済み selectedServerID が現存する一覧を指していればそれを、指していなければ先頭を採る
        // (削除で宙に浮いた id を掴み続けないための健全化)。
        let savedSelected = defaults.string(forKey: Self.selectedKey).flatMap(UUID.init(uuidString:))
        if let savedSelected, servers.contains(where: { $0.id == savedSelected }) {
            self.selectedServerID = savedSelected
        } else {
            self.selectedServerID = servers.first?.id
        }

        // 初回シード直後は servers を永続化しておく(次回起動で「キー未存在=再シード」に戻らないよう、
        // シードした事実をディスクに刻む)。選択 id も併せて確定保存する。
        persist()
    }

    /// 初回シードの中身(caldav 本番1件)。init の2経路(未存在 / デコード失敗)で共有する。
    private static func seededServers() -> [MCPServerEntry] {
        guard let url = URL(string: caldavSeedURLString) else { return [] }
        return [MCPServerEntry(name: caldavSeedName, url: url)]
    }

    private static func logDecodeFailure(_ logger: Logger) {
        logger.notice("mcp.servers.v1 のデコードに失敗: caldav シードで復旧しました")
    }

    // MARK: - 選択

    /// 現在選択中のエントリ。選択 id が宙に浮いていれば先頭にフォールバック(空一覧なら nil)。
    /// ChatHomeViewModel はここから接続先 URL を取る(ハードコード URL の置き換え先)。
    public var selectedEntry: MCPServerEntry? {
        if let id = selectedServerID, let hit = servers.first(where: { $0.id == id }) {
            return hit
        }
        return servers.first
    }

    /// 新規チャット/切替でサーバーを選ぶ。選択を永続化する(次回起動時の既定になる)。
    /// 存在しない id は無視する(宙に浮いた選択を作らない)。
    public func select(_ id: UUID) {
        guard servers.contains(where: { $0.id == id }) else { return }
        selectedServerID = id
        persist()
    }

    // MARK: - 追加 / 改名 / 削除

    /// サーバーを追加して、その id を返す。追加直後は選択もそれに移す
    /// (「今追加したサーバーで話し始めたい」が自然な期待のため)。
    @discardableResult
    public func add(name: String, url: URL) -> MCPServerEntry {
        let entry = MCPServerEntry(name: name, url: url)
        servers.append(entry)
        selectedServerID = entry.id
        persist()
        logger.notice("サーバー追加 name=\(name, privacy: .public) url=\(url.absoluteString, privacy: .public)")
        return entry
    }

    /// 改名 / URL 変更(SettingsSheet の編集)。id は不変なので選択・過去参照は保たれる。
    public func update(id: UUID, name: String, url: URL) {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[idx].name = name
        servers[idx].url = url
        persist()
    }

    /// サーバーを削除する。**該当 URL の OAuth トークンも Keychain から消す**(タスク指示)——
    /// 登録簿から消えたサーバーのトークンを Keychain に残し続けると、同じ URL を再登録したとき
    /// 古い(失効し得る)トークンで繋ぎに行ってしまう。登録簿とトークンの寿命を一致させる。
    ///
    /// KeychainTokenStorage は serverURL 単位でインスタンス化する設計(kSecAttrAccount=URL)なので、
    /// 削除対象 URL でインスタンスを1個作って clear() を呼べば、その URL のトークンだけが消える
    /// (他サーバーのトークンには触れない)。専用の削除 API を新設せず既存の clear() を再利用する。
    public func remove(id: UUID) {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        let removed = servers.remove(at: idx)

        // 該当 URL のトークンを後始末(上記コメント)。clear() は SecItemDelete + メモリキャッシュ破棄。
        KeychainTokenStorage(serverURL: removed.url).clear()

        // 選択中を消したら別のサーバー(先頭)へ選択を移す(宙に浮いた選択を残さない)。
        if selectedServerID == removed.id {
            selectedServerID = servers.first?.id
        }
        persist()
        logger.notice("サーバー削除 url=\(removed.url.absoluteString, privacy: .public)")
    }

    // MARK: - 永続化

    /// servers と selectedServerID を UserDefaults へ書き出す(全変更 API の末尾で呼ぶ)。
    private func persist() {
        if let data = try? JSONEncoder().encode(servers) {
            defaults.set(data, forKey: Self.serversKey)
        }
        // selectedServerID が nil(全削除)なら選択キーを消す(空文字より「未設定」が素直)。
        if let selectedServerID {
            defaults.set(selectedServerID.uuidString, forKey: Self.selectedKey)
        } else {
            defaults.removeObject(forKey: Self.selectedKey)
        }
    }
}

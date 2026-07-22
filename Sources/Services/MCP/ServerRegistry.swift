// MCP サーバーの「登録簿」(M1・汎用クライアント化)。複数の MCP サーバーを登録しておき、
// チャットごとに1つを選んで接続する。caldav 本番は「シード済みの初期エントリの1つ」に
// 格下げされる(= もはやハードコードされた唯一の接続先ではない)。
//
// 【中立性(CLAUDE.md ビジョン2)】この型は caldav 固有の知識を持たない。caldav 本番 URL は
// あくまで「初回のシード値」であって、この型のロジック(add/remove/rename/select)は
// 任意の MCP サーバーに対して同一に振る舞う。シード定数(caldavSeed*)だけが唯一の caldav 参照で、
// それも「既存ユーザーの体験を変えない」ための移行措置にすぎない。
//
// 【永続化の保存先が UserDefaults で足りる理由】このレジストリが持つのは name / URL / id / enabled
// だけで、**秘密情報を一切含まない**(M2 で単一選択 id は廃止)。OAuth のアクセストークンは
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
    /// このサーバーへ自動接続するか(M2・トグルで有効/無効)。
    ///
    /// 【なぜトグルか(ユーザー FB)】「基本 MCP クライアントは複数の remote MCP を繋げる。トグルで
    /// 有効無効ならわかる」。有効なサーバーは起動時に無言接続(トークンが生きていればブラウザ無し)し、
    /// 無効化(OFF)すると接続を破棄して LLM のツール一覧からも外れる。
    ///
    /// 【後方互換(タスク指示)】M1 以前の保存 JSON には enabled キーが無い。非 Optional の Bool を
    /// 素の synthesized decode で読むとキー欠落で失敗するため、下の Codable を手書きして
    /// **decodeIfPresent ?? true**(既定は有効)にする。既存ユーザーの caldav シードが黙って無効に
    /// ならないよう「無ければ有効」に倒す。
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, url: URL, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.enabled = enabled
    }

    // 手書き Codable。enabled だけ decodeIfPresent(旧データ後方互換)、他は必須のまま。
    private enum CodingKeys: String, CodingKey { case id, name, url, enabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.url = try c.decode(URL.self, forKey: .url)
        // 旧データ(enabled 無し)は「有効」に倒す(上のコメント参照)。
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(url, forKey: .url)
        try c.encode(enabled, forKey: .enabled)
    }
}

/// MCP サーバー登録簿ストア。一覧の保持・永続化・有効/無効トグル・トークン後始末を担う(M2)。
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
    // 【M2 で廃止】旧「選択中サーバー(単数)」キー。単一選択モデルを廃し複数同時接続へ移行したため、
    // このキーはもう読み書きしない。init で明示的に removeObject して読み捨てる(残骸を消す)。
    private static let legacySelectedKey = "mcp.selectedServer.v1"

    // MARK: - 公開状態

    /// 登録済みサーバー一覧(SettingsSheet が一覧表示・ChatHomeView がサーバー切替メニューで使う)。
    /// private(set): 変更は add/remove/rename/setEnabled の API 経由に限る(永続化と対で行うため直接書き換え禁止)。
    public private(set) var servers: [MCPServerEntry]

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

        // --- 旧「選択中サーバー(単数)」キーの読み捨て(M2 で単一選択モデルを廃止)---------------
        // M1 まではここで selectedServerID を復元していたが、複数同時接続へ移行したため不要。
        // 残骸を UserDefaults から掃除しておく(次回以降の init で毎回消しても no-op で無害)。
        defaults.removeObject(forKey: Self.legacySelectedKey)

        // 初回シード直後は servers を永続化しておく(次回起動で「キー未存在=再シード」に戻らないよう、
        // シードした事実をディスクに刻む)。
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

    // MARK: - 有効/無効トグル(M2)

    /// 有効(enabled == true)なサーバーだけを返す。ConnectionsManager が起動時の無言接続対象を
    /// ここから取る(無効サーバーは接続しない・LLM のツール一覧にも載らない)。
    public var enabledServers: [MCPServerEntry] {
        servers.filter { $0.enabled }
    }

    /// サーバーの有効/無効を切り替えて永続化する(SettingsSheet のトグル)。
    /// 存在しない id は無視する。ON/OFF に伴う接続の確立/破棄は呼び出し側(ChatHomeViewModel /
    /// ConnectionsManager)が servers の変化を観測して行う(このストアは登録メタデータだけを持つ)。
    public func setEnabled(id: UUID, enabled: Bool) {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        guard servers[idx].enabled != enabled else { return }
        servers[idx].enabled = enabled
        persist()
        logger.notice("サーバー \(enabled ? "有効化" : "無効化") url=\(self.servers[idx].url.absoluteString, privacy: .public)")
    }

    // MARK: - 追加 / 改名 / 削除

    /// サーバーを追加して、その id を返す。追加は enabled=true(すぐ接続を試みる)で入る。
    @discardableResult
    public func add(name: String, url: URL) -> MCPServerEntry {
        let entry = MCPServerEntry(name: name, url: url)
        servers.append(entry)
        persist()
        logger.notice("サーバー追加 name=\(name, privacy: .public) url=\(url.absoluteString, privacy: .public)")
        return entry
    }

    /// 改名 / URL 変更(SettingsSheet の編集)。id は不変なので過去参照は保たれる。
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

        persist()
        logger.notice("サーバー削除 url=\(removed.url.absoluteString, privacy: .public)")
    }

    // MARK: - 永続化

    /// servers を UserDefaults へ書き出す(全変更 API の末尾で呼ぶ)。
    private func persist() {
        if let data = try? JSONEncoder().encode(servers) {
            defaults.set(data, forKey: Self.serversKey)
        }
    }
}

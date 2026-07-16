// チャット履歴の永続化(設計 docs/design/02-chat-llm.md §5)。
//
// 1 ChatSession = 1 JSON ファイル(`<baseDir>/<uuid>.json`)+ 軽量な一覧インデックス
// (`index.json`)。SQLite でなく JSON ファイルを選ぶ理由・保存タイミング(各ターン確定時)は
// 02 §5 の決定を参照。ここは Services 層(FileManager に触れる = プラットフォーム層)。
// Kernel の ChatSession/ChatSessionSummary はそのまま Codable なので変換は要らない。
import Foundation
import Kernel
import OSLog

/// チャット履歴の読み書き。**保存先ディレクトリは呼び出し側が注入する**
/// (本番は Application Support/chats/・テストは一時ディレクトリ・KeychainTokenStorage と同じ
/// 「テスト可能性のために外部リソースを注入で切り離す」流儀)。
public final class ChatStore: @unchecked Sendable {
    private let baseDirectory: URL
    private let indexURL: URL
    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "chat-store")

    // ChatStore はディスク I/O を直列化したいので単純な NSLock で保護する(actor にしなかったのは
    // save/load とも短命な同期処理で、呼び出し側が async 文脈とは限らない箇所 —— ChatViewModel の
    // onTurnSettled コールバックは MainActor 同期関数から呼ばれる想定 —— から呼びたいため。
    // 設計に並行性モデルの指定は無い・こう解釈)。
    private let lock = NSLock()

    /// - Parameter baseDirectory: JSON ファイルの保存先ディレクトリ。無ければ作成する
    ///   (本番は `Application Support/chats/`、テストは一時ディレクトリを渡す)。
    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        self.indexURL = baseDirectory.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    // MARK: - 保存

    /// セッションを `<id>.json` へ保存し、index.json の該当レコードを追加/更新する。
    /// 保存失敗はチャットを止めない方針(A5)なので throw する ——
    /// **呼び出し側(ChatHomeViewModel)が catch してログするだけに留める**設計にすることで、
    /// 「投げるが握りつぶし方は呼び出し側の裁量」という素直な責務分担にする
    /// (ChatStore 自身が握りつぶすと、テストで失敗を検知できなくなる)。
    public func save(_ session: ChatSession) throws {
        lock.lock()
        defer { lock.unlock() }

        let data = try Self.makeEncoder().encode(session)
        let fileURL = sessionFileURL(for: session.id)
        try data.write(to: fileURL, options: .atomic)

        var index = (try? Self.loadIndexRecords(at: indexURL, logger: logger)) ?? []
        let preview = Self.derivePreview(from: session.turns)
        let record = ChatSessionSummary(
            id: session.id,
            title: session.title,
            preview: preview,
            updatedAt: session.updatedAt,
            serverURL: session.serverURL,
            model: session.model
        )
        if let existingIndex = index.firstIndex(where: { $0.id == session.id }) {
            index[existingIndex] = record
        } else {
            index.append(record)
        }
        try Self.writeIndex(index, to: indexURL)
    }

    // MARK: - 読み込み

    /// 一覧を updatedAt 降順で返す(設計 §5「サイドバーは index.json を読むだけで
    /// 日付グループ表示できる」)。
    ///
    /// index.json が壊れている/存在しない場合は空配列を返す(呼び出し側=サイドバーを
    /// 落とさない。**握りつぶさず OSLog に残す**——「破損ファイル・欠損は握りつぶさず
    /// 適切に扱う」指示への対応。原因調査の手がかりを消さないため)。
    public func loadIndex() -> [ChatSessionSummary] {
        lock.lock()
        defer { lock.unlock() }
        let records = (try? Self.loadIndexRecords(at: indexURL, logger: logger)) ?? []
        return records.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 1セッションを ID で読み込む。ファイルが無い/壊れている場合は throw する
    /// (loadIndex と違い、呼び出し側は「開こうとした特定のチャット」の失敗を
    /// ユーザーに見せる責務があるので、ここは握りつぶさない)。
    public func load(id: UUID) throws -> ChatSession {
        lock.lock()
        defer { lock.unlock() }
        let data = try Data(contentsOf: sessionFileURL(for: id))
        return try Self.makeDecoder().decode(ChatSession.self, from: data)
    }

    /// セッションを削除する(ファイル + index.json のレコード両方)。
    /// ファイルが既に無い場合も index からの除去だけは行う(index との不整合を
    /// 「無かったことにして進める」——削除操作は冪等であるべき、という判断)。
    public func delete(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }

        let fileURL = sessionFileURL(for: id)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }

        var index = (try? Self.loadIndexRecords(at: indexURL, logger: logger)) ?? []
        index.removeAll { $0.id == id }
        try Self.writeIndex(index, to: indexURL)
    }

    // MARK: - 内部ヘルパー

    private func sessionFileURL(for id: UUID) -> URL {
        baseDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    /// 最後のターンの text 先頭からプレビュー文言を作る(検索対象・設計 §5「一覧の title/preview
    /// の部分一致で足りる」)。80 文字はサイドバー1行の目安(タイトルの 40 より長め ——
    /// プレビューは補足情報なので少し多めに見せる、という設計に無い判断)。
    private static func derivePreview(from turns: [ChatTurn]) -> String {
        guard let lastText = turns.last?.text else { return "" }
        let trimmed = lastText.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(80))
    }

    /// index.json を読む。**存在しない(初回保存前)場合は空配列を返し、壊れている場合は throw**
    /// して呼び出し側の `try?` に「壊れていた」を伝える(存在しないのと壊れているのを区別する
    /// ——後者だけログを残したいので、ここでは区別のため throw のままにし、
    /// 呼び出し側(save/loadIndex/delete の `(try? ...) ?? []`)でログを出してから空扱いにする)。
    private static func loadIndexRecords(at url: URL, logger: Logger) throws -> [ChatSessionSummary] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try makeDecoder().decode([ChatSessionSummary].self, from: data)
        } catch {
            // 破損 index を握りつぶして「空として続行」する前に、原因追跡のためログへ残す
            // (「破損ファイル・欠損は握りつぶさず適切に扱う」指示への対応)。
            // 呼び出し側は `(try? ...) ?? []` で空扱いに倒すので、ユーザー体験は
            // 「履歴が(一時的に)空に見える」に留まり、アプリを落とさない。
            logger.error("index.json の読み込みに失敗(破損の可能性): \(String(reflecting: error), privacy: .public)")
            throw error
        }
    }

    private static func writeIndex(_ records: [ChatSessionSummary], to url: URL) throws {
        let data = try makeEncoder().encode(records)
        try data.write(to: url, options: .atomic)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

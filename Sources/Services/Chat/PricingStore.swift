// モデル単価テーブルの取得・キャッシュ・ルックアップ(設計 docs/design/02-chat-llm.md §6・T7)。
//
// 単価の出典は litellm(BerriAI/litellm)が公開している `model_prices_and_context_window.json`
// (https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json)。
// タスク指示で確認済みの構造: トップレベルは `{ "<modelId>": { "input_cost_per_token": Double,
// "output_cost_per_token": Double, "litellm_provider": String, "mode": String, ... }, ... }`
// (~2968 モデル・2026-07-16 確認)。"sample_spec" はスキーマ例であってモデルではないので除外し、
// input/output どちらかでも欠ける(embedding 等)エントリも「単価が分からない」ものとして除外する。
//
// **ハードコード単価は持たない**(§6「単価はハードコードすると陳腐化する」・CLAUDE.md
// ユーザー方針)。ここは「取得して持ち回す」役目に徹し、値そのものは litellm 側の正典に委ねる。
import Foundation
import Kernel
import OSLog

private struct PricingRawEntry: Decodable {
    let inputCostPerToken: Double
    let outputCostPerToken: Double

    enum CodingKeys: String, CodingKey {
        case inputCostPerToken = "input_cost_per_token"
        case outputCostPerToken = "output_cost_per_token"
    }
}

/// litellm pricing データの取得・ディスクキャッシュ・ルックアップを担う。
///
/// **@MainActor class にした判断(設計に並行性の指定なし・こう解釈)**: 呼び出し元
/// (ChatHomeViewModel)は @MainActor @Observable で、pricing 読み込み完了後に
/// `chatVM.modelPrice = ...`(ChatViewModel も @MainActor)を直接代入したい。actor にすると
/// その代入のたびに await が要り、呼び出し側のコードが余分に複雑になる。PricingStore の内部処理
/// (JSON fetch・decode・ファイル I/O)自体は重くない(モデル ~3000件の JSON 数百KB)ので、
/// MainActor 直列化のコストは無視できる ——ChatStore(actor でなく NSLock 付き class)とは違い、
/// PricingStore は「UI 状態の隣で使われる薄いキャッシュ」という性格が強いため @MainActor に寄せた。
@MainActor
public final class PricingStore {
    /// パース済み単価テーブル。fetch/load が成功するたびに更新する。未知モデルは辞書に無い = nil。
    private(set) var prices: [String: ModelPrice] = [:]

    private let baseDirectory: URL
    private let cacheFileURL: URL
    private let session: URLSession
    private let ttl: TimeInterval
    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "pricing")

    private static let pricingURL = URL(
        string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
    )!

    /// - Parameters:
    ///   - baseDirectory: キャッシュファイルの保存先ディレクトリ(注入・テストは一時ディレクトリ、
    ///     本番は `Application Support/pricing/`。ChatStore と同じ「外部リソースは注入で切り離す」流儀)。
    ///   - session: URLSession(注入・テストはネットワークを叩かない経路だけを使うので既定で足りる)。
    ///   - ttl: キャッシュ有効期間。既定7日(タスク指示の「例7日」)。litellm の単価表は
    ///     頻繁には変わらないが、新モデル追加は日常的に起きるので長すぎない値にする。
    public init(baseDirectory: URL, session: URLSession = .shared, ttl: TimeInterval = 7 * 24 * 60 * 60) {
        self.baseDirectory = baseDirectory
        self.cacheFileURL = baseDirectory.appendingPathComponent("litellm_prices.json")
        self.session = session
        self.ttl = ttl
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    /// 既知モデルの単価。未知は nil(§6「未知モデルは "—"」の判定はここが起点)。
    public func price(for model: String) -> ModelPrice? {
        prices[model]
    }

    // MARK: - ロード方針(タスク指示どおり)
    //
    // キャッシュが TTL 内に新しければそれを使う。古い/無ければ fetch して更新する。
    // fetch 失敗時は(古くても)キャッシュがあればそれを使う ——「オフラインでも直近の単価は使える」。
    // キャッシュも無ければ prices は空のまま(= 全モデル未知扱い。§6 の安全側デフォルト)。
    // 失敗は握りつぶさず OSLog(category "pricing")に残す(指示どおり)。

    /// 呼び出し側(ChatHomeViewModel)が接続完了後などに一度呼ぶ想定。UI をブロックしないよう
    /// 呼び出し側で Task に包んで叩く(このメソッド自体はブロックしない async だが、
    /// 呼び出し側が await で直列待ちすると体感が遅れるため——コメントで注意喚起)。
    public func load() async {
        if let cached = Self.readCache(at: cacheFileURL, logger: logger),
           Date().timeIntervalSince(cached.fetchedAt) < ttl {
            prices = cached.prices
            return
        }

        do {
            let (data, _) = try await session.data(from: Self.pricingURL)
            let parsed = Self.parse(data: data)
            prices = parsed
            Self.writeCache(prices: parsed, fetchedAt: Date(), to: cacheFileURL, logger: logger)
        } catch {
            logger.error("litellm pricing の fetch に失敗: \(String(reflecting: error), privacy: .public)")
            // fetch 失敗時は古くてもキャッシュがあれば使う(指示どおり)。TTL チェックはしない
            // (「無いよりマシ」——古い単価でも "—" よりは有用な概算になる)。
            if let cached = Self.readCache(at: cacheFileURL, logger: logger) {
                prices = cached.prices
            }
            // キャッシュも無ければ prices は空のまま(未知モデル扱い・安全側)。
        }
    }

    // MARK: - パース(fetch と分離してテスト可能に・タスク指示 F)

    /// litellm JSON の中間デコード先。**必要フィールドだけ**を持ち、それ以外(litellm_provider・
    /// mode・max_tokens 等の数十フィールド)は無視する(タスク指示「その他は無視」)。
    /// input/output いずれかが欠ける・数値でないエントリは decode 失敗として弾く
    /// (`try?` で個別に握りつぶす・全体を壊さない)。
    /// litellm JSON(トップレベル = modelId → エントリの辞書)を `[modelId: ModelPrice]` に変換。
    /// - "sample_spec" は除外(スキーマ例・タスク指示)。
    /// - input/output 両方が数値で取れたエントリだけ採用(embedding 等コスト欠損は自然に脱落)。
    static func parse(data: Data) -> [String: ModelPrice] {
        // トップレベルはモデルごとにフィールド構成が大きく違う(embedding は input のみ、等)ため、
        // 一気に `[String: RawEntry]` で decode すると1件の欠損で全体が失敗する。
        // `[String: JSONValue]` 経由で1件ずつ decode し、失敗した個体だけ弾く(堅牢性優先)。
        guard let top = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            return [:]
        }
        var result: [String: ModelPrice] = [:]
        let entryDecoder = JSONDecoder()
        for (modelId, value) in top {
            guard modelId != "sample_spec" else { continue }
            guard let entryData = try? JSONEncoder().encode(value),
                  let raw = try? entryDecoder.decode(PricingRawEntry.self, from: entryData)
            else { continue }
            result[modelId] = ModelPrice(
                inputCostPerToken: raw.inputCostPerToken,
                outputCostPerToken: raw.outputCostPerToken
            )
        }
        return result
    }

    // MARK: - ディスクキャッシュ(round-trip 可能な形で保存)

    /// キャッシュファイルの形(単価テーブル + 取得時刻)。TTL 判定に fetchedAt を使う。
    private struct CacheFile: Codable {
        let fetchedAt: Date
        let prices: [String: ModelPrice]
    }

    private static func readCache(at url: URL, logger: Logger) -> CacheFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(CacheFile.self, from: data)
        } catch {
            // 破損キャッシュは握りつぶさずログへ(ChatStore.loadIndexRecords と同じ方針)。
            // 呼び出し側は nil を受けて「キャッシュ無し」として fetch にフォールバックする。
            logger.error("pricing キャッシュの読み込みに失敗(破損の可能性): \(String(reflecting: error), privacy: .public)")
            return nil
        }
    }

    private static func writeCache(prices: [String: ModelPrice], fetchedAt: Date, to url: URL, logger: Logger) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(CacheFile(fetchedAt: fetchedAt, prices: prices))
            try data.write(to: url, options: .atomic)
        } catch {
            // キャッシュ書き込み失敗はチャットを止めない(ChatStore.save の失敗方針と同じ姿勢)。
            // 次回起動時に再 fetch されるだけなので実害は薄いが、原因追跡のためログは残す。
            logger.error("pricing キャッシュの書き込みに失敗: \(String(reflecting: error), privacy: .public)")
        }
    }
}

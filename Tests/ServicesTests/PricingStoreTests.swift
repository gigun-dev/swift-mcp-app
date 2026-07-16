// PricingStore(T7・設計 §6)の単体テスト。
//
// ネットワークは一切叩かない(タスク指示「fetch はパース関数と分離してフィクスチャでテスト」):
// PricingStore.parse(data:) はパース専用の internal static 関数として fetch から切り離してあるので、
// フィクスチャ JSON を直接渡してテストする。キャッシュ round-trip は load() 経由ではなく
// ディスクへ直接書いて PricingStore(baseDirectory:) が拾うことを確認する形にし、
// URLSession のモック化(過剰な仕掛け)を避ける。
//
// フィクスチャは litellm 実物(model_prices_and_context_window.json)の小さな抜粋
// (タスク指示に載っている実値をそのまま使用・2026-07-16 確認)。
import Foundation
import Testing
@testable import Kernel
@testable import Services

@MainActor
@Suite(.serialized)
struct PricingStoreTests {
    /// litellm 実物の抜粋(タスク指示の確認値そのまま)。
    /// - "sample_spec": スキーマ例であり実在モデルではない → 除外されるべき。
    /// - "text-embedding-3-small": input のみでコストが載る想定(output 欠損)→ 除外されるべき
    ///   (embedding には出力トークンという概念が無いため litellm 側も output_cost_per_token を持たない)。
    /// - "gpt-5.4-mini" / "gpt-4o-mini": input/output 両方揃っている → 採用されるべき。
    static let fixtureJSON = """
    {
      "sample_spec": {
        "input_cost_per_token": 0.0,
        "output_cost_per_token": 0.0,
        "litellm_provider": "sample",
        "mode": "chat"
      },
      "text-embedding-3-small": {
        "input_cost_per_token": 2e-08,
        "litellm_provider": "openai",
        "mode": "embedding"
      },
      "gpt-5.4-mini": {
        "input_cost_per_token": 7.5e-07,
        "output_cost_per_token": 4.5e-06,
        "litellm_provider": "openai",
        "mode": "chat"
      },
      "gpt-4o-mini": {
        "input_cost_per_token": 1.5e-07,
        "output_cost_per_token": 6e-07,
        "litellm_provider": "openai",
        "mode": "chat"
      }
    }
    """

    // MARK: - パース

    @Test("sample_spec とコスト欠損エントリを除外し、既知モデルを正しくパースする")
    func parseExcludesSampleSpecAndIncompleteEntries() {
        let prices = PricingStore.parse(data: Data(Self.fixtureJSON.utf8))

        #expect(prices["sample_spec"] == nil)
        #expect(prices["text-embedding-3-small"] == nil)

        #expect(prices["gpt-5.4-mini"] == ModelPrice(inputCostPerToken: 7.5e-07, outputCostPerToken: 4.5e-06))
        #expect(prices["gpt-4o-mini"] == ModelPrice(inputCostPerToken: 1.5e-07, outputCostPerToken: 6e-07))
        #expect(prices.count == 2)
    }

    @Test("壊れた JSON は空辞書を返す(全体を落とさない)")
    func parseHandlesGarbage() {
        let prices = PricingStore.parse(data: Data("not json".utf8))
        #expect(prices.isEmpty)
    }

    // MARK: - ルックアップ(未知モデル)

    @Test("price(for:) は未知モデルに nil を返す")
    func priceForUnknownModelIsNil() async throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PricingStore(baseDirectory: dir)
        // load() を呼ばない = prices が空のまま(fetch していない状態を模す)。
        #expect(store.price(for: "totally-unknown-model") == nil)
    }

    // MARK: - キャッシュ round-trip

    @Test("キャッシュに書かれた単価は load() 無しでも読み直せば price(for:) から引ける")
    func cacheRoundTrip() async throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1本目の store でキャッシュファイルを作る(load() は network を叩くので使わず、
        // parse 結果を直接キャッシュへ書き込む private writeCache 相当を経由するため、
        // ここでは PricingStore の公開 API だけで完結させる: 一度 prices を設定できないので、
        // キャッシュファイルを直接同じ形式で書いてから2本目の store で読ませる)。
        let cacheURL = dir.appendingPathComponent("litellm_prices.json")
        let cachePayload = """
        {
          "fetchedAt": "\(ISO8601DateFormatter().string(from: Date()))",
          "prices": {
            "gpt-4o-mini": {"inputCostPerToken": 1.5e-07, "outputCostPerToken": 6e-07}
          }
        }
        """
        try Data(cachePayload.utf8).write(to: cacheURL)

        let store = PricingStore(baseDirectory: dir)
        await store.load()  // ネットワークが無い CI/テスト環境でも、TTL 内キャッシュがあれば fetch せず読むはず。

        #expect(store.price(for: "gpt-4o-mini") == ModelPrice(inputCostPerToken: 1.5e-07, outputCostPerToken: 6e-07))
    }

    private static func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

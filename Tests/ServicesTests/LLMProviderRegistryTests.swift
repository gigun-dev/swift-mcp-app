import Foundation
import Testing
@testable import Services

@Suite(.serialized) struct LLMProviderRegistryTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "LLMProviderRegistryTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("複数のカスタム接続を接続ごとのモデル設定とともに復元できる")
    func persistsMultipleProfiles() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = LLMProviderRegistry(defaults: defaults)
        let first = LLMProviderProfile(
            baseURL: "https://one.example/v1",
            availableModels: ["one-fast", "one-smart"],
            selectedModel: "one-smart",
            reasoningEffort: "high"
        )
        let second = LLMProviderProfile(
            baseURL: "https://two.example/v1/chat/completions",
            availableModels: ["two"],
            selectedModel: "two",
            reasoningEffort: ""
        )

        registry.upsert(first)
        registry.upsert(second)

        #expect(registry.load() == [first, second])
    }

    @Test("旧単一カスタム設定は同じURLで一度だけ移行する")
    func migratesLegacyCustomOnce() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = LLMProviderRegistry(defaults: defaults)

        let first = registry.migrateLegacyCustom(
            baseURL: "https://Example.com/v1/",
            availableModels: ["legacy-model"],
            selectedModel: "legacy-model",
            reasoningEffort: "medium"
        )
        let second = registry.migrateLegacyCustom(
            baseURL: "https://example.com/v1",
            availableModels: [],
            selectedModel: "ignored",
            reasoningEffort: ""
        )

        #expect(first.id == second.id)
        #expect(registry.load().count == 1)
        #expect(registry.load()[0].selectedModel == "legacy-model")
    }

    @Test("URLを編集してもUUID指定の更新なら接続IDを維持する")
    func editingURLKeepsIdentity() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = LLMProviderRegistry(defaults: defaults)
        let original = registry.upsert(LLMProviderProfile(
            baseURL: "https://old.example/v1",
            selectedModel: "model-a"
        ))
        let updated = registry.upsert(LLMProviderProfile(
            id: original.id,
            baseURL: "https://new.example/v1",
            selectedModel: "model-b"
        ))

        #expect(updated.id == original.id)
        #expect(registry.load() == [updated])
    }

    @Test("削除は対象だけを消す")
    func removesOnlyTarget() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = LLMProviderRegistry(defaults: defaults)
        let first = registry.upsert(LLMProviderProfile(baseURL: "https://one.example/v1", selectedModel: "one"))
        let second = registry.upsert(LLMProviderProfile(baseURL: "https://two.example/v1", selectedModel: "two"))

        registry.remove(id: first.id)

        #expect(registry.load() == [second])
    }

    @Test("旧profileはAPI指定なしなら互換接続をChat Completionsとして復元する")
    func oldProfileDefaultsToChatCompletions() throws {
        let id = UUID()
        let data = Data(#"[{"id":"\#(id.uuidString)","baseURL":"https://example.com/v1","availableModels":[],"selectedModel":"m","reasoningEffort":""}]"#.utf8)
        let profiles = try JSONDecoder().decode([LLMProviderProfile].self, from: data)
        #expect(profiles.first?.apiStyle == .chatCompletions)
    }

    @Test("プリセット初期値はOpenAI公式だけResponses")
    func providerAPIStyleDefaults() {
        #expect(LLMAPIStyle.defaultStyle(for: "https://api.openai.com/v1") == .responses)
        #expect(LLMAPIStyle.defaultStyle(for: "https://codex.example/v1") == .chatCompletions)
    }

    @Test("保存URLは既知のAPIパスを除いてv1 baseへ正規化する")
    func normalizesBaseURL() {
        #expect(LLMProviderRegistry.normalizedBaseURL("https://api.openai.com/v1/chat/completions")
            == "https://api.openai.com/v1")
        #expect(LLMProviderRegistry.normalizedBaseURL("https://api.openai.com/v1/responses")
            == "https://api.openai.com/v1")
    }
}

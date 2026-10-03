// BYOKのOpenAI互換接続を管理する。接続の公開設定はUserDefaults、APIキーはKeychainへ分離する。
// 旧版は全接続で固定account "api-key" を共有していたが、複数接続では別プロバイダへキーを
// 誤送信し得るため、標準プリセットはURL単位、カスタムは永続UUID単位のaccountへ保存する。
import Foundation
import Observation
import OSLog
import Services

public enum LLMConnectionSaveError: LocalizedError, Equatable {
    case invalidURL
    case missingAPIKey
    case duplicateURL

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "httpまたはhttpsの有効な接続先URLを入力してください。"
        case .missingAPIKey: "カスタム接続を保存するにはAPIキーが必要です。"
        case .duplicateURL: "同じURLのカスタム接続がすでに保存されています。"
        }
    }
}

@MainActor
@Observable
public final class LLMSettingsStore {
    public static let defaultBaseURL = "https://api.openai.com/v1"
    public static let defaultModel = "gpt-5.4-mini"

    private static let baseURLKey = "llm.baseURL"
    private static let modelKey = "llm.model"
    private static let endpointModelsKey = "llm.modelsByEndpoint"
    private static let reasoningEffortKey = "llm.reasoningEffort"
    private static let apiStyleKey = "llm.apiStyle"
    private static let endpointAPIStylesKey = "llm.apiStylesByEndpoint"
    private static let endpointReasoningEffortsKey = "llm.reasoningEffortsByEndpoint"
    private static let endpointCatalogsKey = "llm.modelCatalogsByEndpoint"
    private static let selectedCustomProviderKey = "llm.selectedCustomProvider.v2"
    private static let keychainMigrationKey = "llm.keychainAccountsMigrated.v2"
    private static let legacyKeychainAccount = "api-key"

    /// 固定プリセットはレジストリへ書き込まない。UIのLLMPresetと同じURL集合を、旧カスタム設定を
    /// 移行するときの境界としてだけ持つ。プリセット自体の表示順・名称はSettingsSheetが正。
    private static let standardEndpoints = [
        "https://api.openai.com/v1",
        "https://openrouter.ai/api/v1",
        "https://api.groq.com/openai/v1",
        "https://api.together.xyz/v1",
        "http://localhost:11434/v1"
    ]

    public var baseURL: String
    public var model: String
    public var reasoningEffort: String
    public var apiStyle: LLMAPIStyle
    public var apiKey: String
    public private(set) var availableModels: [String]
    public private(set) var savedCustomProviders: [LLMProviderProfile]
    public private(set) var selectedCustomProviderID: UUID?
    public private(set) var isAddingCustomProvider = false

    private let defaults: UserDefaults
    private let providerRegistry: LLMProviderRegistry
    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "llm-settings")

    public init(defaults: UserDefaults = .standard) {
        let environment = ProcessInfo.processInfo.environment
        self.defaults = defaults
        self.providerRegistry = LLMProviderRegistry(defaults: defaults)

        let storedBaseURL = environment["MCPHOST_LLM_BASEURL"]
            ?? defaults.string(forKey: Self.baseURLKey)
            ?? Self.defaultBaseURL
        let initialBaseURL = LLMProviderRegistry.normalizedBaseURL(storedBaseURL)
        let initialModel = environment["MCPHOST_LLM_MODEL"]
            ?? defaults.string(forKey: Self.modelKey)
            ?? Self.defaultModel
        let initialEffort = defaults.string(forKey: Self.reasoningEffortKey) ?? ""
        let initialAPIStyle = defaults.string(forKey: Self.apiStyleKey)
            .flatMap(LLMAPIStyle.init(rawValue:)) ?? LLMAPIStyle.defaultStyle(for: initialBaseURL)
        let initialCatalog = Self.catalog(for: initialBaseURL, defaults: defaults)

        let legacyState = LegacyLLMConnectionState(
            baseURL: initialBaseURL,
            model: initialModel,
            reasoningEffort: initialEffort,
            catalog: initialCatalog
        )
        let (profiles, selectedID) = Self.resolveProfiles(
            registry: providerRegistry,
            defaults: defaults,
            legacy: legacyState,
            environmentOverridesBaseURL: environment["MCPHOST_LLM_BASEURL"] != nil
        )

        let selectedProfile = selectedID.flatMap { id in profiles.first(where: { $0.id == id }) }
        self.savedCustomProviders = profiles
        self.selectedCustomProviderID = selectedProfile?.id
        self.baseURL = selectedProfile?.baseURL ?? initialBaseURL
        self.model = selectedProfile?.selectedModel ?? initialModel
        self.reasoningEffort = selectedProfile?.reasoningEffort ?? initialEffort
        self.apiStyle = selectedProfile?.apiStyle ?? initialAPIStyle
        self.availableModels = selectedProfile?.availableModels ?? initialCatalog

        let account = selectedProfile.map { Self.customAccount(id: $0.id) }
            ?? Self.presetAccount(baseURL: initialBaseURL)
        let endpointKey = LLMAPIKeyKeychain.load(account: account)
            ?? Self.migrateLegacyPresetKeyIfNeeded(from: storedBaseURL, to: initialBaseURL)
        let needsKeyMigration = !defaults.bool(forKey: Self.keychainMigrationKey)
        let legacyKey = needsKeyMigration ? LLMAPIKeyKeychain.load(account: Self.legacyKeychainAccount) : nil
        self.apiKey = environment["MCPHOST_LLM_KEY"] ?? endpointKey ?? legacyKey ?? ""
        migrateLegacyKeyIfNeeded(
            endpointKey: endpointKey,
            legacyKey: legacyKey,
            account: account,
            environmentOverridesKey: environment["MCPHOST_LLM_KEY"] != nil
        )
    }

    public var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var selectedPresetBaseURL: String? {
        guard selectedCustomProviderID == nil, !isAddingCustomProvider else { return nil }
        return Self.standardEndpoints.first { Self.identity($0) == Self.identity(baseURL) }
    }

    /// composerからモデルだけを変える経路を含む既存API。接続入力が不正ならmetadataを壊さない。
    public func save() {
        do {
            try saveCurrentConnection()
        } catch {
            logger.notice("LLM接続設定を保存せず維持: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 現在の接続を保存する。カスタムは有効URLとキーが揃った時点で初めて一覧へ追加する。
    public func saveCurrentConnection() throws {
        guard Self.validEndpoint(baseURL) else { throw LLMConnectionSaveError.invalidURL }
        let cleanedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if isAddingCustomProvider || selectedCustomProviderID != nil || !Self.isStandardEndpoint(baseURL) {
            guard hasAPIKey else { throw LLMConnectionSaveError.missingAPIKey }
            let duplicatesAnotherProfile = savedCustomProviders.contains {
                $0.id != selectedCustomProviderID && Self.identity($0.baseURL) == Self.identity(baseURL)
            }
            guard !duplicatesAnotherProfile else { throw LLMConnectionSaveError.duplicateURL }
            let requestedID = selectedCustomProviderID ?? UUID()
            let stored = providerRegistry.upsert(LLMProviderProfile(
                id: requestedID,
                baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                availableModels: availableModels,
                selectedModel: cleanedModel.isEmpty ? Self.defaultModel : cleanedModel,
                reasoningEffort: reasoningEffort,
                apiStyle: apiStyle
            ))
            selectedCustomProviderID = stored.id
            isAddingCustomProvider = false
            savedCustomProviders = providerRegistry.load()
            baseURL = stored.baseURL
            model = stored.selectedModel
            apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(stored.id.uuidString, forKey: Self.selectedCustomProviderKey)
            LLMAPIKeyKeychain.save(apiKey, account: Self.customAccount(id: stored.id))
        } else {
            selectedCustomProviderID = nil
            defaults.removeObject(forKey: Self.selectedCustomProviderKey)
            LLMAPIKeyKeychain.save(apiKey, account: Self.presetAccount(baseURL: baseURL))
            rememberPresetSelection()
        }
        persistLegacyCurrentValues()
    }

    public func selectPreset(_ endpoint: String) {
        selectedCustomProviderID = nil
        isAddingCustomProvider = false
        baseURL = LLMProviderRegistry.normalizedBaseURL(endpoint)
        let endpointID = Self.identity(endpoint)
        let legacyEndpointID = Self.identity(Self.legacyFullEndpoint(endpoint))
        let models = defaults.dictionary(forKey: Self.endpointModelsKey) as? [String: String] ?? [:]
        let efforts = defaults.dictionary(forKey: Self.endpointReasoningEffortsKey) as? [String: String] ?? [:]
        let apiStyles = defaults.dictionary(forKey: Self.endpointAPIStylesKey) as? [String: String] ?? [:]
        model = models[endpointID] ?? models[legacyEndpointID] ?? Self.defaultModel
        reasoningEffort = efforts[endpointID] ?? efforts[legacyEndpointID] ?? ""
        apiStyle = apiStyles[endpointID].flatMap(LLMAPIStyle.init(rawValue:))
            ?? apiStyles[legacyEndpointID].flatMap(LLMAPIStyle.init(rawValue:))
            ?? LLMAPIStyle.defaultStyle(for: endpoint)
        availableModels = Self.catalog(for: endpoint, defaults: defaults)
        apiKey = LLMAPIKeyKeychain.load(account: Self.presetAccount(baseURL: endpoint))
            ?? Self.migrateLegacyPresetKeyIfNeeded(from: Self.legacyFullEndpoint(endpoint), to: endpoint)
            ?? ""
    }

    public func selectCustomProvider(id: UUID) {
        guard let profile = savedCustomProviders.first(where: { $0.id == id }) else { return }
        selectedCustomProviderID = id
        isAddingCustomProvider = false
        baseURL = profile.baseURL
        model = profile.selectedModel
        reasoningEffort = profile.reasoningEffort
        apiStyle = profile.apiStyle
        availableModels = profile.availableModels
        apiKey = LLMAPIKeyKeychain.load(account: Self.customAccount(id: id)) ?? ""
    }

    public func beginAddingCustomProvider() {
        selectedCustomProviderID = nil
        isAddingCustomProvider = true
        baseURL = ""
        model = Self.defaultModel
        reasoningEffort = ""
        apiStyle = .chatCompletions
        availableModels = []
        apiKey = ""
    }

    public func deleteCustomProvider(id: UUID) {
        providerRegistry.remove(id: id)
        LLMAPIKeyKeychain.delete(account: Self.customAccount(id: id))
        savedCustomProviders = providerRegistry.load()
        guard selectedCustomProviderID == id else { return }
        defaults.removeObject(forKey: Self.selectedCustomProviderKey)
        selectPreset(Self.defaultBaseURL)
        persistLegacyCurrentValues()
    }

    public func updateAvailableModels(_ modelIDs: [String]) {
        availableModels = Array(Set(modelIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted()
    }

    /// 新レジストリが無い旧ユーザーでは、標準プリセット以外の単一URLをカスタム接続へ昇格する。
    /// APIキーが一時的に読めなくてもURL・モデルを失わないよう、metadata移行は先に完了させる。
    private static func resolveProfiles(
        registry: LLMProviderRegistry,
        defaults: UserDefaults,
        legacy: LegacyLLMConnectionState,
        environmentOverridesBaseURL: Bool
    ) -> ([LLMProviderProfile], UUID?) {
        var profiles = registry.load()
        var selectedID = defaults.string(forKey: selectedCustomProviderKey).flatMap(UUID.init(uuidString:))
        if environmentOverridesBaseURL
            || selectedID.flatMap({ id in profiles.first(where: { $0.id == id }) }) == nil {
            selectedID = nil
        }
        if !environmentOverridesBaseURL,
           !isStandardEndpoint(legacy.baseURL),
           profiles.allSatisfy({ identity($0.baseURL) != identity(legacy.baseURL) }) {
            let migrated = registry.migrateLegacyCustom(
                baseURL: legacy.baseURL,
                availableModels: legacy.catalog,
                selectedModel: legacy.model,
                reasoningEffort: legacy.reasoningEffort
            )
            profiles = registry.load()
            selectedID = migrated.id
            defaults.set(migrated.id.uuidString, forKey: selectedCustomProviderKey)
        }
        if !environmentOverridesBaseURL, selectedID == nil {
            selectedID = profiles.first(where: { identity($0.baseURL) == identity(legacy.baseURL) })?.id
        }
        return (profiles, selectedID)
    }

    /// 旧キーはコピー成功後も削除しない。Keychain書込み不能な無署名Simulatorでは移行済みにせず、
    /// 次回起動でも旧接続を利用できるようにする。移行済み以後は旧キーを別接続へ流用しない。
    private func migrateLegacyKeyIfNeeded(
        endpointKey: String?,
        legacyKey: String?,
        account: String,
        environmentOverridesKey: Bool
    ) {
        guard !environmentOverridesKey, !defaults.bool(forKey: Self.keychainMigrationKey) else { return }
        if endpointKey != nil || legacyKey == nil {
            defaults.set(true, forKey: Self.keychainMigrationKey)
        } else if let legacyKey, LLMAPIKeyKeychain.save(legacyKey, account: account) {
            defaults.set(true, forKey: Self.keychainMigrationKey)
        }
    }

    private static func validEndpoint(_ value: String) -> Bool {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        return url.host != nil
    }

    private static func isStandardEndpoint(_ value: String) -> Bool {
        standardEndpoints.contains { identity($0) == identity(value) }
    }

    private static func identity(_ value: String) -> String {
        LLMProviderRegistry.endpointIdentity(value)
    }

    private static func catalog(for endpoint: String, defaults: UserDefaults) -> [String] {
        let catalogs = defaults.dictionary(forKey: endpointCatalogsKey) ?? [:]
        return catalogs[identity(endpoint)] as? [String] ?? []
    }

    private static func presetAccount(baseURL: String) -> String {
        "preset:\(identity(baseURL))"
    }

    private static func customAccount(id: UUID) -> String {
        "custom:\(id.uuidString.lowercased())"
    }
}

private extension LLMSettingsStore {
    static func legacyFullEndpoint(_ baseURL: String) -> String {
        LLMProviderRegistry.normalizedBaseURL(baseURL) + "/chat/completions"
    }

    static func migrateLegacyPresetKeyIfNeeded(from oldURL: String, to newURL: String) -> String? {
        let oldAccount = "preset:\(oldURL.trimmingCharacters(in: .whitespacesAndNewlines))"
        let newAccount = presetAccount(baseURL: newURL)
        guard oldAccount != newAccount, let key = LLMAPIKeyKeychain.load(account: oldAccount) else { return nil }
        LLMAPIKeyKeychain.save(key, account: newAccount)
        return key
    }

    func persistLegacyCurrentValues() {
        defaults.set(baseURL, forKey: Self.baseURLKey)
        defaults.set(model, forKey: Self.modelKey)
        defaults.set(reasoningEffort, forKey: Self.reasoningEffortKey)
        defaults.set(apiStyle.rawValue, forKey: Self.apiStyleKey)
    }

    func rememberPresetSelection() {
        let endpoint = Self.identity(baseURL)
        var models = defaults.dictionary(forKey: Self.endpointModelsKey) as? [String: String] ?? [:]
        models[endpoint] = model
        defaults.set(models, forKey: Self.endpointModelsKey)
        var efforts = defaults.dictionary(forKey: Self.endpointReasoningEffortsKey) as? [String: String] ?? [:]
        efforts[endpoint] = reasoningEffort
        defaults.set(efforts, forKey: Self.endpointReasoningEffortsKey)
        var apiStyles = defaults.dictionary(forKey: Self.endpointAPIStylesKey) as? [String: String] ?? [:]
        apiStyles[endpoint] = apiStyle.rawValue
        defaults.set(apiStyles, forKey: Self.endpointAPIStylesKey)
        var catalogs = defaults.dictionary(forKey: Self.endpointCatalogsKey) ?? [:]
        catalogs[endpoint] = availableModels
        defaults.set(catalogs, forKey: Self.endpointCatalogsKey)
    }
}

private struct LegacyLLMConnectionState {
    let baseURL: String
    let model: String
    let reasoningEffort: String
    let catalog: [String]
}

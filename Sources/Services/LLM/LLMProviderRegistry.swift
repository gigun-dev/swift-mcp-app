// OpenAI互換のカスタム接続から、秘密でない設定だけをUserDefaultsへ保存する。
// APIキーはこの型へ渡さず、Features側のLLMSettingsStoreが接続IDごとのKeychain accountで管理する。
// こう分離すると、複数接続の追加・編集・削除と旧単一設定の移行をKeychainなしで単体テストできる。
import Foundation

public struct LLMProviderProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var baseURL: String
    public var availableModels: [String]
    public var selectedModel: String
    public var reasoningEffort: String
    public var apiStyle: LLMAPIStyle

    public init(
        id: UUID = UUID(),
        baseURL: String,
        availableModels: [String] = [],
        selectedModel: String,
        reasoningEffort: String = "",
        apiStyle: LLMAPIStyle = .chatCompletions
    ) {
        self.id = id
        self.baseURL = LLMProviderRegistry.normalizedBaseURL(baseURL)
        self.availableModels = availableModels
        self.selectedModel = selectedModel
        self.reasoningEffort = reasoningEffort
        self.apiStyle = apiStyle
    }

    private enum CodingKeys: String, CodingKey {
        case id, baseURL, availableModels, selectedModel, reasoningEffort, apiStyle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let storedBaseURL = try container.decode(String.self, forKey: .baseURL)
        baseURL = LLMProviderRegistry.normalizedBaseURL(storedBaseURL)
        availableModels = try container.decodeIfPresent([String].self, forKey: .availableModels) ?? []
        selectedModel = try container.decode(String.self, forKey: .selectedModel)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? ""
        let storedStyle = try container.decodeIfPresent(String.self, forKey: .apiStyle)
        apiStyle = storedStyle.flatMap(LLMAPIStyle.init(rawValue:))
            ?? LLMAPIStyle.defaultStyle(for: baseURL)
    }

    /// 初期UIでは名前入力を増やさず、URLから安定した表示名を作る。
    public var displayName: String {
        URL(string: baseURL)?.host(percentEncoded: false) ?? baseURL
    }
}

public final class LLMProviderRegistry: @unchecked Sendable {
    private static let profilesKey = "llm.customProviders.v2"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [LLMProviderProfile] {
        guard let data = defaults.data(forKey: Self.profilesKey) else { return [] }
        return (try? JSONDecoder().decode([LLMProviderProfile].self, from: data)) ?? []
    }

    public func save(_ profiles: [LLMProviderProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: Self.profilesKey)
    }

    /// URLが同じ接続は既存IDを維持して更新する。Keychain accountをUUIDに結びつけるため、
    /// 表記上の再保存だけで別IDへ変わるとAPIキーを見失うので、canonical URLで再利用する。
    @discardableResult
    public func upsert(_ profile: LLMProviderProfile) -> LLMProviderProfile {
        var profiles = load()
        let targetIndex = profiles.firstIndex(where: { $0.id == profile.id })
            ?? profiles.firstIndex(where: {
                Self.endpointIdentity($0.baseURL) == Self.endpointIdentity(profile.baseURL)
            })
        let stored: LLMProviderProfile
        if let targetIndex {
            stored = LLMProviderProfile(
                id: profiles[targetIndex].id,
                baseURL: profile.baseURL,
                availableModels: profile.availableModels,
                selectedModel: profile.selectedModel,
                reasoningEffort: profile.reasoningEffort,
                apiStyle: profile.apiStyle
            )
            profiles[targetIndex] = stored
        } else {
            stored = profile
            profiles.append(stored)
        }
        save(profiles)
        return stored
    }

    public func remove(id: UUID) {
        save(load().filter { $0.id != id })
    }

    /// 旧版の単一カスタム設定を最初のprofileへ持ち上げる。既に同じURLがある場合は重複させない。
    @discardableResult
    public func migrateLegacyCustom(
        baseURL: String,
        availableModels: [String],
        selectedModel: String,
        reasoningEffort: String
    ) -> LLMProviderProfile {
        if let existing = load().first(where: {
            Self.endpointIdentity($0.baseURL) == Self.endpointIdentity(baseURL)
        }) {
            return existing
        }
        return upsert(LLMProviderProfile(
            baseURL: baseURL,
            availableModels: availableModels,
            selectedModel: selectedModel,
            reasoningEffort: reasoningEffort
        ))
    }

    public static func endpointIdentity(_ value: String) -> String {
        let trimmed = normalizedBaseURL(value)
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string ?? trimmed
    }

    public static func normalizedBaseURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        var path = components.percentEncodedPath
        for suffix in ["/chat/completions", "/responses"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
            break
        }
        components.percentEncodedPath = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        return components.string ?? trimmed
    }
}

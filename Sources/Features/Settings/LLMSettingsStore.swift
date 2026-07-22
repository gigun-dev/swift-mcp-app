// BYOK(Bring Your Own Key)の LLM 接続設定を保存/読込する小さな専用ストア(T4-A)。
//
// 秘密度で保存先を分ける(タスク指示):
//  - API キー = **Keychain**(kSecClassGenericPassword)。KeychainTokenStorage の SecItem 流儀を
//    踏襲する(upsert = SecItemUpdate → errSecItemNotFound で SecItemAdd。afterFirstUnlock +
//    thisDeviceOnly)。OAuth トークン用ストアとは service を分ける(こちらは
//    "dev.gigun.mcphost.llm")— 用途が違うキーを同じ service に混ぜない。
//  - base URL / モデル = **UserDefaults**(秘密ではない・@AppStorage で View から直接束縛できる)。
//
// なぜ CLAUDE.md ビジョン1(LLM 呼び出しを1箇所に抽象)と整合するか: この設定が
// OpenAICompatClient(baseURL/apiKey)+ ChatViewModel(model)の生成に必要な3値をすべて
// 供給する。将来 LLM プロキシ(Workers)へ差し替えるときも、ここが吐く3値の出所が
// 変わるだけで Features/Chat の配線は動かない。
//
// env オーバーライド(MCPHOST_LLM_KEY / _BASEURL / _MODEL): MCPHOST_AUTOCONNECT と同じ流儀で、
// エージェント(Claude Code)が simctl launch --setenv だけで実 LLM 往復を人手のキー入力なしに
// 検証できるようにする。**env があれば Keychain/UserDefaults より優先**して初期値に採る。
// リリースビルドに env は渡らないので無害(気になれば #if DEBUG で囲む余地を残す)。
import Foundation
import Observation
import OSLog
import Security

/// BYOK の LLM 設定(base URL・モデル・API キー)を一元管理する @Observable ストア。
///
/// @MainActor: SettingsSheet / ChatHomeViewModel(いずれも MainActor)から触るだけで、
/// バックグラウンドからは触らない。Keychain 呼び出しは同期 API だが一瞬なので MainActor で許容。
@MainActor
@Observable
public final class LLMSettingsStore {
    // MARK: - 既定値(タスク指示)

    /// OpenAI 公式の chat/completions エンドポイント(完全 URL・OpenAICompatClient の baseURL 仕様どおり)。
    public static let defaultBaseURL = "https://api.openai.com/v1/chat/completions"
    /// 既定モデル(ユーザー指定・無料枠が大きい軽量モデル)。設計 §6 のコスト第一級方針に沿う。
    public static let defaultModel = "gpt-5.4-mini"

    // MARK: - UserDefaults キー(base URL・モデル。秘密でない)

    private static let baseURLKey = "llm.baseURL"
    private static let modelKey = "llm.model"

    // MARK: - Keychain(API キー)

    // OAuth トークン用(dev.gigun.mcphost.oauth-token)とは別 service。BYOK の LLM キー専用。
    private static let keychainService = "dev.gigun.mcphost.llm"
    // このアプリでは LLM キーは1本(1プロバイダ)なので account は固定文字列でよい。
    // 将来プロバイダごとに分けたくなったら account を baseURL 等に変える余地を残す。
    private static let keychainAccount = "api-key"

    // MARK: - 公開状態(SettingsSheet が双方向束縛・ChatHomeViewModel が読む)

    /// chat/completions の完全 URL。プリセット chips で差し替わる。
    public var baseURL: String
    /// モデル ID(リクエストの model フィールド)。
    public var model: String
    /// API キー(SecureField で編集)。**メモリ上の編集値**であり、save() で初めて Keychain に書く。
    public var apiKey: String

    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "llm-settings")

    public init() {
        let env = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard

        // base URL: env > UserDefaults > 既定。
        self.baseURL = env["MCPHOST_LLM_BASEURL"]
            ?? defaults.string(forKey: Self.baseURLKey)
            ?? Self.defaultBaseURL
        // モデル: env > UserDefaults > 既定。
        self.model = env["MCPHOST_LLM_MODEL"]
            ?? defaults.string(forKey: Self.modelKey)
            ?? Self.defaultModel
        // API キー: env > Keychain > 空。env は init 内でローカルに読むだけで、
        // Keychain 読み出しは静的メソッド(まだ self が完成していないので分離)。
        self.apiKey = env["MCPHOST_LLM_KEY"]
            ?? Self.loadKeyFromKeychain()
            ?? ""
    }

    // MARK: - 保存

    /// 現在のメモリ値(baseURL/model/apiKey)を永続化する。SettingsSheet の「保存」で呼ぶ。
    /// base URL・モデルは UserDefaults、API キーは Keychain。
    public func save() {
        let defaults = UserDefaults.standard
        defaults.set(baseURL, forKey: Self.baseURLKey)
        defaults.set(model, forKey: Self.modelKey)
        saveKeyToKeychain(apiKey)
    }

    /// キー未設定か(接続前ゲート判定に使う)。空白のみも未設定扱い。
    public var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Keychain 実装(KeychainTokenStorage の SecItem 流儀を踏襲)

    private func saveKeyToKeychain(_ key: String) {
        let query = Self.keychainBaseQuery()
        // 空キー(ユーザーがクリアした)は削除に寄せる — 空文字を保存して load で "" が返るより、
        // 「項目が無い = 未設定」の方が hasAPIKey の判定が素直。
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }

        let data = Data(trimmed.utf8)
        // upsert: SecItemUpdate → errSecItemNotFound なら SecItemAdd(KeychainTokenStorage と同型)。
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            // OAuth トークンと同じアクセス属性: 端末アンロック後のみ・iCloud 同期対象外。
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                // シミュレータ無署名ビルドでは SecItemAdd が entitlement で失敗しうる
                // (KeychainTokenStorage のコメント参照)。致命ではない — メモリ上の apiKey で
                // そのセッションの接続は成立する。手がかりとしてログに残す。
                logger.notice("LLM キーの Keychain 保存失敗(status \(addStatus)): メモリ値で続行")
            }
        } else if updateStatus != errSecSuccess {
            logger.notice("LLM キーの Keychain 更新失敗(status \(updateStatus)): メモリ値で続行")
        }
    }

    /// Keychain から LLM キーを読む。init から呼ぶため static(self 未完成時に触れる)。
    private static func loadKeyFromKeychain() -> String? {
        var query = keychainBaseQuery()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        // Keychain値が壊れていても置換文字で復元し、空判定まで安全に進める。
        // swiftlint:disable:next optional_data_string_conversion
        let key = String(decoding: data, as: UTF8.self)
        return key.isEmpty ? nil : key
    }

    private static func keychainBaseQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount
        ]
    }
}

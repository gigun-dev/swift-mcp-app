// ui/* メッセージのうち「型で写経する最小集合」(設計 §3-2)。
//
// 方針(設計 §3): ブリッジの本質はプロキシなので、tools/call の params や CallToolResult は
// JSONValue のまま素通しする。型を付けるのは「ホストが自分で組み立てる/解釈する必要がある」
// ui/* の一部だけ。ここに載っていない ui/* は §3-3 の passthrough レーンで method 文字列
// ルーティングする。
//
// 出典行はいずれも ext-apps `src/spec.types.ts`(2026-07-15 チェックアウト)。
import Foundation

// MARK: - 共通: Implementation(appInfo / hostInfo)

/// MCP の `Implementation`(name + version)。appInfo(View 側)/ hostInfo(Host 側)に使う。
/// spec.types.ts では MCP SDK から import される型。ここでは最小の2フィールドで写経する。
public struct Implementation: Codable, Hashable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

// MARK: - 共通: hostContext(最小集合)

/// 色テーマ。spec.types.ts:33 McpUiTheme = "light" | "dark"。
public enum UITheme: String, Codable, Hashable, Sendable {
    case light
    case dark
}

/// 表示モード。spec.types.ts:39 McpUiDisplayMode = "inline" | "fullscreen" | "pip"。
public enum UIDisplayMode: String, Codable, Hashable, Sendable {
    case inline
    case fullscreen
    case pip
}

/// コンテナ寸法。spec.types.ts:362 の union 型
/// `({height}|{maxHeight?}) & ({width}|{maxWidth?})` を、4フィールドすべて optional の
/// フラットな構造体で表す(union を Swift の直和で厳密再現するとエンコードが煩雑になり、
/// かつ「固定と上限のどちらか」を実行時に選ぶだけなので optional 4本で十分・ロスもない)。
/// 未指定フィールドは encode 時に省略される(nil は書き出さない)。
public struct ContainerDimensions: Codable, Hashable, Sendable {
    public let width: Double?
    public let maxWidth: Double?
    public let height: Double?
    public let maxHeight: Double?

    public init(width: Double? = nil, maxWidth: Double? = nil,
                height: Double? = nil, maxHeight: Double? = nil) {
        self.width = width
        self.maxWidth = maxWidth
        self.height = height
        self.maxHeight = maxHeight
    }
}

/// hostContext(設計 §3-2 の最小集合: theme / locale / displayMode /
/// containerDimensions / availableDisplayModes のみ)。spec.types.ts:340 McpUiHostContext。
///
/// styles.variables(テーマ CSS 変数)・toolInfo・safeAreaInsets・deviceCapabilities などは
/// P3 の堅牢化に回す(設計 §4 の displayMode/permissions と同じ扱い。省略はプロトコル上合法 —
/// McpUiHostContext は index signature で forward-compat を許す)。
public struct HostContext: Codable, Hashable, Sendable {
    public let theme: UITheme?
    public let locale: String?
    public let displayMode: UIDisplayMode?
    public let availableDisplayModes: [UIDisplayMode]?
    public let containerDimensions: ContainerDimensions?

    public init(theme: UITheme? = nil, locale: String? = nil,
                displayMode: UIDisplayMode? = nil,
                availableDisplayModes: [UIDisplayMode]? = nil,
                containerDimensions: ContainerDimensions? = nil) {
        self.theme = theme
        self.locale = locale
        self.displayMode = displayMode
        self.availableDisplayModes = availableDisplayModes
        self.containerDimensions = containerDimensions
    }
}

// MARK: - ui/initialize(View→Host リクエスト / Host→View 結果)

/// ui/initialize のパラメータ。spec.types.ts:554 McpUiInitializeRequest.params。
/// appCapabilities は「保持するだけで解釈しない」(設計 §3-2)ので JSONValue で持つ。
public struct InitializeParams: Codable, Hashable, Sendable {
    public let appInfo: Implementation
    public let appCapabilities: JSONValue
    public let protocolVersion: String

    public init(appInfo: Implementation, appCapabilities: JSONValue, protocolVersion: String) {
        self.appInfo = appInfo
        self.appCapabilities = appCapabilities
        self.protocolVersion = protocolVersion
    }
}

/// ui/initialize の結果。spec.types.ts:570 McpUiInitializeResult。
/// hostCapabilities は今はホスト側で固定 JSON を返すだけなので JSONValue で持つ
/// (openLinks 等の細かい能力宣言は S3 以降で詰める)。
public struct InitializeResult: Codable, Hashable, Sendable {
    public let protocolVersion: String
    public let hostInfo: Implementation
    public let hostCapabilities: JSONValue
    public let hostContext: HostContext

    public init(protocolVersion: String, hostInfo: Implementation,
                hostCapabilities: JSONValue, hostContext: HostContext) {
        self.protocolVersion = protocolVersion
        self.hostInfo = hostInfo
        self.hostCapabilities = hostCapabilities
        self.hostContext = hostContext
    }
}

// MARK: - Host→View 通知系

/// ui/notifications/tool-input のパラメータ。spec.types.ts:278 McpUiToolInputNotification。
/// arguments は Record<string, unknown> なので JSONValue で持つ(素通し)。
public struct ToolInputParams: Codable, Hashable, Sendable {
    public let arguments: JSONValue?

    public init(arguments: JSONValue?) {
        self.arguments = arguments
    }
}

// tool-result(spec.types.ts:300)は params が CallToolResult そのもの。設計 §3 の
// ロスレス要件(structuredContent の未知フィールドを落とさない)を守るため、**型を付けず
// JSONValue のまま**扱う。専用の struct を作らないのは意図的(ボツ案「CallTool.Result に
// 型付け」を却下した理由と同じ)。配送側は JSONRPCNotification(method: toolResult,
// params: <JSONValue>)を直接組み立てる。

/// ui/notifications/tool-cancelled のパラメータ。spec.types.ts:311 McpUiToolCancelledNotification。
public struct ToolCancelledParams: Codable, Hashable, Sendable {
    public let reason: String?

    public init(reason: String?) {
        self.reason = reason
    }
}

// MARK: - View→Host 通知系

/// ui/notifications/size-changed のパラメータ。spec.types.ts:265 McpUiSizeChangedNotification。
/// width/height はピクセル。設計 §5 では height だけ採用し width は無視する(幅はホスト固定)。
public struct SizeChangedParams: Codable, Hashable, Sendable {
    public let width: Double?
    public let height: Double?

    public init(width: Double? = nil, height: Double? = nil) {
        self.width = width
        self.height = height
    }
}

// MARK: - teardown(Host→View リクエスト / View→Host 結果)

/// ui/resource-teardown のパラメータ。spec.types.ts:446 は `params: {}`(空オブジェクト)。
/// 空 struct を Codable にすると "{}" にエンコードされ、仕様の空 params と一致する。
public struct ResourceTeardownParams: Codable, Hashable, Sendable {
    public init() {}
}

/// ui/resource-teardown の結果。spec.types.ts:455 は index signature のみ(実質空オブジェクト)。
public struct ResourceTeardownResult: Codable, Hashable, Sendable {
    public init() {}
}

// MARK: - ui/open-link(View→Host リクエスト)

/// ui/open-link のパラメータ。spec.types.ts:150 McpUiOpenLinkRequest。
public struct OpenLinkParams: Codable, Hashable, Sendable {
    public let url: String

    public init(url: String) {
        self.url = url
    }
}

import Kernel

/// ui/initialize応答を状態機械から分離して組み立てる純粋なbuilder。
enum AppsBridgeInitializeBuilder {
    struct Context {
        let hostInfo: Implementation
        let theme: UITheme
        let styles: HostStyles?
        let displayMode: UIDisplayMode
        let containerWidth: Double
        let maxHeight: Double
        let supportsDisplayModeRequests: Bool
    }

    static func result(params: InitializeParams, context: Context) throws -> JSONValue {
        let modes: [UIDisplayMode] = context.supportsDisplayModeRequests
            ? [.inline, .fullscreen]
            : [.inline]
        let hostContext = HostContext(
            theme: context.theme,
            styles: context.styles,
            locale: "ja-JP",
            displayMode: context.displayMode,
            availableDisplayModes: modes,
            containerDimensions: ContainerDimensions(
                width: context.containerWidth,
                maxHeight: context.maxHeight
            )
        )
        return try JSONValue(encoding: InitializeResult(
            protocolVersion: params.protocolVersion,
            hostInfo: context.hostInfo,
            hostCapabilities: .object([:]),
            hostContext: hostContext
        ))
    }

    /// View が initialize で**明示した**表示モードを取り出す。
    ///
    /// 戻り値の二重の意味を潰さないことが重要:
    /// - `nil`: `availableDisplayModes` 自体が未設定。apps.mdx:786 の禁止条件は "if set" なので、
    ///   カード発リクエストを能力不足だけを理由に拒否してはならない(旧カード互換)。
    /// - 空集合を含む `Set`: プロパティは設定済み。要求モードが集合に無ければ Host MUST NOT switch。
    ///
    /// JSONValue で保持しているため不正型もここへ到達し得る。不正型を `nil` と同一視すると制約を
    /// 迂回できるので、「設定済みだが有効な宣言なし」= 空集合へ倒して安全側で拒否する。
    static func declaredDisplayModes(_ params: InitializeParams) -> Set<UIDisplayMode>? {
        guard let rawModes = params.appCapabilities["availableDisplayModes"] else { return nil }
        guard let values = rawModes.arrayValue else { return [] }
        return Set(values.compactMap { value in
            value.stringValue.flatMap(UIDisplayMode.init(rawValue:))
        })
    }

    static func supportsFullscreen(_ params: InitializeParams) -> Bool {
        declaredDisplayModes(params)?.contains(.fullscreen) ?? false
    }
}

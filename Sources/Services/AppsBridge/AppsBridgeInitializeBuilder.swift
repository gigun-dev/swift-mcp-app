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

    static func supportsFullscreen(_ params: InitializeParams) -> Bool {
        params.appCapabilities["availableDisplayModes"]?
            .arrayValue?.contains { $0.stringValue == UIDisplayMode.fullscreen.rawValue } ?? false
    }
}

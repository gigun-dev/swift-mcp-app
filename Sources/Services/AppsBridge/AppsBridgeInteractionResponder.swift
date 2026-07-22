import Foundation
import Kernel

/// View起点でユーザー環境へ作用するrequestを、注入されたホスト方針に従って応答する。
struct AppsBridgeInteractionResponder: Sendable {
    let onDisplayModeRequested: (@Sendable (UIDisplayMode) async -> DisplayModeResolution)?
    let onOpenLink: (@Sendable (URL) async -> Bool)?

    /// `unavailable`(initialize 前)・`unspecified`(プロパティ未設定)・`declared` を分ける。
    /// apps.mdx:786 の "if set" により、unspecified は旧カード互換で許可、明示リストは包含時だけ許可する。
    private var displayModeCapabilities: DisplayModeCapabilities = .unavailable

    private enum DisplayModeCapabilities: Sendable {
        case unavailable
        case unspecified
        case declared(Set<UIDisplayMode>)

        func allows(_ mode: UIDisplayMode) -> Bool {
            switch self {
            case .unavailable: false
            case .unspecified: true
            case let .declared(modes): modes.contains(mode)
            }
        }
    }

    init(
        onDisplayModeRequested: (@Sendable (UIDisplayMode) async -> DisplayModeResolution)?,
        onOpenLink: (@Sendable (URL) async -> Bool)?
    ) {
        self.onDisplayModeRequested = onDisplayModeRequested
        self.onOpenLink = onOpenLink
    }

    var supportsDisplayModeRequests: Bool { onDisplayModeRequested != nil }

    /// nil と空集合を同一視しない。nil は wire 上の未設定、空集合は明示したが対応モード無し。
    mutating func configureDisplayModes(_ declaredModes: Set<UIDisplayMode>?) {
        displayModeCapabilities = declaredModes.map(DisplayModeCapabilities.declared) ?? .unspecified
    }

    func openLink(id: RequestID, params: OpenLinkParams) async -> JSONRPCResponse {
        guard let url = OpenLinkPolicy.resolve(urlString: params.url) else {
            return error(id: id, message: "Invalid URL")
        }
        guard let onOpenLink else {
            return error(id: id, message: "Link opening not supported")
        }
        return await onOpenLink(url)
            ? JSONRPCResponse(id: id, result: .object([:]))
            : error(id: id, message: "Link opening denied by user")
    }

    func displayMode(
        id: RequestID,
        params: RequestDisplayModeParams,
        currentMode: UIDisplayMode
    ) async -> JSONRPCResponse {
        // appCapabilities の禁止判定は、実際に UI を切り替える Features callback より前に行う。
        // 拒否も JSON-RPC error ではなく現在モードを返すのが apps.mdx:787 の resulting mode 契約。
        guard displayModeCapabilities.allows(params.mode) else {
            return displayModeResponse(id: id, mode: currentMode)
        }
        let resolution = await onDisplayModeRequested?(params.mode)
            ?? DisplayModeResolution(mode: currentMode)
        return displayModeResponse(id: id, mode: resolution.mode)
    }

    private func displayModeResponse(id: RequestID, mode: UIDisplayMode) -> JSONRPCResponse {
        let result = RequestDisplayModeResult(mode: mode)
        return JSONRPCResponse(
            id: id,
            result: (try? JSONValue(encoding: result)) ?? .object([:])
        )
    }

    private func error(id: RequestID, message: String) -> JSONRPCResponse {
        JSONRPCResponse(id: id, error: JSONRPCError(code: -32000, message: message))
    }
}

import Foundation
import Kernel

/// View起点でユーザー環境へ作用するrequestを、注入されたホスト方針に従って応答する。
struct AppsBridgeInteractionResponder: Sendable {
    let onDisplayModeRequested: (@Sendable (UIDisplayMode) async -> DisplayModeResolution)?
    let onOpenLink: (@Sendable (URL) async -> Bool)?

    var supportsDisplayModeRequests: Bool { onDisplayModeRequested != nil }

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
        let resolution = await onDisplayModeRequested?(params.mode)
            ?? DisplayModeResolution(mode: currentMode)
        let result = RequestDisplayModeResult(mode: resolution.mode)
        return JSONRPCResponse(
            id: id,
            result: (try? JSONValue(encoding: result)) ?? .object([:])
        )
    }

    private func error(id: RequestID, message: String) -> JSONRPCResponse {
        JSONRPCResponse(id: id, error: JSONRPCError(code: -32000, message: message))
    }
}

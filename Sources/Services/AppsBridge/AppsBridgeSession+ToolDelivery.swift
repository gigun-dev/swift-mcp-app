import Kernel

extension AppsBridgeSession {
    /// ツール入力(arguments)を tool-input 通知として送る。ready 前なら outbox へ積む。
    public func sendToolInput(arguments: JSONValue) async {
        let params = ToolInputParams(arguments: arguments)
        let note = JSONRPCNotification(
            method: AppsMethod.toolInput,
            params: try? JSONValue(encoding: params))
        await enqueueOrSend(note, label: "tool-input")
    }

    /// CallToolResult相当のJSONを型付けせず、tool-result通知としてそのまま送る。
    public func sendToolResult(_ raw: JSONValue) async {
        let note = JSONRPCNotification(method: AppsMethod.toolResult, params: raw)
        await enqueueOrSend(note, label: "tool-result")
    }

    public func sendToolCancelled(reason: String) async {
        let params = ToolCancelledParams(reason: reason)
        let note = JSONRPCNotification(
            method: AppsMethod.toolCancelled,
            params: try? JSONValue(encoding: params))
        await enqueueOrSend(note, label: "tool-cancelled")
    }
}

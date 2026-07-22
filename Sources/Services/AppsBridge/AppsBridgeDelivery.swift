import Foundation
import Kernel

/// JSON-RPC型のエンコードとtransport配送を一箇所に閉じ込める。
struct AppsBridgeDelivery: Sendable {
    let transport: any AppsBridgeTransport

    func send(_ notification: JSONRPCNotification) async {
        guard let data = try? JSONEncoder().encode(notification) else { return }
        await transport.deliver(rawJSON: String(data: data, encoding: .utf8) ?? "{}")
    }

    func send(_ response: JSONRPCResponse) async {
        await transport.deliver(response: response)
    }

    func send(_ notifications: [JSONRPCNotification]) async {
        for notification in notifications {
            await send(notification)
        }
    }
}

import Kernel

/// initialize完了前のHost→View通知をFIFOで保持する。
struct AppsBridgeOutbox {
    private var notifications: [JSONRPCNotification] = []

    var count: Int { notifications.count }

    mutating func append(_ notification: JSONRPCNotification) {
        notifications.append(notification)
    }

    mutating func drain() -> [JSONRPCNotification] {
        defer { notifications.removeAll() }
        return notifications
    }
}

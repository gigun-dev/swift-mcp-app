import Kernel

/// Hostが送ったresource-teardown requestとViewのresponseをIDで相関する。
actor TeardownResponseWaiter {
    private var requestID: RequestID?
    private var continuation: CheckedContinuation<Void, Never>?

    func begin(requestID: RequestID) {
        self.requestID = requestID
    }

    func receive(_ response: JSONRPCResponse) -> Bool {
        guard response.id == requestID else { return false }
        requestID = nil
        continuation?.resume()
        continuation = nil
        return true
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            if requestID == nil {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func release() {
        requestID = nil
        continuation?.resume()
        continuation = nil
    }
}

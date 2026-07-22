struct HostRequestIDGenerator {
    private var next = -1

    mutating func make() -> Int {
        defer { next -= 1 }
        return next
    }
}

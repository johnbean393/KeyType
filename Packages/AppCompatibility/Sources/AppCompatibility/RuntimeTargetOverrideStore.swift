import Foundation

public final class RuntimeTargetOverrideStore {
    private let lock = NSLock()
    private var storedOverrides: [TargetOverride]

    public init(overrides: [TargetOverride] = []) {
        self.storedOverrides = overrides
    }

    public var overrides: [TargetOverride] {
        lock.lock()
        defer { lock.unlock() }
        return storedOverrides
    }

    public func replace(overrides: [TargetOverride]) {
        lock.lock()
        storedOverrides = overrides
        lock.unlock()
    }
}

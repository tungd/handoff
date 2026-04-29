import Foundation

public final class AgentInterruptHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Bool)?
    private var pendingRequest = false

    public init() {}

    public func setAction(_ action: @escaping @Sendable () -> Bool) {
        let shouldRun = lock.withLock { () -> Bool in
            self.action = action
            if pendingRequest {
                pendingRequest = false
                return true
            }
            return false
        }

        if shouldRun {
            _ = action()
        }
    }

    public func clearAction() {
        lock.withLock {
            action = nil
            pendingRequest = false
        }
    }

    @discardableResult
    public func requestInterrupt() -> Bool {
        let currentAction = lock.withLock { () -> (@Sendable () -> Bool)? in
            if let action {
                return action
            }
            pendingRequest = true
            return nil
        }

        return currentAction?() ?? true
    }
}

import Foundation

/// Serializes privileged Care / injection / package / bootstrap work so two
/// pipelines never fight over the same app bundle or dpkg lock.
public final class CytrollOperationGate {
    public static let shared = CytrollOperationGate()

    public enum Owner: String {
        case packageTransaction
        case injection
        case autoReinject
        case safeMode
        case dataVault
        case diagnostics
        case appManager
        case bootstrap
    }

    private let lock = NSLock()
    private var current: Owner?

    private init() {}

    public var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return current != nil
            || QueueManager.shared.isProcessing
            || AppInjectionManager.shared.isProcessing
            || DiagnosticsManager.shared.isRepairing
            || BootstrapManager.shared.isBusy
    }

    /// Active Care/pipeline owner, if any. Used by injection to allow
    /// nested rebuilds driven by Auto Re-inject / Safe Mode.
    public var currentOwner: Owner? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public var busyReason: String? {
        lock.lock(); defer { lock.unlock() }
        if let current { return current.rawValue }
        if QueueManager.shared.isProcessing { return Owner.packageTransaction.rawValue }
        if AppInjectionManager.shared.isProcessing { return Owner.injection.rawValue }
        if DiagnosticsManager.shared.isRepairing { return Owner.diagnostics.rawValue }
        if BootstrapManager.shared.isBusy { return Owner.bootstrap.rawValue }
        return nil
    }

    @discardableResult
    public func tryAcquire(_ owner: Owner) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if current != nil { return false }
        if QueueManager.shared.isProcessing { return false }
        if AppInjectionManager.shared.isProcessing { return false }
        if DiagnosticsManager.shared.isRepairing { return false }
        if BootstrapManager.shared.isBusy { return false }
        current = owner
        return true
    }

    public func release(_ owner: Owner) {
        lock.lock(); defer { lock.unlock() }
        if current == owner { current = nil }
    }
}

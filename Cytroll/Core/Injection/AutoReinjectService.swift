import Foundation
import Combine
import UIKit

/// Reapplies tweaks after App Store / TrollStore app updates. Groups
/// `.needsReapply` records per app and runs one rebuild through
/// `AppInjectionManager.applyDesiredTweaks` (fresh pristine when the live
/// app version no longer matches the stored one).
public final class AutoReinjectService: ObservableObject {
    public static let shared = AutoReinjectService()

    @Published public private(set) var isRunning = false
    @Published public private(set) var lastSummary: String?

    private let console = ConsoleManager.shared
    private let recordStore = InjectionRecordStore.shared
    private let injectionManager = AppInjectionManager.shared
    private let care = CytrollCareSettings.shared
    private let safeMode = AppSafeModeManager.shared
    /// Coalesces onAppear + scenePhase.active (same cold launch) and rapid
    /// app switches so we don't rescan installed apps every second.
    private var lastEvaluateAt: Date?
    private let evaluateCooldown: TimeInterval = 8

    private init() {}

    /// Refresh drift flags, then auto-fix when the preference is on.
    /// Cheap when there are no injection records (no app scan).
    public func evaluateOnForeground() {
        // Avoid overlapping work if the user flips apps quickly.
        guard !isRunning else { return }
        let now = Date()
        if let last = lastEvaluateAt, now.timeIntervalSince(last) < evaluateCooldown {
            return
        }
        lastEvaluateAt = now

        recordStore.refreshNeedsReapplyFlags()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            guard !self.isRunning else { return }
            guard self.care.autoReinjectEnabled else { return }
            guard !self.pendingRecords().isEmpty else { return }
            self.reapplyAllPending(triggeredByUser: false)
        }
    }

    public func pendingRecords() -> [InjectionRecord] {
        recordStore.records.filter { record in
            record.status == .needsReapply
                && !safeMode.isPaused(bundleID: record.bundleID)
        }
    }

    public var pendingAppCount: Int {
        Set(pendingRecords().map(\.bundleID)).count
    }

    public func reapplyAllPending(triggeredByUser: Bool, completion: (() -> Void)? = nil) {
        guard !isRunning else { completion?(); return }
        guard CytrollOperationGate.shared.tryAcquire(.autoReinject) else {
            console.log("Re-inject deferred — system busy (\(CytrollOperationGate.shared.busyReason ?? "unknown")).")
            completion?()
            return
        }

        let pending = pendingRecords()
        guard !pending.isEmpty else {
            CytrollOperationGate.shared.release(.autoReinject)
            completion?()
            return
        }

        isRunning = true
        let appCount = Set(pending.map(\.bundleID)).count
        console.log(triggeredByUser
            ? "Re-injecting \(appCount) updated app(s)..."
            : "Auto re-inject: \(appCount) app(s) need reapply.")

        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let byApp = Dictionary(grouping: pending, by: \.bundleID)
            var successApps = 0
            var failedApps = 0

            for (bundleID, records) in byApp {
                let ok = self.reapplyAppSync(bundleID: bundleID, records: records)
                if ok { successApps += 1 } else { failedApps += 1 }
            }

            DispatchQueue.main.async {
                self.isRunning = false
                CytrollOperationGate.shared.release(.autoReinject)
                let summary = "Re-inject finished — \(successApps) ok, \(failedApps) failed."
                self.lastSummary = summary
                self.console.log(summary)
                self.recordStore.refreshNeedsReapplyFlags()
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                }
                completion?()
            }
        }
    }

    private func reapplyAppSync(bundleID: String, records: [InjectionRecord]) -> Bool {
        let displayName = records.first?.appDisplayName ?? bundleID
        let tweaks = records.compactMap { record -> TweakInfo? in
            guard let tweak = self.resolveTweak(id: record.tweakID),
                  FileManager.default.fileExists(atPath: tweak.dylibPath) else {
                return nil
            }
            return tweak
        }
        guard !tweaks.isEmpty else {
            console.log("Re-inject skipped \(displayName) — no dylib on disk.")
            return false
        }

        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        DispatchQueue.main.async {
            self.injectionManager.applyDesiredTweaks(
                bundleID: bundleID,
                displayName: displayName,
                tweaks: tweaks,
                allowCareOwner: true
            ) { result in
                if case .success = result { ok = true }
                else if case .failure(let error) = result {
                    self.console.log("Re-inject failed for \(displayName): \(error.localizedDescription)")
                }
                semaphore.signal()
            }
        }
        semaphore.wait()
        return ok
    }

    private func resolveTweak(id: String) -> TweakInfo? {
        if let apt = TweakInjectionManager.shared.installedTweaks.first(where: { $0.id == id }) {
            return apt
        }
        return SideloadedDylibStore.shared.item(withID: id)?.asTweakInfo
    }
}

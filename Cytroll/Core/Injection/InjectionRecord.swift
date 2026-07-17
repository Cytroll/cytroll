import Foundation
import Combine

public enum InjectionStatus: String, Codable {
    /// Dylib load command present, signature valid, app version unchanged
    /// since injection.
    case active
    /// The target app was updated since injection — App Store/TrollStore
    /// updates replace the executable wholesale, silently reverting the
    /// patch. Needs one tap to re-inject.
    case needsReapply
    /// A rebuild (inject/restore/re-inject) failed AND the atomic swap's
    /// own automatic recovery didn't fully complete (extremely rare — a
    /// filesystem op failing twice in a row) — the app may be left
    /// inconsistent. There's no per-record backup anymore (see
    /// `AppPristineBackupStore`, shared per app rather than per tweak);
    /// the only allowed next step is restoring, which forces a rebuild
    /// from the shared pristine backup (re-inject is blocked until then,
    /// see `AppInjectionManager.performInject`). A background sweep
    /// (`AppInjectionManager.recoverStrayTempDirectories`) also runs on
    /// every launch to self-heal the underlying files where possible.
    case failed
}

/// Persisted record of one tweak-into-app injection, so the Tweaks UI can
/// show "Injected Apps" and detect drift (target app updated) across
/// launches without re-scanning every app's Mach-O load commands.
///
/// Deliberately holds NO backup path of its own — multiple records can
/// share the same `bundleID`, and their app's one true backup lives in
/// `AppPristineBackupStore`, keyed by `bundleID` alone, so restoring or
/// re-injecting any single tweak always rebuilds from the same untouched
/// original regardless of how many other tweaks are also active on it.
public struct InjectionRecord: Identifiable, Codable, Hashable {
    public var id: String { "\(tweakID)::\(bundleID)" }

    public let tweakID: String
    public let tweakName: String
    public let bundleID: String
    public let appDisplayName: String
    /// `CFBundleShortVersionString` of the target app the last time this
    /// tweak's dylib was (re)applied — compared against its current
    /// version to flag `.needsReapply`. Kept in sync across every record
    /// sharing a `bundleID` whenever any one of them triggers a rebuild.
    public var injectedAppVersion: String
    /// Where the tweak's dylib was copied to inside the target bundle.
    public let dylibDestinationPath: String
    public var status: InjectionStatus
    public let injectedAt: Date

    public init(
        tweakID: String,
        tweakName: String,
        bundleID: String,
        appDisplayName: String,
        injectedAppVersion: String,
        dylibDestinationPath: String,
        status: InjectionStatus = .active,
        injectedAt: Date = Date()
    ) {
        self.tweakID = tweakID
        self.tweakName = tweakName
        self.bundleID = bundleID
        self.appDisplayName = appDisplayName
        self.injectedAppVersion = injectedAppVersion
        self.dylibDestinationPath = dylibDestinationPath
        self.status = status
        self.injectedAt = injectedAt
    }
}

/// JSON-backed store for `InjectionRecord`s at
/// `RootlessPaths.injectionRecordsFile`. All reads/writes go through a
/// private serial queue so concurrent inject/restore calls never race on
/// the underlying file.
public final class InjectionRecordStore: ObservableObject {
    public static let shared = InjectionRecordStore()

    @Published public private(set) var records: [InjectionRecord] = []

    private let ioQueue = DispatchQueue(label: "com.cytroll.injectionRecordStore")

    private init() {
        load()
    }

    private func load() {
        ioQueue.sync {
            guard let data = FileManager.default.contents(atPath: RootlessPaths.injectionRecordsFile),
                  let decoded = try? JSONDecoder().decode([InjectionRecord].self, from: data) else {
                return
            }
            DispatchQueue.main.async { self.records = decoded }
        }
    }

    private func persist(_ records: [InjectionRecord]) {
        let dir = RootlessPaths.cytrollStateDir
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: URL(fileURLWithPath: RootlessPaths.injectionRecordsFile), options: .atomic)
    }

    public func upsert(_ record: InjectionRecord) {
        ioQueue.sync {
            var current = self.records
            if let idx = current.firstIndex(where: { $0.id == record.id }) {
                current[idx] = record
            } else {
                current.append(record)
            }
            self.persist(current)
            DispatchQueue.main.async { self.records = current }
        }
    }

    public func remove(id: String) {
        ioQueue.sync {
            let current = self.records.filter { $0.id != id }
            self.persist(current)
            DispatchQueue.main.async { self.records = current }
        }
    }

    public func removeAll(forBundleID bundleID: String) {
        ioQueue.sync {
            let current = self.records.filter { $0.bundleID != bundleID }
            self.persist(current)
            DispatchQueue.main.async { self.records = current }
        }
    }

    public func records(forTweakID tweakID: String) -> [InjectionRecord] {
        records.filter { $0.tweakID == tweakID }
    }

    /// Every tweak currently injected into one specific app — this is
    /// exactly the "desired set" `AppInjectionManager` rebuilds from on
    /// every inject/restore for that `bundleID`.
    public func records(forBundleID bundleID: String) -> [InjectionRecord] {
        records.filter { $0.bundleID == bundleID }
    }

    /// Re-checks every record's target app version against what's
    /// currently installed, flipping `.active` records to
    /// `.needsReapply` when the app was updated since injection. Call
    /// when the Tweaks tab appears — cheap relative to a full app scan
    /// since it reuses one `InstalledAppScanner` pass for every record.
    public func refreshNeedsReapplyFlags() {
        ioQueue.async {
            // No injection history → nothing to drift-check; skip a full
            // installed-apps scan (saves CPU/battery on cold launches).
            let snapshot = self.records
            guard !snapshot.isEmpty else { return }

            let installedApps = InstalledAppScanner.shared.scanInstalledApps()
            let versionByBundleID = Dictionary(uniqueKeysWithValues: installedApps.map { ($0.bundleID, $0.version) })

            var current = snapshot
            var changed = false

            for i in current.indices {
                guard current[i].status != .failed else { continue }
                guard let currentVersion = versionByBundleID[current[i].bundleID] else { continue }
                let shouldNeedReapply = currentVersion != current[i].injectedAppVersion
                let newStatus: InjectionStatus = shouldNeedReapply ? .needsReapply : .active
                if current[i].status != newStatus {
                    current[i].status = newStatus
                    changed = true
                }
            }

            if changed {
                self.persist(current)
                DispatchQueue.main.async { self.records = current }
            }
        }
    }
}

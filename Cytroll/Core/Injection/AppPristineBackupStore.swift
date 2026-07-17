import Foundation

/// One shared, verified "pristine" backup per third-party app bundle ID —
/// captured the very first time ANY tweak is injected into that app, and
/// reused (rebuilt from) for every later inject/restore/re-inject of ANY
/// tweak on that same app.
///
/// This is what makes stacking multiple tweaks on one app safe: every
/// operation recomputes the app from this one known-good copy plus the
/// *current* full set of tweaks that should be active, so restoring tweak
/// A can never accidentally erase tweak B (a real bug in the earlier
/// per-tweak-backup design this replaced, where each tweak's "original"
/// backup was actually a snapshot of the app with every previously
/// injected tweak already baked in — restoring an older one could wipe
/// out a newer one without updating its record).
public struct AppPristineBackup: Codable, Equatable {
    public let bundleID: String
    /// Full path to the backed-up `.app` bundle copy, e.g.
    /// `/var/jb/var/cytroll/backups/<bundleID>/<Name>.app`. Stable per
    /// bundle ID — replaced in place (not versioned/timestamped) whenever
    /// a fresh pristine backup is taken.
    public let backupAppPath: String
    /// Extracted original entitlements plist, read from the backup's
    /// executable before any dylib was ever loaded into it.
    public let entitlementsPath: String
    /// `CFBundleShortVersionString` at the moment this backup was taken.
    /// A mismatch against the live app's current version means the app
    /// was updated since — App Store/TrollStore updates replace the
    /// executable wholesale, so the live app right now (before any of
    /// today's dylibs are reapplied) already IS the new pristine
    /// baseline, and a fresh backup must be taken before rebuilding.
    public let appVersionAtBackup: String
}

/// JSON-backed store for `AppPristineBackup`s at
/// `RootlessPaths.pristineBackupsFile`, keyed by bundle ID. All reads/
/// writes go through a private serial queue so concurrent inject/restore
/// calls — including batch injection across several apps at once — never
/// race on the underlying file.
public final class AppPristineBackupStore {
    public static let shared = AppPristineBackupStore()

    private let ioQueue = DispatchQueue(label: "com.cytroll.pristineBackupStore")
    private var backups: [String: AppPristineBackup] = [:]
    private let fm = FileManager.default

    private init() {
        load()
    }

    private func load() {
        ioQueue.sync {
            guard let data = fm.contents(atPath: RootlessPaths.pristineBackupsFile),
                  let decoded = try? JSONDecoder().decode([AppPristineBackup].self, from: data) else {
                return
            }
            backups = Dictionary(uniqueKeysWithValues: decoded.map { ($0.bundleID, $0) })
        }
    }

    private func persist() {
        if !fm.fileExists(atPath: RootlessPaths.cytrollStateDir) {
            try? fm.createDirectory(atPath: RootlessPaths.cytrollStateDir, withIntermediateDirectories: true)
        }
        guard let data = try? JSONEncoder().encode(Array(backups.values)) else { return }
        try? data.write(to: URL(fileURLWithPath: RootlessPaths.pristineBackupsFile), options: .atomic)
    }

    public func backup(for bundleID: String) -> AppPristineBackup? {
        ioQueue.sync { backups[bundleID] }
    }

    public func set(_ backup: AppPristineBackup) {
        ioQueue.sync {
            backups[backup.bundleID] = backup
            persist()
        }
    }

    public func remove(bundleID: String) {
        ioQueue.sync {
            backups.removeValue(forKey: bundleID)
            persist()
        }
    }

    public var all: [AppPristineBackup] {
        ioQueue.sync { Array(backups.values) }
    }
}

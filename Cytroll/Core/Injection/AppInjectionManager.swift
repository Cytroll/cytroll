import Foundation
import Combine

public enum InjectionError: Error, LocalizedError {
    case appNotFound
    case dylibNotFound
    case toolMissing(String)
    case backupFailed(String)
    case backupVerificationFailed
    case dylibCopyFailed
    case insertDylibFailed
    case signingFailed
    case verificationFailed
    case swapFailed
    case rollbackIncomplete
    case needsRestoreFirst
    case recordMissing
    case busy

    public var errorDescription: String? {
        switch self {
        case .appNotFound: return "Target app not found (was it uninstalled?)."
        case .dylibNotFound: return "Tweak dylib not found on disk."
        case .toolMissing(let name): return "Required bundled tool missing: \(name)."
        case .backupFailed(let reason): return "Backup failed — no changes were made. (\(reason))"
        case .backupVerificationFailed: return "Backup verification failed — aborted before touching the app."
        case .dylibCopyFailed: return "Could not stage the dylib — nothing was touched."
        case .insertDylibFailed: return "Failed to patch a working copy of the app's executable — the live app was never touched."
        case .signingFailed: return "Failed to re-sign the patched working copy — the live app was never touched."
        case .verificationFailed: return "Post-patch verification failed on the working copy — the live app was never touched."
        case .swapFailed: return "Could not swap the rebuilt app into place — the original app was left exactly as it was."
        case .rollbackIncomplete: return "The app may be in an inconsistent state after a failed swap. Tap \"Restore Original\" for it in Injected Apps, or relaunch Cytroll to trigger automatic recovery."
        case .needsRestoreFirst: return "A previous attempt on this app didn't fully recover. Tap \"Restore Original\" for it in Injected Apps before trying again."
        case .recordMissing: return "No pristine backup found for this app/tweak."
        case .busy: return "Another injection operation is already running."
        }
    }
}

/// TrollFools-style per-app tweak injection: patches a third-party app's
/// Mach-O executable to load one or more tweaks' dylibs, re-signs it with
/// `ldid`, and never touches the live app in place.
///
/// Every inject/restore/re-inject is really "rebuild the whole app from
/// its one pristine backup plus whatever full set of tweaks should now be
/// active, entirely inside a temp copy, verify that copy, and only then
/// atomically swap it in." This is what makes multiple tweaks safely
/// stackable on one app — restoring tweak A always reapplies tweak B
/// fresh as part of the same rebuild, so it can never be silently wiped
/// out by an unrelated operation on a different tweak.
public final class AppInjectionManager: ObservableObject {
    public static let shared = AppInjectionManager()

    @Published public private(set) var isProcessing = false

    private let coreBridge = CytrollCoreBridge.shared
    private let console = ConsoleManager.shared
    private let recordStore = InjectionRecordStore.shared
    private let backupStore = AppPristineBackupStore.shared
    private let fm = FileManager.default

    private init() {
        recoverStrayTempDirectories()
    }

    // MARK: - Inject

    public func inject(tweak: TweakInfo, into app: InstalledAppInfo, completion: @escaping (Result<InjectionRecord, InjectionError>) -> Void) {
        injectBatch(tweak: tweak, into: [app], progress: { _, result in completion(result) }, completion: {})
    }

    /// Injects the same tweak into several apps as one operation. Safe to
    /// do sequentially — each app has its own independent pristine backup
    /// and container path, so one app's rebuild can never interfere with
    /// another's.
    public func injectBatch(
        tweak: TweakInfo,
        into apps: [InstalledAppInfo],
        progress: @escaping (InstalledAppInfo, Result<InjectionRecord, InjectionError>) -> Void,
        completion: @escaping () -> Void
    ) {
        guard !isProcessing else {
            completion()
            return
        }
        guard !apps.isEmpty else {
            completion()
            return
        }
        guard !shouldRefuseForForeignGate(allowCareOwner: false) else {
            console.log("Injection deferred — system busy (\(CytrollOperationGate.shared.busyReason ?? "unknown")).")
            completion()
            return
        }
        isProcessing = true
        console.log("Starting injection: \(tweak.name) -> \(apps.count) app(s)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            for app in apps {
                let result = self.performInject(tweak: tweak, app: app)
                DispatchQueue.main.async {
                    switch result {
                    case .success(let record):
                        self.console.log("Injection succeeded: \(tweak.name) -> \(app.displayName).")
                        self.recordStore.upsert(record)
                        self.refreshAppAfterChange(bundlePath: app.bundlePath, displayName: app.displayName)
                    case .failure(let error):
                        self.console.log("Injection FAILED for \(app.displayName): \(error.localizedDescription)")
                        if case .rollbackIncomplete = error {
                            self.markAppRecordsFailed(bundleID: app.bundleID)
                        }
                    }
                    progress(app, result)
                }
            }

            DispatchQueue.main.async {
                self.isProcessing = false
                self.console.log("Injection batch finished. Restart the affected app(s) (uicache/respring recommended) for changes to take effect.")
                completion()
            }
        }
    }

    /// Rebuilds an app to match an exact tweak set. Empty `tweaks` strips
    /// every injection (per-app Safe Mode pause / full restore). Used by
    /// Care features so Pause/Resume/Re-inject are one atomic rebuild each.
    public func applyDesiredTweaks(
        bundleID: String,
        displayName: String,
        tweaks: [TweakInfo],
        allowCareOwner: Bool = false,
        completion: @escaping (Result<Void, InjectionError>) -> Void
    ) {
        guard !isProcessing else {
            completion(.failure(.busy))
            return
        }

        var desiredByID: [String: TweakInfo] = [:]
        for tweak in tweaks { desiredByID[tweak.id] = tweak }
        let desired = Array(desiredByID.values)

        if desired.isEmpty && recordStore.records(forBundleID: bundleID).isEmpty {
            completion(.success(()))
            return
        }
        guard !shouldRefuseForForeignGate(allowCareOwner: allowCareOwner) else {
            completion(.failure(.busy))
            return
        }

        isProcessing = true
        console.log(desired.isEmpty
            ? "Stripping all injections from \(displayName)..."
            : "Rebuilding \(displayName) with \(desired.count) tweak(s)...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            if !desired.isEmpty,
               self.recordStore.records(forBundleID: bundleID).contains(where: { $0.status == .failed }) {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    completion(.failure(.needsRestoreFirst))
                }
                return
            }

            let result = self.rebuild(bundleID: bundleID, desiredTweaks: desired)
            DispatchQueue.main.async {
                self.isProcessing = false
                switch result {
                case .failure(let error):
                    self.console.log("Rebuild FAILED for \(displayName): \(error.localizedDescription)")
                    if case .rollbackIncomplete = error {
                        self.markAppRecordsFailed(bundleID: bundleID)
                    }
                    completion(.failure(error))
                case .success(let pristine):
                    for record in self.recordStore.records(forBundleID: bundleID) {
                        self.recordStore.remove(id: record.id)
                    }
                    if desired.isEmpty {
                        self.backupStore.remove(bundleID: bundleID)
                        self.deleteBackupDir(forBackupAppPath: pristine.backupAppPath)
                        self.console.log("All injections removed from \(displayName).")
                    } else {
                        for tweak in desired {
                            let record = InjectionRecord(
                                tweakID: tweak.id,
                                tweakName: tweak.name,
                                bundleID: bundleID,
                                appDisplayName: displayName,
                                injectedAppVersion: pristine.appVersionAtBackup,
                                dylibDestinationPath: (InstalledAppScanner.shared.app(withBundleID: bundleID)?.bundlePath ?? "")
                                    + "/Frameworks/" + self.dylibFileName(for: tweak)
                            )
                            self.recordStore.upsert(record)
                        }
                        self.console.log("Rebuild succeeded: \(displayName) ← \(desired.count) tweak(s).")
                        if let livePath = InstalledAppScanner.shared.app(withBundleID: bundleID)?.bundlePath {
                            self.refreshAppAfterChange(bundlePath: livePath, displayName: displayName)
                        }
                    }
                    completion(.success(()))
                }
            }
        }
    }

    private func performInject(tweak: TweakInfo, app: InstalledAppInfo) -> Result<InjectionRecord, InjectionError> {
        guard fm.fileExists(atPath: app.bundlePath) else { return .failure(.appNotFound) }
        guard fm.fileExists(atPath: tweak.dylibPath) else { return .failure(.dylibNotFound) }

        // A `.failed` record means a previous rebuild's atomic swap didn't
        // fully recover — refuse to start another rebuild on top of a
        // possibly-inconsistent app. Force an explicit restore first.
        if recordStore.records(forBundleID: app.bundleID).contains(where: { $0.status == .failed }) {
            return .failure(.needsRestoreFirst)
        }

        var desiredByID: [String: TweakInfo] = [:]
        for record in recordStore.records(forBundleID: app.bundleID) {
            if let info = resolveTweakInfo(id: record.tweakID) {
                desiredByID[info.id] = info
            }
        }
        desiredByID[tweak.id] = tweak
        let desiredTweaks = Array(desiredByID.values)

        switch rebuild(bundleID: app.bundleID, desiredTweaks: desiredTweaks) {
        case .failure(let error):
            return .failure(error)
        case .success(let pristine):
            syncSiblingRecords(bundleID: app.bundleID, excludingTweakID: tweak.id, newVersion: pristine.appVersionAtBackup)
            let record = InjectionRecord(
                tweakID: tweak.id,
                tweakName: tweak.name,
                bundleID: app.bundleID,
                appDisplayName: app.displayName,
                injectedAppVersion: pristine.appVersionAtBackup,
                dylibDestinationPath: app.bundlePath + "/Frameworks/" + dylibFileName(for: tweak)
            )
            return .success(record)
        }
    }

    // MARK: - Restore

    /// Removes ONE tweak from an app, rebuilding it with every other
    /// currently-active tweak still applied. Only once the LAST tweak
    /// comes off does the app go back to its untouched pristine state and
    /// its shared backup get freed.
    public func restore(_ record: InjectionRecord, completion: @escaping (Result<Void, InjectionError>) -> Void) {
        guard !isProcessing else {
            completion(.failure(.busy))
            return
        }
        guard !shouldRefuseForForeignGate(allowCareOwner: false) else {
            completion(.failure(.busy))
            return
        }
        isProcessing = true
        console.log("Restoring \(record.tweakName) from \(record.appDisplayName)...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = self.performRestore(record)

            DispatchQueue.main.async {
                self.isProcessing = false
                switch result {
                case .success:
                    self.console.log("Restored \(record.tweakName) from \(record.appDisplayName).")
                    self.recordStore.remove(id: record.id)
                    completion(.success(()))
                    if let livePath = InstalledAppScanner.shared.app(withBundleID: record.bundleID)?.bundlePath {
                        self.refreshAppAfterChange(bundlePath: livePath, displayName: record.appDisplayName)
                    }
                case .failure(let error):
                    self.console.log("Restore FAILED for \(record.appDisplayName): \(error.localizedDescription)")
                    if case .rollbackIncomplete = error {
                        self.markAppRecordsFailed(bundleID: record.bundleID)
                    }
                    completion(.failure(error))
                }
            }
        }
    }

    private func performRestore(_ record: InjectionRecord) -> Result<Void, InjectionError> {
        // `rebuild(_:_:)` does its own `InstalledAppScanner` lookup (and
        // returns `.appNotFound` itself) — avoid scanning every installed
        // app's Info.plist twice per restore just to check the same thing.
        let remaining = recordStore.records(forBundleID: record.bundleID)
            .filter { $0.tweakID != record.tweakID && $0.status != .failed }
            .compactMap { resolveTweakInfo(id: $0.tweakID) }

        switch rebuild(bundleID: record.bundleID, desiredTweaks: remaining) {
        case .failure(let error):
            return .failure(error)
        case .success(let pristine):
            if remaining.isEmpty {
                backupStore.remove(bundleID: record.bundleID)
                deleteBackupDir(forBackupAppPath: pristine.backupAppPath)
            } else {
                syncSiblingRecords(bundleID: record.bundleID, excludingTweakID: record.tweakID, newVersion: pristine.appVersionAtBackup)
            }
            return .success(())
        }
    }

    /// Restores a batch of records sequentially in the background.
    /// Deliberately bypasses the single-operation `isProcessing` guard
    /// used by the user-facing `restore(_:completion:)` — these are
    /// independent, non-interactive cleanups (e.g. several apps injected
    /// with the same tweak that just got disabled/removed), each touching
    /// a different app bundle, so running them back-to-back is safe.
    public func restoreAll(_ records: [InjectionRecord]) {
        guard !records.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            for record in records {
                let result = self.performRestore(record)
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        self.console.log("Restored \(record.tweakName) from \(record.appDisplayName) (its tweak was disabled or removed).")
                        self.recordStore.remove(id: record.id)
                        if let livePath = InstalledAppScanner.shared.app(withBundleID: record.bundleID)?.bundlePath {
                            self.refreshAppAfterChange(bundlePath: livePath, displayName: record.appDisplayName)
                        }
                    case .failure(let error):
                        self.console.log("Auto-restore failed for \(record.appDisplayName): \(error.localizedDescription)")
                        if case .appNotFound = error {
                            // The app itself is gone — nothing left to
                            // restore or track.
                            self.recordStore.remove(id: record.id)
                        } else if record.status != .failed {
                            // Don't let a stale "Active"/"Needs Reapply"
                            // badge keep claiming the tweak is still wired
                            // up when the automatic restore we just tried
                            // actually failed — surface it.
                            if case .rollbackIncomplete = error {
                                self.markAppRecordsFailed(bundleID: record.bundleID)
                            } else {
                                var stale = record
                                stale.status = .failed
                                self.recordStore.upsert(stale)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Lifecycle reconciliation

    /// Called after `TweakInjectionManager.refreshTweaks()` re-scans the
    /// tweak directory. If a tweak that has active `InjectionRecord`s is
    /// no longer present at all (its `.dylib`/`.plist` were deleted — i.e.
    /// apt fully removed/purged the package, as opposed to just disabling
    /// it), every app it was injected into gets automatically restored so
    /// no dangling dylib reference is left pointing at deleted files.
    public func reconcileAfterTweakChanges(currentTweaks: [TweakInfo]) {
        // `currentTweaks` only ever holds apt-sourced tweaks (this is
        // called from `TweakInjectionManager.refreshTweaks()`, which only
        // scans the apt TweakInject directory) — checking a record's
        // tweakID against JUST that list would flag every sideloaded
        // dylib's record as "orphaned" on every single refresh, since a
        // "sideload_..." ID can never appear there. Resolve through both
        // sources instead, same as everywhere else in this class.
        let currentTweakIDs = Set(currentTweaks.map { $0.id })
        let orphaned = recordStore.records.filter { record in
            if currentTweakIDs.contains(record.tweakID) { return false }
            return resolveTweakInfo(id: record.tweakID) == nil
        }
        guard !orphaned.isEmpty else { return }

        console.log("\(orphaned.count) injected app(s) reference a tweak that was removed — restoring automatically.")
        restoreAll(orphaned)
    }

    // MARK: - Rebuild core

    /// Rebuilds `bundleID`'s app from its pristine backup plus an exact
    /// desired set of tweaks: stages everything in a temp copy, verifies
    /// it, then atomically swaps it into place. The live app is only
    /// ever touched at the very last step, and that step is itself
    /// recoverable (see the swap below) — every earlier failure leaves
    /// the live app completely untouched.
    private func rebuild(bundleID: String, desiredTweaks: [TweakInfo]) -> Result<AppPristineBackup, InjectionError> {
        guard let app = InstalledAppScanner.shared.app(withBundleID: bundleID) else {
            return .failure(.appNotFound)
        }

        // Both stores are always kept in sync by this class — the only
        // way to have active records but no matching pristine backup is
        // a corrupted/tampered state file. Refuse to "fix" that by
        // silently backing up the live app (which may already be
        // patched) as if it were pristine; surface it instead.
        let existingRecords = recordStore.records(forBundleID: bundleID).filter { $0.status != .failed }
        if backupStore.backup(for: bundleID) == nil, !existingRecords.isEmpty {
            console.log("WARNING: \(app.displayName) has injection records but no pristine backup on file — flagging as inconsistent instead of risking a bad backup.")
            markAppRecordsFailed(bundleID: bundleID)
            return .failure(.recordMissing)
        }

        let pristine: AppPristineBackup
        if let existing = backupStore.backup(for: bundleID),
           existing.appVersionAtBackup == app.version,
           fm.fileExists(atPath: existing.backupAppPath) {
            pristine = existing
        } else {
            switch takeFreshPristineBackup(app: app) {
            case .success(let fresh): pristine = fresh
            case .failure(let error): return .failure(error)
            }
        }

        guard let insertDylibPath = BootstrapConfig.bundledToolPath("insert_dylib") else {
            return .failure(.toolMissing("insert_dylib"))
        }
        let ldidPath = BootstrapConfig.bundledToolPath("ldid") ?? RootlessPaths.ldid
        guard fm.fileExists(atPath: ldidPath) else { return .failure(.toolMissing("ldid")) }
        for tweak in desiredTweaks {
            guard fm.fileExists(atPath: tweak.dylibPath) else { return .failure(.dylibNotFound) }
        }

        let tempPath = app.bundlePath + ".cytroll_rebuild_tmp"
        _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", tempPath])
        guard coreBridge.executeCommand(executable: "/bin/cp", arguments: ["-Rp", pristine.backupAppPath, tempPath]) else {
            _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", tempPath])
            return .failure(.backupFailed("could not stage a working copy from the pristine backup"))
        }
        guard verifyMirror(source: pristine.backupAppPath, mirror: tempPath) else {
            _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", tempPath])
            return .failure(.backupVerificationFailed)
        }

        let tempExecutablePath = tempPath + "/" + (app.executablePath as NSString).lastPathComponent
        let frameworksDir = tempPath + "/Frameworks"
        _ = coreBridge.executeCommand(executable: "/bin/mkdir", arguments: ["-p", frameworksDir])

        for tweak in desiredTweaks {
            let dylibDestPath = frameworksDir + "/" + dylibFileName(for: tweak)
            guard coreBridge.executeCommand(executable: "/bin/cp", arguments: ["-p", tweak.dylibPath, dylibDestPath]) else {
                _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", tempPath])
                return .failure(.dylibCopyFailed)
            }
            // Ad-hoc sign the injected dylib too (matches real TrollFools
            // behavior; best-effort, failure here is never fatal).
            _ = coreBridge.executeCommand(executable: ldidPath, arguments: ["-S", dylibDestPath])

            let loadCommandString = "@executable_path/Frameworks/\(dylibFileName(for: tweak))"
            let insertArgs = ["--inplace", "--weak", "--strip-codesig", "--all-yes", "--overwrite", loadCommandString, tempExecutablePath]
            guard coreBridge.executeCommand(executable: insertDylibPath, arguments: insertArgs) else {
                _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", tempPath])
                return .failure(.insertDylibFailed)
            }
        }

        let signArgs: [String] = fm.fileExists(atPath: pristine.entitlementsPath)
            ? ["-S\(pristine.entitlementsPath)", tempExecutablePath]
            : ["-S", tempExecutablePath]
        guard coreBridge.executeCommand(executable: ldidPath, arguments: signArgs) else {
            _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", tempPath])
            return .failure(.signingFailed)
        }

        let (verifyOK, _) = coreBridge.executeCommandCapturingOutput(executable: ldidPath, arguments: ["-e", tempExecutablePath])
        guard verifyOK, fm.fileExists(atPath: tempExecutablePath) else {
            _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", tempPath])
            return .failure(.verificationFailed)
        }

        switch atomicSwap(liveBundlePath: app.bundlePath, stagedBundlePath: tempPath, displayName: app.displayName) {
        case .failure(let error):
            return .failure(error)
        case .success:
            backupStore.set(pristine)
            return .success(pristine)
        }
    }

    /// Renames the live bundle aside (never deletes it first), moves the
    /// verified staged copy into place, then cleans up — if the *second*
    /// move fails, moves the original right back so nothing is lost. Only
    /// if BOTH the put-back and one retry of it also fail does the app
    /// end up in a genuinely inconsistent state (`.rollbackIncomplete`);
    /// `recoverStrayTempDirectories()` sweeps for exactly this on the next
    /// launch.
    private func atomicSwap(liveBundlePath: String, stagedBundlePath: String, displayName: String) -> Result<Void, InjectionError> {
        let oldAsidePath = liveBundlePath + ".cytroll_previous_tmp"
        _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", oldAsidePath])

        guard coreBridge.executeCommand(executable: "/bin/mv", arguments: [liveBundlePath, oldAsidePath]) else {
            _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", stagedBundlePath])
            return .failure(.swapFailed)
        }

        guard coreBridge.executeCommand(executable: "/bin/mv", arguments: [stagedBundlePath, liveBundlePath]) else {
            var putBackOK = coreBridge.executeCommand(executable: "/bin/mv", arguments: [oldAsidePath, liveBundlePath])
            if !putBackOK {
                _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", liveBundlePath])
                putBackOK = coreBridge.executeCommand(executable: "/bin/mv", arguments: [oldAsidePath, liveBundlePath])
            }
            _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", stagedBundlePath])
            console.log(putBackOK
                ? "Rebuild failed but \(displayName) was safely restored to its previous state."
                : "CRITICAL: rebuild failed AND \(displayName) could not be restored automatically. Check \(oldAsidePath) with a file manager.")
            return .failure(putBackOK ? .swapFailed : .rollbackIncomplete)
        }

        _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", oldAsidePath])
        return .success(())
    }

    private func takeFreshPristineBackup(app: InstalledAppInfo) -> Result<AppPristineBackup, InjectionError> {
        let backupDir = RootlessPaths.injectionBackupsDir + "/" + sanitize(app.bundleID)
        let appBundleName = (app.bundlePath as NSString).lastPathComponent
        let backupAppPath = backupDir + "/" + appBundleName

        console.log("Backing up \(app.displayName) (pristine baseline)...")
        _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", backupDir])
        _ = coreBridge.executeCommand(executable: "/bin/mkdir", arguments: ["-p", backupDir])

        guard coreBridge.executeCommand(executable: "/bin/cp", arguments: ["-Rp", app.bundlePath, backupAppPath]) else {
            _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", backupDir])
            return .failure(.backupFailed("cp exited with a non-zero status"))
        }
        guard verifyMirror(source: app.bundlePath, mirror: backupAppPath) else {
            console.log("Backup does not mirror the original app (file count/size mismatch) — deleting partial backup, aborting.")
            _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", backupDir])
            return .failure(.backupVerificationFailed)
        }

        let backupExecutablePath = backupAppPath + "/" + (app.executablePath as NSString).lastPathComponent
        let entitlementsPath = backupDir + "/entitlements.plist"
        let ldidPath = BootstrapConfig.bundledToolPath("ldid") ?? RootlessPaths.ldid
        if fm.fileExists(atPath: ldidPath) {
            let (ok, xml) = coreBridge.executeCommandCapturingOutput(executable: ldidPath, arguments: ["-e", backupExecutablePath])
            if ok, xml.contains("<?xml") {
                try? xml.write(toFile: entitlementsPath, atomically: true, encoding: .utf8)
            }
        }

        return .success(AppPristineBackup(
            bundleID: app.bundleID,
            backupAppPath: backupAppPath,
            entitlementsPath: entitlementsPath,
            appVersionAtBackup: app.version
        ))
    }

    // MARK: - Crash / interruption recovery

    /// Sweeps every installed app's container for leftover
    /// `.cytroll_rebuild_tmp` / `.cytroll_previous_tmp` directories — left
    /// behind either by a rebuild that was killed mid-flight (app
    /// force-quit, crash, device reboot during a swap) or by the
    /// doomsday case in `atomicSwap` where even the automatic put-back
    /// didn't succeed. Safe to call anytime; a no-op when nothing is
    /// stray. Runs once at startup and again whenever the Tweaks tab
    /// appears.
    public func recoverStrayTempDirectories() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let root = RootlessPaths.bundleApplicationsRoot
            guard let containerDirs = try? self.fm.contentsOfDirectory(atPath: root) else { return }

            for containerDir in containerDirs {
                let containerPath = root + "/" + containerDir
                guard let entries = try? self.fm.contentsOfDirectory(atPath: containerPath) else { continue }

                for entry in entries where entry.hasSuffix(".cytroll_previous_tmp") {
                    let strayPath = containerPath + "/" + entry
                    let realName = String(entry.dropLast(".cytroll_previous_tmp".count))
                    let realPath = containerPath + "/" + realName
                    if !self.fm.fileExists(atPath: realPath) {
                        self.console.log("Recovering \(realName) from a leftover backup after an interrupted operation...")
                        _ = self.coreBridge.executeCommand(executable: "/bin/mv", arguments: [strayPath, realPath])
                    } else {
                        // The real app is already back in place — this
                        // stray copy is redundant, safe to drop.
                        _ = self.coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", strayPath])
                    }
                }

                for entry in entries where entry.hasSuffix(".cytroll_rebuild_tmp") {
                    // A staged working copy from a killed rebuild — never
                    // the live app itself, always safe to discard.
                    _ = self.coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", containerPath + "/" + entry])
                }
            }
        }
    }

    // MARK: - Helpers

    /// Refuse new work while another pipeline owns the gate.
    /// Care callers (Auto Re-inject / Safe Mode) pass `allowCareOwner: true`
    /// so their nested rebuild is permitted while they hold the gate.
    private func shouldRefuseForForeignGate(allowCareOwner: Bool) -> Bool {
        if QueueManager.shared.isProcessing
            || DiagnosticsManager.shared.isRepairing
            || BootstrapManager.shared.isBusy {
            return true
        }
        guard let owner = CytrollOperationGate.shared.currentOwner else { return false }
        if allowCareOwner {
            switch owner {
            case .autoReinject, .safeMode, .injection, .appManager:
                return false
            case .packageTransaction, .dataVault, .diagnostics, .bootstrap:
                return true
            }
        }
        return true
    }

    /// Best-effort `uicache -p <app.path>` after a successful inject/
    /// restore so the icon/registration cache picks up the change without
    /// requiring a manual respring. Must pass the `.app` bundle path —
    /// Procursus `uicache -p` does not accept a bundle identifier.
    /// Purely a convenience — failure here is never treated as an
    /// injection failure.
    private func refreshAppAfterChange(bundlePath: String, displayName: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self, self.fm.fileExists(atPath: RootlessPaths.uicache) else { return }
            guard self.fm.fileExists(atPath: bundlePath) else { return }
            self.console.log("Refreshing \(displayName)'s registration (uicache -p)...")
            _ = self.coreBridge.executeCommand(executable: RootlessPaths.uicache, arguments: ["-p", bundlePath])
        }
    }

    /// Any OTHER active records for the same app were also just silently
    /// rebuilt (their dylibs reapplied fresh) as a side effect of this
    /// rebuild — bring their bookkeeping (version stamp, `.needsReapply`
    /// -> `.active`) in line with reality instead of leaving them stale
    /// until the next manual reapply.
    private func syncSiblingRecords(bundleID: String, excludingTweakID: String, newVersion: String) {
        for other in recordStore.records(forBundleID: bundleID) where other.tweakID != excludingTweakID && other.status != .failed {
            var updated = other
            updated.injectedAppVersion = newVersion
            updated.status = .active
            recordStore.upsert(updated)
        }
    }

    private func markAppRecordsFailed(bundleID: String) {
        for record in recordStore.records(forBundleID: bundleID) {
            var updated = record
            updated.status = .failed
            recordStore.upsert(updated)
        }
    }

    /// Looks up a tweak by ID across both sources `AppInjectionManager`
    /// can inject: apt-installed tweaks (`TweakInjectionManager`) and
    /// user-picked dylibs (`SideloadedDylibStore`).
    private func resolveTweakInfo(id: String) -> TweakInfo? {
        if let apt = TweakInjectionManager.shared.installedTweaks.first(where: { $0.id == id }) {
            return apt
        }
        return SideloadedDylibStore.shared.item(withID: id)?.asTweakInfo
    }

    /// `backupAppPath` is always `<backupDir>/<AppBundleName>.app`;
    /// deleting its parent removes the whole backup (app copy +
    /// entitlements.plist) in one shot.
    private func deleteBackupDir(forBackupAppPath backupAppPath: String) {
        guard !backupAppPath.isEmpty else { return }
        let backupDir = (backupAppPath as NSString).deletingLastPathComponent
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = self?.coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", backupDir])
        }
    }

    private func dylibFileName(for tweak: TweakInfo) -> String {
        "CytrollTweak_\(sanitize(tweak.id)).dylib"
    }

    private func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    private func verifyMirror(source: String, mirror: String) -> Bool {
        guard let sourceSnapshot = directorySnapshot(at: source),
              let mirrorSnapshot = directorySnapshot(at: mirror) else {
            return false
        }
        return sourceSnapshot.fileCount == mirrorSnapshot.fileCount && sourceSnapshot.totalSize == mirrorSnapshot.totalSize
    }

    private func directorySnapshot(at path: String) -> (fileCount: Int, totalSize: Int64)? {
        guard let enumerator = fm.enumerator(atPath: path) else { return nil }

        var count = 0
        var size: Int64 = 0

        for item in enumerator {
            guard let relativePath = item as? String else { continue }
            let fullPath = path + "/" + relativePath

            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue { continue }

            count += 1
            if let attributes = try? fm.attributesOfItem(atPath: fullPath), let fileSize = attributes[.size] as? Int64 {
                size += fileSize
            }
        }

        return (count, size)
    }
}

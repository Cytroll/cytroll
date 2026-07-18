import Foundation
import Combine
import UIKit
import CryptoKit

public final class BootstrapManager: NSObject, ObservableObject {
    public static let shared = BootstrapManager()

    /// `/var/jb` is the shared rootless prefix (Dopamine / Sileo /
    /// Procursus). `health` distinguishes "no environment", "a real working
    /// one already there — just use it" and "present but missing pieces —
    /// needs repair, not a destructive reinstall".
    @Published public private(set) var health: RootlessPaths.BootstrapHealth = .missing
    @Published public private(set) var isInstalling: Bool = false
    /// True while a download-only (no extract) job is running.
    @Published public private(set) var isDownloading: Bool = false
    @Published public private(set) var progress: Double = 0.0
    @Published public private(set) var logs: [String] = []
    /// Bumped whenever the on-disk cache changes so the gatekeeper CTA refreshes.
    @Published public private(set) var localArchiveRevision: Int = 0

    /// Kept for existing call sites — `true` for both `.healthy` and
    /// `.broken` (a directory is present either way); use `health` directly
    /// when the distinction matters.
    public var isBootstrapInstalled: Bool { health != .missing }

    public var isBusy: Bool { isInstalling || isDownloading }

    private let coreBridge = CytrollCoreBridge.shared
    private let console = ConsoleManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private override init() {
        super.init()
        checkBootstrapStatus()

        console.$logs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newLogs in
                self?.logs = newLogs
            }
            .store(in: &cancellables)
    }

    public func checkBootstrapStatus() {
        health = RootlessPaths.bootstrapHealth
    }

    // MARK: - Local archive (cache + bundled)

    public func hasLocalArchive(for version: BootstrapVersion) -> Bool {
        if FileManager.default.fileExists(atPath: cachedArchiveURL(for: version).path) {
            return true
        }
        return BootstrapConfig.bundledBootstrapURL(for: version) != nil
    }

    public func refreshLocalArchiveAvailability() {
        localArchiveRevision += 1
    }

    /// Application Support cache for a previously downloaded bootstrap tarball.
    public func cachedArchiveURL(for version: BootstrapVersion) -> URL {
        Self.bootstrapCacheDirectory().appendingPathComponent(version.fileName)
    }

    private static func bootstrapCacheDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Cytroll/Bootstrap", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Resolves a local archive without touching the network: persistent
    /// cache first, then any copy bundled inside the app.
    public func resolveLocalArchiveURL(for version: BootstrapVersion) -> URL? {
        let cached = cachedArchiveURL(for: version)
        if FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        return BootstrapConfig.bundledBootstrapURL(for: version)
    }

    // MARK: - Public actions

    /// Downloads the bootstrap archive into the persistent cache only —
    /// does not extract. Prefer `setupBootstrap` for a full real install.
    public func downloadBootstrapOnly(version: BootstrapVersion) {
        guard !isBusy else {
            console.log("Bootstrap download ignored — already busy.")
            return
        }
        guard CytrollOperationGate.shared.tryAcquire(.bootstrap) else {
            console.log("Bootstrap download deferred — system busy (\(CytrollOperationGate.shared.busyReason ?? "unknown")).")
            return
        }

        backgroundTaskID = UIApplication.shared.beginBackgroundTask {
            self.console.log("WARNING: iOS forced background termination!")
            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
        }

        isDownloading = true
        progress = 0.0
        console.clear()
        console.log("Download Bootstrap tapped (\(version.displayName)).")

        Task {
            await performDownloadOnly(version: version)
        }
    }

    /// Extracts from cache/bundled archive with no network. Use for fresh
    /// bootstrap when `health == .missing`.
    public func installFromLocalArchive(version: BootstrapVersion) {
        beginLocalInstall(version: version, preserveExisting: false)
    }

    /// Re-extracts over an incomplete environment from cache/bundled only.
    public func repairFromLocalArchive(version: BootstrapVersion = BootstrapVersion.forCurrentOS()) {
        beginLocalInstall(version: version, preserveExisting: true)
    }

    /// Fresh install — legacy entry that still prefers local then falls back
    /// to download+extract. Prefer the split download/install APIs for UI.
    public func setupBootstrap(version: BootstrapVersion) {
        if hasLocalArchive(for: version) {
            installFromLocalArchive(version: version)
        } else {
            beginInstallWithNetworkFallback(version: version, preserveExisting: false)
        }
    }

    public func repairBootstrap(version: BootstrapVersion = BootstrapVersion.forCurrentOS()) {
        if hasLocalArchive(for: version) {
            repairFromLocalArchive(version: version)
        } else {
            beginInstallWithNetworkFallback(version: version, preserveExisting: true)
        }
    }

    public func autoSetupBootstrap() {
        setupBootstrap(version: BootstrapVersion.forCurrentOS())
    }

    // MARK: - Download only

    private func performDownloadOnly(version: BootstrapVersion) async {
        console.log("Downloading bootstrap (\(version.displayName))...")
        DispatchQueue.main.async { self.progress = 0.02 }

        let entry = BootstrapConfig.manifestEntry(for: version)
            ?? BootstrapConfig.fallbackManifestEntry(for: version)
        guard let remoteURL = URL(string: entry.url) else {
            finishDownload(success: false, reason: "Invalid download URL for \(version.fileName).")
            return
        }

        console.log("Fetching \(entry.url)...")
        guard let downloaded = await downloadBootstrap(
            from: remoteURL,
            fileName: version.fileName,
            expectedSHA256: entry.sha256,
            progressRange: 0.02...0.95
        ) else {
            finishDownload(success: false, reason: "Download failed for \(version.fileName).")
            return
        }

        do {
            let dest = cachedArchiveURL(for: version)
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: downloaded, to: dest)
            if downloaded.path != dest.path {
                try? fm.removeItem(at: downloaded)
            }
            // Keep only this version's archive — drop the other suite's file.
            purgeOtherCachedArchives(keeping: version)
            scrubStaleBootstrapTemps()
            console.log("Bootstrap archive saved — ready to Bootstrap.")
            DispatchQueue.main.async {
                self.progress = 1.0
                self.isDownloading = false
                self.refreshLocalArchiveAvailability()
                self.endBackgroundImmunity()
                CytrollOperationGate.shared.release(.bootstrap)
            }
        } catch {
            finishDownload(success: false, reason: "Could not save archive: \(error.localizedDescription)")
        }
    }

    private func finishDownload(success: Bool, reason: String) {
        if !success {
            console.log("DOWNLOAD ERROR: \(reason)")
        }
        DispatchQueue.main.async {
            self.isDownloading = false
            if !success { self.progress = 0.0 }
            self.refreshLocalArchiveAvailability()
            self.endBackgroundImmunity()
            CytrollOperationGate.shared.release(.bootstrap)
        }
    }

    // MARK: - Local install / repair

    private func beginLocalInstall(version: BootstrapVersion, preserveExisting: Bool) {
        guard !isBusy else {
            console.log("Bootstrap ignored — already busy.")
            return
        }
        guard CytrollOperationGate.shared.tryAcquire(.bootstrap) else {
            console.log("Bootstrap deferred — system busy (\(CytrollOperationGate.shared.busyReason ?? "unknown")).")
            return
        }

        backgroundTaskID = UIApplication.shared.beginBackgroundTask {
            self.console.log("WARNING: iOS forced background termination!")
            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
        }

        // Set busy flags immediately (not deferred) so the button/progress
        // react on the same tap that started the job.
        isInstalling = true
        progress = 0.0
        console.clear()
        console.log(preserveExisting
            ? "Repair Bootstrap tapped (\(version.displayName))."
            : "Bootstrap tapped (\(version.displayName)).")

        Task {
            await installFromLocal(version: version, preserveExisting: preserveExisting)
        }
    }

    private func installFromLocal(version: BootstrapVersion, preserveExisting: Bool) async {
        console.log(preserveExisting
            ? "Repairing rootless environment (\(version.displayName)) from local archive..."
            : "Bootstrapping Procursus (\(version.displayName)) from local archive...")

        DispatchQueue.main.async { self.progress = 0.1 }

        if let archiveURL = resolveLocalArchiveURL(for: version) {
            if archiveURL.path.contains("Application Support") || archiveURL.path.contains("Cytroll/Bootstrap") {
                console.log("Using cached \(version.fileName)")
            } else {
                console.log("Using bundled \(version.fileName)")
            }
            await extractBootstrap(from: archiveURL, version: version, preserveExisting: preserveExisting)
            return
        }

        // Local claimed available but resolve failed — download then extract.
        console.log("Local archive missing — falling back to download…")
        guard let archive = await downloadAndCacheBootstrap(version: version, progressRange: 0.05...0.25) else {
            failBootstrap(reason: "No local bootstrap archive for \(version.fileName), and download failed.")
            return
        }
        await extractBootstrap(from: archive, version: version, preserveExisting: preserveExisting)
    }

    /// Full real path: try local, else download from Procursus then extract
    /// into `/var/jb`.
    private func beginInstallWithNetworkFallback(version: BootstrapVersion, preserveExisting: Bool) {
        guard !isBusy else {
            console.log("Bootstrap ignored — already busy.")
            return
        }
        guard CytrollOperationGate.shared.tryAcquire(.bootstrap) else {
            console.log("Bootstrap deferred — system busy (\(CytrollOperationGate.shared.busyReason ?? "unknown")).")
            return
        }

        backgroundTaskID = UIApplication.shared.beginBackgroundTask {
            self.console.log("WARNING: iOS forced background termination!")
            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
        }

        isInstalling = true
        progress = 0.0
        console.clear()
        console.log("Bootstrap started (\(version.displayName)) — will download from web if needed.")

        Task {
            if let local = resolveLocalArchiveURL(for: version) {
                console.log("Using local archive at \(local.lastPathComponent)")
                await extractBootstrap(from: local, version: version, preserveExisting: preserveExisting)
                return
            }

            console.log(preserveExisting
                ? "Repairing — downloading bootstrap from Procursus…"
                : "Downloading Procursus rootless bootstrap from the web…")

            guard let archive = await downloadAndCacheBootstrap(version: version, progressRange: 0.02...0.28) else {
                failBootstrap(reason: "Could not download bootstrap archive for \(version.fileName). Check network and try again.")
                return
            }

            console.log("Download complete — extracting into \(RootlessPaths.prefix)…")
            await extractBootstrap(from: archive, version: version, preserveExisting: preserveExisting)
        }
    }

    /// Downloads from Procursus (manifest or hardcoded fallback), verifies
    /// optional SHA256, and persists into Application Support cache.
    private func downloadAndCacheBootstrap(
        version: BootstrapVersion,
        progressRange: ClosedRange<Double>
    ) async -> URL? {
        let entry = BootstrapConfig.manifestEntry(for: version)
            ?? BootstrapConfig.fallbackManifestEntry(for: version)
        guard let remoteURL = URL(string: entry.url) else {
            console.log("Invalid remote URL for \(version.fileName)")
            return nil
        }

        console.log("GET \(entry.url)")
        guard let downloaded = await downloadBootstrap(
            from: remoteURL,
            fileName: version.fileName,
            expectedSHA256: entry.sha256,
            progressRange: progressRange
        ) else {
            return nil
        }

        let dest = cachedArchiveURL(for: version)
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: downloaded, to: dest)
            if downloaded.path != dest.path {
                try? fm.removeItem(at: downloaded)
            }
            purgeOtherCachedArchives(keeping: version)
            DispatchQueue.main.async { self.refreshLocalArchiveAvailability() }
            console.log("Cached \(version.fileName) (\(byteCount(of: dest)))")
            return dest
        } catch {
            console.log("Cache write failed (\(error.localizedDescription)) — using temp file.")
            return downloaded
        }
    }

    /// Deletes every cached bootstrap tarball except `keeping` (saves tens of MB).
    private func purgeOtherCachedArchives(keeping version: BootstrapVersion) {
        let fm = FileManager.default
        for other in BootstrapVersion.allCases where other != version {
            let url = cachedArchiveURL(for: other)
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
                console.log("Removed unused cache \(other.fileName)")
            }
        }
    }

    /// After a successful install the archive is no longer needed on-device.
    public func purgeAllBootstrapCaches() {
        let fm = FileManager.default
        for version in BootstrapVersion.allCases {
            let url = cachedArchiveURL(for: version)
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }
        scrubStaleBootstrapTemps()
        DispatchQueue.main.async { self.refreshLocalArchiveAvailability() }
        console.log("Cleared bootstrap download cache (frees app Documents/Support space).")
    }

    private func scrubStaleBootstrapTemps() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return }
        for url in items {
            let name = url.lastPathComponent
            if name.hasPrefix("cytroll-bootstrap-")
                || name.hasPrefix("bootstrap_") && (name.hasSuffix(".tar.zst") || name.hasSuffix(".tar")) {
                try? fm.removeItem(at: url)
            }
        }
    }

    private func byteCount(of url: URL) -> String {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return "?"
        }
        return ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
    }

    private func downloadBootstrap(
        from url: URL,
        fileName: String,
        expectedSHA256: String?,
        progressRange: ClosedRange<Double> = 0.05...0.25
    ) async -> URL? {
        do {
            let downloaded = try await BootstrapDownloadSession.shared.download(
                from: url,
                onProgress: { [weak self] fraction in
                    guard let self = self else { return }
                    let lo = progressRange.lowerBound
                    let hi = progressRange.upperBound
                    let mapped = lo + (hi - lo) * max(0, min(1, fraction))
                    DispatchQueue.main.async { self.progress = mapped }
                }
            )

            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: downloaded, to: dest)

            let sizeNote = byteCount(of: dest)
            console.log("Downloaded \(fileName) (\(sizeNote))")

            // Reject empty / truncated downloads.
            if let size = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber,
               size.intValue < 1_000_000 {
                console.log("Download too small (\(sizeNote)) — rejecting.")
                try? FileManager.default.removeItem(at: dest)
                return nil
            }

            if let expected = expectedSHA256, !expected.isEmpty {
                let data = try Data(contentsOf: dest)
                let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
                guard hash.lowercased() == expected.lowercased() else {
                    console.log("SHA256 mismatch for downloaded bootstrap.")
                    try? FileManager.default.removeItem(at: dest)
                    return nil
                }
                console.log("SHA256 verified.")
            }

            DispatchQueue.main.async { self.progress = progressRange.upperBound }
            return dest
        } catch {
            console.log("Download error: \(error.localizedDescription)")
            return nil
        }
    }

    private func extractBootstrap(from archiveURL: URL, version: BootstrapVersion, preserveExisting: Bool) async {
        let fm = FileManager.default

        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: archiveURL.path)

        if !preserveExisting, fm.fileExists(atPath: RootlessPaths.prefix) {
            console.log("Removing existing \(RootlessPaths.prefix)...")
            _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", RootlessPaths.prefix])
        }

        DispatchQueue.main.async { self.progress = 0.3 }

        guard let zstdPath = BootstrapConfig.bundledToolPath("zstd"),
              let tarPath = BootstrapConfig.bundledToolPath("tar") else {
            failBootstrap(reason: "Missing zstd or tar in app Binaries/.")
            return
        }

        let tarFileName = version.fileName.replacingOccurrences(of: ".zst", with: "")
        let tempTarPath = fm.temporaryDirectory.appendingPathComponent(tarFileName).path

        console.log("Decompressing \(version.fileName)...")
        let zstdOK = coreBridge.executeCommand(executable: zstdPath, arguments: [
            "-d", archiveURL.path, "-o", tempTarPath, "-f"
        ])

        guard zstdOK, fm.fileExists(atPath: tempTarPath) else {
            failBootstrap(reason: "Failed to decompress bootstrap archive.")
            return
        }

        DispatchQueue.main.async { self.progress = 0.5 }
        console.log("Extracting Procursus tree to / (creates \(RootlessPaths.prefix))...")

        let extractOK = coreBridge.executeCommand(executable: tarPath, arguments: [
            "-xpf", tempTarPath, "-C", "/"
        ])
        try? fm.removeItem(atPath: tempTarPath)

        guard extractOK else {
            failBootstrap(reason: "Failed to extract bootstrap tar archive.")
            return
        }

        DispatchQueue.main.async { self.progress = 0.7 }

        _ = coreBridge.executeCommand(
            executable: RootlessPaths.chmod,
            arguments: ["-R", "755", RootlessPaths.prefix]
        )

        runPrepBootstrapScript()
        seedDefaultSources(version: version)

        if fm.fileExists(atPath: RootlessPaths.uicache) {
            console.log("Running uicache...")
            _ = coreBridge.executeCommand(executable: RootlessPaths.uicache, arguments: ["-a"])
        }

        // Bootstrap just laid down a fresh dpkg database and seeded sources —
        // make sure the shared package cache reflects that instead of
        // whatever (empty) state it held before the rootless env existed.
        PackageIndexStore.shared.refresh()

        // Stability: refuse to call the install "done" if apt/dpkg aren't there.
        if !verifyBootstrapHealth() {
            failBootstrap(reason: "Extract finished but /var/jb is incomplete (missing apt/dpkg). Use Repair Bootstrap.")
            return
        }

        // Drop the multi‑MB download cache + temp tars — /var/jb is enough.
        purgeAllBootstrapCaches()

        DispatchQueue.main.async {
            self.progress = 1.0
            self.console.log("Bootstrap ready at \(RootlessPaths.effectivePrefix) — health check passed.")
            self.isInstalling = false
            self.checkBootstrapStatus()
            self.endBackgroundImmunity()
            CytrollOperationGate.shared.release(.bootstrap)
        }
    }

    /// Logs which core tools are present and returns true only when healthy.
    private func verifyBootstrapHealth() -> Bool {
        let fm = FileManager.default
        let checks: [(String, String)] = [
            ("dpkg", RootlessPaths.dpkg),
            ("apt-get", RootlessPaths.aptGet),
            ("dpkg status", RootlessPaths.dpkgStatus),
        ]
        var ok = true
        for (label, path) in checks {
            if fm.fileExists(atPath: path) {
                console.log("Health OK: \(label) at \(path)")
            } else {
                console.log("Health MISSING: \(label) (\(path))")
                ok = false
            }
        }
        return ok
    }

    private func runPrepBootstrapScript() {
        let fm = FileManager.default
        let script = RootlessPaths.prepBootstrapScript
        guard fm.fileExists(atPath: script) else { return }

        console.log("Signing and running prep_bootstrap.sh...")
        let ldidPath = BootstrapConfig.bundledToolPath("ldid") ?? RootlessPaths.ldid
        _ = coreBridge.executeCommand(executable: ldidPath, arguments: ["-S", script])

        if !coreBridge.executeCommand(executable: RootlessPaths.sh, arguments: [script]) {
            console.log("WARNING: prep_bootstrap.sh returned non-zero.")
        }
    }

    /// Seeds / merges essential APT sources (Procursus, ElleKit, Havoc,
    /// Chariz). Idempotent — never wipes an existing `cytroll.list`; only
    /// appends hosts that are still missing.
    private func seedDefaultSources(version: BootstrapVersion) {
        console.log("Ensuring essential APT sources (suite \(version.aptSuite))...")
        let semaphore = DispatchSemaphore(value: 0)
        RepositoryManager.shared.ensureEssentialSources {
            semaphore.signal()
        }
        // Bootstrap runs on a background queue; wait so apt update finishes
        // before we mark install complete.
        _ = semaphore.wait(timeout: .now() + 180)
    }

    private func failBootstrap(reason: String) {
        console.log("BOOTSTRAP ERROR: \(reason)")
        DispatchQueue.main.async {
            self.isInstalling = false
            self.isDownloading = false
            self.progress = 0.0
            self.checkBootstrapStatus()
            self.endBackgroundImmunity()
            CytrollOperationGate.shared.release(.bootstrap)
        }
    }

    private func endBackgroundImmunity() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
}

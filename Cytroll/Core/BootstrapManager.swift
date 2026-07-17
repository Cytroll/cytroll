import Foundation
import Combine
import UIKit
import CryptoKit

public final class BootstrapManager: NSObject, ObservableObject {
    public static let shared = BootstrapManager()

    /// Rootless prefix is `/var/mobile/.lara_jb`. `health` distinguishes
    /// "no environment", "a real working one already there — just use it"
    /// and "present but missing pieces — needs repair, not a destructive
    /// reinstall".
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
            console.log("Bootstrap archive saved — ready to Bootstrap.")
            DispatchQueue.main.async {
                self.progress = 1.0
                self.isDownloading = false
                self.refreshLocalArchiveAvailability()
                self.endBackgroundImmunity()
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
        }
    }

    // MARK: - Local install / repair

    private func beginLocalInstall(version: BootstrapVersion, preserveExisting: Bool) {
        guard !isBusy else {
            console.log("Bootstrap ignored — already busy.")
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
    /// into `/var/mobile/.lara_jb`.
    private func beginInstallWithNetworkFallback(version: BootstrapVersion, preserveExisting: Bool) {
        guard !isBusy else {
            console.log("Bootstrap ignored — already busy.")
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
            DispatchQueue.main.async { self.refreshLocalArchiveAvailability() }
            console.log("Cached \(version.fileName) (\(byteCount(of: dest)))")
            return dest
        } catch {
            console.log("Cache write failed (\(error.localizedDescription)) — using temp file.")
            return downloaded
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

        // Wipe destination prefix on fresh install (never leave a half tree).
        if !preserveExisting {
            for candidate in [RootlessPaths.prefix, RootlessPaths.privatePrefix] {
                if fm.fileExists(atPath: candidate) {
                    console.log("Removing existing \(candidate)...")
                    _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", candidate])
                }
            }
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
        // Upstream archives still unpack as var/jb/... — we relocate next.
        console.log("Extracting Procursus tree (temporary \(RootlessPaths.legacyProcursusPrefix))...")

        let extractOK = coreBridge.executeCommand(executable: tarPath, arguments: [
            "-xpf", tempTarPath, "-C", "/"
        ])
        try? fm.removeItem(atPath: tempTarPath)

        guard extractOK else {
            failBootstrap(reason: "Failed to extract bootstrap tar archive.")
            return
        }

        guard relocateExtractedBootstrap(preserveExisting: preserveExisting) else {
            failBootstrap(reason: "Failed to relocate bootstrap to \(RootlessPaths.prefix).")
            return
        }

        console.log("Rewriting legacy /var/jb paths inside \(RootlessPaths.prefix)...")
        rewriteLegacyJBPaths(in: RootlessPaths.effectivePrefix)

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

        DispatchQueue.main.async {
            self.progress = 1.0
            self.console.log("Bootstrap ready at \(RootlessPaths.effectivePrefix)")
            self.isInstalling = false
            self.checkBootstrapStatus()
            self.endBackgroundImmunity()
        }
    }

    /// Moves the temporary `/var/jb` tree created by the Procursus archive
    /// into `/var/mobile/.lara_jb`, then deletes any leftover legacy path.
    private func relocateExtractedBootstrap(preserveExisting: Bool) -> Bool {
        let fm = FileManager.default
        let dest = RootlessPaths.prefix
        let sources = [
            RootlessPaths.legacyProcursusPrivatePrefix,
            RootlessPaths.legacyProcursusPrefix
        ]

        guard let source = sources.first(where: { fm.fileExists(atPath: $0) }) else {
            // Archive may already have been transformed, or extract used dest.
            if fm.fileExists(atPath: dest) || fm.fileExists(atPath: RootlessPaths.privatePrefix) {
                console.log("Bootstrap already at \(dest)")
                return true
            }
            console.log("ERROR: Extracted tree not found at \(RootlessPaths.legacyProcursusPrefix)")
            return false
        }

        _ = coreBridge.executeCommand(executable: "/bin/mkdir", arguments: ["-p", "/var/mobile"])

        if fm.fileExists(atPath: dest) || fm.fileExists(atPath: RootlessPaths.privatePrefix) {
            if preserveExisting {
                console.log("Merging \(source) into \(dest)...")
                _ = coreBridge.executeCommand(executable: "/bin/mkdir", arguments: ["-p", dest])
                let mergeOK = coreBridge.executeCommand(
                    executable: "/bin/cp",
                    arguments: ["-a", source + "/.", dest + "/"]
                )
                _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", source])
                guard mergeOK else { return false }
            } else {
                console.log("Replacing \(dest) with \(source)...")
                _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", dest])
                _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", RootlessPaths.privatePrefix])
                let moved = coreBridge.executeCommand(executable: "/bin/mv", arguments: [source, dest])
                guard moved else { return false }
            }
        } else {
            console.log("Moving \(source) → \(dest)...")
            let moved = coreBridge.executeCommand(executable: "/bin/mv", arguments: [source, dest])
            guard moved else { return false }
        }

        // Never leave a legacy /var/jb behind.
        for leftover in sources where fm.fileExists(atPath: leftover) {
            console.log("Removing leftover \(leftover)...")
            _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", leftover])
        }

        return fm.fileExists(atPath: dest) || fm.fileExists(atPath: RootlessPaths.privatePrefix)
    }

    private static let pathRewriteExtensions: Set<String> = [
        "sh", "bash", "zsh", "csh", "conf", "cfg", "list", "txt",
        "in", "plist", "service", "py", "pl", "rb", "lua", "json", "xml"
    ]

    /// Rewrites `/var/jb` and `/private/var/jb` string references inside
    /// text-like files under the relocated tree (prep_bootstrap.sh, apt
    /// configs, dpkg metadata, etc.).
    private func rewriteLegacyJBPaths(in root: String) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: root) else { return }

        var rewritten = 0
        while let relative = enumerator.nextObject() as? String {
            let full = root + "/" + relative
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }

            let ext = (relative as NSString).pathExtension.lowercased()
            let base = (relative as NSString).lastPathComponent
            let looksText =
                Self.pathRewriteExtensions.contains(ext) ||
                ext.isEmpty && (base.hasSuffix("_bootstrap") || base.contains("bootstrap") || base == "status") ||
                relative.contains("/dpkg/") ||
                relative.contains("/apt/")

            guard looksText else { continue }
            guard rewriteLegacyJBPathsInFile(at: full) else { continue }
            rewritten += 1
        }

        console.log("Rewrote legacy paths in \(rewritten) file(s).")
    }

    @discardableResult
    private func rewriteLegacyJBPathsInFile(at path: String) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > 0,
              size.intValue <= 2_000_000 else { return false }

        guard let data = fm.contents(atPath: path), !data.isEmpty else { return false }
        // Skip binaries (NUL in the first chunk).
        let probe = data.prefix(8192)
        if probe.contains(0) { return false }

        guard var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return false
        }

        let before = text
        // Longer private path first so we don't double-rewrite.
        text = text.replacingOccurrences(
            of: RootlessPaths.legacyProcursusPrivatePrefix,
            with: RootlessPaths.privatePrefix
        )
        text = text.replacingOccurrences(
            of: RootlessPaths.legacyProcursusPrefix,
            with: RootlessPaths.prefix
        )

        guard text != before else { return false }
        guard let out = text.data(using: .utf8) else { return false }
        return (try? out.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
            || fm.createFile(atPath: path, contents: out, attributes: nil)
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
        }
    }

    private func endBackgroundImmunity() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
}

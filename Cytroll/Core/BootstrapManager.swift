import Foundation
import Combine
import UIKit
import CryptoKit

public final class BootstrapManager: NSObject, ObservableObject {
    public static let shared = BootstrapManager()

    /// `/var/jb` is the shared rootless prefix (also used by Dopamine and
    /// other modern jailbreaks). `health` distinguishes "no environment",
    /// "a real working one already there — just use it" and "present but
    /// missing pieces — needs repair, not a destructive reinstall".
    @Published public private(set) var health: RootlessPaths.BootstrapHealth = .missing
    @Published public private(set) var isInstalling: Bool = false
    @Published public private(set) var progress: Double = 0.0
    @Published public private(set) var logs: [String] = []

    /// Kept for existing call sites — `true` for both `.healthy` and
    /// `.broken` (a directory is present either way); use `health` directly
    /// when the distinction matters.
    public var isBootstrapInstalled: Bool { health != .missing }

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

    /// Fresh install — only meaningful (and only destructive) when nothing
    /// usable exists yet. Wipes `/var/jb` first since there's nothing worth
    /// preserving.
    public func setupBootstrap(version: BootstrapVersion) {
        beginInstall(version: version, preserveExisting: false)
    }

    /// Repairs an incomplete/corrupted environment by re-extracting the
    /// bootstrap tree over what's there — never deletes `/var/jb` first, so
    /// installed packages/tweaks and their config survive. `tar -xpf`
    /// simply overwrites/fills in whatever the archive contains.
    public func repairBootstrap(version: BootstrapVersion = BootstrapVersion.forCurrentOS()) {
        beginInstall(version: version, preserveExisting: true)
    }

    public func autoSetupBootstrap() {
        setupBootstrap(version: BootstrapVersion.forCurrentOS())
    }

    // MARK: - Installation pipeline

    private func beginInstall(version: BootstrapVersion, preserveExisting: Bool) {
        guard !isInstalling else { return }

        backgroundTaskID = UIApplication.shared.beginBackgroundTask {
            self.console.log("WARNING: iOS forced background termination!")
            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
        }

        DispatchQueue.main.async {
            self.isInstalling = true
            self.progress = 0.0
            self.console.clear()
        }

        Task {
            await installBootstrap(version: version, preserveExisting: preserveExisting)
        }
    }

    private func installBootstrap(version: BootstrapVersion, preserveExisting: Bool) async {
        console.log(preserveExisting
            ? "Repairing rootless environment (\(version.displayName)) in place..."
            : "Starting Procursus rootless bootstrap (\(version.displayName))...")

        guard let archiveURL = await acquireBootstrapArchive(version: version) else {
            failBootstrap(reason: "Could not obtain bootstrap archive for \(version.fileName).")
            return
        }

        await extractBootstrap(from: archiveURL, version: version, preserveExisting: preserveExisting)
    }

    /// Remote download first, bundled fallback second.
    private func acquireBootstrapArchive(version: BootstrapVersion) async -> URL? {
        DispatchQueue.main.async { self.progress = 0.05 }

        if let entry = BootstrapConfig.manifestEntry(for: version),
           let remoteURL = URL(string: entry.url) {
            console.log("Downloading bootstrap from \(entry.url)...")
            if let downloaded = await downloadBootstrap(from: remoteURL, fileName: version.fileName, expectedSHA256: entry.sha256) {
                return downloaded
            }
            console.log("Remote download failed — trying bundled archive...")
        }

        if let bundled = BootstrapConfig.bundledBootstrapURL(for: version) {
            console.log("Using bundled \(version.fileName)")
            return bundled
        }

        return nil
    }

    private func downloadBootstrap(from url: URL, fileName: String, expectedSHA256: String?) async -> URL? {
        do {
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)

            if let expected = expectedSHA256, !expected.isEmpty {
                let data = try Data(contentsOf: dest)
                let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
                guard hash.lowercased() == expected.lowercased() else {
                    console.log("SHA256 mismatch for downloaded bootstrap.")
                    try? FileManager.default.removeItem(at: dest)
                    return nil
                }
            }

            DispatchQueue.main.async { self.progress = 0.2 }
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

        DispatchQueue.main.async {
            self.progress = 1.0
            self.console.log("Bootstrap ready at \(RootlessPaths.effectivePrefix)")
            self.isInstalling = false
            self.checkBootstrapStatus()
            self.endBackgroundImmunity()
        }
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

    /// Writes default Procursus APT sources so user can add packages immediately.
    private func seedDefaultSources(version: BootstrapVersion) {
        let fm = FileManager.default
        let sourcesDir = RootlessPaths.sourcesListDir
        let targetFile = RootlessPaths.cytrollSourcesFile

        if !fm.fileExists(atPath: sourcesDir) {
            try? fm.createDirectory(atPath: sourcesDir, withIntermediateDirectories: true)
        }

        if fm.fileExists(atPath: targetFile) {
            console.log("Sources file already exists — skipping default seed.")
            return
        }

        let lines = BootstrapConfig.defaultSources(for: version)
            .map { $0.replacingOccurrences(of: "{SUITE}", with: version.aptSuite) }
        let content = lines.joined(separator: "\n") + "\n"

        do {
            try content.write(toFile: targetFile, atomically: true, encoding: .utf8)
            console.log("Seeded default Procursus sources (\(version.aptSuite)).")
            _ = coreBridge.executeCommand(
                executable: RootlessPaths.aptGet,
                arguments: ["update", "--allow-insecure-repositories"]
            )
        } catch {
            console.log("Failed to seed default sources: \(error.localizedDescription)")
        }
    }

    private func failBootstrap(reason: String) {
        console.log("BOOTSTRAP ERROR: \(reason)")
        DispatchQueue.main.async {
            self.isInstalling = false
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

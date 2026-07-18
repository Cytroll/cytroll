import Foundation
import Combine

public final class JailbreakUtilities: ObservableObject {
    public static let shared = JailbreakUtilities()
    private let bridge = CytrollCoreBridge.shared

    /// Mirrors `/var/jb/.disable_tweaks` for the Home Safe Mode CTA and Settings.
    @Published public private(set) var tweaksEnabled: Bool = true
    @Published public private(set) var isUpdatingSafeMode: Bool = false

    private init() {
        refreshTweaksState()
    }

    public func refreshTweaksState() {
        let enabled = !FileManager.default.fileExists(atPath: RootlessPaths.disableTweaksFlag)
        if Thread.isMainThread {
            tweaksEnabled = enabled
        } else {
            DispatchQueue.main.async { self.tweaksEnabled = enabled }
        }
    }

    /// Runs on a background queue so the UI never freezes waiting on
    /// `posix_spawn` / `waitpid` (respring and userspace reboot often
    /// never return cleanly to the caller anyway).
    public func respring() {
        DispatchQueue.global(qos: .userInitiated).async {
            ConsoleManager.shared.log("Respringing (sbreload)...")
            _ = self.bridge.executeCommand(executable: RootlessPaths.sbreload, arguments: [])
        }
    }

    public func userspaceReboot() {
        DispatchQueue.global(qos: .userInitiated).async {
            ConsoleManager.shared.log("Requesting userspace reboot...")
            _ = self.bridge.executeCommand(
                executable: RootlessPaths.launchctl,
                arguments: ["reboot", "userspace"]
            )
        }
    }

    public func uicache() {
        DispatchQueue.global(qos: .userInitiated).async {
            ConsoleManager.shared.log("Refreshing icon cache (uicache -a)...")
            _ = self.bridge.executeCommand(executable: RootlessPaths.uicache, arguments: ["-a"])
        }
    }

    /// Creates/removes the safe-mode flag via the root helper so the
    /// toggle reflects disk state even when the rootless prefix isn't plain-writable
    /// by the app process.
    public func setTweaksEnabled(_ enabled: Bool, completion: (() -> Void)? = nil) {
        DispatchQueue.main.async { self.isUpdatingSafeMode = true }

        DispatchQueue.global(qos: .userInitiated).async {
            let path = RootlessPaths.disableTweaksFlag
            if enabled {
                if FileManager.default.fileExists(atPath: path) {
                    let ok = self.bridge.executeCommand(executable: "/bin/rm", arguments: ["-f", path])
                    ConsoleManager.shared.log(ok ? "Tweaks enabled (safe-mode flag removed)." : "Failed to remove safe-mode flag.")
                } else {
                    ConsoleManager.shared.log("Tweaks already enabled.")
                }
            } else {
                // `touch` via redirect isn't available; write an empty file
                // with a tiny shell, falling back to FileManager.
                let ok = self.bridge.executeCommand(
                    executable: RootlessPaths.sh,
                    arguments: ["-c", "touch '\(path)'"]
                )
                if !ok {
                    FileManager.default.createFile(atPath: path, contents: nil, attributes: nil)
                }
                let present = FileManager.default.fileExists(atPath: path)
                ConsoleManager.shared.log(present
                    ? "Global Safe Mode ON — tweaks disabled (\(path))."
                    : "Failed to create safe-mode flag at \(path).")
            }

            let nowEnabled = !FileManager.default.fileExists(atPath: path)
            DispatchQueue.main.async {
                self.tweaksEnabled = nowEnabled
                self.isUpdatingSafeMode = false
                completion?()
            }
        }
    }

    /// One-tap global Safe Mode used by the Home dashboard.
    public func enterGlobalSafeMode(thenRespring: Bool, completion: (() -> Void)? = nil) {
        setTweaksEnabled(false) {
            if thenRespring {
                self.respring()
            }
            completion?()
        }
    }

    public func exitGlobalSafeMode(thenRespring: Bool, completion: (() -> Void)? = nil) {
        setTweaksEnabled(true) {
            if thenRespring {
                self.respring()
            }
            completion?()
        }
    }

    public func areTweaksEnabled() -> Bool {
        !FileManager.default.fileExists(atPath: RootlessPaths.disableTweaksFlag)
    }

    public func removeEnvironment(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            ConsoleManager.shared.log("Removing \(RootlessPaths.prefix)...")
            let success = self.bridge.executeCommand(
                executable: "/bin/rm",
                arguments: ["-rf", RootlessPaths.prefix]
            )
            let gone = !FileManager.default.fileExists(atPath: RootlessPaths.prefix)
            DispatchQueue.main.async { completion(success || gone) }
        }
    }
}

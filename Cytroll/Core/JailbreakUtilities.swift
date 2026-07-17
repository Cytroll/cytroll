import Foundation

public final class JailbreakUtilities {
    public static let shared = JailbreakUtilities()
    private let bridge = CytrollCoreBridge.shared

    private init() {}

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
    public func setTweaksEnabled(_ enabled: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let path = RootlessPaths.disableTweaksFlag
            if enabled {
                if FileManager.default.fileExists(atPath: path) {
                    let ok = self.bridge.executeCommand(executable: "/bin/rm", arguments: ["-f", path])
                    ConsoleManager.shared.log(ok ? "Tweaks enabled (safe-mode flag removed)." : "Failed to remove safe-mode flag.")
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
                ConsoleManager.shared.log("Tweaks disabled (safe-mode flag set at \(path)).")
            }
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

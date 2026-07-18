import Foundation
import Combine

public final class DiagnosticsManager: ObservableObject {
    public static let shared = DiagnosticsManager()

    private let coreBridge = CytrollCoreBridge.shared
    private let console = ConsoleManager.shared

    @Published public private(set) var isRepairing: Bool = false

    private init() {}

    public func configureDpkg(completion: @escaping (Bool) -> Void) {
        guard !isRepairing else { return }
        guard CytrollOperationGate.shared.tryAcquire(.diagnostics) else {
            console.log("Diagnostics deferred — system busy (\(CytrollOperationGate.shared.busyReason ?? "unknown")).")
            completion(false)
            return
        }
        isRepairing = true
        console.log("Starting dpkg --configure -a")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let success = self.coreBridge.executeDpkg(arguments: ["--configure", "-a"])

            DispatchQueue.main.async {
                self.console.log(success ? "dpkg configured successfully." : "dpkg configure failed.")
                self.isRepairing = false
                CytrollOperationGate.shared.release(.diagnostics)
                BootstrapManager.shared.checkBootstrapStatus()
                completion(success)
            }
        }
    }

    public func fixBrokenPackages(completion: @escaping (Bool) -> Void) {
        guard !isRepairing else { return }
        guard CytrollOperationGate.shared.tryAcquire(.diagnostics) else {
            console.log("Diagnostics deferred — system busy (\(CytrollOperationGate.shared.busyReason ?? "unknown")).")
            completion(false)
            return
        }
        isRepairing = true
        console.log("Running apt --fix-broken install")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let success = self.coreBridge.executeAptGet(arguments: ["--fix-broken", "install", "-y"])

            DispatchQueue.main.async {
                self.console.log(success ? "Broken packages fixed." : "Fix broken packages failed.")
                self.isRepairing = false
                CytrollOperationGate.shared.release(.diagnostics)
                BootstrapManager.shared.checkBootstrapStatus()
                completion(success)
            }
        }
    }

    /// Runs both repair steps under a single `isRepairing` session so the
    /// Live Console stays open for the whole protocol.
    public func runFullDiagnostics(completion: @escaping (Bool) -> Void) {
        guard !isRepairing else { return }
        guard CytrollOperationGate.shared.tryAcquire(.diagnostics) else {
            console.log("Diagnostics deferred — system busy (\(CytrollOperationGate.shared.busyReason ?? "unknown")).")
            completion(false)
            return
        }
        isRepairing = true
        console.log("Initiating full repair protocol...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            self.console.log("Starting dpkg --configure -a")
            let dpkgSuccess = self.coreBridge.executeDpkg(arguments: ["--configure", "-a"])
            self.console.log(dpkgSuccess ? "dpkg configured successfully." : "dpkg configure failed.")

            self.console.log("Running apt --fix-broken install")
            let aptSuccess = self.coreBridge.executeAptGet(arguments: ["--fix-broken", "install", "-y"])
            self.console.log(aptSuccess ? "Broken packages fixed." : "Fix broken packages failed.")

            self.console.log("Full repair finished.")
            DispatchQueue.main.async {
                self.isRepairing = false
                CytrollOperationGate.shared.release(.diagnostics)
                BootstrapManager.shared.checkBootstrapStatus()
                if BootstrapManager.shared.health == .broken {
                    self.console.log("WARNING: /var/jb still incomplete after repair — use Repair Bootstrap.")
                }
                completion(dpkgSuccess && aptSuccess)
            }
        }
    }
}

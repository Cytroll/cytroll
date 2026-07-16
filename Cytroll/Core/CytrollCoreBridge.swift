import Foundation

public final class CytrollCoreBridge {
    public static let shared = CytrollCoreBridge()

    private let console = ConsoleManager.shared

    public init() {}

    /// Makes sure `helperPath` is executable without ever *lowering* its
    /// current permissions. Blindly forcing `0o755` here would silently
    /// strip an existing setuid bit (`0o4000`) on the one install path
    /// where it's actually meaningful — the `.deb`/`postinst` route, which
    /// runs with real dpkg-level root and can legitimately `chown root` +
    /// `chmod 4755` this file (see `packaging/debian/postinst`). The
    /// primary TrollStore `.tipa` path never has that bit set in the first
    /// place, so this is a no-op there either way.
    private func ensureHelperExecutable(at path: String, fm: FileManager) {
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let existing = attrs[.posixPermissions] as? Int {
            let hasSetuid = (existing & 0o4000) != 0
            let hasOwnerExec = (existing & 0o100) != 0
            guard !hasOwnerExec else { return } // already executable — leave setuid/group/other bits exactly as-is
            let target = hasSetuid ? 0o4755 : 0o755
            try? fm.setAttributes([.posixPermissions: target], ofItemAtPath: path)
        } else {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    /// Executes a command via cytrollhelper (TrollStore root proxy).
    @discardableResult
    public func executeCommand(executable: String, arguments: [String]) -> Bool {
        console.log("Executing: \(executable) \(arguments.joined(separator: " "))")

        let process = Process()
        let helperPath = RootlessPaths.rootHelperPath
        let fm = FileManager.default

        if fm.fileExists(atPath: helperPath) {
            ensureHelperExecutable(at: helperPath, fm: fm)
            process.executableURL = URL(fileURLWithPath: helperPath)
            process.arguments = [executable] + arguments
        } else {
            console.log("WARNING: cytrollhelper not found — direct execution fallback.")
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        }

        process.environment = RootlessEnvironment.make()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.count > 0, let str = String(data: data, encoding: .utf8) {
                str.components(separatedBy: .newlines)
                    .filter { !$0.isEmpty }
                    .forEach { self?.console.log($0) }
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.count > 0, let str = String(data: data, encoding: .utf8) {
                str.components(separatedBy: .newlines)
                    .filter { !$0.isEmpty }
                    .forEach { self?.console.log("ERROR: \($0)") }
            }
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            console.log("EXCEPTION: Failed to launch \(executable): \(error.localizedDescription)")
            return false
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        let success = process.terminationStatus == 0
        if !success {
            console.log("Process exited with status code: \(process.terminationStatus)")
        }
        return success
    }

    /// Like `executeCommand`, but also returns captured stdout as a string.
    /// Used for commands whose *output* matters, not just their exit code
    /// (e.g. `ldid -e <binary>` to dump entitlements XML before re-signing).
    public func executeCommandCapturingOutput(executable: String, arguments: [String]) -> (success: Bool, output: String) {
        console.log("Executing (capture): \(executable) \(arguments.joined(separator: " "))")

        let process = Process()
        let helperPath = RootlessPaths.rootHelperPath
        let fm = FileManager.default

        if fm.fileExists(atPath: helperPath) {
            ensureHelperExecutable(at: helperPath, fm: fm)
            process.executableURL = URL(fileURLWithPath: helperPath)
            process.arguments = [executable] + arguments
        } else {
            console.log("WARNING: cytrollhelper not found — direct execution fallback.")
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        }

        process.environment = RootlessEnvironment.make()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            console.log("EXCEPTION: Failed to launch \(executable): \(error.localizedDescription)")
            return (false, "")
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if let errStr = String(data: errorData, encoding: .utf8), !errStr.isEmpty {
            errStr.components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
                .forEach { console.log("ERROR: \($0)") }
        }

        let success = process.terminationStatus == 0
        let output = String(data: outputData, encoding: .utf8) ?? ""
        if !success {
            console.log("Process exited with status code: \(process.terminationStatus)")
        }
        return (success, output)
    }

    @discardableResult
    public func executeDpkg(arguments: [String]) -> Bool {
        executeCommand(executable: RootlessPaths.dpkg, arguments: arguments)
    }

    @discardableResult
    public func executeAptGet(arguments: [String]) -> Bool {
        executeCommand(executable: RootlessPaths.aptGet, arguments: arguments)
    }
}

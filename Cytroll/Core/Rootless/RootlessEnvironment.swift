import Foundation

/// Procursus-compatible environment variables for rootless APT/dpkg execution.
public enum RootlessEnvironment {

    /// Builds the process environment for privileged commands running inside the rootless prefix.
    public static func make(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        let jb = RootlessPaths.effectivePrefix

        env["PATH"] = [
            RootlessPaths.jb("usr", "bin"),
            RootlessPaths.jb("usr", "local", "bin"),
            RootlessPaths.jb("bin"),
            "/usr/bin",
            "/bin"
        ].joined(separator: ":")

        env["HOME"] = jb
        env["TMPDIR"] = "/tmp"
        env["DEBIAN_FRONTEND"] = "noninteractive"
        env["APT_LISTCHANGES_FRONTEND"] = "none"
        env["CYTROLL_ROOTLESS"] = "1"
        env["CYTROLL_JB_PREFIX"] = jb

        // Procursus rootless dpkg/apt prefix
        env["DPKG_ROOT"] = jb
        env["DPKG_ADMINDIR"] = RootlessPaths.jb("var", "lib", "dpkg")
        env["APT_CONFIG"] = RootlessPaths.jb("etc", "apt", "apt.conf")

        return env
    }
}

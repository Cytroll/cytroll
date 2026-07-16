import Foundation

/// Single source of truth for all rootless jailbreak paths.
/// Procursus installs into `/var/jb` (resolved as `/private/var/jb` on iOS).
/// Never reference signed system volume paths (SSV) from here.
public enum RootlessPaths {

    // MARK: - Prefix

    /// Logical rootless prefix used by Procursus APT/dpkg.
    public static let prefix = "/var/jb"

    /// iOS-resolved physical path (symlink target).
    public static let privatePrefix = "/private/var/jb"

    /// Active prefix — prefers the path that actually exists on disk.
    public static var effectivePrefix: String {
        let fm = FileManager.default
        var isDir: ObjCBool = false

        if fm.fileExists(atPath: privatePrefix, isDirectory: &isDir), isDir.boolValue {
            return privatePrefix
        }
        if fm.fileExists(atPath: prefix, isDirectory: &isDir), isDir.boolValue {
            return prefix
        }
        return prefix
    }

    /// Joins path components under the rootless prefix.
    public static func jb(_ components: String...) -> String {
        ([effectivePrefix] + components).joined(separator: "/")
    }

    // MARK: - APT / dpkg

    public static var aptGet: String { jb("usr", "bin", "apt-get") }
    public static var apt: String { jb("usr", "bin", "apt") }
    public static var dpkg: String { jb("usr", "bin", "dpkg") }

    public static var aptListsDir: String { jb("var", "lib", "apt", "lists") }
    public static var dpkgStatus: String { jb("var", "lib", "dpkg", "status") }
    public static var dpkgInfoDir: String { jb("var", "lib", "dpkg", "info") }
    public static var sourcesListDir: String { jb("etc", "apt", "sources.list.d") }
    public static var cytrollSourcesFile: String { jb("etc", "apt", "sources.list.d", "cytroll.list") }
    public static var aptConfigDir: String { jb("etc", "apt") }

    // MARK: - System utilities (inside prefix)

    public static var sbreload: String { jb("usr", "bin", "sbreload") }
    public static var uicache: String { jb("usr", "bin", "uicache") }
    public static var launchctl: String { jb("bin", "launchctl") }
    public static var sh: String { jb("usr", "bin", "sh") }
    public static var chmod: String { jb("usr", "bin", "chmod") }
    public static var ldid: String { jb("usr", "bin", "ldid") }

    // MARK: - Tweak injection

    public static var tweakInjectDir: String { jb("usr", "lib", "TweakInject") }
    public static var mobileSubstrateDir: String { jb("Library", "MobileSubstrate", "DynamicLibraries") }
    public static var disableTweaksFlag: String { jb(".disable_tweaks") }

    // MARK: - Bootstrap

    public static var prepBootstrapScript: String { jb("prep_bootstrap.sh") }
    public static var applicationsDir: String { jb("Applications") }
    public static var usrBinDir: String { jb("usr", "bin") }

    // MARK: - App bundle

    public static var bundledBinariesDir: String {
        Bundle.main.bundlePath + "/Binaries"
    }

    public static var rootHelperPath: String {
        bundledBinariesDir + "/cytrollhelper"
    }

    // MARK: - Safety

    /// Paths that must never be modified by Cytroll (signed system volume).
    public static let protectedSystemPrefixes = [
        "/System",
        "/private/preboot",
        "/private/var/containers/Bundle/Application",
        "/Applications/Weather.app",
        "/Applications/MobileSafari.app"
    ]

    /// Returns true when `path` is inside the rootless prefix.
    public static func isInsideJBPrefix(_ path: String) -> Bool {
        path.hasPrefix(prefix + "/") ||
        path == prefix ||
        path.hasPrefix(privatePrefix + "/") ||
        path == privatePrefix
    }

    /// Returns true when bootstrap environment is present.
    public static var isBootstrapInstalled: Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let candidates = [prefix, privatePrefix]
        return candidates.contains { candidate in
            fm.fileExists(atPath: candidate, isDirectory: &isDir) && isDir.boolValue
        }
    }

    // MARK: - Environment health

    /// `/var/jb` is the same standard rootless prefix used by Dopamine and
    /// other modern jailbreaks — not something Cytroll necessarily created
    /// itself. A bare directory-exists check can't tell "a real, working
    /// Procursus environment (ours or someone else's)" apart from "an empty
    /// or half-extracted folder left over from a failed install". `health`
    /// actually probes for the binaries/database a rootless env needs.
    public enum BootstrapHealth: Equatable {
        /// No `/var/jb` at all — offer a fresh install.
        case missing
        /// Directory exists and the core apt/dpkg toolchain + database are
        /// present — safe to use as-is, regardless of who created it.
        case healthy
        /// Directory exists but is missing pieces a working environment
        /// needs (interrupted extraction, corrupted install, etc.) —
        /// should be repaired in place, never silently wiped.
        case broken
    }

    public static var bootstrapHealth: BootstrapHealth {
        guard isBootstrapInstalled else { return .missing }

        let fm = FileManager.default
        let requiredPaths = [dpkg, aptGet, dpkgStatus]
        let allPresent = requiredPaths.allSatisfy { fm.fileExists(atPath: $0) }
        return allPresent ? .healthy : .broken
    }
}

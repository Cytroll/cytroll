import Foundation

/// Maps to Procursus's own suite numbering (confirmed against
/// https://apt.procurs.us/dists/ and the Procursus Makefile):
/// 1800 = iOS 15, 1900 = iOS 16. There is no separate published rootless
/// bootstrap tarball for iOS 17/18 yet (Dopamine itself only ships
/// `bootstrap_1800`/`bootstrap_1900`), so 1900 is reused for iOS 16+
/// exactly like upstream does.
public enum BootstrapVersion: String, CaseIterable, Identifiable, Codable {
    case ios15 = "1800"
    case ios16Plus = "1900"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ios15: return "iOS 15.x (Procursus 1800)"
        case .ios16Plus: return "iOS 16.0+ (Procursus 1900)"
        }
    }

    public var fileName: String {
        "bootstrap_\(rawValue).tar.zst"
    }

    /// Procursus's APT suite is literally the numeric prefix (e.g. `1800`),
    /// used as: `deb https://apt.procurs.us/ 1800 main`.
    public var aptSuite: String {
        rawValue
    }

    public static func forCurrentOS() -> BootstrapVersion {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 16 ? .ios16Plus : .ios15
    }
}

public struct BootstrapManifestEntry: Codable {
    public let fileName: String
    public let url: String
    public let sha256: String?
    public let size: Int?
}

public struct BootstrapManifest: Codable {
    public let versions: [String: BootstrapManifestEntry]
}

/// Bootstrap acquisition: remote download (preferred) with bundled fallback.
public enum BootstrapConfig {

    public static let manifestResourceName = "bootstrap-manifest"
    public static let defaultSourcesResourceName = "default-sources"

    public static func manifestEntry(for version: BootstrapVersion) -> BootstrapManifestEntry? {
        if let manifest = loadManifest(), let entry = manifest.versions[version.rawValue] {
            return entry
        }
        // Hardcoded Procursus URLs — always available even if the JSON
        // resource failed to land in the .app bundle.
        return fallbackManifestEntry(for: version)
    }

    /// Official Procursus rootless bootstrap tarballs.
    public static func fallbackManifestEntry(for version: BootstrapVersion) -> BootstrapManifestEntry {
        switch version {
        case .ios15:
            return BootstrapManifestEntry(
                fileName: version.fileName,
                url: "https://apt.procurs.us/bootstraps/1800/bootstrap-iphoneos-arm64.tar.zst",
                sha256: nil,
                size: nil
            )
        case .ios16Plus:
            return BootstrapManifestEntry(
                fileName: version.fileName,
                url: "https://apt.procurs.us/bootstraps/1900/bootstrap-iphoneos-arm64.tar.zst",
                sha256: nil,
                size: nil
            )
        }
    }

    public static func remoteBootstrapURL(for version: BootstrapVersion) -> URL? {
        URL(string: manifestEntry(for: version)?.url ?? fallbackManifestEntry(for: version).url)
    }

    public static func loadManifest() -> BootstrapManifest? {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: manifestResourceName, withExtension: "json", subdirectory: "Resources/Bootstrap"),
            Bundle.main.url(forResource: manifestResourceName, withExtension: "json", subdirectory: "Bootstrap"),
            Bundle.main.url(forResource: manifestResourceName, withExtension: "json"),
        ]
        for candidate in candidates {
            guard let url = candidate,
                  let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(BootstrapManifest.self, from: data) else {
                continue
            }
            return manifest
        }
        return nil
    }

    public static func defaultSources(for version: BootstrapVersion) -> [String] {
        guard let url = Bundle.main.url(
            forResource: defaultSourcesResourceName,
            withExtension: "list",
            subdirectory: "Resources/Bootstrap"
        ) ?? Bundle.main.url(forResource: defaultSourcesResourceName, withExtension: "list") else {
            return fallbackSources(for: version)
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return fallbackSources(for: version)
        }
        return content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Canonical rootless sources Cytroll always wants present. Host is used
    /// for idempotent merge (`RepositoryManager.ensureEssentialSources`) so
    /// we don't double-add if the user already has the same repo under a
    /// slightly different URL spelling.
    public struct EssentialSource: Sendable {
        public let displayName: String
        public let host: String
        public let websiteURL: String
        /// `{SUITE}` is substituted with `BootstrapVersion.aptSuite`.
        public let debLineTemplate: String
    }

    public static let essentialSources: [EssentialSource] = [
        EssentialSource(
            displayName: "Procursus",
            host: "apt.procurs.us",
            websiteURL: "https://procursus.com",
            debLineTemplate: "deb https://apt.procurs.us/ {SUITE} main"
        ),
        EssentialSource(
            displayName: "ElleKit",
            host: "ellekit.space",
            websiteURL: "https://ellekit.space",
            debLineTemplate: "deb https://ellekit.space/ ./"
        ),
        EssentialSource(
            displayName: "Havoc",
            host: "havoc.app",
            websiteURL: "https://havoc.app",
            debLineTemplate: "deb https://havoc.app/ ./"
        ),
        EssentialSource(
            displayName: "Chariz",
            host: "repo.chariz.com",
            websiteURL: "https://chariz.com",
            debLineTemplate: "deb https://repo.chariz.com/ ./"
        ),
    ]

    public static func fallbackSources(for version: BootstrapVersion) -> [String] {
        essentialSources.map {
            $0.debLineTemplate.replacingOccurrences(of: "{SUITE}", with: version.aptSuite)
        }
    }

    public static func friendlySourceName(forHost host: String) -> String? {
        let key = host.lowercased()
        return essentialSources.first(where: { $0.host == key })?.displayName
    }

    public static func bundledBootstrapURL(for version: BootstrapVersion) -> URL? {
        // Prefer a direct path — Bundle.main.url(forResource: "foo.tar.zst")
        // is unreliable with compound extensions on device.
        let direct = RootlessPaths.bundledBinariesDir + "/" + version.fileName
        if FileManager.default.fileExists(atPath: direct) {
            return URL(fileURLWithPath: direct)
        }
        let base = "bootstrap_\(version.rawValue)"
        return Bundle.main.url(forResource: base, withExtension: "tar.zst", subdirectory: "Binaries")
            ?? Bundle.main.url(forResource: base, withExtension: "tar.zst")
    }

    public static func bundledToolPath(_ name: String) -> String? {
        let path = RootlessPaths.bundledBinariesDir + "/\(name)"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }
}

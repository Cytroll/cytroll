import Foundation

/// Lightweight disk/health snapshot for the Storage & Health screen.
public struct CytrollStorageSnapshot: Sendable {
    public let health: RootlessPaths.BootstrapHealth
    public let jbBytes: Int64
    public let bootstrapCacheBytes: Int64
    public let injectionBackupBytes: Int64
    public let dataVaultBytes: Int64
    public let cytrollStateBytes: Int64

    public var totalManagedBytes: Int64 {
        bootstrapCacheBytes + injectionBackupBytes + dataVaultBytes + cytrollStateBytes
    }
}

public enum CytrollStorageHealth {
    public static func snapshot() -> CytrollStorageSnapshot {
        let fm = FileManager.default
        let health = RootlessPaths.bootstrapHealth

        let jbBytes = directorySize(at: RootlessPaths.effectivePrefix)
        let cacheDir = BootstrapManager.shared.cachedArchiveURL(for: .ios15)
            .deletingLastPathComponent().path
        let bootstrapCacheBytes = directorySize(at: cacheDir)
        let injectionBackupBytes = directorySize(at: RootlessPaths.injectionBackupsDir)
        let dataVaultBytes = directorySize(at: RootlessPaths.appDataVaultDir)

        // State JSON + sideloaded dylibs, excluding large backup/vault trees
        // already counted above.
        var stateBytes: Int64 = 0
        let stateDir = RootlessPaths.cytrollStateDir
        if let names = try? fm.contentsOfDirectory(atPath: stateDir) {
            for name in names {
                if name == "backups" || name == "data_vault" { continue }
                stateBytes += directorySize(at: stateDir + "/" + name)
            }
        }

        return CytrollStorageSnapshot(
            health: health,
            jbBytes: jbBytes,
            bootstrapCacheBytes: bootstrapCacheBytes,
            injectionBackupBytes: injectionBackupBytes,
            dataVaultBytes: dataVaultBytes,
            cytrollStateBytes: stateBytes
        )
    }

    public static func clearBootstrapCache() {
        BootstrapManager.shared.purgeAllBootstrapCaches()
    }

    public static func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func directorySize(at path: String) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        var count = 0
        // Cap walk so a huge /var/jb never freezes the UI for minutes.
        let maxFiles = 80_000
        for item in enumerator {
            guard let relative = item as? String else { continue }
            let full = path + "/" + relative
            if let size = try? fm.attributesOfItem(atPath: full)[.size] as? NSNumber {
                total += size.int64Value
            }
            count += 1
            if count >= maxFiles { break }
        }
        return total
    }
}

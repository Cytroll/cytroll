import Foundation

public final class DpkgStatusParser {
    public static let shared = DpkgStatusParser()
    
    private let statusPath = "/var/jb/var/lib/dpkg/status"
    
    private init() {}
    
    /// Reads and parses the dpkg status file into an array of Package objects.
    /// Thread-Safe and highly optimized to handle large strings.
    public func parseInstalledPackages() -> [Package] {
        var installedPackages: [Package] = []
        
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statusPath)),
              let content = String(data: data, encoding: .utf8) else {
            return installedPackages
        }
        
        // Packages in dpkg status are separated by double newlines
        let blocks = content.components(separatedBy: "\n\n")
        
        for block in blocks {
            guard !block.isEmpty else { continue }
            
            let isInstalled = block.contains("Status: install ok installed")
            let isHalfInstalled = block.contains("half-installed")
            let isHalfConfigured = block.contains("half-configured")
            let isUnpacked = block.contains("unpacked")
            
            // تجاهل الحزم غير المثبتة بالكامل أو المحذوفة
            guard isInstalled || isHalfInstalled || isHalfConfigured || isUnpacked else {
                continue
            }
            
            var id = "", name = "", version = "", author = "", architecture = "", description = ""
            
            let lines = block.components(separatedBy: .newlines)
            for line in lines {
                if line.hasPrefix("Package: ") {
                    id = String(line.dropFirst(9))
                } else if line.hasPrefix("Name: ") {
                    name = String(line.dropFirst(6))
                } else if line.hasPrefix("Version: ") {
                    version = String(line.dropFirst(9))
                } else if line.hasPrefix("Author: ") || line.hasPrefix("Maintainer: ") {
                    author = String(line.dropFirst(line.hasPrefix("Author: ") ? 8 : 12))
                } else if line.hasPrefix("Architecture: ") {
                    architecture = String(line.dropFirst(14))
                } else if line.hasPrefix("Description: ") {
                    description = String(line.dropFirst(13))
                }
            }
            
            // Fallback for name if it's missing (some backend packages only have Package ID)
            if name.isEmpty { name = id }
            
            if !id.isEmpty {
                let pkg = Package(id: id, name: name, version: version, author: author, architecture: architecture, description: description)
                installedPackages.append(pkg)
            }
        }
        
        return installedPackages
    }
}

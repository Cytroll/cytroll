import Foundation
import Combine

public final class PackagesViewModel: ObservableObject {
    @Published public private(set) var packages: [Package] = []
    @Published public var searchQuery: String = ""
    
    public init() {
        loadPackagesFromBackend()
    }
    
    public var filteredPackages: [Package] {
        if searchQuery.isEmpty {
            return packages
        } else {
            return packages.filter { 
                $0.name.localizedCaseInsensitiveContains(searchQuery) || 
                $0.id.localizedCaseInsensitiveContains(searchQuery) 
            }
        }
    }
    
    public func loadPackagesFromBackend() {
        // Background parsing to ensure UI does not freeze during heavy IO parsing
        DispatchQueue.global(qos: .userInitiated).async {
            // Load installed packages from the dpkg status file natively
            let installedPackages = DpkgStatusParser.shared.parseInstalledPackages()
            
            // Add packages from the APT repos natively
            let repoPackages = AptIndexParser.shared.parseRepoPackages()
            
            // Merge logic: preserve installed state, but inject sourceURL from repo if available
            var finalDict = [String: Package]()
            
            // 1. Add repo packages first
            for pkg in repoPackages {
                finalDict[pkg.id] = pkg
            }
            
            // 2. Override/Update with installed packages
            for var installedPkg in installedPackages {
                if let repoPkg = finalDict[installedPkg.id] {
                    // If it's in a repo, borrow its sourceURL so we know where it came from
                    installedPkg.sourceURL = repoPkg.sourceURL
                }
                finalDict[installedPkg.id] = installedPkg
            }
            
            let finalPackages = Array(finalDict.values)
            
            DispatchQueue.main.async {
                self.packages = finalPackages.sorted { $0.name.lowercased() < $1.name.lowercased() }
            }
        }
    }
}

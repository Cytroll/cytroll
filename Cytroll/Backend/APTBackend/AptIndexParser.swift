import Foundation

public final class AptIndexParser {
    public static let shared = AptIndexParser()
    
    private let aptListsPath = "/var/jb/var/lib/apt/lists/"
    
    private init() {}
    
    /// Reads and parses all APT index files natively to get repo packages.
    public func parseRepoPackages() -> [Package] {
        var repoPackages: [Package] = []
        
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: aptListsPath) else {
            return repoPackages
        }
        
        // Find all _Packages files
        let packageFiles = files.filter { $0.hasSuffix("_Packages") }
        
        for file in packageFiles {
            let path = aptListsPath + file
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let content = String(data: data, encoding: .utf8) else {
                continue
            }
            
            // استخراج عنوان السورس تقريبياً من اسم الملف
            // مثال: repo.chariz.com_._Packages -> repo.chariz.com
            var sourceURLGuess: String? = nil
            if let firstUnderscoreIndex = file.firstIndex(of: "_") {
                sourceURLGuess = "https://" + String(file[..<firstUnderscoreIndex])
            }
            
            let blocks = content.components(separatedBy: "\n\n")
            
            for block in blocks {
                guard !block.isEmpty else { continue }
                
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
                
                if name.isEmpty { name = id }
                
                if !id.isEmpty {
                    let pkg = Package(id: id, name: name, version: version, author: author, architecture: architecture, description: description, sourceURL: sourceURLGuess)
                    repoPackages.append(pkg)
                }
            }
        }
        
        return repoPackages
    }
}

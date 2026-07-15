import Foundation

public enum QueueAction: String, Codable {
    case install = "Install"
    case remove = "Remove"
    case upgrade = "Upgrade"
    case reinstall = "Reinstall"
}

public struct Package: Identifiable, Hashable, Codable {
    public let id: String // Bundle ID e.g. com.saurik.substrate.safemode
    public let name: String
    public let version: String
    public let author: String
    public let architecture: String
    public let description: String
    public var sourceURL: String?
    
    // UI State flags
    public var isInstalled: Bool = false
    public var isBroken: Bool = false
    
    // The action assigned to this package in the queue
    public var action: QueueAction? = nil
    
    public init(id: String, name: String, version: String, author: String, architecture: String, description: String, sourceURL: String? = nil, isInstalled: Bool = false, isBroken: Bool = false, action: QueueAction? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.architecture = architecture
        self.description = description
        self.sourceURL = sourceURL
        self.isInstalled = isInstalled
        self.isBroken = isBroken
        self.action = action
    }
    
    // Hashable conformance based on bundle ID to ensure uniqueness in Collections
    public static func == (lhs: Package, rhs: Package) -> Bool {
        return lhs.id == rhs.id
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

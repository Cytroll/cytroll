import Foundation
import Combine

public final class RepositoryManager: ObservableObject {
    public static let shared = RepositoryManager()
    
    @Published public private(set) var sources: [Source] = []
    @Published public private(set) var isRefreshing: Bool = false
    
    private var sourcesDir: String { RootlessPaths.sourcesListDir }
    private var cytrollSourcesFile: String { RootlessPaths.cytrollSourcesFile }
    private let coreBridge = CytrollCoreBridge.shared
    /// Avoid re-walking sources.list.d on every Home/Sources appear.
    private var lastEssentialEnsureAt: Date?
    private let essentialEnsureCooldown: TimeInterval = 30
    
    private init() {
        loadSources()
    }
    
    public func loadSources() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Warms the shared cache on first launch (whoever gets there
            // first pays for the parse); every other consumer just reads
            // the same result instead of re-parsing the same files again.
            PackageIndexStore.shared.ensureLoaded {
                DispatchQueue.global(qos: .userInitiated).async {
                    self?.loadSourcesSync()
                }
            }
        }
    }

    /// Synchronous worker — call only from a background thread. Reads the
    /// sources.list(.d) files, tallies real package counts, and publishes
    /// the result on the main thread before returning.
    private func loadSourcesSync() {
            let fm = FileManager.default
            var loadedSources: [Source] = []

            if !fm.fileExists(atPath: self.sourcesDir) {
                try? fm.createDirectory(atPath: self.sourcesDir, withIntermediateDirectories: true, attributes: nil)
            }

            guard let files = try? fm.contentsOfDirectory(atPath: self.sourcesDir) else { return }

            for file in files {
                let path = "\(self.sourcesDir)/\(file)"
                guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }

                if file.hasSuffix(".list") {
                    let lines = content.components(separatedBy: .newlines)
                    for line in lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("deb ") || trimmed.hasPrefix("deb-src ") {
                            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                            if parts.count >= 2 {
                                let url = String(parts[1])
                                loadedSources.append(Source(name: URL(string: url)?.host ?? url, url: url))
                            }
                        }
                    }
                } else if file.hasSuffix(".sources") {
                    // Deb822 format basic parser
                    let blocks = content.components(separatedBy: "\n\n")
                    for block in blocks {
                        let lines = block.components(separatedBy: .newlines)
                        for line in lines {
                            if line.hasPrefix("URIs: ") {
                                let url = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                                if !url.isEmpty {
                                    loadedSources.append(Source(name: URL(string: url)?.host ?? url, url: url))
                                }
                            }
                        }
                    }
                }
            }

            // Remove duplicates by URL
            var uniqueByURL = [String: Source]()
            for s in loadedSources { uniqueByURL[s.url] = s }

            // Real package counts: tally repo packages (from the shared
            // cache — no independent re-parse) by matching host.
            let repoPackages = PackageIndexStore.shared.repoPackagesSnapshot()
            var countsByHost = [String: Int]()
            for pkg in repoPackages {
                guard let sourceURL = pkg.sourceURL, let host = URL(string: sourceURL)?.host else { continue }
                countsByHost[host, default: 0] += 1
            }

            let finalSources = uniqueByURL.values.map { source -> Source in
                let host = URL(string: source.url)?.host ?? source.name
                let count = countsByHost[host] ?? 0
                let name = BootstrapConfig.friendlySourceName(forHost: host) ?? source.name
                return Source(name: name, url: source.url, iconURL: source.iconURL, packageCount: count)
            }.sorted { $0.name.lowercased() < $1.name.lowercased() }

            DispatchQueue.main.async {
                self.sources = finalSources
            }
    }

    /// Ensures Procursus / ElleKit / Havoc / Chariz are present in
    /// `cytroll.list`. Idempotent: matches by host so an existing entry
    /// (any suite / trailing-slash variant) counts. Safe to call on every
    /// Sources-tab appear and after bootstrap — only runs `apt-get update`
    /// when something was actually added.
    public func ensureEssentialSources(completion: (() -> Void)? = nil) {
        let now = Date()
        if let last = lastEssentialEnsureAt, now.timeIntervalSince(last) < essentialEnsureCooldown {
            completion?()
            return
        }
        lastEssentialEnsureAt = now

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { completion?(); return }
            let added = self.ensureEssentialSourcesSync()
            if added {
                ConsoleManager.shared.log("Added missing essential sources. Updating APT...")
                _ = self.coreBridge.executeAptGet(arguments: ["update", "--allow-insecure-repositories"])
                PackageIndexStore.shared.refresh {
                    self.loadSourcesSync()
                    DispatchQueue.main.async { completion?() }
                }
            } else {
                // Still refresh the in-memory list so friendly names show up.
                self.loadSourcesSync()
                DispatchQueue.main.async { completion?() }
            }
        }
    }

    /// Returns `true` if at least one essential source line was appended.
    @discardableResult
    private func ensureEssentialSourcesSync() -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: sourcesDir) {
            try? fm.createDirectory(atPath: sourcesDir, withIntermediateDirectories: true)
        }

        let presentHosts = currentSourceHosts()
        let version = BootstrapVersion.forCurrentOS()
        var linesToAppend: [String] = []

        for essential in BootstrapConfig.essentialSources {
            if presentHosts.contains(essential.host.lowercased()) { continue }
            let line = essential.debLineTemplate
                .replacingOccurrences(of: "{SUITE}", with: version.aptSuite)
            linesToAppend.append(line)
            ConsoleManager.shared.log("Seeding essential source: \(essential.displayName) (\(essential.host))")
        }

        guard !linesToAppend.isEmpty else { return false }

        let block = (linesToAppend.joined(separator: "\n") + "\n")
        if fm.fileExists(atPath: cytrollSourcesFile),
           let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: cytrollSourcesFile)) {
            handle.seekToEndOfFile()
            if let data = block.data(using: .utf8) { handle.write(data) }
            handle.closeFile()
        } else {
            try? block.write(toFile: cytrollSourcesFile, atomically: true, encoding: .utf8)
        }
        return true
    }

    private func currentSourceHosts() -> Set<String> {
        var hosts = Set<String>()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sourcesDir) else { return hosts }

        for file in files {
            let path = "\(sourcesDir)/\(file)"
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }

            if file.hasSuffix(".list") {
                for line in content.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("deb ") || trimmed.hasPrefix("deb-src ") else { continue }
                    let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                    guard parts.count >= 2, let host = URL(string: String(parts[1]))?.host else { continue }
                    hosts.insert(host.lowercased())
                }
            } else if file.hasSuffix(".sources") {
                for block in content.components(separatedBy: "\n\n") {
                    guard let uriLine = block.components(separatedBy: .newlines).first(where: { $0.hasPrefix("URIs: ") }) else { continue }
                    let url = String(uriLine.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    if let host = URL(string: url)?.host {
                        hosts.insert(host.lowercased())
                    }
                }
            }
        }
        return hosts
    }

    /// Runs a real `apt-get update` through the root helper, then reloads
    /// sources/counts. Used by the pull-to-refresh gesture in Sources tab.
    public func refreshAll(completion: (() -> Void)? = nil) {
        guard !isRefreshing else { completion?(); return }
        isRefreshing = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            ConsoleManager.shared.log("Refreshing APT sources...")
            let success = self.coreBridge.executeAptGet(arguments: ["update", "--allow-insecure-repositories"])
            ConsoleManager.shared.log(success ? "Sources refreshed." : "Failed to refresh sources — check your connection.")

            // `apt-get update` just rewrote the on-disk `_Packages` files,
            // so the shared cache must be force-refreshed (not just
            // ensure-loaded) before recomputing per-source counts.
            PackageIndexStore.shared.refresh {
                self.loadSourcesSync()

                DispatchQueue.main.async {
                    self.isRefreshing = false
                    completion?()
                }
            }
        }
    }
    
    public func addSource(url: String) {
        var cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanURL.count > 10,
              let parsed = URL(string: cleanURL),
              parsed.scheme == "http" || parsed.scheme == "https",
              parsed.host != nil else {
            ConsoleManager.shared.log("Rejected invalid source URL: \(url)")
            return
        }
        if !cleanURL.hasSuffix("/") { cleanURL += "/" }

        let host = parsed.host!.lowercased()
        if sources.contains(where: {
            normalize($0.url) == normalize(cleanURL)
                || (URL(string: $0.url)?.host?.lowercased() == host)
        }) {
            ConsoleManager.shared.log("Source \(cleanURL) already exists.")
            return
        }
        
        let newLine = "deb \(cleanURL) ./\n"
        
        let fm = FileManager.default
        if fm.fileExists(atPath: cytrollSourcesFile) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: cytrollSourcesFile)) {
                handle.seekToEndOfFile()
                if let data = newLine.data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            }
        } else {
            try? newLine.write(toFile: cytrollSourcesFile, atomically: true, encoding: .utf8)
        }
        
        ConsoleManager.shared.log("Added source: \(cleanURL). Updating APT...")
        
        // Run APT update using the bridge in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            _ = self.coreBridge.executeAptGet(arguments: ["update", "--allow-insecure-repositories"])
            // New source's index just landed on disk — force a re-parse
            // rather than `loadSources()`'s ensure-loaded (which would
            // no-op since the cache is already warm from a prior load).
            PackageIndexStore.shared.refresh {
                self.loadSourcesSync()
            }
        }
    }

    /// Removes a source's line (`.list`) or block (`.sources`, Deb822) from
    /// whichever file under `sources.list.d/` actually contains it — not
    /// just Cytroll's own `cytroll.list`, since other installers can drop
    /// their own `.list` files there too. Plain `FileManager` I/O mirrors
    /// `addSource` above: this directory is writable without going through
    /// `cytrollhelper`. Never touches the top-level `sources.list` file
    /// (out of scope — `loadSourcesSync` never reads it either).
    public func removeSource(_ source: Source) {
        let normalizedTarget = normalize(source.url)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(atPath: self.sourcesDir) else { return }

            for file in files {
                let path = "\(self.sourcesDir)/\(file)"
                guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }

                if file.hasSuffix(".list") {
                    let keptLines = content.components(separatedBy: .newlines).filter { line in
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("deb ") || trimmed.hasPrefix("deb-src ") else { return true }
                        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                        guard parts.count >= 2 else { return true }
                        return self.normalize(String(parts[1])) != normalizedTarget
                    }
                    self.rewriteOrDelete(path: path, lines: keptLines)
                } else if file.hasSuffix(".sources") {
                    let blocks = content.components(separatedBy: "\n\n")
                    let keptBlocks = blocks.filter { block in
                        guard let uriLine = block.components(separatedBy: .newlines).first(where: { $0.hasPrefix("URIs: ") }) else { return true }
                        let url = String(uriLine.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        return self.normalize(url) != normalizedTarget
                    }
                    self.rewriteOrDelete(path: path, blocks: keptBlocks)
                }
            }

            ConsoleManager.shared.log("Removed source: \(source.url). Updating APT...")
            _ = self.coreBridge.executeAptGet(arguments: ["update", "--allow-insecure-repositories"])
            PackageIndexStore.shared.refresh {
                self.loadSourcesSync()
            }
        }
    }

    /// Edits a source's URL in place, wherever its line/block currently
    /// lives, preserving that file and every other entry in it. Falls back
    /// to a no-op with a console warning if the old URL can't be found
    /// (e.g. it was already removed/refreshed away).
    public func editSource(oldURL: String, newURL: String) {
        var cleanNew = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanNew.hasSuffix("/") { cleanNew += "/" }
        let normalizedOld = normalize(oldURL)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(atPath: self.sourcesDir) else { return }
            var replaced = false

            for file in files {
                let path = "\(self.sourcesDir)/\(file)"
                guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }

                if file.hasSuffix(".list") {
                    let lines = content.components(separatedBy: .newlines).map { line -> String in
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("deb ") || trimmed.hasPrefix("deb-src ") else { return line }
                        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                        guard parts.count >= 2, self.normalize(parts[1]) == normalizedOld else { return line }
                        replaced = true
                        var newParts = parts
                        newParts[1] = cleanNew
                        return newParts.joined(separator: " ")
                    }
                    if replaced {
                        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                        break
                    }
                } else if file.hasSuffix(".sources") {
                    let blocks = content.components(separatedBy: "\n\n").map { block -> String in
                        guard block.contains("URIs: ") else { return block }
                        let lines = block.components(separatedBy: .newlines).map { line -> String in
                            guard line.hasPrefix("URIs: ") else { return line }
                            let url = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                            guard self.normalize(url) == normalizedOld else { return line }
                            replaced = true
                            return "URIs: \(cleanNew)"
                        }
                        return lines.joined(separator: "\n")
                    }
                    if replaced {
                        try? blocks.joined(separator: "\n\n").write(toFile: path, atomically: true, encoding: .utf8)
                        break
                    }
                }
            }

            guard replaced else {
                ConsoleManager.shared.log("Could not find source \(oldURL) to edit.")
                return
            }

            ConsoleManager.shared.log("Updated source to \(cleanNew). Updating APT...")
            _ = self.coreBridge.executeAptGet(arguments: ["update", "--allow-insecure-repositories"])
            PackageIndexStore.shared.refresh {
                self.loadSourcesSync()
            }
        }
    }

    // MARK: - Source file helpers

    private func normalize(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasSuffix("/") { s += "/" }
        return s.lowercased()
    }

    private func rewriteOrDelete(path: String, lines: [String]) {
        let isEmpty = lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        if isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        } else {
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func rewriteOrDelete(path: String, blocks: [String]) {
        let isEmpty = blocks.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        } else {
            try? blocks.joined(separator: "\n\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

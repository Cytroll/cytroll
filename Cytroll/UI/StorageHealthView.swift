import SwiftUI

/// Stability-focused overview: rootless health + where Cytroll/jb disk goes,
/// with one-tap cleanup for reclaimable app cache.
public struct StorageHealthView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @ObservedObject private var bootstrapManager = BootstrapManager.shared

    @State private var snapshot: CytrollStorageSnapshot?
    @State private var isLoading = true
    @State private var isClearingCache = false

    public init() {}

    public var body: some View {
        ZStack {
            themeManager.backgroundGradient().ignoresSafeArea()

            if isLoading && snapshot == nil {
                ProgressView("Measuring storage…")
                    .tint(themeManager.currentTheme.accent)
            } else if let snapshot {
                List {
                    Section(header: Text("Environment Health").foregroundColor(themeManager.currentTheme.textSecondary)) {
                        HStack {
                            Text("Status")
                                .foregroundColor(themeManager.currentTheme.textPrimary)
                            Spacer()
                            Text(healthLabel(snapshot.health))
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(healthColor(snapshot.health))
                        }
                        Text(healthDetail(snapshot.health))
                            .font(.caption)
                            .foregroundColor(themeManager.currentTheme.textSecondary)
                    }
                    .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))

                    Section(header: Text("Disk Usage").foregroundColor(themeManager.currentTheme.textSecondary)) {
                        row("Rootless \(RootlessPaths.prefix)", snapshot.jbBytes)
                        row("Bootstrap download cache", snapshot.bootstrapCacheBytes)
                        row("Injection backups", snapshot.injectionBackupBytes)
                        row("Data Vault", snapshot.dataVaultBytes)
                        row("Cytroll state", snapshot.cytrollStateBytes)
                        HStack {
                            Text("Cytroll managed (excl. /var/jb tree)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(themeManager.currentTheme.textPrimary)
                            Spacer()
                            Text(CytrollStorageHealth.formattedBytes(snapshot.totalManagedBytes))
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(themeManager.currentTheme.accent)
                        }
                    }
                    .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))

                    Section(
                        header: Text("Cleanup").foregroundColor(themeManager.currentTheme.textSecondary),
                        footer: Text("Clearing the bootstrap cache only removes downloaded .tar.zst files from the app. /var/jb and package installs are untouched. Injection backup cleanup is on the Tweaks → Backup Storage screen.")
                    ) {
                        Button(action: clearCache) {
                            HStack {
                                if isClearingCache { ProgressView().tint(.orange) }
                                Text(snapshot.bootstrapCacheBytes > 0
                                      ? "Clear Bootstrap Cache (\(CytrollStorageHealth.formattedBytes(snapshot.bootstrapCacheBytes)))"
                                      : "Bootstrap Cache Empty")
                            }
                        }
                        .foregroundColor(.orange)
                        .disabled(isClearingCache || snapshot.bootstrapCacheBytes == 0 || bootstrapManager.isBusy)

                        NavigationLink(destination: InjectionBackupStorageView()) {
                            Text("Injection Backup Storage")
                                .foregroundColor(themeManager.currentTheme.textPrimary)
                        }
                    }
                    .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                }
                .listStyle(.insetGrouped)
                .cytrollHideScrollBackground()
            }
        }
        .navigationTitle("Storage & Health")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .refreshable { reload() }
    }

    private func row(_ title: String, _ bytes: Int64) -> some View {
        HStack {
            Text(title)
                .foregroundColor(themeManager.currentTheme.textPrimary)
            Spacer()
            Text(CytrollStorageHealth.formattedBytes(bytes))
                .foregroundColor(themeManager.currentTheme.textSecondary)
        }
    }

    private func healthLabel(_ health: RootlessPaths.BootstrapHealth) -> String {
        switch health {
        case .healthy: return "Healthy"
        case .broken: return "Broken"
        case .missing: return "Missing"
        }
    }

    private func healthColor(_ health: RootlessPaths.BootstrapHealth) -> Color {
        switch health {
        case .healthy: return .green
        case .broken: return .orange
        case .missing: return .red
        }
    }

    private func healthDetail(_ health: RootlessPaths.BootstrapHealth) -> String {
        switch health {
        case .healthy:
            return "dpkg, apt-get, and the package database are present under \(RootlessPaths.effectivePrefix)."
        case .broken:
            return "A rootless tree exists but core tools are missing. Use Repair Bootstrap on Home."
        case .missing:
            return "No rootless environment at \(RootlessPaths.prefix). Run Bootstrap from Home."
        }
    }

    private func reload() {
        isLoading = true
        bootstrapManager.checkBootstrapStatus()
        DispatchQueue.global(qos: .utility).async {
            let snap = CytrollStorageHealth.snapshot()
            DispatchQueue.main.async {
                self.snapshot = snap
                self.isLoading = false
            }
        }
    }

    private func clearCache() {
        isClearingCache = true
        DispatchQueue.global(qos: .utility).async {
            CytrollStorageHealth.clearBootstrapCache()
            let snap = CytrollStorageHealth.snapshot()
            DispatchQueue.main.async {
                self.snapshot = snap
                self.isClearingCache = false
            }
        }
    }
}

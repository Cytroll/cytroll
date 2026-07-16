import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var diagnostics = DiagnosticsManager.shared
    @StateObject private var queueManager = QueueManager.shared
    @State private var tweaksEnabled: Bool = JailbreakUtilities.shared.areTweaksEnabled()

    /// Diagnostics/removal and a queued install/remove transaction both
    /// drive dpkg/apt directly — never let them run at the same time.
    private var isSystemBusy: Bool { queueManager.isProcessing || diagnostics.isRepairing }
    @State private var showingRemoveAlert = false
    @State private var isRemoving = false
    
    // Backup & Restore states
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var backupDocument: BackupDocument?
    
    // Live Diagnostics Console State
    @State private var showingDiagnosticsConsole = false
    
    public init() {}
    
    public var body: some View {
        NavigationView {
            ZStack {
                themeManager.backgroundGradient().ignoresSafeArea()
                
                List {
                    // MARK: Backup & Restore
                    Section(header: Text("Data Management").foregroundColor(themeManager.currentTheme.textSecondary)) {
                        Button(action: {
                            backupDocument = BackupManager.shared.createBackup()
                            showingExporter = true
                        }) {
                            HStack {
                                Image(systemName: "square.and.arrow.up.fill")
                                Text("Backup Tweaks List")
                            }
                        }
                        
                        Button(action: {
                            showingImporter = true
                        }) {
                            HStack {
                                Image(systemName: "square.and.arrow.down.fill")
                                Text("Restore Tweaks List")
                            }
                        }
                    }
                    .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                    .foregroundColor(themeManager.currentTheme.accent)
                    
                    // MARK: Appearance
                    Section(header: Text("Appearance").foregroundColor(themeManager.currentTheme.textSecondary)) {
                        Picker(selection: Binding(
                            get: { themeManager.currentTheme.name },
                            set: { themeManager.switchTheme(to: $0) }
                        ), label: HStack {
                            Image(systemName: "paintpalette.fill")
                                .foregroundColor(themeManager.currentTheme.accent)
                            Text("App Theme")
                        }) {
                            Text("Mocha (Classic)").tag("Mocha")
                            Text("Espresso (OLED Dark)").tag("Espresso")
                        }
                        .pickerStyle(.menu)
                    }
                    .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                    .foregroundColor(themeManager.currentTheme.textPrimary)
                    
                    // MARK: Tweak Management
                    Section(header: Text("Tweak Management").foregroundColor(themeManager.currentTheme.textSecondary)) {
                        Toggle(isOn: $tweaksEnabled) {
                            HStack {
                                Image(systemName: "puzzlepiece.extension.fill")
                                    .foregroundColor(themeManager.currentTheme.accent)
                                Text("Enable Tweaks")
                                    .foregroundColor(themeManager.currentTheme.textPrimary)
                            }
                        }
                        .tint(themeManager.currentTheme.accent)
                        .onChange(of: tweaksEnabled) { newValue in
                            JailbreakUtilities.shared.setTweaksEnabled(newValue)
                        }
                        
                        NavigationLink(destination: TweaksManagerView()) {
                            HStack {
                                Image(systemName: "list.bullet.rectangle.portrait.fill")
                                    .foregroundColor(themeManager.currentTheme.accent)
                                Text("Manage Injected Tweaks")
                                    .foregroundColor(themeManager.currentTheme.textPrimary)
                            }
                        }
                        
                        if !tweaksEnabled {
                            Text("Safe Mode active. Tweaks are disabled. Please perform a Userspace Reboot to apply changes.")
                                .font(.caption)
                                .foregroundColor(.orange)
                                .padding(.vertical, 4)
                        }
                    }
                    .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                    
                    // MARK: Utilities
                    Section(header: Text("Utilities").foregroundColor(themeManager.currentTheme.textSecondary)) {
                        Button(action: { JailbreakUtilities.shared.respring() }) {
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("Respring (sbreload)")
                            }
                        }
                        
                        Button(action: { JailbreakUtilities.shared.uicache() }) {
                            HStack {
                                Image(systemName: "app.dashed")
                                Text("Refresh Icon Cache (uicache)")
                            }
                        }
                        
                        Button(action: { JailbreakUtilities.shared.userspaceReboot() }) {
                            HStack {
                                Image(systemName: "power")
                                Text("Userspace Reboot")
                            }
                        }
                    }
                    .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                    .foregroundColor(themeManager.currentTheme.textPrimary)
                    
                    // MARK: Advanced Diagnostics
                    Section(header: Text("System Diagnostics").foregroundColor(themeManager.currentTheme.textSecondary)) {
                        Button(action: {
                            guard !isSystemBusy else { return }
                            showingDiagnosticsConsole = true
                            diagnostics.runFullDiagnostics { _ in }
                        }) {
                            HStack {
                                Image(systemName: "stethoscope")
                                Text(diagnostics.isRepairing ? "Repairing System..." : "Run Advanced Diagnostics")
                            }
                        }
                        .disabled(isSystemBusy)

                        if queueManager.isProcessing {
                            Text("A package transaction is running — wait for it to finish first.")
                                .font(.caption2)
                                .foregroundColor(themeManager.currentTheme.textSecondary)
                        }
                    }
                    .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                    .foregroundColor(.orange)
                    
                    // MARK: Danger Zone
                    Section(header: Text("Danger Zone").foregroundColor(.red)) {
                        Button(action: {
                            guard !isSystemBusy else { return }
                            showingRemoveAlert = true
                        }) {
                            HStack {
                                Image(systemName: "trash.fill")
                                Text(isRemoving ? "Removing Environment..." : "Remove Jailbreak")
                            }
                        }
                        .foregroundColor(.red)
                        .disabled(isRemoving || isSystemBusy)
                    }
                    .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            
            // File Exporter
            .fileExporter(
                isPresented: $showingExporter,
                document: backupDocument,
                contentType: .json,
                defaultFilename: "Cytroll_Tweaks_Backup"
            ) { result in
                switch result {
                case .success(let url):
                    print("Backup saved to: \(url)")
                case .failure(let error):
                    print("Failed to save backup: \(error.localizedDescription)")
                }
            }
            
            // File Importer
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        do {
                            let data = try Data(contentsOf: url)
                            let backup = try JSONDecoder().decode(CytrollBackup.self, from: data)
                            BackupManager.shared.restoreFromBackup(backup)
                        } catch {
                            print("Failed to decode backup: \(error)")
                        }
                    }
                case .failure(let error):
                    print("Failed to import backup: \(error.localizedDescription)")
                }
            }
            
            // Removal Alert
            .alert("Remove Jailbreak?", isPresented: $showingRemoveAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Delete Everything", role: .destructive) {
                    isRemoving = true
                    JailbreakUtilities.shared.removeEnvironment { success in
                        isRemoving = false
                        BootstrapManager.shared.checkBootstrapStatus()
                        PackageIndexStore.shared.refresh()
                        JailbreakUtilities.shared.userspaceReboot()
                    }
                }
            } message: {
                Text("This will permanently delete \(RootlessPaths.prefix) including all your tweaks and preferences. Your device will return to stock iOS state. This cannot be undone.")
            }
            
            // Live Console Cover for Diagnostics
            .fullScreenCover(isPresented: $showingDiagnosticsConsole) {
                LiveConsoleView(
                    isPresented: $showingDiagnosticsConsole,
                    isRunning: diagnostics.isRepairing,
                    title: "System Diagnostics"
                )
            }
        }
    }
}

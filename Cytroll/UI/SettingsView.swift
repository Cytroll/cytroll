import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var diagnostics = DiagnosticsManager.shared
    @StateObject private var queueManager = QueueManager.shared
    @StateObject private var pmSettings = PackageManagerSettings.shared
    @StateObject private var careSettings = CytrollCareSettings.shared
    @ObservedObject private var jailbreakUtils = JailbreakUtilities.shared

    /// Diagnostics/removal and a queued install/remove transaction both
    /// drive dpkg/apt directly — never let them run at the same time.
    private var isSystemBusy: Bool {
        queueManager.isProcessing || diagnostics.isRepairing || CytrollOperationGate.shared.isBusy
    }
    @State private var showingRemoveAlert = false
    @State private var isRemoving = false
    
    // Backup & Restore states
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var backupDocument: BackupDocument?
    
    // Live Diagnostics Console State
    @State private var showingDiagnosticsConsole = false
    @State private var settingsAlertTitle = ""
    @State private var settingsAlertMessage = ""
    @State private var showingSettingsAlert = false
    
    public init() {}
    
    public var body: some View {
        NavigationView {
            ZStack {
                themeManager.backgroundGradient().ignoresSafeArea()
                
                List {
                    // MARK: Backup & Restore
                    Section(header: Text("Data Management").foregroundColor(themeManager.currentTheme.textSecondary)) {
                        Button(action: {
                            BackupManager.shared.createBackup { document in
                                backupDocument = document
                                showingExporter = true
                            }
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
                    
                    // MARK: Package Manager
                    Section(header: Text("Package Manager").foregroundColor(themeManager.currentTheme.textSecondary)) {
                        Toggle(isOn: $pmSettings.filterIncompatiblePackages) {
                            HStack {
                                Image(systemName: "checkmark.shield.fill")
                                    .foregroundColor(themeManager.currentTheme.accent)
                                Text("Filter Incompatible Packages")
                                    .foregroundColor(themeManager.currentTheme.textPrimary)
                            }
                        }
                        .tint(themeManager.currentTheme.accent)

                        Text("Hides packages whose Architecture targets a different platform (watchOS, macOS, etc.) from the Packages tab.")
                            .font(.caption2)
                            .foregroundColor(themeManager.currentTheme.textSecondary)

                        Toggle(isOn: $pmSettings.showAllVersions) {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundColor(themeManager.currentTheme.accent)
                                Text("Expand Other Versions by Default")
                                    .foregroundColor(themeManager.currentTheme.textPrimary)
                            }
                        }
                        .tint(themeManager.currentTheme.accent)

                        Text("Auto-expands the \"Other Versions Available\" list on a package's Details page instead of hiding it behind a disclosure.")
                            .font(.caption2)
                            .foregroundColor(themeManager.currentTheme.textSecondary)
                    }
                    .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))

                    // MARK: Tweak Management
                    Section(header: Text("Tweak Management").foregroundColor(themeManager.currentTheme.textSecondary)) {
                        Toggle(isOn: Binding(
                            get: { jailbreakUtils.tweaksEnabled },
                            set: { newValue in
                                guard newValue != jailbreakUtils.tweaksEnabled else { return }
                                jailbreakUtils.setTweaksEnabled(newValue)
                            }
                        )) {
                            HStack {
                                Image(systemName: "puzzlepiece.extension.fill")
                                    .foregroundColor(themeManager.currentTheme.accent)
                                Text("Enable Tweaks")
                                    .foregroundColor(themeManager.currentTheme.textPrimary)
                            }
                        }
                        .tint(themeManager.currentTheme.accent)
                        .disabled(jailbreakUtils.isUpdatingSafeMode)

                        Toggle(isOn: $careSettings.autoReinjectEnabled) {
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                                    .foregroundColor(themeManager.currentTheme.accent)
                                Text("Auto Re-inject After Updates")
                                    .foregroundColor(themeManager.currentTheme.textPrimary)
                            }
                        }
                        .tint(themeManager.currentTheme.accent)
                        
                        NavigationLink(destination: AppManagerView()) {
                            HStack {
                                Image(systemName: "square.grid.2x2.fill")
                                    .foregroundColor(themeManager.currentTheme.accent)
                                Text("App Manager")
                                    .foregroundColor(themeManager.currentTheme.textPrimary)
                            }
                        }

                        NavigationLink(destination: TweaksManagerView()) {
                            HStack {
                                Image(systemName: "list.bullet.rectangle.portrait.fill")
                                    .foregroundColor(themeManager.currentTheme.accent)
                                Text("Manage Injected Tweaks")
                                    .foregroundColor(themeManager.currentTheme.textPrimary)
                            }
                        }
                        
                        if !jailbreakUtils.tweaksEnabled {
                            Text("Global Safe Mode: Substrate/ElleKit tweaks are disabled. Respring (or reboot userspace) to apply fully.")
                                .font(.caption)
                                .foregroundColor(.orange)
                                .padding(.vertical, 4)
                        }
                    }
                    .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                    .onAppear { jailbreakUtils.refreshTweaksState() }
                    
                    // MARK: Utilities
                    Section(header: Text("Utilities").foregroundColor(themeManager.currentTheme.textSecondary)) {
                        Button(action: { jailbreakUtils.respring() }) {
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
                        NavigationLink(destination: StorageHealthView()) {
                            HStack {
                                Image(systemName: "internaldrive.fill")
                                Text("Storage & Health")
                            }
                        }

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
                .cytrollHideScrollBackground()
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
                case .success:
                    presentSettingsAlert(title: "Backup Saved", message: "Your tweaks list was exported successfully.")
                case .failure(let error):
                    presentSettingsAlert(title: "Backup Failed", message: error.localizedDescription)
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
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let data = try Data(contentsOf: url)
                        let backup = try JSONDecoder().decode(CytrollBackup.self, from: data)
                        DispatchQueue.global(qos: .userInitiated).async {
                            let summary = BackupManager.shared.restoreFromBackup(backup)
                            DispatchQueue.main.async {
                                if summary.queuedFromRepos == 0 {
                                    presentSettingsAlert(
                                        title: "Nothing Queued",
                                        message: summary.skippedMissingSource > 0
                                            ? "None of the \(summary.skippedMissingSource) package(s) in this backup were found in your sources. Refresh Sources and try again."
                                            : "The backup file contained no packages."
                                    )
                                } else {
                                    var message = "\(summary.queuedFromRepos) package(s) added to the queue. Confirm from the floating bar to install."
                                    if summary.skippedMissingSource > 0 {
                                        message += " \(summary.skippedMissingSource) skipped (missing from sources)."
                                    }
                                    presentSettingsAlert(title: "Restore Queued", message: message)
                                }
                            }
                        }
                    } catch {
                        presentSettingsAlert(title: "Restore Failed", message: error.localizedDescription)
                    }
                case .failure(let error):
                    presentSettingsAlert(title: "Import Failed", message: error.localizedDescription)
                }
            }
            .alert(settingsAlertTitle, isPresented: $showingSettingsAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(settingsAlertMessage)
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
                        if success {
                            JailbreakUtilities.shared.userspaceReboot()
                        } else {
                            presentSettingsAlert(
                                title: "Removal Failed",
                                message: "Could not delete \(RootlessPaths.prefix). Nothing was rebooted — check the console and try again."
                            )
                        }
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

    private func presentSettingsAlert(title: String, message: String) {
        settingsAlertTitle = title
        settingsAlertMessage = message
        showingSettingsAlert = true
    }
}

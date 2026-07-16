import SwiftUI
import UniformTypeIdentifiers

public struct TweaksManagerView: View {
    @StateObject private var tweakManager = TweakInjectionManager.shared
    @StateObject private var injectionManager = AppInjectionManager.shared
    @StateObject private var recordStore = InjectionRecordStore.shared
    @StateObject private var sideloadStore = SideloadedDylibStore.shared
    @StateObject private var themeManager = ThemeManager.shared

    @State private var injectionRequest: InjectionRequestContext?
    @State private var isLoadingCandidates = false

    @State private var showingSideloadImporter = false
    @State private var showingInjectionConsole = false
    @State private var lastInjectionErrorMessage: String?
    @State private var showingInjectionError = false

    public init() {}

    public var body: some View {
        ZStack {
            themeManager.backgroundGradient().ignoresSafeArea()

            List {
                tweaksSection
                sideloadedSection
                if !recordStore.records.isEmpty {
                    injectedAppsSection
                }
                storageSection
                perAppInjectionDisclaimer
            }
            .listStyle(.insetGrouped)
            .cytrollHideScrollBackground()
        }
        .navigationTitle("Tweak Injector")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            tweakManager.refreshTweaks()
            recordStore.refreshNeedsReapplyFlags()
            injectionManager.recoverStrayTempDirectories()
        }
        .sheet(item: $injectionRequest) { request in
            InjectionTargetPickerSheet(
                tweak: request.tweak,
                apps: request.apps,
                headerNote: request.headerNote,
                isLoading: isLoadingCandidates,
                onConfirm: { apps in
                    injectionRequest = nil
                    startInjection(tweak: request.tweak, apps: apps)
                }
            )
        }
        .fullScreenCover(isPresented: $showingInjectionConsole) {
            LiveConsoleView(
                isPresented: $showingInjectionConsole,
                isRunning: injectionManager.isProcessing,
                title: "Tweak Injection"
            )
        }
        .fileImporter(
            isPresented: $showingSideloadImporter,
            // iOS rarely tags .dylib files with a matching UTType, so a
            // narrow filter (filenameExtension: "dylib") greys them out
            // in the Files picker. Allow any item, then enforce .dylib
            // in handleSideloadPicked.
            allowedContentTypes: Self.sideloadImportTypes,
            allowsMultipleSelection: false
        ) { result in
            handleSideloadPicked(result)
        }
        .alert("Injection Failed", isPresented: $showingInjectionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lastInjectionErrorMessage ?? "Unknown error.")
        }
    }

    // MARK: - Sections

    private var tweaksSection: some View {
        Section(header: Text("Installed Tweaks").foregroundColor(themeManager.currentTheme.textSecondary)) {
            if tweakManager.installedTweaks.isEmpty {
                Text("No apt tweaks found. Install some from the Packages tab, or add a .dylib file directly below.")
                    .font(.subheadline)
                    .foregroundColor(themeManager.currentTheme.textSecondary)
            }
            ForEach(tweakManager.installedTweaks) { tweak in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tweak.name)
                                .font(.headline)
                                .foregroundColor(themeManager.currentTheme.textPrimary)
                            Text(tweak.isEnabled ? "Enabled" : "Disabled")
                                .font(.caption)
                                .foregroundColor(tweak.isEnabled ? .green : .red)
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { tweak.isEnabled },
                            set: { newValue in
                                tweakManager.toggleTweak(tweak, enable: newValue) { _ in }
                            }
                        ))
                        .tint(themeManager.currentTheme.accent)
                        .disabled(tweakManager.isProcessing)
                    }

                    Button(action: { presentInjectionSheet(for: tweak) }) {
                        HStack {
                            Image(systemName: "syringe.fill")
                            Text("Inject Into App…")
                        }
                        .font(.caption.bold())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(tweak.isEnabled ? themeManager.currentTheme.accent : themeManager.currentTheme.textSecondary)
                    .disabled(injectionManager.isProcessing || !tweak.isEnabled)

                    if tweak.filterBundleIDs.isEmpty {
                        Text("No app-injection Filter found in this tweak's plist — you'll pick from every installed app instead.")
                            .font(.caption2)
                            .foregroundColor(themeManager.currentTheme.textSecondary)
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
            }
        }
    }

    private var sideloadedSection: some View {
        Section(
            header: Text("Sideloaded Dylibs").foregroundColor(themeManager.currentTheme.textSecondary),
            footer: Text("Pick any .dylib from Files (Filza, On My iPhone, iCloud, etc.). Only .dylib is accepted. You always pick its target app manually.")
        ) {
            ForEach(sideloadStore.items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.name)
                        .font(.headline)
                        .foregroundColor(themeManager.currentTheme.textPrimary)

                    Button(action: { presentInjectionSheet(for: item.asTweakInfo) }) {
                        HStack {
                            Image(systemName: "syringe.fill")
                            Text("Inject Into App…")
                        }
                        .font(.caption.bold())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(themeManager.currentTheme.accent)
                    .disabled(injectionManager.isProcessing)
                }
                .padding(.vertical, 4)
                .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                .swipeActions {
                    Button(role: .destructive) {
                        sideloadStore.remove(item)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            Button(action: { showingSideloadImporter = true }) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("Add .dylib File…")
                }
                .font(.subheadline.bold())
            }
            .buttonStyle(.plain)
            .foregroundColor(themeManager.currentTheme.accent)
            .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
        }
    }

    private var injectedAppsSection: some View {
        Section(header: Text("Injected Apps").foregroundColor(themeManager.currentTheme.textSecondary)) {
            ForEach(recordStore.records) { record in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.appDisplayName)
                                .font(.subheadline.bold())
                                .foregroundColor(themeManager.currentTheme.textPrimary)
                            Text("Tweak: \(record.tweakName)")
                                .font(.caption2)
                                .foregroundColor(themeManager.currentTheme.textSecondary)
                        }
                        Spacer()
                        statusBadge(for: record.status)
                    }

                    HStack {
                        // `.failed` means the atomic swap's own automatic
                        // recovery didn't fully complete — force "Restore
                        // Original" as the only next step rather than
                        // offering a re-inject that would just be
                        // rejected (and could otherwise stack a fresh
                        // rebuild on top of an unclear state).
                        if record.status == .needsReapply {
                            Button("Re-inject") {
                                reapply(record: record)
                            }
                            .font(.caption.bold())
                            .foregroundColor(themeManager.currentTheme.accent)
                            .disabled(injectionManager.isProcessing)
                        }
                        Spacer()
                        Button("Restore Original") {
                            injectionManager.restore(record) { _ in }
                        }
                        .font(.caption.bold())
                        .foregroundColor(.red)
                        .disabled(injectionManager.isProcessing)
                    }
                    if record.status == .failed {
                        Text("A previous attempt didn't fully recover. Restore this app before trying again.")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
            }
        }
    }

    private var storageSection: some View {
        Section {
            NavigationLink(destination: InjectionBackupStorageView()) {
                HStack {
                    Image(systemName: "internaldrive")
                    Text("Backup Storage")
                }
                .foregroundColor(themeManager.currentTheme.textPrimary)
            }
        }
        .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
    }

    private var perAppInjectionDisclaimer: some View {
        Section {
            Text("Per-app injection only works on third-party apps, breaks silently after that app updates (look for \"Needs Reapply\" above), and needs the app restarted to take effect. It never touches Apple's own apps or SpringBoard.")
                .font(.caption2)
                .foregroundColor(themeManager.currentTheme.textSecondary)
        }
        .listRowBackground(Color.clear)
    }

    private func statusBadge(for status: InjectionStatus) -> some View {
        let (text, color): (String, Color) = {
            switch status {
            case .active: return ("Active", .green)
            case .needsReapply: return ("Needs Reapply", .orange)
            case .failed: return ("Failed", .red)
            }
        }()
        return Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    // MARK: - Actions

    /// Tweaks that ship a `Filter -> Bundles` plist only ever offer those
    /// explicitly-declared apps; everything else (no filter, or a
    /// sideloaded dylib which never has one) falls back to the full
    /// installed-apps list, same as real TrollFools' manual target
    /// picker.
    private func presentInjectionSheet(for tweak: TweakInfo) {
        isLoadingCandidates = true
        let usesFullList = tweak.filterBundleIDs.isEmpty
        injectionRequest = InjectionRequestContext(
            tweak: tweak,
            apps: [],
            headerNote: usesFullList ? "No Filter declared — pick any installed app." : "Apps matching \(tweak.name)'s Filter."
        )

        if usesFullList {
            InstalledAppScanner.shared.scanInstalledApps { apps in
                injectionRequest?.apps = apps
                isLoadingCandidates = false
            }
        } else {
            tweakManager.candidateApps(for: tweak) { apps in
                injectionRequest?.apps = apps
                isLoadingCandidates = false
            }
        }
    }

    private func startInjection(tweak: TweakInfo, apps: [InstalledAppInfo]) {
        guard !apps.isEmpty else { return }
        ConsoleManager.shared.clear()
        showingInjectionConsole = true

        var failures: [String] = []
        injectionManager.injectBatch(
            tweak: tweak,
            into: apps,
            progress: { app, result in
                if case .failure(let error) = result {
                    failures.append("\(app.displayName): \(error.localizedDescription)")
                }
            },
            completion: {
                if !failures.isEmpty {
                    lastInjectionErrorMessage = failures.joined(separator: "\n\n")
                    showingInjectionError = true
                }
            }
        )
    }

    private func reapply(record: InjectionRecord) {
        guard let tweak = resolveTweakInfo(id: record.tweakID) else {
            lastInjectionErrorMessage = "This tweak is no longer installed."
            showingInjectionError = true
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let app = InstalledAppScanner.shared.app(withBundleID: record.bundleID)
            DispatchQueue.main.async {
                guard let app = app else {
                    lastInjectionErrorMessage = "This app is no longer installed."
                    showingInjectionError = true
                    return
                }
                startInjection(tweak: tweak, apps: [app])
            }
        }
    }

    private func resolveTweakInfo(id: String) -> TweakInfo? {
        if let apt = tweakManager.installedTweaks.first(where: { $0.id == id }) {
            return apt
        }
        return sideloadStore.item(withID: id)?.asTweakInfo
    }

    /// Prefer the declared Cytroll dylib UTI + Apple's Mach-O dylib type,
    /// but always include `.item` so unknown/untagged .dylib files stay
    /// tappable in the document picker on real devices.
    private static var sideloadImportTypes: [UTType] {
        var types: [UTType] = [.item, .data]
        if let cytroll = UTType("com.cytroll.dylib") {
            types.insert(cytroll, at: 0)
        }
        if let byExt = UTType(filenameExtension: "dylib", conformingTo: .data) {
            types.insert(byExt, at: 0)
        }
        types.insert(.dynamicLibrary, at: 0)
        return types
    }

    private func handleSideloadPicked(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            lastInjectionErrorMessage = error.localizedDescription
            showingInjectionError = true
        case .success(let urls):
            guard let url = urls.first else { return }
            let ext = url.pathExtension.lowercased()
            guard ext == "dylib" else {
                lastInjectionErrorMessage = "Please pick a .dylib file (got “\(url.lastPathComponent)”)."
                showingInjectionError = true
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = sideloadStore.add(from: url, displayName: nil)
                DispatchQueue.main.async {
                    if case .failure(let error) = outcome {
                        lastInjectionErrorMessage = "Could not add \(url.lastPathComponent): \(error.localizedDescription)"
                        showingInjectionError = true
                    }
                }
            }
        }
    }
}

/// Identity is the tweak's ID (stable), not a fresh UUID per update — the
/// sheet is presented immediately with an empty `apps` list while
/// scanning runs in the background, then updated in place once results
/// arrive; a fresh identity on that second update would make SwiftUI
/// treat it as a brand new sheet and flicker.
private struct InjectionRequestContext: Identifiable {
    var id: String { tweak.id }
    let tweak: TweakInfo
    var apps: [InstalledAppInfo]
    var headerNote: String
}

/// Sheet listing candidate apps for a tweak/dylib — either the ones it
/// explicitly declares support for (`Filter -> Bundles`) or, failing
/// that, every installed app. Supports selecting multiple apps at once
/// (batch injection) with one shared confirmation before anything is
/// touched.
private struct InjectionTargetPickerSheet: View {
    let tweak: TweakInfo
    let apps: [InstalledAppInfo]
    let headerNote: String
    let isLoading: Bool
    let onConfirm: ([InstalledAppInfo]) -> Void

    @StateObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedBundleIDs: Set<String> = []
    @State private var showingConfirmation = false
    @State private var searchText = ""

    private var filteredApps: [InstalledAppInfo] {
        guard !searchText.isEmpty else { return apps }
        return apps.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.bundleID.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                themeManager.backgroundGradient().ignoresSafeArea()

                if isLoading {
                    ProgressView("Scanning installed apps…")
                        .tint(themeManager.currentTheme.accent)
                } else if apps.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "questionmark.app")
                            .font(.system(size: 40))
                            .foregroundColor(themeManager.currentTheme.textSecondary)
                        Text("No installed app matches this tweak's Filter.")
                            .font(.subheadline)
                            .foregroundColor(themeManager.currentTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                } else {
                    VStack(spacing: 0) {
                        List {
                            Section {
                                ForEach(filteredApps) { app in
                                    Button(action: { toggle(app) }) {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(app.displayName)
                                                    .font(.headline)
                                                    .foregroundColor(themeManager.currentTheme.textPrimary)
                                                Text("\(app.bundleID) · v\(app.version)")
                                                    .font(.caption2)
                                                    .foregroundColor(themeManager.currentTheme.textSecondary)
                                            }
                                            Spacer()
                                            Image(systemName: selectedBundleIDs.contains(app.bundleID) ? "checkmark.circle.fill" : "circle")
                                                .foregroundColor(selectedBundleIDs.contains(app.bundleID) ? themeManager.currentTheme.accent : themeManager.currentTheme.textSecondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                Text(headerNote)
                            } footer: {
                                Text("Select one or more apps, then confirm below. A full backup is made first for each and restored automatically if anything fails.")
                            }
                            .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                        }
                        .listStyle(.insetGrouped)
                        .cytrollHideScrollBackground()
                        .searchable(text: $searchText, prompt: "Search apps")

                        Button(action: { showingConfirmation = true }) {
                            Text(selectedBundleIDs.isEmpty ? "Select at Least One App" : "Inject Into \(selectedBundleIDs.count) App\(selectedBundleIDs.count == 1 ? "" : "s")")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                        .background(selectedBundleIDs.isEmpty ? themeManager.currentTheme.textSecondary.opacity(0.3) : themeManager.currentTheme.accent)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .disabled(selectedBundleIDs.isEmpty)
                        .padding()
                    }
                }
            }
            .navigationTitle("Inject \(tweak.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert(
                "Inject Into \(selectedBundleIDs.count) App\(selectedBundleIDs.count == 1 ? "" : "s")?",
                isPresented: $showingConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Inject", role: .destructive) {
                    onConfirm(apps.filter { selectedBundleIDs.contains($0.bundleID) })
                }
            } message: {
                Text("This patches each selected app's executable to load \(tweak.name). A full backup is made first per app and restored automatically if anything fails. Works only on third-party apps, breaks silently on each app's next update, and needs the app restarted (or the device resprung) to take effect.")
            }
        }
    }

    private func toggle(_ app: InstalledAppInfo) {
        if selectedBundleIDs.contains(app.bundleID) {
            selectedBundleIDs.remove(app.bundleID)
        } else {
            selectedBundleIDs.insert(app.bundleID)
        }
    }
}

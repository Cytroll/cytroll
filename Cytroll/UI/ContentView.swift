import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var queueManager = QueueManager.shared
    @Environment(\.scenePhase) private var scenePhase
    
    @State private var selectedTab = 0
    @State private var showingTerminal = false
    
    public init() {}
    
    public var body: some View {
        ZStack(alignment: .bottom) {
            // MARK: - Main Tab Navigation
            TabView(selection: $selectedTab) {
                HomeView()
                    .tabItem { Label("Home", systemImage: "house.fill") }
                    .tag(0)
                
                SourcesView()
                    .tabItem { Label("Sources", systemImage: "safari.fill") }
                    .tag(1)
                
                ChangesView()
                    .tabItem { Label("Changes", systemImage: "arrow.triangle.2.circlepath") }
                    .tag(2)
                
                PackagesTabView()
                    .tabItem { Label("Packages", systemImage: "shippingbox.fill") }
                    .tag(3)
                
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                    .tag(4)
            }
            .accentColor(themeManager.currentTheme.accent)
            
            // MARK: - Dynamic Queue Floating Bar
            if !queueManager.queue.isEmpty {
                queueFloatingBar
            }
        }
        // MARK: - Native Modern Presentation
        .fullScreenCover(isPresented: $showingTerminal) {
            TerminalView(showingTerminal: $showingTerminal, queueManager: queueManager, themeManager: themeManager)
        }
        .onAppear {
            // Initial launch: scenePhase onChange does not fire for the
            // already-active value, so we still need one call here.
            if scenePhase == .active {
                AutoReinjectService.shared.evaluateOnForeground()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                AutoReinjectService.shared.evaluateOnForeground()
            }
        }
    }
    
    // MARK: - Queue Floating Bar Subview
    private var queueFloatingBar: some View {
        HStack {
            Image(systemName: "shippingbox.fill")
                .foregroundColor(themeManager.currentTheme.accent)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("\(queueManager.queue.count) packages in queue")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(themeManager.currentTheme.textPrimary)
            }
            
            Spacer()
            
            Button(action: {
                guard !queueManager.isProcessing else { return }
                showingTerminal = true
                queueManager.confirmAndExecute { _ in
                    // Terminal stays open so user can read logs.
                }
            }) {
                Text(queueManager.isProcessing ? "Running…" : "Confirm")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(themeManager.currentTheme.accent.opacity(queueManager.isProcessing ? 0.5 : 1))
                    .cornerRadius(8)
            }
            .disabled(queueManager.isProcessing)
        }
        .padding()
        .glassCard(theme: themeManager.currentTheme)
        .padding(.horizontal)
        // Elevate above TabBar safely
        .padding(.bottom, 60)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(), value: queueManager.queue.count)
    }
}

// MARK: - Modern Terminal View
public struct TerminalView: View {
    @Binding var showingTerminal: Bool
    @ObservedObject var queueManager: QueueManager
    @ObservedObject var themeManager: ThemeManager
    
    public var body: some View {
        ZStack(alignment: .top) {
            // Pure black classic terminal background
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Classic Navigation Header
                ZStack {
                    Color(white: 0.1).ignoresSafeArea(edges: .top)
                    Text(queueManager.isProcessing ? "Executing..." : "Complete")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.vertical, 16)
                }
                .frame(height: 50)
                
                // Raw Terminal Output with Auto-Scroll
                ScrollView {
                    ScrollViewReader { proxy in
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(queueManager.processLogs.enumerated()), id: \.offset) { index, log in
                                Text(log)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(logColor(for: log))
                                    .id(index) // Anchor for scrolling
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: queueManager.processLogs.count) { _ in
                            if !queueManager.processLogs.isEmpty {
                                withAnimation {
                                    proxy.scrollTo(queueManager.processLogs.count - 1, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
                
                // The "Return" Button (Appears only when done)
                if !queueManager.isProcessing {
                    Button(action: {
                        // Native dismiss
                        showingTerminal = false
                    }) {
                        Text("Back to Cytroll")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(white: 0.15))
                    }
                }
            }
        }
        // Force dark mode for status bar consistency
        .preferredColorScheme(.dark)
    }
    
    // MARK: - Console Color Parser
    private func logColor(for log: String) -> Color {
        let lower = log.lowercased()
        if lower.contains("error") || lower.contains("failed") || lower.contains("fatal") {
            return .red
        } else if lower.contains("success") || lower.contains("done") || lower.contains("perfectly") {
            return .green
        } else if lower.contains("warning") {
            return .yellow
        } else {
            return themeManager.currentTheme.textPrimary
        }
    }
}

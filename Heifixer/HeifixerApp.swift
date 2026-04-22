//
//  HeifixerApp.swift
//  Heifixer
//

import Photos
import SwiftData
import SwiftUI

@main
struct HeifixerApp: App {
    private let modelContainer: ModelContainer
    @State private var scanner: PhotoLibraryScanner
    @State private var fixer: PhotoFixer
    @State private var monitor: LibraryChangeMonitor

    init() {
        // Fail fast on schema errors: without SwiftData the whole app is
        // meaningless. In practice this only fails if the underlying store
        // is corrupt, which should be rare enough to crash on.
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Candidate.self, ScanState.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        self.modelContainer = container

        let scanner = PhotoLibraryScanner()
        let fixer = PhotoFixer()
        let monitor = LibraryChangeMonitor(
            scanner: scanner,
            modelContext: container.mainContext
        )
        _scanner = State(initialValue: scanner)
        _fixer = State(initialValue: fixer)
        _monitor = State(initialValue: monitor)
    }

    var body: some Scene {
        WindowGroup {
            HeifixerRootView(modelContainer: modelContainer, monitor: monitor)
                .environment(scanner)
                .environment(fixer)
        }
        .modelContainer(modelContainer)
    }
}

// MARK: - Root (onboarding vs home, scan when authorized)

private struct HeifixerRootView: View {
    let modelContainer: ModelContainer
    let monitor: LibraryChangeMonitor
    @Environment(PhotoFixer.self) private var fixer
    @Environment(PhotoLibraryScanner.self) private var scanner
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if fixer.hasLibraryAccess {
                HomeView()
            } else {
                OnboardingView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                fixer.refreshAuthorizationStatus()
            }
        }
        .task(id: fixer.authorizationStatus) {
            guard fixer.hasLibraryAccess else { return }
            monitor.register()
            await scanner.scan(modelContext: modelContainer.mainContext)
        }
    }
}

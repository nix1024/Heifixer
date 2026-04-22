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
            ContentView()
                .environment(scanner)
                .environment(fixer)
                .task {
                    // Request authorization up front if the user has not
                    // answered the system prompt yet. Subsequent scans will
                    // no-op if access is denied.
                    if fixer.authorizationStatus == .notDetermined {
                        await fixer.requestAuthorization()
                    }
                    if fixer.hasLibraryAccess {
                        monitor.register()
                        await scanner.scan(modelContext: modelContainer.mainContext)
                    }
                }
        }
        .modelContainer(modelContainer)
    }
}

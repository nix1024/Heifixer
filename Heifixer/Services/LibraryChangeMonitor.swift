//
//  LibraryChangeMonitor.swift
//  Heifixer
//
//  Bridges Photos' `PHPhotoLibraryChangeObserver` (an NSObject protocol
//  with callbacks arriving on a private queue) to a MainActor `Task` that
//  triggers an incremental scan. The trampoline `NSObject` subclass avoids
//  having to bend the whole `PhotoLibraryScanner` to NSObject conformance.
//

import Foundation
import Photos
import SwiftData

@MainActor
final class LibraryChangeMonitor {
    private let scanner: PhotoLibraryScanner
    private let modelContext: ModelContext
    private var trampoline: Trampoline?

    init(scanner: PhotoLibraryScanner, modelContext: ModelContext) {
        self.scanner = scanner
        self.modelContext = modelContext
    }

    func register() {
        guard trampoline == nil else { return }
        let trampoline = Trampoline { [weak self] in
            // Hop to MainActor: the change callback fires on a private Photos
            // queue, and we mutate `@Observable` state + SwiftData from the
            // main actor.
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.scanner.scan(modelContext: self.modelContext)
            }
        }
        PHPhotoLibrary.shared().register(trampoline)
        self.trampoline = trampoline
    }

    func unregister() {
        guard let trampoline else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(trampoline)
        self.trampoline = nil
    }

    deinit {
        // Cannot call `unregister()` here because it touches MainActor state.
        // Photos holds a weak reference to observers, so this is safe to skip.
    }
}

/// NSObject trampoline that forwards change notifications to a sendable
/// closure. Kept `private`-ish via file scope to prevent other modules from
/// accidentally subclassing.
private final class Trampoline: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let handler: @Sendable () -> Void

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        super.init()
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        handler()
    }
}

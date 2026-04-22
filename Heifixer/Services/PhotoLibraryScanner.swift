//
//  PhotoLibraryScanner.swift
//  Heifixer
//
//  Heuristic scan over `PHAsset`s that discovers candidate Sony HEIFs using
//  only metadata that is cheap to read (PHAsset fields and PHAssetResource
//  identifiers). NO file I/O is performed here; iCloud-only photos are
//  scanned identically to local ones because UTI and filename are available
//  for every PHAssetResource regardless of local availability.
//

import Foundation
import Photos
import SwiftData

@Observable
@MainActor
final class PhotoLibraryScanner {
    // MARK: - Status

    /// Single source of truth for the scanner's lifecycle. Using an enum
    /// collapses several previously-separate properties (`isScanning`,
    /// progress counters, `lastScanFinishedAt`, `lastErrorMessage`) into one
    /// so callers can drive all status UI off one value, and so mutually
    /// exclusive outcomes (success vs. failure) cannot coexist.
    enum Status: Equatable {
        /// No scan has run yet in this app lifetime.
        case none
        /// A scan is in flight. `total` is set once the `PHFetchResult` is
        /// built (may be 0 briefly at the very start of the run or during
        /// the DEBUG warm-up sleep). `scanned` / `matched` tick up live.
        case scanning(scanned: Int, total: Int, matched: Int)
        /// The most recent scan finished successfully. `at` is the
        /// completion timestamp; counts reflect the final tally.
        case completed(at: Date, scanned: Int, total: Int, matched: Int)
        /// The most recent scan failed. `message` is a user-facing,
        /// localized string suitable for display.
        case failed(message: String)

        /// True only while actively scanning. Convenient shorthand for
        /// "are we busy right now?" gates in the UI.
        var isScanning: Bool {
            if case .scanning = self { true } else { false }
        }
    }

    // MARK: - Observable status

    private(set) var status: Status = .none

    // MARK: - Configuration

    /// Debug-build safety cap for the initial full-library scan to avoid
    /// stalling a simulator with tens of thousands of rows. In Release this
    /// limit is disabled (nil).
    private static var debugFullScanLimit: Int? {
        #if DEBUG
        return 10
        #else
        return nil
        #endif
    }

    /// Compiled once, reused for every asset. Case-insensitive to match
    /// real-world variations ("dsc00001.HEIF", etc.). The plan's regex is
    /// anchored end-to-end.
    private static let sonyFilenameRegex: NSRegularExpression = {
        // The scanner only inspects the filename portion, not the full path,
        // so no leading path separators.
        return try! NSRegularExpression(
            pattern: "^DSC\\d+\\.HEIF$",
            options: [.caseInsensitive]
        )
    }()

    // MARK: - Public API

    #if DEBUG
    /// Debug-only: wipe all persisted state (Candidate + ScanState) and
    /// reset the observable status. Next `scan()` will run in full-library
    /// mode again. Intended for developer iteration in the simulator.
    func resetAll(modelContext: ModelContext) {
        // Don't run destructive cleanup while a scan is in flight; caller
        // should gate the UI, but we defend regardless.
        guard !status.isScanning else { return }

        try? modelContext.delete(model: Candidate.self)
        try? modelContext.delete(model: ScanState.self)
        try? modelContext.save()

        status = .none
    }
    #endif

    /// Run a scan. Chooses full or incremental mode based on persisted
    /// `ScanState.firstScanCompletedAt`. Guards against concurrent runs so
    /// observer-triggered rescans can't race with an initial launch scan.
    func scan(modelContext: ModelContext) async {
        guard !status.isScanning else { return }
        status = .scanning(scanned: 0, total: 0, matched: 0)

        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
            || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
        else {
            status = .failed(message: "照片库访问未授权，无法扫描。")
            return
        }

        #if DEBUG
        // Artificial delay so the scanning hero card animation is visible
        // during local iteration. Release builds run at full speed.
        try? await Task.sleep(for: .seconds(3))
        #endif

        let scanState = fetchOrCreateScanState(in: modelContext)
        let runStartedAt = Date()
        let isFullScan = scanState.firstScanCompletedAt == nil

        let fetch = makeFetchResult(
            isFullScan: isFullScan,
            cutoff: scanState.lastScanAt
        )
        let total = fetch.count
        var scanned = 0
        var matched = 0
        status = .scanning(scanned: 0, total: total, matched: 0)

        // Process synchronously on the main actor. `PHFetchResult` access is
        // thread-safe but the SwiftData `ModelContext` we write to is
        // MainActor-isolated in this app, so staying on the main queue
        // keeps the code simple. Inserts are cheap; the expensive part
        // (EXIF read) was removed from the scanner entirely.
        for index in 0..<total {
            let asset = fetch.object(at: index)
            scanned += 1
            if let candidate = evaluate(asset: asset, in: modelContext) {
                matched += 1
                _ = candidate
            }
            status = .scanning(scanned: scanned, total: total, matched: matched)
        }

        // Persist on success. We update `lastScanAt` to the start of this
        // run (not end) so any asset that was added *during* the scan is
        // still picked up by the next incremental pass.
        scanState.lastScanAt = runStartedAt
        if isFullScan {
            scanState.firstScanCompletedAt = runStartedAt
        }

        do {
            try modelContext.save()
            status = .completed(
                at: Date(),
                scanned: scanned,
                total: total,
                matched: matched
            )
        } catch {
            status = .failed(message: "扫描结果保存失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Fetch construction

    private func makeFetchResult(isFullScan: Bool, cutoff: Date?) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        if !isFullScan, let cutoff {
            // Incremental: anything created OR modified after the last scan.
            // `modificationDate` catches assets whose local state changed
            // (e.g. iCloud downloaded in), which can expose previously-
            // unevaluable resources.
            options.predicate = NSPredicate(
                format: "creationDate > %@ OR modificationDate > %@",
                cutoff as NSDate,
                cutoff as NSDate
            )
        }

        if isFullScan, let limit = Self.debugFullScanLimit {
            options.fetchLimit = limit
        }

        return PHAsset.fetchAssets(with: .image, options: options)
    }

    // MARK: - Per-asset evaluation

    /// Returns the upserted `Candidate` if the asset matches the heuristic
    /// filters, otherwise `nil` (and no DB writes).
    private func evaluate(asset: PHAsset, in context: ModelContext) -> Candidate? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let primary = primaryHEIFResource(in: resources) else { return nil }

        let filename = primary.originalFilename
        guard Self.matchesSonyFilename(filename) else { return nil }

        return upsert(
            assetID: asset.localIdentifier,
            filename: filename,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            creationDate: asset.creationDate,
            in: context
        )
    }

    /// Pick the "best" HEIF resource from the asset's resource list, if any.
    /// Prefers `.photo` over `.fullSizePhoto` over other types. Returns
    /// `nil` if none are HEIF.
    private func primaryHEIFResource(in resources: [PHAssetResource]) -> PHAssetResource? {
        let ordered = resources.sorted { Self.typePriority($0.type) < Self.typePriority($1.type) }
        return ordered.first { Self.isHEIF($0) }
    }

    private static func isHEIF(_ resource: PHAssetResource) -> Bool {
        let uti = resource.uniformTypeIdentifier.lowercased()
        let ext = (resource.originalFilename as NSString).pathExtension.lowercased()
        // Sony A6700 HEIF files report UTI "public.heif" with extension "HEIF".
        // The iOS Photos path that re-derives thumbnails reads orientation from
        // IFD0 only, which Sony does not populate; that mismatch is the bug
        // we fix downstream.
        return uti.contains("heif") || ext == "heif" || ext == "hif"
    }

    private static func typePriority(_ type: PHAssetResourceType) -> Int {
        switch type {
        case .photo: 0
        case .fullSizePhoto: 1
        case .alternatePhoto: 2
        default: 10
        }
    }

    private static func matchesSonyFilename(_ filename: String) -> Bool {
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        return sonyFilenameRegex.firstMatch(in: filename, options: [], range: range) != nil
    }

    // MARK: - SwiftData upsert

    private func fetchOrCreateScanState(in context: ModelContext) -> ScanState {
        let descriptor = FetchDescriptor<ScanState>(
            predicate: #Predicate<ScanState> { $0.singletonKey == "default" }
        )
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let scanState = ScanState()
        context.insert(scanState)
        return scanState
    }

    /// Insert a new Candidate if none exists for the given PHAsset id. If a
    /// row exists in `pending` state we leave it alone (idempotent rescans);
    /// rows in any terminal state (fixed/originalDeleted/skipped/failed) are
    /// also left alone so history is preserved. Returns the row if the scan
    /// considers it an active candidate (pending-like), else nil.
    private func upsert(
        assetID: String,
        filename: String,
        pixelWidth: Int,
        pixelHeight: Int,
        creationDate: Date?,
        in context: ModelContext
    ) -> Candidate? {
        let descriptor = FetchDescriptor<Candidate>(
            predicate: #Predicate<Candidate> { $0.originalAssetID == assetID }
        )
        if let existing = try? context.fetch(descriptor).first {
            // Keep filename / dimensions fresh in case user renamed or the
            // asset was replaced by a cloud variant. State is NOT overwritten.
            existing.originalFilename = filename
            existing.pixelWidth = pixelWidth
            existing.pixelHeight = pixelHeight
            existing.creationDate = creationDate
            return existing.state == .pending ? existing : nil
        }

        let candidate = Candidate(
            originalAssetID: assetID,
            originalFilename: filename,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            creationDate: creationDate
        )
        context.insert(candidate)
        return candidate
    }
}

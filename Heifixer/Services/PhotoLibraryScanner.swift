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
    // MARK: - Observable progress state

    private(set) var isScanning: Bool = false
    /// Number of PHAssets visited during the most recent (or current) scan.
    private(set) var scannedCount: Int = 0
    /// Number of candidates upserted during the most recent (or current) scan.
    private(set) var matchedCount: Int = 0
    /// End time of the last completed scan. `nil` until one completes.
    private(set) var lastScanFinishedAt: Date?
    /// Human-readable error from the most recent scan, cleared on success.
    private(set) var lastErrorMessage: String?

    // MARK: - Configuration

    /// Debug-build safety cap for the initial full-library scan to avoid
    /// stalling a simulator with tens of thousands of rows. In Release this
    /// limit is disabled (nil).
    private static var debugFullScanLimit: Int? {
        #if DEBUG
        return 20
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
    /// reset observable counters. Next `scan()` will run in full-library
    /// mode again. Intended for developer iteration in the simulator.
    func resetAll(modelContext: ModelContext) {
        // Don't run destructive cleanup while a scan is in flight; caller
        // should gate the UI, but we defend regardless.
        guard !isScanning else { return }

        try? modelContext.delete(model: Candidate.self)
        try? modelContext.delete(model: ScanState.self)
        try? modelContext.save()

        scannedCount = 0
        matchedCount = 0
        lastScanFinishedAt = nil
        lastErrorMessage = nil
    }
    #endif

    /// Run a scan. Chooses full or incremental mode based on persisted
    /// `ScanState.firstScanCompletedAt`. Guards against concurrent runs so
    /// observer-triggered rescans can't race with an initial launch scan.
    func scan(modelContext: ModelContext) async {
        guard !isScanning else { return }
        isScanning = true
        scannedCount = 0
        matchedCount = 0
        lastErrorMessage = nil
        defer { isScanning = false }

        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
            || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
        else {
            lastErrorMessage = "照片库访问未授权，无法扫描。"
            return
        }

        let state = fetchOrCreateScanState(in: modelContext)
        let runStartedAt = Date()
        let isFullScan = state.firstScanCompletedAt == nil

        let fetch = makeFetchResult(
            isFullScan: isFullScan,
            cutoff: state.lastScanAt
        )

        // Process synchronously on the main actor. `PHFetchResult` access is
        // thread-safe but the SwiftData `ModelContext` we write to is
        // MainActor-isolated in this app, so staying on the main queue
        // keeps the code simple. Inserts are cheap; the expensive part
        // (EXIF read) was removed from the scanner entirely.
        for index in 0..<fetch.count {
            let asset = fetch.object(at: index)
            scannedCount += 1
            if let candidate = evaluate(asset: asset, in: modelContext) {
                matchedCount += 1
                _ = candidate
            }
        }

        // Persist on success. We update `lastScanAt` to the start of this
        // run (not end) so any asset that was added *during* the scan is
        // still picked up by the next incremental pass.
        state.lastScanAt = runStartedAt
        if isFullScan {
            state.firstScanCompletedAt = runStartedAt
        }

        do {
            try modelContext.save()
            lastScanFinishedAt = Date()
        } catch {
            lastErrorMessage = "扫描结果保存失败：\(error.localizedDescription)"
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
        let state = ScanState()
        context.insert(state)
        return state
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

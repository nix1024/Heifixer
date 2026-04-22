//
//  PhotoFixer.swift
//  Heifixer
//
//  Consumes `Candidate` rows in `.pending` state and:
//    1. streams the original HEIF bytes to a local temp file,
//    2. verifies the EXIF Make field starts with "SONY" (the only
//       signal we can read; Sony A6700 omits IFD0 Orientation and
//       stores rotation in the HEIF `irot` box + MakerNote),
//    3. creates a new asset with filename "<base>.HEIC" using those
//       bytes verbatim,
//    4. (optional) queues the original for batched deletion so the
//       user sees a single system confirmation prompt for the batch.
//

import Foundation
import ImageIO
import Photos
import SwiftData
import SwiftUI

enum FixMode: String, CaseIterable, Identifiable {
    /// Create a new HEIC asset; leave the original HEIF untouched.
    case keepOriginal
    /// Create a new HEIC asset and delete the original HEIF (batched at the
    /// end of processing so only one system prompt appears).
    case replaceOriginal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepOriginal: "保留原图"
        case .replaceOriginal: "替换原图"
        }
    }

    var explanation: String {
        switch self {
        case .keepOriginal:
            "在照片库中新建一张修复后的副本，原照片完全不动。"
        case .replaceOriginal:
            "新建修复后的照片并删除原照片（会保留所在自定义相簿）。批量处理完会统一弹一次系统删除确认。"
        }
    }
}

@Observable
@MainActor
final class PhotoFixer {
    // MARK: - Status

    /// Single source of truth for the fixer's run-time status. Using an
    /// enum (instead of multiple booleans) makes illegal combinations like
    /// "cleaning up but not processing" unrepresentable, and lets the UI
    /// drive both the busy gate and the status label off one value.
    enum Status: Equatable {
        case idle
        /// Iterating candidates and writing new assets. `processed` advances
        /// after each candidate; `total` is fixed for the run.
        case fixing(processed: Int, total: Int)
        /// Batched original-deletion prompt/commit at the tail of a
        /// `replaceOriginal` run.
        case cleaningUp
    }

    // MARK: - Configuration

    var mode: FixMode = .keepOriginal
    var authorizationStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    // MARK: - Observable status

    private(set) var status: Status = .idle
    /// Surfaced to the UI for non-fatal notices (e.g. batch delete cancelled).
    var lastError: String?

    /// Successful fixes whose original asset is pending batched deletion.
    /// Keyed by original PHAsset so we can map back to the Candidate row
    /// after the batch deletion commits.
    private var pendingReplacements: [(candidateID: PersistentIdentifier, originalAsset: PHAsset)] = []

    // MARK: - Authorization

    func requestAuthorization() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        self.authorizationStatus = status
    }

    var hasLibraryAccess: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    // MARK: - Batch processing

    /// Iterate every `Candidate` in `.pending` state and attempt to fix it.
    /// Writes state transitions back into the provided `ModelContext` as
    /// each candidate completes. Safe to call while scanning is in flight;
    /// new candidates that appear mid-run are deferred to the next call.
    func processPending(modelContext: ModelContext) async {
        guard case .idle = status else { return }
        guard hasLibraryAccess else {
            lastError = "照片库访问未授权。"
            return
        }
        lastError = nil
        pendingReplacements.removeAll()
        defer { status = .idle }

        let runMode = mode
        let pendingRaw = Candidate.State.pending.rawValue
        let descriptor = FetchDescriptor<Candidate>(
            predicate: #Predicate<Candidate> { $0.stateRaw == pendingRaw },
            sortBy: [SortDescriptor(\Candidate.creationDate, order: .reverse)]
        )

        let candidates: [Candidate]
        do {
            candidates = try modelContext.fetch(descriptor)
        } catch {
            lastError = "读取待修复列表失败：\(error.localizedDescription)"
            return
        }

        let total = candidates.count
        status = .fixing(processed: 0, total: total)

        for (index, candidate) in candidates.enumerated() {
            await process(candidate, mode: runMode, in: modelContext)
            status = .fixing(processed: index + 1, total: total)
        }

        // Persist everything we changed per-candidate; SwiftData autosaves
        // in many cases but an explicit save guarantees durability before
        // we hand off to the batched-delete stage.
        try? modelContext.save()

        if runMode == .replaceOriginal, !pendingReplacements.isEmpty {
            status = .cleaningUp
            await flushPendingDeletions(modelContext: modelContext)
            try? modelContext.save()
        }
    }

    /// After a `.keepOriginal` run, originals remain in the library. This
    /// batches deletion of those originals for every `.fixed` candidate,
    /// mirroring the tail of `.replaceOriginal`. Rows whose original asset
    /// is already gone are marked `.originalDeleted` without prompting.
    func deleteFixedOriginals(modelContext: ModelContext) async {
        guard case .idle = status else { return }
        guard hasLibraryAccess else {
            lastError = "照片库访问未授权。"
            return
        }
        lastError = nil

        let fixedRaw = Candidate.State.fixed.rawValue
        let descriptor = FetchDescriptor<Candidate>(
            predicate: #Predicate<Candidate> { $0.stateRaw == fixedRaw },
            sortBy: [SortDescriptor(\Candidate.fixedAt, order: .reverse)]
        )

        let fixedRows: [Candidate]
        do {
            fixedRows = try modelContext.fetch(descriptor)
        } catch {
            lastError = "读取已修复记录失败：\(error.localizedDescription)"
            return
        }

        guard !fixedRows.isEmpty else { return }

        var targets: [(candidateID: PersistentIdentifier, originalAsset: PHAsset)] = []
        var missingOriginalIDs: [PersistentIdentifier] = []

        for candidate in fixedRows {
            let fetch = PHAsset.fetchAssets(
                withLocalIdentifiers: [candidate.originalAssetID],
                options: nil
            )
            if let asset = fetch.firstObject {
                targets.append((candidate.persistentModelID, asset))
            } else {
                missingOriginalIDs.append(candidate.persistentModelID)
            }
        }

        let now = Date()
        for id in missingOriginalIDs {
            if let candidate = modelContext.model(for: id) as? Candidate {
                candidate.state = .originalDeleted
                candidate.originalDeletedAt = now
            }
        }
        try? modelContext.save()

        guard !targets.isEmpty else { return }

        status = .cleaningUp
        defer { status = .idle }

        await performBatchOriginalDeletion(targets: targets, modelContext: modelContext)
        try? modelContext.save()
    }

    // MARK: - Single-candidate flow

    private func process(
        _ candidate: Candidate,
        mode: FixMode,
        in context: ModelContext
    ) async {
        candidate.state = .processing
        do {
            try await fix(candidate, mode: mode, in: context)
        } catch let error as FixError {
            switch error {
            case .alreadyHEIC, .notSony, .notHEIF:
                candidate.state = .skipped
                candidate.skipReason = error.errorDescription
            default:
                candidate.state = .failed
                candidate.skipReason = error.errorDescription
            }
        } catch {
            candidate.state = .failed
            candidate.skipReason = error.localizedDescription
        }
    }

    private func fix(
        _ candidate: Candidate,
        mode: FixMode,
        in context: ModelContext
    ) async throws {
        let asset = try fetchAsset(identifier: candidate.originalAssetID)
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = Self.primaryHEIFResource(in: resources) else {
            throw FixError.notHEIF
        }

        let sourceName = resource.originalFilename
        let baseName = (sourceName as NSString).deletingPathExtension
        let ext = (sourceName as NSString).pathExtension.lowercased()

        // If the resource is already .HEIC extension we have nothing to fix
        // (renaming to itself is a no-op); record as skipped.
        if ext == "heic" {
            throw FixError.alreadyHEIC
        }

        let newFilename = "\(baseName).HEIC"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("heic")

        try await Self.writeResource(resource, to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // EXIF verify now that bytes are on local disk. Parse only the
        // properties dictionary (no pixel decode) so this costs microseconds.
        try Self.verifySonyMake(at: tempURL)

        // Snapshot asset metadata we want to preserve on the new asset.
        // `creationDate` keeps the new row in the correct chronological
        // position in the main Library tab; `isFavorite` is Photos-specific
        // metadata not embedded in the file bytes.
        let creationDate = asset.creationDate
        let isFavorite = asset.isFavorite
        // Mirror custom-album membership so "replace" doesn't lose curation.
        let userAlbums: [PHAssetCollection] = (mode == .replaceOriginal)
            ? Self.userAlbumsContaining(asset)
            : []

        // Box the created placeholder's local identifier so we can write
        // `fixedAssetID` back to the Candidate after the change block
        // settles.
        var createdIdentifier: String?

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let opts = PHAssetResourceCreationOptions()
            opts.originalFilename = newFilename
            opts.shouldMoveFile = false
            request.addResource(with: .photo, fileURL: tempURL, options: opts)
            if let creationDate {
                request.creationDate = creationDate
            }
            request.isFavorite = isFavorite

            if let placeholder = request.placeholderForCreatedAsset {
                createdIdentifier = placeholder.localIdentifier
                for album in userAlbums {
                    if let albumRequest = PHAssetCollectionChangeRequest(for: album) {
                        albumRequest.addAssets([placeholder] as NSArray)
                    }
                }
            }
        }

        candidate.fixedAssetID = createdIdentifier
        candidate.fixedAt = .now
        candidate.state = .fixed
        candidate.skipReason = nil

        if mode == .replaceOriginal {
            pendingReplacements.append((candidate.persistentModelID, asset))
        }
    }

    // MARK: - Batched deletion

    /// Single `performChanges` block that asks the system to delete every
    /// original we replaced in this run. iOS surfaces a single confirmation
    /// prompt ("Delete N photos?") regardless of batch size — there is no
    /// documented hard upper bound on the number of assets you can pass to
    /// `deleteAssets(_:)`.
    private func flushPendingDeletions(modelContext: ModelContext) async {
        let targets = pendingReplacements
        pendingReplacements.removeAll()
        await performBatchOriginalDeletion(targets: targets, modelContext: modelContext)
    }

    private func performBatchOriginalDeletion(
        targets: [(candidateID: PersistentIdentifier, originalAsset: PHAsset)],
        modelContext: ModelContext
    ) async {
        guard !targets.isEmpty else { return }
        let assets = targets.map(\.originalAsset)

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
            let now = Date()
            for entry in targets {
                if let candidate = modelContext.model(for: entry.candidateID) as? Candidate {
                    candidate.state = .originalDeleted
                    candidate.originalDeletedAt = now
                }
            }
        } catch {
            // Common case: user tapped "Cancel" on the system prompt. The
            // new HEICs are preserved; the originals stay. Candidates stay
            // in `.fixed` so they still show up in records.
            lastError = "原图删除已取消或失败：修复后的照片已保留，原照片仍在照片库中。（\(error.localizedDescription)）"
        }
    }

    // MARK: - Helpers

    private func fetchAsset(identifier: String) throws -> PHAsset {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = fetch.firstObject else {
            throw FixError.assetNotFound
        }
        return asset
    }

    nonisolated private static func primaryHEIFResource(in resources: [PHAssetResource]) -> PHAssetResource? {
        let ordered = resources.sorted { typePriority($0.type) < typePriority($1.type) }
        return ordered.first { isHEIF($0) }
    }

    nonisolated private static func isHEIF(_ resource: PHAssetResource) -> Bool {
        let uti = resource.uniformTypeIdentifier.lowercased()
        let ext = (resource.originalFilename as NSString).pathExtension.lowercased()
        return uti.contains("heif") || ext == "heif" || ext == "hif"
    }

    nonisolated private static func typePriority(_ type: PHAssetResourceType) -> Int {
        switch type {
        case .photo: 0
        case .fullSizePhoto: 1
        case .alternatePhoto: 2
        default: 10
        }
    }

    nonisolated private static func userAlbumsContaining(_ asset: PHAsset) -> [PHAssetCollection] {
        let result = PHAssetCollection.fetchAssetCollectionsContaining(
            asset,
            with: .album,
            options: nil
        )
        var albums: [PHAssetCollection] = []
        for index in 0..<result.count {
            let album = result.object(at: index)
            if album.canPerform(.addContent) {
                albums.append(album)
            }
        }
        return albums
    }

    /// Read just the TIFF Make field from the local file; throw if it does
    /// not start with "SONY". We deliberately do NOT check orientation:
    /// Sony A6700 stores rotation in the HEIF container's `irot` transform
    /// property and in the Sony MakerNote, not in IFD0 EXIF Orientation,
    /// so `kCGImagePropertyOrientation` is meaningless for our use case.
    nonisolated private static func verifySonyMake(at url: URL) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else {
            throw FixError.cannotReadMetadata
        }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let make = (tiff[kCGImagePropertyTIFFMake] as? String ?? "").uppercased()
        guard make.hasPrefix("SONY") else { throw FixError.notSony }
    }

    nonisolated private static func writeResource(_ resource: PHAssetResource, to url: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: url,
                options: options
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

enum FixError: LocalizedError {
    case notHEIF
    case alreadyHEIC
    case assetNotFound
    case unauthorized
    case notSony
    case cannotReadMetadata

    var errorDescription: String? {
        switch self {
        case .notHEIF: "该照片格式不支持，已跳过。"
        case .alreadyHEIC: "该照片无需修复。"
        case .assetNotFound: "无法定位到原照片，可能已被删除。"
        case .unauthorized: "照片库访问未授权。"
        case .notSony: "该照片不在支持范围内，已跳过。"
        case .cannotReadMetadata: "无法读取照片元数据。"
        }
    }
}

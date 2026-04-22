//
//  PhotoFixer.swift
//  Heifixer
//

import Foundation
import Photos
import PhotosUI
import SwiftUI

enum FixMode: String, CaseIterable, Identifiable {
    /// Create a new HEIC asset; leave the original HEIF untouched.
    case keepOriginal
    /// Create a new HEIC asset and delete the original HEIF (batched at the end of processing).
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
            "在照片库中新建一张 HEIC 副本，原 HEIF 完全不动。"
        case .replaceOriginal:
            "新建 HEIC 并删除原 HEIF（会保留所在自定义相簿）。批量处理完会统一弹一次系统删除确认。"
        }
    }
}

@Observable
final class PhotoFixer {
    var jobs: [FixJob] = []
    var isProcessing: Bool = false
    var mode: FixMode = .keepOriginal
    var authorizationStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var lastError: String?

    /// Replacements that have been prepared (new HEIC created) but whose originals
    /// still need to be deleted at the end of `processAll`.
    private var pendingReplacements: [(job: FixJob, originalAsset: PHAsset)] = []

    // MARK: - Authorization

    func requestAuthorization() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        self.authorizationStatus = status
    }

    var hasLibraryAccess: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    // MARK: - Job queue management

    /// Turn PhotosPicker selections into fix jobs. The picker **must** be constructed with
    /// `photoLibrary: .shared()` so that `itemIdentifier` resolves to a `PHAsset` local
    /// identifier; otherwise we can't reach `PHAssetResourceManager` for the original bytes.
    func addJobs(from selections: [PhotosPickerItem]) {
        let identifiers = selections.compactMap(\.itemIdentifier)
        guard !identifiers.isEmpty else {
            lastError = "未能从所选照片中获取资源标识符，请确认已授权完整照片库访问。"
            return
        }

        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var newJobs: [FixJob] = []
        for index in 0..<fetch.count {
            let asset = fetch.object(at: index)
            if jobs.contains(where: { $0.assetLocalIdentifier == asset.localIdentifier }) {
                continue
            }
            let primary = Self.primaryResource(for: asset)
            let job = FixJob(
                assetLocalIdentifier: asset.localIdentifier,
                displayName: primary?.originalFilename ?? "未命名照片",
                originalUTI: primary?.uniformTypeIdentifier,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                creationDate: asset.creationDate
            )
            newJobs.append(job)
        }
        jobs.append(contentsOf: newJobs)
    }

    func remove(_ job: FixJob) {
        jobs.removeAll { $0.id == job.id }
    }

    func clearCompleted() {
        jobs.removeAll { $0.status.isTerminal }
    }

    func resetAll() {
        jobs.removeAll()
    }

    // MARK: - Processing

    func processAll() async {
        guard !isProcessing else { return }
        isProcessing = true
        lastError = nil
        pendingReplacements.removeAll()
        defer { isProcessing = false }

        // Snapshot mode for this run so mid-run toggles don't cause mixed behavior.
        let runMode = mode

        let pending = jobs.filter { !$0.status.isTerminal || $0.status == .pending }
        for job in pending {
            await process(job, mode: runMode)
        }

        // Batched deletion: one system prompt covers every replaced original.
        if runMode == .replaceOriginal, !pendingReplacements.isEmpty {
            await flushPendingDeletions()
        }
    }

    func process(_ job: FixJob, mode: FixMode? = nil) async {
        let runMode = mode ?? self.mode
        job.status = .processing
        do {
            try await fix(job, mode: runMode)
        } catch let error as FixError {
            switch error {
            case .notHEIF, .alreadyHEIC:
                job.status = .skipped(reason: error.errorDescription ?? "已跳过")
            default:
                job.status = .failed(message: error.errorDescription ?? "修复失败")
            }
        } catch {
            job.status = .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Core fix

    private func fix(_ job: FixJob, mode: FixMode) async throws {
        guard hasLibraryAccess else {
            throw FixError.unauthorized
        }
        let asset = try fetchAsset(identifier: job.assetLocalIdentifier)
        guard let resource = Self.primaryHEIFResource(for: asset) else {
            throw FixError.notHEIF
        }

        let sourceName = resource.originalFilename
        let baseName = (sourceName as NSString).deletingPathExtension
        let ext = (sourceName as NSString).pathExtension.lowercased()

        if ext == "heic" {
            throw FixError.alreadyHEIC
        }

        let newFilename = "\(baseName).HEIC"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("heic")

        try await Self.writeResource(resource, to: tempURL)

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        // Copy metadata that determines where the new asset lands in the Photos
        // timeline. `creationDate` controls position in the main Library tab
        // (grouped by shot date). `isFavorite` is Apple-specific metadata not
        // present in EXIF, so we must copy it explicitly. Location is already
        // in the HEIF's EXIF GPS block and Photos will re-extract it on import,
        // so we don't need to set `request.location` manually.
        // NOTE: `PHAsset.dateAdded` is assigned by the system at insert time
        // and is not settable via public API, so the new asset always appears
        // newest in the "Recents" smart album.
        let creationDate = asset.creationDate
        let isFavorite = asset.isFavorite
        // When replacing, mirror the original's custom-album membership onto the
        // new asset so the user doesn't lose organization. Smart albums
        // (Favorites, Selfies, Panoramas, ...) are owned by the system and we
        // skip them; `canPerform(.addContent)` filters those out.
        let userAlbums: [PHAssetCollection] = (mode == .replaceOriginal)
            ? Self.userAlbumsContaining(asset)
            : []

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
                for album in userAlbums {
                    if let albumRequest = PHAssetCollectionChangeRequest(for: album) {
                        albumRequest.addAssets([placeholder] as NSArray)
                    }
                }
            }
        }

        // The new asset exists; queue the original for deletion if replacing.
        // We defer deletion so that ONE system prompt covers the whole batch.
        if mode == .replaceOriginal {
            pendingReplacements.append((job, asset))
        }

        job.status = .succeeded(wasReplaced: false)
    }

    // MARK: - Batched deletion

    private func flushPendingDeletions() async {
        let targets = pendingReplacements
        pendingReplacements.removeAll()
        let assets = targets.map(\.originalAsset)

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
            for t in targets {
                if case .succeeded = t.job.status {
                    t.job.status = .succeeded(wasReplaced: true)
                }
            }
        } catch {
            // Most common case: user tapped "取消" on the system delete prompt.
            // New HEICs remain; originals also remain. The jobs are already
            // marked `.succeeded(wasReplaced: false)` from the create phase.
            lastError = "原图删除已取消或失败：修复后的 HEIC 已保留，原 HEIF 仍在照片库中。（\(error.localizedDescription)）"
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

    nonisolated private static func primaryResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first(where: { $0.type == .photo })
            ?? resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first
    }

    nonisolated private static func primaryHEIFResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let ordered = resources.sorted { typePriority($0.type) < typePriority($1.type) }
        return ordered.first { resource in
            isHEIF(resource)
        }
    }

    nonisolated private static func isHEIF(_ resource: PHAssetResource) -> Bool {
        let uti = resource.uniformTypeIdentifier.lowercased()
        let ext = (resource.originalFilename as NSString).pathExtension.lowercased()
        // HEIC container identifiers: public.heif, public.heif-standard, public.heic
        // Sony A6700 HEIF files are UTI public.heif with extension HEIF.
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

    var errorDescription: String? {
        switch self {
        case .notHEIF: "该照片不是 HEIF 格式，已跳过。"
        case .alreadyHEIC: "该照片已经是 HEIC 格式，无需修复。"
        case .assetNotFound: "无法定位到所选照片，请确认授权完整照片库访问。"
        case .unauthorized: "照片库访问未授权。"
        }
    }
}

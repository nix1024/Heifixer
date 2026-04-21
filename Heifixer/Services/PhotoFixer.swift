//
//  PhotoFixer.swift
//  Heifixer
//

import Foundation
import Photos
import PhotosUI
import SwiftUI

@Observable
final class PhotoFixer {
    var jobs: [FixJob] = []
    var isProcessing: Bool = false
    var authorizationStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var lastError: String?

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
        defer { isProcessing = false }

        let pending = jobs.filter { !$0.status.isTerminal || $0.status == .pending }
        for job in pending {
            await process(job)
        }
    }

    func process(_ job: FixJob) async {
        job.status = .processing
        do {
            try await fix(job)
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

    private func fix(_ job: FixJob) async throws {
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

        let creationDate = job.creationDate
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let opts = PHAssetResourceCreationOptions()
            opts.originalFilename = newFilename
            opts.shouldMoveFile = false
            request.addResource(with: .photo, fileURL: tempURL, options: opts)
            if let creationDate {
                request.creationDate = creationDate
            }
        }

        job.status = .succeeded(newAssetID: nil)
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

//
//  FixJob.swift
//  Heifixer
//

import Foundation
import Photos

@Observable
final class FixJob: Identifiable {
    enum Status: Equatable {
        case pending
        case processing
        /// A replacement new asset has been written to the library.
        /// `wasReplaced` is true when the original HEIF was also deleted.
        case succeeded(wasReplaced: Bool)
        case skipped(reason: String)
        case failed(message: String)

        var isTerminal: Bool {
            switch self {
            case .pending, .processing: false
            case .succeeded, .skipped, .failed: true
            }
        }
    }

    let id = UUID()
    let assetLocalIdentifier: String

    var displayName: String
    var originalUTI: String?
    var pixelWidth: Int
    var pixelHeight: Int
    var creationDate: Date?
    var status: Status = .pending

    init(
        assetLocalIdentifier: String,
        displayName: String,
        originalUTI: String? = nil,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        creationDate: Date? = nil
    ) {
        self.assetLocalIdentifier = assetLocalIdentifier
        self.displayName = displayName
        self.originalUTI = originalUTI
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.creationDate = creationDate
    }
}

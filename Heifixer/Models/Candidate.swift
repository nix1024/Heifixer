//
//  Candidate.swift
//  Heifixer
//
//  One row per photo that matched the heuristic scan. Non-matches are never
//  recorded. `originalAssetID` is unique so re-scans (from incremental or a
//  full rescan) idempotently upsert rather than duplicate.
//

import Foundation
import SwiftData

@Model
final class Candidate {
    /// Lifecycle state of the candidate. Stored as raw `String` because
    /// SwiftData's enum support is fine for simple cases but verbose for
    /// `Codable` wrappers; a plain string keeps migrations straightforward.
    enum State: String, CaseIterable, Codable {
        /// Scanner matched, not yet processed.
        case pending
        /// Fixer picked it up and is currently working.
        case processing
        /// New HEIC asset successfully created, original still present.
        /// Terminal in `.keepOriginal` mode.
        case fixed
        /// Original HEIF was also deleted after `.fixed`. Only reachable in
        /// `.replaceOriginal` mode.
        case originalDeleted
        /// Candidate was rejected at fix time (e.g. EXIF Make != SONY, or
        /// resource already HEIC). No library mutation happened.
        case skipped
        /// An unrecoverable error while processing (writeData / performChanges).
        case failed
    }

    /// `PHAsset.localIdentifier` of the original photo. Unique so rescans
    /// upsert into the same row.
    @Attribute(.unique) var originalAssetID: String

    /// Filename at the time of scan, e.g. `DSC00123.HEIF`. Purely informational.
    var originalFilename: String

    /// Photos-reported dimensions of the original asset (landscape sensor-
    /// dims for buggy Sony HEIFs). Used only for display in the UI.
    var pixelWidth: Int
    var pixelHeight: Int

    /// Original asset's creation date as reported by `PHAsset.creationDate`.
    var creationDate: Date?

    /// When this row was first inserted by the scanner.
    var detectedAt: Date

    /// Current lifecycle state (raw `State.rawValue`).
    var stateRaw: String

    /// Populated when `state == .skipped` or `.failed`.
    var skipReason: String?

    /// `PHAsset.localIdentifier` of the newly-created HEIC asset (after a
    /// successful fix).
    var fixedAssetID: String?

    /// Timestamp of when the new HEIC asset was committed to Photos.
    var fixedAt: Date?

    /// Timestamp of when the original HEIF was deleted (only set in
    /// `.replaceOriginal` mode).
    var originalDeletedAt: Date?

    init(
        originalAssetID: String,
        originalFilename: String,
        pixelWidth: Int,
        pixelHeight: Int,
        creationDate: Date?,
        detectedAt: Date = .now,
        state: State = .pending
    ) {
        self.originalAssetID = originalAssetID
        self.originalFilename = originalFilename
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.creationDate = creationDate
        self.detectedAt = detectedAt
        self.stateRaw = state.rawValue
    }

    var state: State {
        get { State(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }
}

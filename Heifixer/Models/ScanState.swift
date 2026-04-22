//
//  ScanState.swift
//  Heifixer
//
//  Singleton-ish SwiftData row that tracks scan progress across launches.
//  Using `singletonKey` (unique = "default") lets us upsert with a simple
//  fetch-or-create pattern without an external UserDefaults dependency.
//

import Foundation
import SwiftData

@Model
final class ScanState {
    /// Fixed key; the first (and only) row uses `"default"`. Declaring it
    /// unique guarantees no duplicate singletons if two scans race.
    @Attribute(.unique) var singletonKey: String

    /// Date predicate boundary for the next incremental scan. Set after each
    /// successful scan completes (full or incremental).
    var lastScanAt: Date?

    /// Set the first time a full-library scan finishes. If nil, the next
    /// scan runs in full-library mode; otherwise incremental.
    var firstScanCompletedAt: Date?

    init(singletonKey: String = "default") {
        self.singletonKey = singletonKey
    }
}

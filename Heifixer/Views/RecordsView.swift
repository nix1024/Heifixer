//
//  RecordsView.swift
//  Heifixer
//
//  Historical listing of candidates that have left the `.pending` state.
//  Four sections: originalDeleted (full success), fixed (new HEIC written,
//  original kept), skipped, failed.
//

import SwiftData
import SwiftUI

struct RecordsView: View {
    // We could do one big @Query and group in-memory, but @Query-per-section
    // is cheaper: SwiftData can return only rows relevant to each predicate.
    @Query(
        filter: #Predicate<Candidate> { $0.stateRaw == "originalDeleted" },
        sort: [SortDescriptor(\Candidate.originalDeletedAt, order: .reverse)]
    )
    private var deleted: [Candidate]

    @Query(
        filter: #Predicate<Candidate> { $0.stateRaw == "fixed" },
        sort: [SortDescriptor(\Candidate.fixedAt, order: .reverse)]
    )
    private var fixed: [Candidate]

    @Query(
        filter: #Predicate<Candidate> { $0.stateRaw == "skipped" },
        sort: [SortDescriptor(\Candidate.detectedAt, order: .reverse)]
    )
    private var skipped: [Candidate]

    @Query(
        filter: #Predicate<Candidate> { $0.stateRaw == "failed" },
        sort: [SortDescriptor(\Candidate.detectedAt, order: .reverse)]
    )
    private var failed: [Candidate]

    var body: some View {
        List {
            if deleted.isEmpty && fixed.isEmpty && skipped.isEmpty && failed.isEmpty {
                Section {
                    ContentUnavailableView(
                        "还没有任何记录",
                        systemImage: "tray",
                        description: Text("修复过的照片会在这里按状态分组显示。")
                    )
                }
            }
            if !deleted.isEmpty {
                Section("已替换（\(deleted.count)）") {
                    ForEach(deleted) { RecordRow(candidate: $0) }
                }
            }
            if !fixed.isEmpty {
                Section("已修复·保留原图（\(fixed.count)）") {
                    ForEach(fixed) { RecordRow(candidate: $0) }
                }
            }
            if !skipped.isEmpty {
                Section("已跳过（\(skipped.count)）") {
                    ForEach(skipped) { RecordRow(candidate: $0) }
                }
            }
            if !failed.isEmpty {
                Section("失败（\(failed.count)）") {
                    ForEach(failed) { RecordRow(candidate: $0) }
                }
            }
        }
        .navigationTitle("修复记录")
#if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}

private struct RecordRow: View {
    let candidate: Candidate

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.originalFilename)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let timestamp {
                Text(timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var timestamp: Date? {
        switch candidate.state {
        case .originalDeleted: candidate.originalDeletedAt ?? candidate.fixedAt
        case .fixed: candidate.fixedAt
        case .skipped, .failed: candidate.detectedAt
        default: nil
        }
    }

    private var subtitle: String {
        switch candidate.state {
        case .originalDeleted, .fixed:
            if candidate.pixelWidth > 0 && candidate.pixelHeight > 0 {
                "\(candidate.pixelWidth) × \(candidate.pixelHeight)"
            } else {
                ""
            }
        case .skipped, .failed:
            candidate.skipReason ?? "未知原因"
        default:
            ""
        }
    }

    private var icon: String {
        switch candidate.state {
        case .originalDeleted: "checkmark.seal.fill"
        case .fixed: "checkmark.circle.fill"
        case .skipped: "minus.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "questionmark.circle"
        }
    }

    private var iconColor: Color {
        switch candidate.state {
        case .originalDeleted: .green
        case .fixed: .blue
        case .skipped: .orange
        case .failed: .red
        default: .secondary
        }
    }
}

#Preview {
    NavigationStack {
        RecordsView()
    }
    .modelContainer(for: [Candidate.self, ScanState.self], inMemory: true)
}

//
//  ContentView.swift
//  Heifixer
//

import Photos
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(PhotoFixer.self) private var fixer
    @Environment(PhotoLibraryScanner.self) private var scanner
    @Environment(\.modelContext) private var modelContext

    // The `stateRaw` predicate matches Candidate.State.pending.rawValue.
    @Query(
        filter: #Predicate<Candidate> { $0.stateRaw == "pending" },
        sort: [SortDescriptor(\Candidate.creationDate, order: .reverse)]
    )
    private var pendingCandidates: [Candidate]

    @State private var showDeleteErrorAlert = false
    @State private var showResetConfirm = false

    var body: some View {
        @Bindable var fixer = fixer
        NavigationStack {
            Group {
                if fixer.hasLibraryAccess {
                    mainContent
                } else {
                    AuthorizationPromptView()
                }
            }
            .navigationTitle("Heifixer")
#if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar { toolbarContent }
            .onChange(of: fixer.lastError) { _, newValue in
                showDeleteErrorAlert = newValue != nil
            }
            .alert("原图未删除", isPresented: $showDeleteErrorAlert) {
                Button("好") { fixer.lastError = nil }
            } message: {
                Text(fixer.lastError ?? "")
            }
#if DEBUG
            .alert("重置整个 App？", isPresented: $showResetConfirm) {
                Button("取消", role: .cancel) {}
                Button("重置", role: .destructive) {
                    performReset()
                }
            } message: {
                Text("将删除本 App 的全部扫描与修复记录，照片库中的照片不会受影响。下次启动会重新做一次全量扫描。")
            }
#endif
        }
    }

#if DEBUG
    private func performReset() {
        scanner.resetAll(modelContext: modelContext)
        Task { await scanner.scan(modelContext: modelContext) }
    }
#endif

    @ViewBuilder
    private var mainContent: some View {
        List {
            scanSection
            pendingSection
            modeSection
            recordsSection
        }
        .safeAreaInset(edge: .bottom) {
            fixButton
        }
    }

    // MARK: - Scan status

    private var scanSection: some View {
        Section {
            if scanner.isScanning {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("正在扫描…").font(.body)
                        Text("已检查 \(scanner.scannedCount) 张 · 命中 \(scanner.matchedCount) 张")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack {
                    Image(systemName: "checkmark.seal")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        if let finished = scanner.lastScanFinishedAt {
                            Text("最近扫描于 \(finished.formatted(date: .abbreviated, time: .shortened))")
                                .font(.body)
                        } else {
                            Text("尚未扫描").font(.body)
                        }
                        if let err = scanner.lastErrorMessage {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    Button {
                        Task {
                            await scanner.scan(modelContext: modelContext)
                        }
                    } label: {
                        Label("重扫", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(fixer.isProcessing)
                }
            }
        } header: {
            Text("扫描状态")
        }
    }

    // MARK: - Pending count

    private var pendingSection: some View {
        Section {
            HStack(spacing: 16) {
                Image(systemName: "photo.stack")
                    .font(.title)
                    .foregroundStyle(.tint)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(pendingCandidates.count)")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                    Text("张待修复照片")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !pendingCandidates.isEmpty {
                DisclosureGroup("查看前 10 张") {
                    ForEach(pendingCandidates.prefix(10)) { candidate in
                        CandidateRow(candidate: candidate)
                    }
                }
                .font(.subheadline)
            }
        } header: {
            Text("待修复")
        } footer: {
            if pendingCandidates.isEmpty {
                Text("没有命中的照片。Heifixer 会在照片库发生变化时自动重扫。")
            }
        }
    }

    // MARK: - Mode

    private var modeSection: some View {
        @Bindable var fixer = fixer
        return Section {
            Picker("修复模式", selection: $fixer.mode) {
                ForEach(FixMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(fixer.isProcessing)
            Text(fixer.mode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("修复模式")
        }
    }

    // MARK: - Records link

    private var recordsSection: some View {
        Section {
            NavigationLink {
                RecordsView()
            } label: {
                Label("修复记录", systemImage: "list.bullet.clipboard")
            }
        }
    }

    // MARK: - Bottom button

    private var fixButton: some View {
        // Liquid Glass CTA. The `.glassProminent` style renders its own
        // material surface; avoid wrapping in `.background(.bar)` or adding
        // a Divider — both would fight the automatic scroll-edge effect
        // that iOS 26 draws under the inset.
        Button {
            Task { await fixer.processPending(modelContext: modelContext) }
        } label: {
            HStack(spacing: 8) {
                if fixer.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在修复 \(fixer.processedCount) / \(fixer.totalCount)…")
                } else {
                    Image(systemName: "wand.and.stars")
                    Text(startButtonTitle)
                }
            }
            .font(.headline)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(fixer.isProcessing || pendingCandidates.isEmpty)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var startButtonTitle: String {
        if pendingCandidates.isEmpty {
            "没有待修复的照片"
        } else {
            "修复这 \(pendingCandidates.count) 张"
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
#if DEBUG
        ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                Label("重置", systemImage: "arrow.counterclockwise.circle")
            }
            .disabled(scanner.isScanning || fixer.isProcessing)
        }
#endif
    }
}

// MARK: - Row

private struct CandidateRow: View {
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
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if candidate.pixelWidth > 0 && candidate.pixelHeight > 0 {
            "\(candidate.pixelWidth) × \(candidate.pixelHeight)"
        } else {
            "待修复"
        }
    }

    private var icon: String {
        switch candidate.state {
        case .pending: "clock"
        case .processing: "gear"
        case .fixed: "checkmark.circle.fill"
        case .originalDeleted: "checkmark.seal.fill"
        case .skipped: "minus.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch candidate.state {
        case .pending, .processing: .secondary
        case .fixed, .originalDeleted: .green
        case .skipped: .orange
        case .failed: .red
        }
    }
}

// MARK: - Authorization prompt

private struct AuthorizationPromptView: View {
    @Environment(PhotoFixer.self) private var fixer
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("需要照片库权限", systemImage: "lock.shield")
        } description: {
            Text(descriptionText)
        } actions: {
            Button(action: primaryAction) {
                Text(buttonTitle)
                    .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var descriptionText: String {
        switch fixer.authorizationStatus {
        case .denied, .restricted:
            "Heifixer 需要读写您的照片库，才能读取原始 HEIF 数据并写回修复后的 HEIC。请在「设置」中为 Heifixer 开启「所有照片」访问。"
        default:
            "Heifixer 需要读写您的照片库，才能读取原始 HEIF 数据并写回修复后的 HEIC。"
        }
    }

    private var buttonTitle: String {
        switch fixer.authorizationStatus {
        case .denied, .restricted: "前往设置"
        default: "授权访问"
        }
    }

    private func primaryAction() {
        switch fixer.authorizationStatus {
        case .denied, .restricted:
#if os(iOS) || os(visionOS)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
#endif
        default:
            Task { await fixer.requestAuthorization() }
        }
    }
}

#Preview {
    ContentView()
        .environment(PhotoFixer())
        .environment(PhotoLibraryScanner())
        .modelContainer(for: [Candidate.self, ScanState.self], inMemory: true)
}

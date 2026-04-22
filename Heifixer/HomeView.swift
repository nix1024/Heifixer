//
//  HomeView.swift
//  Heifixer
//

import Photos
import SwiftData
import SwiftUI

struct HomeView: View {
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

    @Namespace private var glassNamespace

    var body: some View {
        NavigationStack {
            Group {
                if fixer.hasLibraryAccess {
                    mainContent
                } else {
                    AuthorizationPromptView()
                }
            }
            .navigationTitle("Heifixer")
            .toolbar { toolbarContent }
            .toolbarTitleDisplayMode(.inlineLarge)
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

    // MARK: - Main content

    private var mainContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                GlassEffectContainer(spacing: 20) {
                    HeroCard(mode: heroMode)
                        .glassEffectID("hero", in: glassNamespace)
                }
                .padding(.horizontal)

                modeCard
                    .padding(.horizontal)
            }
            .padding(.top, 24)
            .padding(.bottom, 120)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) { fixButton }
    }

    // MARK: - Hero state mapping

    private var heroMode: HeroCard.Mode {
        if !pendingCandidates.isEmpty {
            .pending(count: pendingCandidates.count, isScanning: scanner.isScanning)
        } else if scanner.isScanning {
            .scanning(scanned: scanner.scannedCount, matched: scanner.matchedCount)
        } else {
            .empty
        }
    }

    // MARK: - Mode card

    private var modeCard: some View {
        @Bindable var fixer = fixer
        return VStack(alignment: .leading, spacing: 10) {
            Text("修复模式")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("修复模式", selection: $fixer.mode) {
                ForEach(FixMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(fixer.isProcessing)

            Text(fixer.mode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Label("重置", systemImage: "arrow.counterclockwise")
            }
            .disabled(scanner.isScanning || fixer.isProcessing)
        }
#endif
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
            "Heifixer 需要读写您的照片库，才能读取原始照片并写回修复后的版本。请在「设置」中为 Heifixer 开启「所有照片」访问。"
        default:
            "Heifixer 需要读写您的照片库，才能读取原始照片并写回修复后的版本。"
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

// MARK: - Hero card

/// Self-contained hero card for the home screen. Takes a pure value `Mode`
/// input so each visual state is easy to preview in isolation — the card
/// does not read any environment or services.
struct HeroCard: View {
    enum Mode: Equatable {
        case empty
        case scanning(scanned: Int, matched: Int)
        case pending(count: Int, isScanning: Bool)
    }

    let mode: Mode

    var body: some View {
        Group {
            switch mode {
            case .empty:
                EmptyHero()
            case .scanning(let scanned, let matched):
                ScanningHero(scannedCount: scanned, matchedCount: matched)
            case .pending(let count, let isScanning):
                PendingHero(count: count, isScanning: isScanning)
            }
        }
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: 28, style: .continuous)
        )
    }
}

private struct PendingHero: View {
    let count: Int
    let isScanning: Bool

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                HeroBigNumber(value: count, countsDown: true)
                Text("张照片待修复")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            if isScanning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在扫描照片库…")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }
}

private struct ScanningHero: View {
    let scannedCount: Int
    let matchedCount: Int

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                HeroBigNumber(value: matchedCount, countsDown: false)
                Text("张照片待修复")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("已检查 \(scannedCount) 张")
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }
}

private struct EmptyHero: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 56, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            Text("一切就绪")
                .font(.system(.title, design: .rounded, weight: .semibold))
            Text("没有需要修复的照片。\n新照片加入照片库时，Heifixer 会自动检测。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }
}

/// Shared large numeric display used by both the scanning and pending hero
/// states so the matched count morphs smoothly into the final pending count.
private struct HeroBigNumber: View {
    let value: Int
    let countsDown: Bool

    var body: some View {
        Text("\(value)")
            .font(.system(size: 96, weight: .bold, design: .rounded))
            .contentTransition(.numericText(countsDown: countsDown))
            .monospacedDigit()
            .foregroundStyle(
                LinearGradient(
                    colors: [.primary, .primary.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
}

// MARK: - Previews

#Preview("Home") {
    HomeView()
        .environment(PhotoFixer())
        .environment(PhotoLibraryScanner())
        .modelContainer(for: [Candidate.self, ScanState.self], inMemory: true)
}

#Preview("Hero") {
    @Previewable @Namespace var emptyNamespace
    @Previewable @Namespace var scanningNamespace
    @Previewable @Namespace var pendingNamespace
    @Previewable @Namespace var pendingScanningNamespace

    ScrollView {
        VStack(spacing: 24) {
            GlassEffectContainer(spacing: 20) {
                HeroCard(mode: .empty)
                    .glassEffectID("hero", in: emptyNamespace)
            }
            .padding(.horizontal)

            GlassEffectContainer(spacing: 20) {
                HeroCard(mode: .scanning(scanned: 1_284, matched: 17))
                    .glassEffectID("hero", in: scanningNamespace)
            }
            .padding(.horizontal)

            GlassEffectContainer(spacing: 20) {
                HeroCard(mode: .pending(count: 42, isScanning: false))
                    .glassEffectID("hero", in: pendingNamespace)
            }
            .padding(.horizontal)

            GlassEffectContainer(spacing: 20) {
                HeroCard(mode: .pending(count: 42, isScanning: true))
                    .glassEffectID("hero", in: pendingScanningNamespace)
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
    }
}

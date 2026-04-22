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
            .navigationSubtitle(statusSubtitle)
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
            return .pending(count: pendingCandidates.count)
        }
        if case .scanning(_, _, let matched) = scanner.status {
            return .scanning(matched: matched)
        }
        return .empty
    }

    // MARK: - Navigation subtitle

    /// Compact, at-a-glance status shown under the navigation title.
    /// Priority: ongoing work (cleanup > fix > scan) beats transient
    /// "just finished" notices. An empty string hides the subtitle.
    private var statusSubtitle: String {
        switch fixer.status {
        case .cleaningUp:
            return "正在清理原图…"
        case .fixing(let processed, let total):
            return "正在修复 \(processed) / \(total)"
        case .idle:
            break
        }
        switch scanner.status {
        case .scanning(let scanned, let total, _):
            // `total` is only known after the PHFetchResult is built; before
            // that (e.g. during the DEBUG warm-up sleep) fall back to the
            // indeterminate label so we never render "X / 0".
            return total > 0 ? "正在扫描 \(scanned) / \(total)" : "正在扫描…"
        case .completed:
            return "扫描完成"
        case .failed(let message):
            return message
        case .none:
            return ""
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
            .disabled(fixer.status != .idle)

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
                switch fixer.status {
                case .fixing(let processed, let total):
                    ProgressView()
                        .controlSize(.small)
                    Text("正在修复 \(processed) / \(total)…")
                case .cleaningUp:
                    ProgressView()
                        .controlSize(.small)
                    Text("正在清理原图…")
                case .idle:
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
        .disabled(fixer.status != .idle || pendingCandidates.isEmpty)
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
            .disabled(scanner.status.isScanning || fixer.status != .idle)
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
        case scanning(matched: Int)
        case pending(count: Int)
    }

    let mode: Mode

    var body: some View {
        Group {
            switch mode {
            case .empty:
                EmptyHero()
            case .scanning(let matched):
                CountHero(count: matched, isScanning: true)
            case .pending(let count):
                CountHero(count: count, isScanning: false)
            }
        }
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: 28, style: .continuous)
        )
    }
}

/// Shared hero body for both "scanning" and "pending" states. Keeping them
/// in a single view preserves the `HeroBigNumber`'s identity across the
/// scanning → pending handoff so the numeric content transition actually
/// animates when the final matched count becomes the pending count.
private struct CountHero: View {
    let count: Int
    let isScanning: Bool

    var body: some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading) {
                HStack {
                    Image(systemName: "photo.on.rectangle.angled")
                    Text("待修复照片")
                        .font(.headline)
                }
                .foregroundStyle(.secondary)
                
                HeroBigNumber(value: count, countsDown: !isScanning)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isScanning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("扫描中…")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
        .animation(.snappy, value: isScanning)
    }
}

private struct EmptyHero: View {
    var body: some View {
        VStack(alignment: .leading) {
            Image(systemName: "sparkles")
                .font(.system(size: 56, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            Text("一切就绪")
                .font(.system(.title, design: .rounded, weight: .semibold))
                .padding(.top)
            Text("没有需要修复的照片。新照片加入照片库时，Heifixer 会自动检测。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal)
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
            // `.contentTransition(.numericText)` only animates when the value
            // change happens inside an animation context. Binding a spring
            // here guarantees the rolling-digit effect regardless of whether
            // upstream state flips inside `withAnimation`.
            .animation(.snappy, value: value)
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

    ScrollView {
        VStack(spacing: 24) {
            GlassEffectContainer(spacing: 20) {
                HeroCard(mode: .empty)
                    .glassEffectID("hero", in: emptyNamespace)
            }
            .padding(.horizontal)

            GlassEffectContainer(spacing: 20) {
                HeroCard(mode: .scanning(matched: 17))
                    .glassEffectID("hero", in: scanningNamespace)
            }
            .padding(.horizontal)

            GlassEffectContainer(spacing: 20) {
                HeroCard(mode: .pending(count: 42))
                    .glassEffectID("hero", in: pendingNamespace)
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
    }
}

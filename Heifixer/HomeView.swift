//
//  HomeView.swift
//  Heifixer
//

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

    @Query(
        filter: #Predicate<Candidate> { $0.stateRaw == "fixed" },
        sort: [SortDescriptor(\Candidate.fixedAt, order: .reverse)]
    )
    private var fixedCandidates: [Candidate]

    @State private var showDeleteErrorAlert = false
    @State private var showResetConfirm = false

    var body: some View {
        NavigationStack {
            mainContent
            .navigationTitle("Heifixer")
            .navigationSubtitle("")
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
        Form {
            Section {
                HeroCard(count: pendingCandidates.count, isScanning: scanner.status.isScanning)
            } footer: {
                heroSectionFooter
            }

            Section {
                Toggle(
                    "自动删除原图",
                    isOn: Binding(
                        get: { fixer.mode == .replaceOriginal },
                        set: { fixer.mode = $0 ? .replaceOriginal : .keepOriginal }
                    )
                )
                .disabled(fixer.status != .idle)
            } footer: {
                Text(fixer.mode.explanation)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            if !fixedCandidates.isEmpty {
                Section {
                    Button(role: .destructive) {
                        Task { await fixer.deleteFixedOriginals(modelContext: modelContext) }
                    } label: {
                        Text("删除 \(fixedCandidates.count) 张原图")
                    }
                    .disabled(fixer.status != .idle || scanner.status.isScanning)
                } footer: {
                    Text(
                        "仅删除照片库中仍存在的原始照片，已生成的修复版照片不会删除。"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { fixButton }
    }

    // MARK: - Hero section footer (status)

    /// Form section footers keep status grouped with the hero metric without
    /// competing with the navigation title.
    private var heroSectionFooter: some View {
        let payload = homeHeroStatusPayload
        return Group {
            if !payload.text.isEmpty {
                HStack(alignment: .center, spacing: 8) {
                    if payload.showsProgress {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(payload.text)
                        .foregroundStyle(payload.isFailure ? .red : .secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.snappy, value: payload.text)
    }

    private var homeHeroStatusPayload: (text: String, showsProgress: Bool, isFailure: Bool) {
        switch fixer.status {
        case .cleaningUp:
            return ("正在清理原图…", true, false)
        case .fixing(let processed, let total):
            return ("正在修复 \(processed) / \(total)", true, false)
        case .idle:
            break
        }
        switch scanner.status {
        case .scanning(let scanned, let total, _):
            // `total` is only known after the PHFetchResult is built; before
            // that (e.g. during the DEBUG warm-up sleep) fall back to the
            // indeterminate label so we never render "X / 0".
            let line = total > 0 ? "正在扫描 \(scanned) / \(total)" : "正在扫描…"
            return (line, true, false)
        case .completed:
            return ("扫描完成", false, false)
        case .failed(let message):
            return (message, false, true)
        case .none:
            return ("", false, false)
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

// MARK: - Hero card

/// Self-contained hero for the home screen — no environment; preview with
/// `count` and `isScanning` only.
struct HeroCard: View {
    let count: Int
    let isScanning: Bool

    var body: some View {
        Group {
            if count == 0 {
                EmptyHero()
            } else {
                CountHero(count: count, isScanning: isScanning)
            }
        }
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            Text("没有需要修复的照片。新照片加入照片库时，Heifixer 会自动扫描。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shared large numeric display used by both the scanning and pending hero
/// states so the matched count morphs smoothly into the final pending count.
private struct HeroBigNumber: View {
    let value: Int
    let countsDown: Bool

    var body: some View {
        Text("\(value)")
            .font(.system(size: 64, weight: .bold, design: .rounded))
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

#Preview("Hero — Form sections") {
    Form {
        Section {
            HeroCard(count: 0, isScanning: false)
        } footer: {
            Text("扫描完成")
        }

        Section {
            HeroCard(count: 17, isScanning: true)
        } footer: {
            Text("正在扫描 128 / 4000")
        }

        Section {
            HeroCard(count: 42, isScanning: false)
        } footer: {
            Text("扫描完成")
        }
    }
}

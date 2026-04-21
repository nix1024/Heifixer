//
//  ContentView.swift
//  Heifixer
//
//  Created by 王昕 on 2026/4/20.
//

import Photos
import PhotosUI
import SwiftUI

struct ContentView: View {
    @Environment(PhotoFixer.self) private var fixer
    @State private var selection: [PhotosPickerItem] = []

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
            .onChange(of: selection) {
                guard !selection.isEmpty else { return }
                let picked = selection
                selection = []
                fixer.addJobs(from: picked)
            }
        }
        .task {
            if fixer.authorizationStatus == .notDetermined {
                await fixer.requestAuthorization()
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if fixer.jobs.isEmpty {
            EmptyStateView()
        } else {
            jobList
        }
    }

    private var jobList: some View {
        List {
            Section {
                ForEach(fixer.jobs) { job in
                    FixJobRow(job: job)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                fixer.remove(job)
                            } label: {
                                Label("移除", systemImage: "trash")
                            }
                        }
                }
            } header: {
                Text("待修复照片 (\(fixer.jobs.count))")
            } footer: {
                summaryFooter
            }
        }
        .safeAreaInset(edge: .bottom) {
            fixButton
        }
    }

    private var summaryFooter: some View {
        let succeeded = fixer.jobs.filter {
            if case .succeeded = $0.status { return true } else { return false }
        }.count
        let failed = fixer.jobs.filter {
            if case .failed = $0.status { return true } else { return false }
        }.count
        let skipped = fixer.jobs.filter {
            if case .skipped = $0.status { return true } else { return false }
        }.count
        return Text("成功 \(succeeded) · 跳过 \(skipped) · 失败 \(failed)")
    }

    private var fixButton: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                Task { await fixer.processAll() }
            } label: {
                HStack {
                    if fixer.isProcessing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text("正在修复…")
                    } else {
                        Image(systemName: "wand.and.stars")
                        Text("开始修复")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(fixer.isProcessing || !fixer.jobs.contains { $0.status == .pending })
            .padding()
        }
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            PhotosPicker(
                selection: $selection,
                maxSelectionCount: nil,
                matching: .images,
                preferredItemEncoding: .current,
                photoLibrary: .shared()
            ) {
                Label("添加照片", systemImage: "plus")
            }
            .disabled(fixer.isProcessing)
        }
        if !fixer.jobs.isEmpty {
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    Button(role: .destructive) {
                        fixer.resetAll()
                    } label: {
                        Label("清空列表", systemImage: "trash")
                    }
                    Button {
                        fixer.clearCompleted()
                    } label: {
                        Label("清除已完成", systemImage: "checkmark.circle")
                    }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
                .disabled(fixer.isProcessing)
            }
        }
    }
}

// MARK: - Row

private struct FixJobRow: View {
    let job: FixJob

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayName)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                subtitle
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .processing:
            ProgressView()
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .skipped:
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.orange)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var subtitle: Text {
        switch job.status {
        case .pending:
            Text(dimensionText)
        case .processing:
            Text("正在修复…")
        case .succeeded:
            Text("已写入照片库 · \(dimensionText)")
        case .skipped(let reason):
            Text(reason)
        case .failed(let message):
            Text(message)
        }
    }

    private var dimensionText: String {
        if job.pixelWidth > 0 && job.pixelHeight > 0 {
            "\(job.pixelWidth) × \(job.pixelHeight)"
        } else {
            job.originalUTI ?? ""
        }
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    var body: some View {
        ContentUnavailableView {
            Label("还没有照片", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("点击右上角的 + 选择需要修复的 HEIF 照片。\n（例如 Sony A6700 拍摄的 .HEIF 文件）")
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
}

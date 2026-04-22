//
//  OnboardingView.swift
//  Heifixer
//

import Photos
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct OnboardingView: View {
    @Environment(PhotoFixer.self) private var fixer
    @Environment(\.openURL) private var openURL

    private enum Step: Equatable {
        case intro
        case permission
    }

    @State private var step: Step = .intro

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: step == .intro ? "wand.and.stars" : "lock.shield")
                    .font(.system(size: 56, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 32)
                    .accessibilityHidden(true)

                Text("Heifixer")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)

                if step == .intro {
                    introContent
                } else {
                    permissionContent
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 120)
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
        .onAppear(perform: applyInitialStepForSystemStatus)
    }

    // MARK: - Step 1: 功能与隐私

    private var introContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("在本地修复某些型号相机 HEIF/HEIC 的显示方向，让照片在相册里方向正确。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                OnboardingBullet(
                    systemImage: "doc.text.magnifyingglass",
                    title: "扫描与识别",
                    subtitle: "在照片库中找出需要方向修复的 Sony 照片。"
                )
                OnboardingBullet(
                    systemImage: "arrow.triangle.2.circlepath",
                    title: "修复与写回",
                    subtitle: "在您的设备上生成修复后的照片副本。"
                )
            }
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: - Step 2: 授权

    private var permissionContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(permissionLead)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            OnboardingBullet(
                systemImage: "lock.fill",
                title: "本地处理，保护隐私",
                subtitle: "所有分析与生成都发生在本机，照片不会上传至任何服务器。"
            )
            .accessibilityElement(children: .contain)
        }
    }

    private var permissionLead: String {
        switch fixer.authorizationStatus {
        case .denied, .restricted:
            "需要访问照片库才能读取与保存照片。请在「设置」中为 Heifixer 开启「所有照片」或「选中的照片」访问。"
        default:
            "接下来需要您授权 Heifixer 访问照片。我们只会在您已同意后读写照片，用于上述本地修复。"
        }
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        Group {
            if step == .intro {
                Button(action: goToPermissionStep) {
                    Text("继续")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .accessibilityHint("进入照片授权步骤")
            } else {
                Button(action: primaryPermissionAction) {
                    Text(permissionButtonTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .accessibilityHint(
                    fixer.authorizationStatus == .denied || fixer.authorizationStatus == .restricted
                        ? "在设置中打开 Heifixer 的照片访问"
                        : "请求系统照片库访问权限"
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    // MARK: - Actions

    /// 若系统已标记为拒绝或受限，直接进入授权步骤。
    private func applyInitialStepForSystemStatus() {
        switch fixer.authorizationStatus {
        case .denied, .restricted:
            step = .permission
        default:
            break
        }
    }

    private func goToPermissionStep() {
        step = .permission
    }

    private var permissionButtonTitle: String {
        switch fixer.authorizationStatus {
        case .denied, .restricted: "前往设置"
        default: "授权访问照片"
        }
    }

    private func primaryPermissionAction() {
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

private struct OnboardingBullet: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    OnboardingView()
        .environment(PhotoFixer())
}

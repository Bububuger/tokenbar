import SwiftUI
import TokenBarCore

/// Full-featured update notification card with mascot animation.
/// Displays when a new version is available.
struct UpdateNotificationCard: View {
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let update = runtimeModel.availableUpdate, update.isNewer {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    // Mascot with download animation
                    MascotDownloadView(downloadState: runtimeModel.updateDownloadState)

                    // Update info and actions
                    VStack(alignment: .leading, spacing: 8) {
                        Text("发现新版本 v\(update.latestVersion)")
                            .font(.headline)
                            .foregroundColor(.primary)

                        Text("当前版本: v\(update.currentVersion)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack(spacing: 8) {
                            actionButton

                            Button("查看更新说明") {
                                openURL(update.releaseURL)
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Dismiss button
                    Button(action: { runtimeModel.dismissUpdateNotification() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("暂时隐藏更新提示")
                }
                .padding(16)
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: Color.black.opacity(0.1), radius: 4, y: 2)
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch runtimeModel.updateDownloadState {
        case .idle:
            if runtimeModel.availableUpdate?.dmgURL != nil {
                Button("下载更新") {
                    runtimeModel.downloadAvailableUpdate()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Button("前往下载页面") {
                    if let url = runtimeModel.availableUpdate?.releaseURL {
                        openURL(url)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

        case .downloading:
            Button("下载中...") {}
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(true)

        case .completed:
            Button("安装更新") {
                openDownloadedDMG()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("打开下载的 DMG，将 TokenBar.app 拖到 /Applications/")

        case .failed:
            Button("重试下载") {
                runtimeModel.downloadAvailableUpdate()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .foregroundColor(.red)
        }
    }

    private func openDownloadedDMG() {
        guard let dmg = runtimeModel.consumeCompletedUpdate() else { return }
        NSWorkspace.shared.open(dmg)
    }
}

// MARK: - Preview

#Preview("Update Available - Idle") {
    UpdateNotificationCard()
        .frame(width: 600)
        .padding()
}

#Preview("Update Available - Downloading") {
    UpdateNotificationCard()
        .frame(width: 600)
        .padding()
}

#Preview("Update Available - Completed") {
    UpdateNotificationCard()
        .frame(width: 600)
        .padding()
}

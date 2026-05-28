import SwiftUI
import TokenBarCore

struct PluginGalleryView: View {
    @EnvironmentObject private var runtimeModel: TokenBarRuntimeModel
    @State private var registryEntries: [PluginRegistryEntry] = []
    @State private var installedManifests: [PluginManifest] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var confirmingExecutable: PluginRegistryEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            installedSection
            availableSection
        }
    }

    @ViewBuilder
    private var installedSection: some View {
        if !installedManifests.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Installed")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TokenBarStyle.faint)
                        .textCase(.uppercase)
                    Text("\(installedManifests.count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(TokenBarStyle.faint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(TokenBarStyle.faint.opacity(0.12), in: Capsule())
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(installedManifests, id: \.id) { manifest in
                        pluginCard(manifest: manifest, installed: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var availableSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Available")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TokenBarStyle.faint)
                    .textCase(.uppercase)
                if !registryEntries.isEmpty {
                    Text("\(registryEntries.count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(TokenBarStyle.faint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(TokenBarStyle.faint.opacity(0.12), in: Capsule())
                }
                Spacer()
                Button {
                    Task { await refreshRegistry(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(TokenBarStyle.faint)
                .disabled(isLoading)
            }

            if isLoading {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading registry…")
                        .font(.system(size: 11))
                        .foregroundStyle(TokenBarStyle.faint)
                }
                .padding(.vertical, 8)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.8))
                    .padding(.vertical, 4)
            } else if registryEntries.isEmpty {
                Text("No additional plugins available")
                    .font(.system(size: 11))
                    .foregroundStyle(TokenBarStyle.faint)
                    .padding(.vertical, 8)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(availableEntries) { entry in
                        registryCard(entry: entry)
                    }
                }
            }
        }
        .task { await refreshRegistry() }
        .alert("Install Executable Plugin?", isPresented: .init(
            get: { confirmingExecutable != nil },
            set: { if !$0 { confirmingExecutable = nil } }
        )) {
            Button("Cancel", role: .cancel) { confirmingExecutable = nil }
            Button("Install") {
                if let entry = confirmingExecutable {
                    Task { await installPlugin(entry: entry) }
                }
                confirmingExecutable = nil
            }
        } message: {
            Text("This plugin runs an external script on your machine. Only install plugins from sources you trust.")
        }
    }

    private var availableEntries: [PluginRegistryEntry] {
        let installedIds = Set(installedManifests.map(\.id))
        return registryEntries.filter { !installedIds.contains($0.id) }
    }

    private func pluginCard(manifest: PluginManifest, installed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(manifest.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TokenBarStyle.foreground)
                    .lineLimit(1)
                Spacer()
            }
            Text("v\(manifest.version)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(TokenBarStyle.faint)
            HStack(spacing: 4) {
                Text(manifest.source.sourceType.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(pluginTypeTint(manifest.source.sourceType))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(pluginTypeTint(manifest.source.sourceType).opacity(0.12), in: Capsule())
                Spacer()
                if installed {
                    Button("Uninstall") {
                        Task { await uninstallPlugin(pluginId: manifest.id) }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.red.opacity(0.7))
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(TokenBarStyle.faint.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(TokenBarStyle.faint.opacity(0.15), lineWidth: 1))
    }

    private func registryCard(entry: PluginRegistryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TokenBarStyle.foreground)
                    .lineLimit(1)
                Spacer()
            }
            Text("v\(entry.version)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(TokenBarStyle.faint)
            HStack(spacing: 4) {
                if let type = entry.type {
                    Text(type.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(pluginTypeTint(type))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(pluginTypeTint(type).opacity(0.12), in: Capsule())
                }
                Spacer()
                Button("Install") {
                    if entry.type == "executable" {
                        confirmingExecutable = entry
                    } else {
                        Task { await installPlugin(entry: entry) }
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TokenBarStyle.accent)
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(TokenBarStyle.faint.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(TokenBarStyle.faint.opacity(0.15), lineWidth: 1))
    }

    private func pluginTypeTint(_ type: String) -> Color {
        switch type {
        case "jsonl", "declarative": .green
        case "sqlite": .blue
        case "executable": .orange
        default: .gray
        }
    }

    private func refreshRegistry(force: Bool = false) async {
        isLoading = true
        errorMessage = nil
        installedManifests = PluginManager(store: runtimeModel.store).installedManifests()

        do {
            let client = PluginRegistryClient()
            let index = try await client.fetchIndex(forceRefresh: force)
            registryEntries = index.plugins
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func installPlugin(entry: PluginRegistryEntry) async {
        do {
            let client = PluginRegistryClient()
            let (manifest, data) = try await client.downloadManifest(from: entry)
            var attachments: [(name: String, data: Data)] = []

            if case .executable(let src) = manifest.source, let script = src.script {
                let baseURL = entry.downloadUrl
                    .replacingOccurrences(of: "/manifest.json", with: "")
                let scriptData = try await client.downloadAttachment(baseURL: baseURL, fileName: script)
                attachments.append((name: script, data: scriptData))
            }

            let manager = PluginManager(store: runtimeModel.store)
            try await manager.install(manifest: manifest, manifestData: data, attachments: attachments)
            await refreshRegistry()
            runtimeModel.rebuildPopoverSnapshot(trigger: "plugin-install")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func uninstallPlugin(pluginId: String) async {
        do {
            let manager = PluginManager(store: runtimeModel.store)
            try await manager.uninstall(pluginId: pluginId)
            await refreshRegistry()
            runtimeModel.rebuildPopoverSnapshot(trigger: "plugin-uninstall")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

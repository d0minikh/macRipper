import SwiftUI

struct ToolsView: View {
    @EnvironmentObject var tools: ToolManager
    @EnvironmentObject var manager: JobManager
    @ViewState private var showOutput = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("MacRipper drives external programs. Missing tools can be installed and updated here; paths can be overridden in Settings.")
                    .foregroundStyle(.secondary)

                if tools.brewPath == nil { homebrewMissing }
                if let error = tools.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if !manager.activeJobs.isEmpty {
                    Label("Installing and updating is disabled while jobs are running.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }

                ForEach(tools.tools) { tool in
                    ToolCard(tool: tool, jobsRunning: !manager.activeJobs.isEmpty)
                }

                if !tools.output.isEmpty {
                    DisclosureGroup("Output of the last operation", isExpanded: $showOutput) {
                        ScrollView {
                            Text(tools.output)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 220)
                        .padding(8)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    }
                }

                HStack {
                    Button("Open Logs Folder") { NSWorkspace.shared.open(AppPaths.logs) }
                    Button("Open Config Folder") { NSWorkspace.shared.open(AppPaths.support) }
                }
            }
            .padding(24)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Tools")
        .task { await tools.refresh() }
    }

    private var homebrewMissing: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Homebrew is required to install HandBrakeCLI, FFmpeg and Apprise.", systemImage: "shippingbox")
                    .font(.headline)
                Text("Homebrew's installer needs your administrator password, so it has to run in Terminal. Copy the command, paste it into Terminal, then click Check for Updates.")
                    .foregroundStyle(.secondary)
                Text(ToolManager.homebrewInstallCommand)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                HStack {
                    Button("Copy Install Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ToolManager.homebrewInstallCommand, forType: .string)
                    }
                    Button("Open Terminal") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                    }
                    Link("brew.sh", destination: URL(string: "https://brew.sh")!)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ToolCard: View {
    let tool: ToolManager.Tool
    let jobsRunning: Bool
    @EnvironmentObject var tools: ToolManager

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Image(systemName: icon)
                        .foregroundStyle(color)
                        .font(.title2)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(tool.name).font(.headline)
                            if let v = tool.installedVersion { Text(v).foregroundStyle(.secondary) }
                            if tool.updateAvailable, let latest = tool.latestVersion {
                                Text("Update to \(latest)")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.orange.opacity(0.18), in: Capsule())
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text(tool.purpose).foregroundStyle(.secondary)
                        if let path = tool.path {
                            Text(path).font(.caption.monospaced()).textSelection(.enabled)
                        } else if let latest = tool.latestVersion {
                            Text("Not installed – version \(latest) available").font(.caption)
                        } else {
                            Text("Not installed").font(.caption)
                        }
                    }
                    Spacer()
                    actionButton
                }
                if tools.busyTool == tool.id {
                    VStack(alignment: .leading, spacing: 4) {
                        if let p = tools.progress {
                            ProgressView(value: p)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                        Text(tools.activity).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if tool.source == .system {
            EmptyView()
        } else if tools.busyTool == tool.id {
            Button("Cancel") { tools.cancel() }
        } else if !tool.isInstalled {
            Button("Install") { Task { await tools.installOrUpdate(tool.id) } }
                .buttonStyle(.borderedProminent)
                .disabled(!canAct)
        } else if tool.updateAvailable {
            Button("Update") { Task { await tools.installOrUpdate(tool.id) } }
                .buttonStyle(.borderedProminent)
                .disabled(!canAct)
        } else if tool.latestVersion != nil {
            Text("Up to date").foregroundStyle(.secondary)
        }
    }

    private var canAct: Bool {
        guard tools.busyTool == nil, !jobsRunning else { return false }
        if case .brew = tool.source { return tools.brewPath != nil }
        return true
    }

    private var icon: String {
        if !tool.isInstalled { return "xmark.octagon.fill" }
        return tool.updateAvailable ? "arrow.down.circle.fill" : "checkmark.seal.fill"
    }

    private var color: Color {
        if !tool.isInstalled { return .red }
        return tool.updateAvailable ? .orange : .green
    }
}

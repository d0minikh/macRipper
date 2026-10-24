import SwiftUI

struct DrivesView: View {
    @Binding var selection: SidebarItem?
    @EnvironmentObject var manager: JobManager
    @EnvironmentObject var monitor: DiscMonitor
    @EnvironmentObject var configStore: ConfigStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                StatsStrip()
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle("Drives")
                    if monitor.drives.isEmpty && monitor.discs.isEmpty {
                        ContentUnavailableView("No Optical Drive", systemImage: "opticaldiscdrive",
                                               description: Text("Connect a DVD or Blu-ray drive. MacRipper starts automatically when a disc is inserted."))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    }
                    // A plain stack: an adaptive grid changes its column count with the width and, next to the
                    // inspector, can make the split view re-layout endlessly in narrow windows.
                    VStack(spacing: 14) {
                        ForEach(monitor.drives) { drive in
                            DriveCard(drive: drive, disc: disc(in: drive), selection: $selection)
                        }
                        // Discs whose drive drutil does not list (e.g. some USB enclosures).
                        ForEach(unmatchedDiscs) { disc in
                            DriveCard(drive: nil, disc: disc, selection: $selection)
                        }
                    }
                }
                if configStore.config.webServerEnabled, let url = configStore.config.webInterfaceURL {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle("Web Interface")
                        Link(destination: url) { Label("Open in Browser", systemImage: "safari") }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Drives")
    }

    private func disc(in drive: OpticalDrive) -> DetectedDisc? {
        monitor.discs.first { $0.deviceModel.localizedCaseInsensitiveContains(drive.product)
            || drive.product.localizedCaseInsensitiveContains($0.deviceModel) && !$0.deviceModel.isEmpty }
            ?? (monitor.drives.count == 1 ? monitor.discs.first : nil)
    }

    private var unmatchedDiscs: [DetectedDisc] {
        monitor.discs.filter { disc in !monitor.drives.contains { self.disc(in: $0) == disc } }
    }
}

struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.6)
    }
}

/// Small figures at the top of the Drives page, like the library summary in Final Cut Pro.
private struct StatsStrip: View {
    @EnvironmentObject var manager: JobManager
    @EnvironmentObject var monitor: DiscMonitor

    var body: some View {
        HStack(spacing: 12) {
            tile("\(monitor.discs.count)", "Discs inserted", "opticaldisc", .accentColor)
            tile("\(manager.activeJobs.count)", "Running", "waveform", .orange)
            tile("\(manager.finishedJobs.filter { $0.status == .success }.count)", "Finished", "checkmark.circle", .green)
            tile("\(manager.finishedJobs.filter { $0.status == .failed }.count)", "Failed", "exclamationmark.triangle", .red)
        }
    }

    private func tile(_ value: String, _ caption: String, _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit()
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

private struct DriveCard: View {
    let drive: OpticalDrive?
    let disc: DetectedDisc?
    @Binding var selection: SidebarItem?
    @EnvironmentObject var manager: JobManager

    private var job: Job? {
        guard let disc else { return nil }
        return manager.activeJobs.first { $0.devicePath == disc.devicePath }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "opticaldiscdrive.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(drive?.name ?? disc?.deviceModel ?? "Optical Drive").font(.headline).lineLimit(1)
                    Text(drive.map { "Drive \($0.id) · \($0.bus)" } ?? disc?.devicePath ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Divider()
            if let disc {
                HStack(spacing: 12) {
                    Image(systemName: "opticaldisc.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(tint(disc).gradient)
                        .frame(width: 34)
                        .symbolEffect(.rotate, isActive: job?.status == .ripping)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(job?.displayTitle ?? volumeName(disc) ?? disc.mediaLabel).lineLimit(1)
                        Text(job.map { j in j.remainingText.map { "\(j.stage) · \($0)" } ?? j.stage }
                             ?? "\(disc.mediaLabel) · \(disc.devicePath)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if let job { ProgressView(value: job.progress).progressViewStyle(.linear) }
                HStack {
                    if let job {
                        Button("Show Job") { selection = .job(job.id) }
                    } else {
                        Button("Rip") { manager.startJob(for: disc) }
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    Button("Eject") { Task { await DiscMonitor.eject(disc.devicePath) } }
                        .disabled(manager.isBusy(disc.devicePath))
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "opticaldisc")
                        .font(.system(size: 26, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                        .frame(width: 34)
                    Text("No disc").foregroundStyle(.secondary)
                    Spacer()
                    if let drive {
                        // drutil can only open the tray; most slot and slim drives cannot close it.
                        Button("Open Tray") {
                            Task { _ = try? await ProcessRunner().run("/usr/bin/drutil", ["-drive", "\(drive.id)", "tray", "eject"]) }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.6)))
    }

    private func tint(_ disc: DetectedDisc) -> Color {
        switch disc.mediaKind {
        case "IOBDMedia": .blue
        case "IODVDMedia": .indigo
        default: .pink
        }
    }

    private func volumeName(_ disc: DetectedDisc) -> String? {
        DiscMonitor.mountPoint(for: disc.bsdName).map { ($0 as NSString).lastPathComponent }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var manager: JobManager
    @EnvironmentObject var monitor: DiscMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if manager.activeJobs.isEmpty {
            Text("No active jobs")
        }
        ForEach(manager.activeJobs) { job in
            Text("\(job.displayTitle) – \(job.status.label) \(job.progress.formatted(.percent.precision(.fractionLength(0))))"
                 + (job.remainingText.map { " · \($0)" } ?? ""))
        }
        Divider()
        ForEach(monitor.discs) { disc in
            if !manager.isBusy(disc.devicePath) {
                Button("Rip \(disc.mediaLabel) in \(disc.deviceModel)") { manager.startJob(for: disc) }
            }
        }
        Button("Open MacRipper") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit MacRipper") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

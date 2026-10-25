import SwiftUI

/// The middle column for a job: artwork and status on top, titles or tracks as a table below.
struct JobViewer: View {
    let jobID: UUID
    /// Owned by the window, so the shared toolbar and the Disc menu can trigger them.
    @Binding var confirmAbandon: Bool
    @Binding var showLog: Bool
    @EnvironmentObject var manager: JobManager

    var body: some View {
        if let job = manager.job(jobID) {
            VStack(spacing: 0) {
                ViewerHeader(job: job)
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 14)
                if let error = job.errorMessage {
                    Banner(symbol: "exclamationmark.triangle.fill", tint: .red, title: "The job failed", message: error)
                        .padding(.horizontal, 24).padding(.bottom, 12)
                }
                if job.discType == .audioCD, job.status == .success,
                   job.audioInfo?.tagsChangedAfterRip == true || manager.retagging.contains(job.id)
                    || manager.retagErrors[job.id] != nil {
                    RetagBanner(job: job).padding(.horizontal, 24).padding(.bottom, 12)
                }
                Divider()
                switch job.discType {
                case .audioCD: TrackTable(job: job)
                case .dvd, .bluray: TitleTable(job: job)
                default: DataSummary(job: job)
                }
            }
            .navigationTitle(job.displayTitle)
            .navigationSubtitle(job.discType.label)
            .confirmationDialog("Abandon “\(job.displayTitle)”?", isPresented: $confirmAbandon) {
                Button("Abandon Job", role: .destructive) { manager.abandon(job.id) }
            } message: {
                Text("The running tool is stopped. Files already written stay in place.")
            }
            .sheet(isPresented: $showLog) { LogView(url: job.logURL) }
            .focusedSceneValue(\.showLog, $showLog)
            .focusedSceneValue(\.confirmAbandon, $confirmAbandon)
        }
    }
}

// MARK: - Header

private struct ViewerHeader: View {
    let job: Job

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            artwork
            VStack(alignment: .leading, spacing: 6) {
                Text(kindLine)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Text(job.displayTitle)
                    .font(.system(.title, weight: .bold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                if !subtitle.isEmpty {
                    Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    StatusBadge(status: job.status)
                    if job.status.isActive {
                        Text(job.remainingText.map { "\(job.stage) · \($0)" } ?? job.stage)
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.top, 2)
                if job.status.isActive {
                    // Compressible on purpose: the header must never force the viewer wider than the window allows.
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                        .frame(minWidth: 0, maxWidth: 360)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if job.discType == .audioCD {
            CoverImageView(cover: job.audioInfo?.cover, size: 112)
        } else if job.discType.isVideo, let url = URL(string: job.posterURL), !job.posterURL.isEmpty {
            RemoteImage(url: url, points: 112) { JobThumbnail(job: job, size: 96) }
                .frame(width: 78, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        } else {
            JobThumbnail(job: job, size: 96)
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
        }
    }

    private var kindLine: String {
        var parts = [job.discType.label]
        if job.discType.isVideo, job.videoKind != .unknown { parts.append(job.videoKind.label) }
        if job.discType == .audioCD, let info = job.audioInfo, info.discTotal > 1 {
            parts.append("Disc \(info.discNumber) of \(info.discTotal)")
        }
        return parts.joined(separator: " · ")
    }

    private var subtitle: String {
        switch job.discType {
        case .audioCD:
            let info = job.audioInfo
            return [job.year, info?.genre ?? "", info?.label ?? "", "\(job.titles.count) tracks"]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        case .dvd, .bluray:
            let total = job.titles.filter(\.selected).reduce(0) { $0 + $1.durationSeconds }
            return [job.discLabel, total > 0 ? Job.formatDuration(total) : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        default:
            return job.discLabel
        }
    }
}

struct Banner: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Tables

private struct TrackTable: View {
    let job: Job
    @EnvironmentObject var manager: JobManager
    @ViewState private var selection: Set<Int> = []

    private var tagsEditable: Bool {
        switch job.status {
        case .identifying, .waiting: true
        case .success: !manager.retagging.contains(job.id)
        default: false
        }
    }

    private var selectionEditable: Bool { job.status == .identifying || job.status == .waiting }

    var body: some View {
        Table(job.titles, selection: $selection) {
            TableColumn("") { track in
                Toggle("", isOn: Binding(get: { track.selected },
                                         set: { manager.toggleTitle(job.id, title: track.id, selected: $0) }))
                    .labelsHidden()
                    .disabled(!selectionEditable)
                    .accessibilityLabel("Include track \(track.id)")
            }
            .width(24)
            TableColumn("#") { track in
                Text(String(format: "%02d", track.id)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(30)
            TableColumn("Title") { track in
                CommitTextField("Title", value: track.name) { setTitle(track, $0) }
                    .textFieldStyle(.plain)
                    .disabled(!tagsEditable)
                    .accessibilityLabel("Title of track \(track.id)")
            }
            .width(min: 110, ideal: 300)
            TableColumn("Artist") { track in
                CommitTextField(job.artist, value: track.audio?.artist ?? "") { setArtist(track, $0) }
                    .textFieldStyle(.plain)
                    .disabled(!tagsEditable)
                    .help("Leave empty to use the album artist")
                    .accessibilityLabel("Artist of track \(track.id)")
            }
            .width(min: 80, ideal: 200)
            TableColumn("Time") { track in
                Text(Self.time(track.durationSeconds)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(54)
            TableColumn("") { track in
                StatusIcon(done: track.ripped, label: track.ripped ? "Ripped" : "Pending")
            }
            .width(22)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    static func time(_ seconds: Int) -> String {
        seconds >= 3600 ? DiscTitle.format(seconds: seconds) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func setTitle(_ track: DiscTitle, _ value: String) {
        manager.setIdentification(job.id) { j in
            if let i = j.titles.firstIndex(where: { $0.id == track.id }) { j.titles[i].name = value }
        }
    }

    private func setArtist(_ track: DiscTitle, _ value: String) {
        manager.setIdentification(job.id) { j in
            guard let i = j.titles.firstIndex(where: { $0.id == track.id }) else { return }
            var tags = j.titles[i].audio ?? AudioTrackTags()
            tags.artist = value
            j.titles[i].audio = tags
        }
    }
}

private struct TitleTable: View {
    let job: Job
    @EnvironmentObject var manager: JobManager
    @ViewState private var selection: Set<Int> = []

    private var editable: Bool { job.status == .identifying || job.status == .waiting }

    var body: some View {
        Table(job.titles, selection: $selection) {
            TableColumn("") { title in
                Toggle("", isOn: Binding(get: { title.selected },
                                         set: { manager.toggleTitle(job.id, title: title.id, selected: $0) }))
                    .labelsHidden()
                    .disabled(!editable)
                    .accessibilityLabel("Include title \(title.id)")
            }
            .width(24)
            TableColumn("#") { title in
                Text("\(title.id)").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(30)
            TableColumn("Name") { title in
                HStack(spacing: 6) {
                    Text(title.name.isEmpty ? "Title \(title.id)" : title.name).lineLimit(1)
                    if title.isMainFeature {
                        Text("MAIN")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("Main feature")
                    }
                }
            }
            .width(min: 110, ideal: 260)
            TableColumn("Source") { title in
                Text(title.sourceFile).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 60, ideal: 110)
            TableColumn("Chapters") { title in
                Text(title.chapters > 0 ? "\(title.chapters)" : "–").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(62)
            TableColumn("Size") { title in
                Text(title.sizeBytes > 0 ? title.sizeBytes.formatted(.byteCount(style: .file)) : "–")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(76)
            TableColumn("Duration") { title in
                Text(title.durationText).monospacedDigit()
            }
            .width(70)
            TableColumn("") { title in
                StatusIcon(done: title.transcoded || title.ripped && !job.status.isActive,
                           label: title.transcoded ? "Transcoded" : title.ripped ? "Ripped" : "Pending")
            }
            .width(22)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }
}

private struct StatusIcon: View {
    let done: Bool
    let label: String
    var body: some View {
        Image(systemName: done ? "checkmark.circle.fill" : "circle.dotted")
            .foregroundStyle(done ? .green : .secondary.opacity(0.5))
            .accessibilityLabel(label)
    }
}

private struct DataSummary: View {
    let job: Job

    var body: some View {
        ContentUnavailableView {
            Label(job.status == .success ? "Disc Image Created" : "Data Disc", systemImage: "externaldrive")
        } description: {
            Text(job.outputPath.isEmpty ? "The disc is copied into an ISO image." : job.outputPath)
                .textSelection(.enabled)
        } actions: {
            if job.status == .success, !job.outputPath.isEmpty {
                Button("Show in Finder") { NSWorkspace.shared.selectFile(job.outputPath, inFileViewerRootedAtPath: "") }
            }
        }
    }
}

// MARK: - LCD

/// Status display in the toolbar, modelled on Logic Pro's LCD: what runs, how long it ran and how long it still needs.
struct ActivityLCD: View {
    let selectedJobID: UUID?
    @Binding var selection: SidebarItem?
    @EnvironmentObject var manager: JobManager
    @EnvironmentObject var monitor: DiscMonitor

    private var job: Job? {
        if let id = selectedJobID, let job = manager.job(id), job.status.isActive { return job }
        return manager.activeJobs.first
    }

    var body: some View {
        // Only a running job has a clock to advance; an idle LCD would otherwise wake the app every second.
        TimelineView(.periodic(from: .now, by: job == nil ? 86_400 : 1)) { context in
            HStack(spacing: 14) {
                Circle()
                    .fill(job.map { $0.status.tint } ?? Color.secondary.opacity(0.6))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 0) {
                    Text(job?.displayTitle ?? "MacRipper")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(job?.stage ?? idleText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 170, alignment: .leading)
                Divider().frame(height: 24)
                field(value: job.map { Self.clock(Int(context.date.timeIntervalSince($0.created))) } ?? "--:--:--",
                      caption: "ELAPSED")
                field(value: job?.remainingSeconds.map { Self.clock($0) } ?? "--:--:--", caption: "REMAINING")
                field(value: job.map { "\(Int(($0.progress * 100).rounded()))%" } ?? "––", caption: "PROGRESS", width: 58)
                if manager.activeJobs.count > 1 {
                    Text("+\(manager.activeJobs.count - 1)")
                        .font(.caption2.weight(.bold))
                        .fixedSize()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help("\(manager.activeJobs.count) jobs are running")
                }
            }
            .padding(.horizontal, 14)
            // A fixed size keeps the toolbar from re-laying out every second while the clock ticks.
            .frame(width: Self.width, height: 36, alignment: .leading)
            .overlay(alignment: .bottomLeading) {
                if let job {
                    Capsule()
                        .fill(job.status.tint)
                        .frame(width: (Self.width - 28) * min(max(job.progress, 0), 1), height: 2)
                        .padding(.leading, 14)
                        .padding(.bottom, 2)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let job { selection = .job(job.id) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .help(job == nil ? "Ready" : "Show the running job")
    }

    private var idleText: String {
        monitor.discs.isEmpty ? "Ready – insert a disc" : "\(monitor.discs.count) disc\(monitor.discs.count == 1 ? "" : "s") inserted"
    }

    private var accessibilityText: String {
        guard let job else { return "MacRipper is ready" }
        return "\(job.displayTitle), \(job.stage), \(Int(job.progress * 100)) percent" + (job.remainingText.map { ", \($0)" } ?? "")
    }

    private func field(value: String, caption: String, width: CGFloat = 84) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .monospacedDigit()
            Text(caption)
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
        }
        .frame(width: width)
    }

    static let width: CGFloat = 560

    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

// MARK: - Focused values

struct ShowLogKey: FocusedValueKey { typealias Value = Binding<Bool> }
struct ConfirmAbandonKey: FocusedValueKey { typealias Value = Binding<Bool> }

extension FocusedValues {
    var showLog: Binding<Bool>? {
        get { self[ShowLogKey.self] }
        set { self[ShowLogKey.self] = newValue }
    }
    var confirmAbandon: Binding<Bool>? {
        get { self[ConfirmAbandonKey.self] }
        set { self[ConfirmAbandonKey.self] = newValue }
    }
}

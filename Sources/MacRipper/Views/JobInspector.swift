import SwiftUI
import Combine

enum InspectorTab: String, CaseIterable, Identifiable {
    case info, artwork, file
    var id: String { rawValue }
    var label: String {
        switch self {
        case .info: "Info"
        case .artwork: "Artwork"
        case .file: "File"
        }
    }
    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .artwork: "photo"
        case .file: "doc"
        }
    }
}

/// Right column: everything that can be looked at or edited for the selected job.
struct JobInspector: View {
    let jobID: UUID
    @EnvironmentObject var manager: JobManager
    @AppStorage("inspectorTab") private var tab: InspectorTab = .info
    @ViewState private var showSearch = false

    var body: some View {
        if let job = manager.job(jobID) {
            let tabs = InspectorTab.allCases.filter { $0 != .artwork || job.discType == .audioCD }
            VStack(spacing: 0) {
                Picker("Inspector", selection: $tab) {
                    ForEach(tabs) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                Divider()
                switch tabs.contains(tab) ? tab : .info {
                case .info:
                    switch job.discType {
                    case .audioCD: AudioInfoForm(job: job, showSearch: $showSearch)
                    case .dvd, .bluray: VideoInfoForm(job: job, showSearch: $showSearch)
                    default: DataInfoForm(job: job)
                    }
                case .artwork: ArtworkPanel(job: job)
                case .file: FileInfoForm(job: job)
                }
            }
            .sheet(isPresented: $showSearch) {
                if job.discType == .audioCD { AudioSearchSheet(job: job) } else { VideoSearchSheet(job: job) }
            }
            .focusedSceneValue(\.showMetadataSearch, job.discType == .data ? nil : $showSearch)
        }
    }
}

// MARK: - Video and data

private struct VideoInfoForm: View {
    let job: Job
    @Binding var showSearch: Bool
    @EnvironmentObject var manager: JobManager

    private var editable: Bool { job.status == .identifying || job.status == .waiting }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: jobBinding(manager, job, \.title))
                TextField("Year", text: jobBinding(manager, job, \.year))
                Picker("Type", selection: jobBinding(manager, job, \.videoKind)) {
                    ForEach(VideoKind.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                InspectorHeader(title: "Identification") {
                    if editable { Button("Search…") { showSearch = true }.controlSize(.small) }
                }
            }
            .disabled(!editable)
            if !job.imdbID.isEmpty, let url = URL(string: "https://www.imdb.com/title/\(job.imdbID)/") {
                Section("Links") {
                    LabeledContent("IMDb") { Link(job.imdbID, destination: url) }
                }
            }
            Section("Selection") {
                LabeledContent("Titles", value: "\(job.titles.filter(\.selected).count) of \(job.titles.count)")
                let total = job.titles.filter(\.selected).reduce(0) { $0 + $1.durationSeconds }
                LabeledContent("Total length", value: DiscTitle.format(seconds: total))
            }
        }
        .formStyle(.grouped)
    }
}

private struct DataInfoForm: View {
    let job: Job
    @EnvironmentObject var manager: JobManager

    var body: some View {
        Form {
            Section("Disc Image") {
                TextField("Name", text: jobBinding(manager, job, \.title))
                    .disabled(!(job.status == .identifying || job.status == .waiting))
                LabeledContent("Volume", value: job.discLabel.isEmpty ? "–" : job.discLabel)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - File

private struct FileInfoForm: View {
    let job: Job
    @ViewState private var showLog = false

    var body: some View {
        Form {
            Section("Disc") {
                LabeledContent("Type", value: job.discType.label)
                LabeledContent("Volume label", value: job.discLabel.isEmpty ? "–" : job.discLabel)
                LabeledContent("Drive", value: job.driveName.isEmpty ? "–" : job.driveName)
                LabeledContent("Device", value: job.devicePath)
                if !job.musicBrainzDiscID.isEmpty {
                    LabeledContent("Disc ID") {
                        Text(job.musicBrainzDiscID).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            Section("Job") {
                LabeledContent("Status") { StatusBadge(status: job.status) }
                LabeledContent("Started", value: job.created.formatted(date: .abbreviated, time: .standard))
                if let finished = job.finished {
                    LabeledContent("Finished", value: finished.formatted(date: .abbreviated, time: .standard))
                }
                LabeledContent("Duration", value: Job.formatDuration(job.elapsedSeconds))
                LabeledContent("Job ID") {
                    Text(job.id.uuidString).font(.caption2.monospaced()).textSelection(.enabled)
                }
            }
            Section("Output") {
                if job.outputPath.isEmpty {
                    Text("Not written yet").foregroundStyle(.secondary)
                } else {
                    Text(job.outputPath)
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineLimit(4)
                    Button("Show in Finder") { NSWorkspace.shared.selectFile(job.outputPath, inFileViewerRootedAtPath: "") }
                }
                Button("Show Log…") { showLog = true }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showLog) { LogView(url: job.logURL) }
    }
}

// MARK: - Shared pieces

/// Section header with a trailing control, as in Final Cut's inspector.
struct InspectorHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            trailing
        }
    }
}

/// Binding to a field of a job that survives the job being deleted while the view is still on screen.
@MainActor
func jobBinding<T>(_ manager: JobManager, _ snapshot: Job, _ keyPath: WritableKeyPath<Job, T>) -> Binding<T> {
    Binding(
        get: { manager.job(snapshot.id)?[keyPath: keyPath] ?? snapshot[keyPath: keyPath] },
        set: { value in manager.setIdentification(snapshot.id) { $0[keyPath: keyPath] = value } })
}

struct ShowMetadataSearchKey: FocusedValueKey { typealias Value = Binding<Bool> }

extension FocusedValues {
    var showMetadataSearch: Binding<Bool>? {
        get { self[ShowMetadataSearchKey.self] }
        set { self[ShowMetadataSearchKey.self] = newValue }
    }
}

struct LogView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @ViewState private var text = ""
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(url.lastPathComponent).font(.headline)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "(empty)" : text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: text) { proxy.scrollTo("end") }
            }
        }
        .frame(width: 820, height: 560)
        .onAppear(perform: reload)
        .onReceive(timer) { _ in reload() }
    }

    func reload() {
        let new = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if new != text { text = new }
    }
}

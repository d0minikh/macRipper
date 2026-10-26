import SwiftUI

enum SidebarItem: Hashable {
    case job(UUID), drives, tools
}

/// Main window: library sidebar and inspector float as Liquid Glass panels over the page, as in Apple Music.
struct ContentView: View {
    @EnvironmentObject var manager: JobManager
    @EnvironmentObject var monitor: DiscMonitor
    @EnvironmentObject var tools: ToolManager
    @EnvironmentObject var configStore: ConfigStore
    @ViewState private var selection: SidebarItem? = .drives
    @ViewState private var showLog = false
    @ViewState private var confirmAbandon = false
    @SceneStorage("showInspector") private var showInspector = true
    #if DEBUG
    @Environment(\.openSettings) private var openSettings
    #endif

    static let panelWidth: CGFloat = 330

    private var selectedJobID: UUID? {
        if case .job(let id) = selection, manager.job(id) != nil { return id }
        return nil
    }

    private var selectedJob: Job? { selectedJobID.flatMap(manager.job) }

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            detail
                // AppKit's split view must never see a minimum width larger than the space it can give the middle
                // column; otherwise it keeps re-laying out the window. Content that does not fit is laid out within
                // the available width instead.
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                // The inspector floats over the page; the page keeps its width for content and its background
                // continues underneath the glass.
                .safeAreaInset(edge: .trailing, spacing: 0) {
                    if showInspector {
                        InspectorPanel(jobID: selectedJobID)
                            .frame(width: Self.panelWidth)
                            .padding(.trailing, 10)
                            .padding(.bottom, 10)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .scrollContentBackground(.hidden)
                .background { PageBackdrop(job: selectedJob).backgroundExtensionEffect() }
                .animation(.smooth(duration: 0.3), value: showInspector)
                .toolbar { toolbarContent }
        }
        // No light strip under the toolbar: neither the top scroll edge effect of the columns nor the toolbar
        // background that appears on hover. The toolbar items keep their own glass.
        .scrollEdgeEffectHidden(true, for: .top)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .focusedSceneValue(\.selectedJobID, selectedJobID)
        .focusedSceneValue(\.inspectorVisible, $showInspector)
        .focusedSceneValue(\.sidebarSelection, $selection)
        .focusedSceneValue(\.showLog, selectedJobID == nil ? nil : $showLog)
        .focusedSceneValue(\.confirmAbandon, selectedJob?.status.isActive == true ? $confirmAbandon : nil)
        .onChange(of: selection) { showLog = false; confirmAbandon = false }
        .onChange(of: manager.jobs.map(\.id)) { _, ids in
            // Leave a job's page as soon as the job is deleted.
            if case .job(let id) = selection, !ids.contains(id) { selection = .drives }
        }
        .onChange(of: manager.activeJobs.map(\.id)) { old, new in
            // Jump to a newly inserted disc.
            if let added = new.first(where: { !old.contains($0) }) { selection = .job(added) }
        }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.environment["MACRIPPER_SETTINGS_TAB"] != nil { openSettings() }
            if let panel = ProcessInfo.processInfo.environment["MACRIPPER_INSPECTOR"] { showInspector = panel == "1" }
            switch ProcessInfo.processInfo.environment["MACRIPPER_SELECT"] {
            case "tools": selection = .tools
            case "history":
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if let first = manager.finishedJobs.first { selection = .job(first.id) }
                }
            default: break
            }
        }
        #endif
    }

    /// The only toolbar of the window, so the order is fixed: the page's actions, then reload, and the
    /// inspector button always at the outer edge.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ActivityLCD(selectedJobID: selectedJobID, selection: $selection)
        }
        if let job = selectedJob {
            if job.status.isActive {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { confirmAbandon = true } label: { Label("Abandon", systemImage: "stop.fill") }
                        .help("Abandon this job (⌘.)")
                    if job.status == .waiting {
                        Button { manager.startNow(job.id) } label: { Label("Start Now", systemImage: "play.fill") }
                            .buttonStyle(.glassProminent)
                            .help("Start ripping without waiting (⌘↩)")
                    }
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showLog = true } label: { Label("Show Log", systemImage: "doc.text.magnifyingglass") }
                    .help("Show the job log (⇧⌘L)")
                Button {
                    NSWorkspace.shared.selectFile(job.outputPath, inFileViewerRootedAtPath: "")
                } label: { Label("Show in Finder", systemImage: "folder") }
                    .help("Reveal the output in Finder")
                    .disabled(job.outputPath.isEmpty)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        } else if selection == .tools, tools.updatesAvailable > 0 {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await tools.updateAll() } } label: {
                    Label("Update All (\(tools.updatesAvailable))", systemImage: "arrow.down.circle")
                }
                .help("Update every tool that has a newer version")
                .disabled(tools.busyTool != nil || !manager.activeJobs.isEmpty)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            switch selection {
            case .tools:
                Button { Task { await tools.refresh() } } label: {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                }
                .help("Check the tools for updates")
                .disabled(tools.refreshing || tools.busyTool != nil)
            case .job:
                EmptyView()
            default:
                Button { monitor.refresh() } label: { Label("Refresh Drives", systemImage: "arrow.clockwise") }
                    .help("Look for optical drives again")
            }
            InspectorToggle(isPresented: $showInspector)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .job(let id) where manager.job(id) != nil:
            JobViewer(jobID: id, confirmAbandon: $confirmAbandon, showLog: $showLog).id(id)
        case .tools:
            ToolsView()
        default:
            DrivesView(selection: $selection)
        }
    }
}

struct InspectorToggle: View {
    @Binding var isPresented: Bool
    var body: some View {
        Button { isPresented.toggle() } label: {
            Label(isPresented ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
        }
        .help(isPresented ? "Hide the inspector (⌥⌘I)" : "Show the inspector (⌥⌘I)")
    }
}

// MARK: - Sidebar

private struct LibrarySidebar: View {
    @Binding var selection: SidebarItem?
    @EnvironmentObject var manager: JobManager
    @EnvironmentObject var monitor: DiscMonitor
    @EnvironmentObject var tools: ToolManager
    @ViewState private var confirmClear = false

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("Drives", systemImage: "opticaldiscdrive")
                    .badge(monitor.discs.count)
                    .tag(SidebarItem.drives)
                Label("Tools", systemImage: "wrench.and.screwdriver")
                    .badge(tools.updatesAvailable)
                    .tag(SidebarItem.tools)
            }
            Section("Activity") {
                if manager.activeJobs.isEmpty {
                    Label("Insert a disc to start", systemImage: "opticaldisc")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                ForEach(manager.activeJobs) { job in
                    JobRow(job: job).tag(SidebarItem.job(job.id))
                }
            }
            ForEach(historyGroups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.jobs) { job in
                        JobRow(job: job).tag(SidebarItem.job(job.id))
                            .contextMenu {
                                if !job.outputPath.isEmpty {
                                    Button("Show in Finder") {
                                        NSWorkspace.shared.selectFile(job.outputPath, inFileViewerRootedAtPath: "")
                                    }
                                    Divider()
                                }
                                Button("Remove from History") { manager.delete(job.id) }
                                Button("Clear History…") { confirmClear = true }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .confirmationDialog("Clear the job history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { manager.clearHistory() }
        } message: {
            Text("Finished, failed and abandoned jobs are removed. Ripped files and logs are kept.")
        }
    }

    /// History grouped like Finder's recents: Today, Yesterday, Previous 7 Days, Earlier.
    private var historyGroups: [(title: String, jobs: [Job])] {
        let calendar = Calendar.current
        let now = Date()
        var buckets: [(String, [Job])] = [("Today", []), ("Yesterday", []), ("Previous 7 Days", []), ("Earlier", [])]
        for job in manager.finishedJobs {
            let date = job.finished ?? job.created
            let index = calendar.isDateInToday(date) ? 0
                : calendar.isDateInYesterday(date) ? 1
                : (now.timeIntervalSince(date) < 7 * 86_400 ? 2 : 3)
            buckets[index].1.append(job)
        }
        return buckets.filter { !$0.1.isEmpty }.map { (title: $0.0, jobs: $0.1) }
    }
}

struct JobRow: View {
    let job: Job

    var body: some View {
        HStack(spacing: 10) {
            JobThumbnail(job: job, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayTitle).lineLimit(1)
                if job.status.isActive {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                    Text(job.remainingText.map { "\(job.stage) · \($0)" } ?? job.stage)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    HStack(spacing: 4) {
                        Circle().fill(job.status.tint).frame(width: 6, height: 6)
                        Text("\(job.discType.label) · \(job.status.label)")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(job.displayTitle), \(job.discType.label), \(job.status.label)")
    }
}

/// Artwork if there is some, otherwise a tinted symbol tile – like the clip thumbnails in Final Cut's browser.
struct JobThumbnail: View {
    let job: Job
    let size: CGFloat

    var body: some View {
        Group {
            if let cover = job.audioInfo?.cover, let image = CoverCache.image(for: cover, points: size) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else if let url = URL(string: job.posterURL), !job.posterURL.isEmpty {
                RemoteImage(url: url, points: size, fill: true) { symbol }
            } else {
                symbol
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
        .accessibilityHidden(true)
    }

    private var symbol: some View {
        Image(systemName: job.discType.symbol)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(job.discType.tint.gradient)
    }
}

struct StatusBadge: View {
    let status: JobStatus
    var body: some View {
        Text(status.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(status.tint.opacity(0.18), in: Capsule())
            .foregroundStyle(status.tint)
    }
}

extension JobStatus {
    var tint: Color {
        switch self {
        case .success: .green
        case .failed: .red
        case .abandoned: .gray
        case .waiting: .orange
        default: .accentColor
        }
    }
}

extension DiscType {
    var tint: Color {
        switch self {
        case .bluray: .blue
        case .dvd: .indigo
        case .audioCD: .pink
        case .data: .teal
        case .unknown: .gray
        }
    }
}

// MARK: - Focused values for menu commands

struct SelectedJobKey: FocusedValueKey { typealias Value = UUID }
struct InspectorVisibleKey: FocusedValueKey { typealias Value = Binding<Bool> }
struct SidebarSelectionKey: FocusedValueKey { typealias Value = Binding<SidebarItem?> }

extension FocusedValues {
    var selectedJobID: UUID? {
        get { self[SelectedJobKey.self] }
        set { self[SelectedJobKey.self] = newValue }
    }
    var inspectorVisible: Binding<Bool>? {
        get { self[InspectorVisibleKey.self] }
        set { self[InspectorVisibleKey.self] = newValue }
    }
    var sidebarSelection: Binding<SidebarItem?>? {
        get { self[SidebarSelectionKey.self] }
        set { self[SidebarSelectionKey.self] = newValue }
    }
}

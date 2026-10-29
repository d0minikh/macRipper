import SwiftUI

enum SidebarItem: Hashable {
    case job(UUID), drives, tools, tagEditor, tagAlbum(UUID)

    var isTagEditor: Bool {
        switch self {
        case .tagEditor, .tagAlbum: true
        default: false
        }
    }
}

/// Main window: library sidebar and inspector float as Liquid Glass panels over the page, as in Apple Music.
struct ContentView: View {
    @EnvironmentObject var manager: JobManager
    @EnvironmentObject var monitor: DiscMonitor
    @EnvironmentObject var tools: ToolManager
    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var tagEditor: TagEditor
    @ViewState private var selection: SidebarItem? = .drives
    @ViewState private var showLog = false
    @ViewState private var confirmAbandon = false
    /// Songs selected in the Tag Editor's table; the inspector edits these.
    @ViewState private var tagSelection: Set<UUID> = []
    /// Albums selected in the Tag Editor's cover grid; the inspector edits them together.
    @ViewState private var tagAlbumSelection: Set<UUID> = []
    @ViewState private var tagSheet: TagSheet?
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

    private var selectedAlbum: LibraryAlbum? {
        if case .tagAlbum(let id) = selection { return tagEditor.album(id) }
        return nil
    }

    /// The albums the Tag Editor's inspector and actions work on: the open album, or those selected in the grid.
    private var tagScopeAlbums: [LibraryAlbum] {
        if let selectedAlbum { return [selectedAlbum] }
        guard selection == .tagEditor, !tagAlbumSelection.isEmpty else { return [] }
        return tagEditor.sortedAlbums.map(\.album).filter { tagAlbumSelection.contains($0.id) }
    }

    /// The songs the Tag Editor's actions apply to: the selected songs or the whole album, or every song of the
    /// selected albums.
    private var tagTargets: [UUID]? {
        let albums = tagScopeAlbums
        if albums.count == 1 { return tagEditor.targets(album: albums[0], selection: tagSelection) }
        return albums.isEmpty ? nil : albums.flatMap { tagEditor.tracks(in: $0).map(\.id) }
    }

    /// The songs Save and Revert apply to: the albums in scope, or every song on the Tag Editor page.
    private var tagSaveScope: [UUID]? {
        let albums = tagScopeAlbums
        if !albums.isEmpty { return albums.flatMap(\.trackIDs) }
        return selection == .tagEditor ? Array(tagEditor.tracks.keys) : nil
    }

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
                        InspectorPanel(jobID: selectedJobID, tagAlbumIDs: tagScopeAlbums.map(\.id), tagSelection: tagSelection,
                                       tagSheet: $tagSheet,
                                       placeholder: selection?.isTagEditor == true
                                           ? "Select one or more albums to see and edit their tags."
                                           : "Select a job to see and edit its details.")
                            .frame(width: Self.panelWidth)
                            .padding(.trailing, 10)
                            .padding(.bottom, 10)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .scrollContentBackground(.hidden)
                .background {
                    PageBackdrop(job: selectedJob, cover: selectedAlbum.flatMap { tagEditor.summary($0).cover },
                                 tint: selection?.isTagEditor == true ? DiscType.audioCD.tint : nil)
                        .backgroundExtensionEffect()
                }
                .sheet(item: $tagSheet) { sheet in
                    tagSheetView(sheet).environmentObject(tagEditor)
                }
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
        .focusedSceneValue(\.tagTargets, tagTargets)
        .focusedSceneValue(\.tagSaveScope, tagSaveScope)
        .focusedSceneValue(\.tagSingleAlbum, tagScopeAlbums.count == 1)
        .focusedSceneValue(\.tagSheet, tagScopeAlbums.isEmpty ? nil : $tagSheet)
        .onChange(of: selection) {
            showLog = false
            confirmAbandon = false
            tagSelection = []
            tagAlbumSelection = []
        }
        .onChange(of: tagEditor.albums.map(\.id)) { _, ids in
            // Leave an album's page when its files are removed from the Tag Editor.
            if case .tagAlbum(let id) = selection, !ids.contains(id) { selection = .tagEditor }
            tagAlbumSelection.formIntersection(ids)
        }
        .onChange(of: manager.jobs.map(\.id)) { _, ids in
            // Leave a job's page as soon as the job is deleted.
            if case .job(let id) = selection, !ids.contains(id) { selection = .drives }
        }
        .onChange(of: manager.activeJobs.map(\.id)) { old, new in
            // Jump to a newly inserted disc.
            if let added = new.first(where: { !old.contains($0) }) { selection = .job(added) }
        }
        #if DEBUG
        .onAppear(perform: applyDebugLaunchOptions)
        #endif
    }

    #if DEBUG
    private func applyDebugLaunchOptions() {
        let env = ProcessInfo.processInfo.environment
        if env["MACRIPPER_SETTINGS_TAB"] != nil { openSettings() }
        if let panel = env["MACRIPPER_INSPECTOR"] { showInspector = panel == "1" }
        switch env["MACRIPPER_SELECT"] {
        case "tools": selection = .tools
        case "tags": selection = .tagEditor
        case "tagalbum":
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if let first = tagEditor.sortedAlbums.first { selection = .tagAlbum(first.album.id) }
            }
        case "tagall":
            selection = .tagEditor
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { tagAlbumSelection = Set(tagEditor.albums.map(\.id)) }
        case "history":
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let first = manager.finishedJobs.first { selection = .job(first.id) }
            }
        default: break
        }
    }
    #endif

    /// The only toolbar of the window, so the order is fixed: the page's actions, then reload, and the
    /// inspector button always at the outer edge.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ActivityLCD(selectedJobID: selectedJobID, selection: $selection)
        }
        // Separate ifs instead of one else-if chain, which the type checker cannot handle in reasonable time.
        // At most one of them applies, because each belongs to a different page.
        if let job = selectedJob {
            jobToolbar(job)
        }
        if !tagScopeAlbums.isEmpty, let targets = tagTargets {
            tagAlbumToolbar(tagScopeAlbums, targets: targets)
        }
        if showsSaveAll {
            tagLibraryToolbar
        }
        if showsUpdateAll {
            toolsToolbar
        }
        ToolbarItemGroup(placement: .primaryAction) {
            pageButton
            InspectorToggle(isPresented: $showInspector)
        }
    }

    private var showsSaveAll: Bool { selection == .tagEditor && tagAlbumSelection.isEmpty && tagEditor.modifiedCount > 0 }
    private var showsUpdateAll: Bool { selection == .tools && tools.updatesAvailable > 0 }

    @ToolbarContentBuilder
    private func jobToolbar(_ job: Job) -> some ToolbarContent {
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
    }

    @ToolbarContentBuilder
    private var toolsToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { Task { await tools.updateAll() } } label: {
                Label("Update All (\(tools.updatesAvailable))", systemImage: "arrow.down.circle")
            }
            .help("Update every tool that has a newer version")
            .disabled(tools.busyTool != nil || !manager.activeJobs.isEmpty)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
    }

    /// The page's own button next to the inspector toggle: reload for drives and tools, add for the Tag Editor.
    @ViewBuilder
    private var pageButton: some View {
        switch selection {
        case .tools:
            Button { Task { await tools.refresh() } } label: {
                Label("Check for Updates", systemImage: "arrow.clockwise")
            }
            .help("Check the tools for updates")
            .disabled(tools.refreshing || tools.busyTool != nil)
        case .job:
            EmptyView()
        case .tagEditor, .tagAlbum:
            Button { tagEditor.chooseAndAdd() } label: { Label("Add Music", systemImage: "plus") }
                .help("Add songs or album folders to the Tag Editor (⌘O)")
                .disabled(tagEditor.loading != nil)
        default:
            Button { monitor.refresh() } label: { Label("Refresh Drives", systemImage: "arrow.clockwise") }
                .help("Look for optical drives again")
        }
    }

    @ToolbarContentBuilder
    private func tagAlbumToolbar(_ albums: [LibraryAlbum], targets: [UUID]) -> some ToolbarContent {
        let modified = albums.flatMap(\.trackIDs).filter { tagEditor.tracks[$0]?.isModified == true }
        let saving = albums.contains(where: tagEditor.isSaving)
        ToolbarItemGroup(placement: .primaryAction) {
            Button { tagSheet = .albumLookup(targets) } label: {
                Label("Look Up on MusicBrainz", systemImage: "magnifyingglass")
            }
            .help(albums.count == 1 ? "Find the album on MusicBrainz and take over its tags (⌥⌘F)"
                                    : "Albums are looked up one at a time – select a single album")
            .disabled(albums.count != 1)
            Button { Task { await tagEditor.save(modified) } } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.glassProminent)
            .help("Write the changed tags into the files (⌘S)")
            .disabled(modified.isEmpty || saving)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Button { tagEditor.revert(modified) } label: {
                Label("Revert Changes", systemImage: "arrow.uturn.backward")
            }
            .help(albums.count == 1 ? "Discard the unsaved changes of this album" : "Discard the unsaved changes of the selected albums")
            .disabled(modified.isEmpty || saving)
            Button { tagSheet = .rename(targets) } label: {
                Label("Rename Files", systemImage: "character.cursor.ibeam")
            }
            .help("Rename the files after their tags")
            .disabled(saving)
            Button { NSWorkspace.shared.activateFileViewerSelecting(albums.map(\.folder)) } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .help(albums.count == 1 ? "Show the album's folder in Finder" : "Show the albums' folders in Finder")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
    }

    @ToolbarContentBuilder
    private var tagLibraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { Task { await tagEditor.save(tagEditor.modifiedIDs) } } label: {
                Label("Save All (\(tagEditor.modifiedCount))", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.glassProminent)
            .help("Write all changed tags into the files")
            .disabled(!tagEditor.saving.isEmpty)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .job(let id) where manager.job(id) != nil:
            JobViewer(jobID: id, confirmAbandon: $confirmAbandon, showLog: $showLog).id(id)
        case .tools:
            ToolsView()
        case .tagEditor:
            TagLibraryView(selection: $selection, albumSelection: $tagAlbumSelection)
        case .tagAlbum(let id) where tagEditor.album(id) != nil:
            TagAlbumView(albumID: id, selection: $tagSelection, sheet: $tagSheet).id(id)
        case .tagAlbum:
            TagLibraryView(selection: $selection, albumSelection: $tagAlbumSelection)
        default:
            DrivesView(selection: $selection)
        }
    }

    @ViewBuilder
    private func tagSheetView(_ sheet: TagSheet) -> some View {
        switch sheet {
        case .albumLookup(let ids): ReleaseLookupSheet(ids: ids)
        case .songLookup(let id): SongLookupSheet(id: id)
        case .rename(let ids): RenameSheet(ids: ids)
        case .covers(let ids):
            CoverPickerSheet(load: { await tagEditor.coverCandidates(for: ids) },
                             use: { try await tagEditor.useCover($0, for: ids) })
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
    @EnvironmentObject var tagEditor: TagEditor
    @ViewState private var confirmClear = false

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("Drives", systemImage: "opticaldiscdrive")
                    .badge(monitor.discs.count)
                    .tag(SidebarItem.drives)
                Label("Tag Editor", systemImage: "tag")
                    .badge(tagEditor.modifiedCount)
                    .tag(SidebarItem.tagEditor)
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
            if !tagEditor.albums.isEmpty {
                Section("Tag Editor") {
                    ForEach(tagEditor.sortedAlbums, id: \.album.id) { entry in
                        TagAlbumRow(summary: entry.summary)
                            .tag(SidebarItem.tagAlbum(entry.album.id))
                            .contextMenu { TagAlbumMenu(albums: [entry.album]) }
                    }
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
        // Songs and folders dropped onto the sidebar go to the Tag Editor, which opens if it is not shown.
        .musicDropTarget { if selection?.isTagEditor != true { selection = .tagEditor } }
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
struct TagTargetsKey: FocusedValueKey { typealias Value = [UUID] }
struct TagSaveScopeKey: FocusedValueKey { typealias Value = [UUID] }
struct TagSingleAlbumKey: FocusedValueKey { typealias Value = Bool }
struct TagSheetKey: FocusedValueKey { typealias Value = Binding<TagSheet?> }

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
    var tagTargets: [UUID]? {
        get { self[TagTargetsKey.self] }
        set { self[TagTargetsKey.self] = newValue }
    }
    var tagSaveScope: [UUID]? {
        get { self[TagSaveScopeKey.self] }
        set { self[TagSaveScopeKey.self] = newValue }
    }
    var tagSingleAlbum: Bool? {
        get { self[TagSingleAlbumKey.self] }
        set { self[TagSingleAlbumKey.self] = newValue }
    }
    var tagSheet: Binding<TagSheet?>? {
        get { self[TagSheetKey.self] }
        set { self[TagSheetKey.self] = newValue }
    }
}

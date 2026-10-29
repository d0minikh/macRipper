import SwiftUI
import UniformTypeIdentifiers

/// Sheets of the Tag Editor. Owned by the window, so the toolbar, the menus, the table and the inspector can all
/// open them.
enum TagSheet: Identifiable {
    case albumLookup([UUID]), songLookup(UUID), rename([UUID]), covers([UUID])

    var id: String {
        switch self {
        case .albumLookup(let ids): "album-\(ids.hashValue)"
        case .songLookup(let id): "song-\(id)"
        case .rename(let ids): "rename-\(ids.hashValue)"
        case .covers(let ids): "covers-\(ids.hashValue)"
        }
    }
}

extension TagEditor {
    /// Asks for files and folders to add.
    func chooseAndAdd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        // Folders must be listed as well; with only audio types, the panel lets you open folders but not choose them.
        panel.allowedContentTypes = [.folder, UTType(filenameExtension: "flac") ?? .audio, .mpeg4Audio, .mp3]
        panel.prompt = "Add"
        panel.message = "Choose songs or album folders (FLAC, Apple Lossless, AAC, MP3). Folders are searched completely."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await add(urls) }
    }

    /// The files an action applies to: the selected songs of the album, or all of its songs.
    func targets(album: LibraryAlbum, selection: Set<UUID>) -> [UUID] {
        let selected = album.trackIDs.filter(selection.contains)
        return tracks(selected.isEmpty ? album.trackIDs : selected).map(\.id)
    }
}

// MARK: - Drag and drop

/// Lets songs and folders be dropped onto a view to add them to the Tag Editor. While files are dragged over it, the
/// view gets the accent colored ring Finder and Music draw around a drop destination.
struct MusicDropTarget: ViewModifier {
    var showsRing = true
    var isTargeted: Binding<Bool>?
    var onDrop: () -> Void = {}
    @EnvironmentObject var editor: TagEditor
    @ViewState private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if showsRing, targeted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .background(Color.accentColor.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(4)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: targeted)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                Task { @MainActor in
                    var urls: [URL] = []
                    for provider in providers {
                        if let url = await Self.fileURL(from: provider) { urls.append(url) }
                    }
                    guard !urls.isEmpty else { return }
                    onDrop()
                    await editor.add(urls)
                }
                return true
            }
            .onChange(of: targeted) { _, value in isTargeted?.wrappedValue = value }
            #if DEBUG
            .onAppear { if ProcessInfo.processInfo.environment["MACRIPPER_DROP_PREVIEW"] == "1" { targeted = true } }
            #endif
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}

extension View {
    func musicDropTarget(showsRing: Bool = true, isTargeted: Binding<Bool>? = nil,
                         onDrop: @escaping () -> Void = {}) -> some View {
        modifier(MusicDropTarget(showsRing: showsRing, isTargeted: isTargeted, onDrop: onDrop))
    }
}

/// The empty Tag Editor: a dashed drop well like the ones in Apple's own apps, which lights up while files are
/// dragged over the page.
private struct TagDropWell: View {
    let isTargeted: Bool
    @EnvironmentObject var editor: TagEditor

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                .symbolEffect(.bounce, value: isTargeted)
            VStack(spacing: 6) {
                Text(isTargeted ? "Release to Add" : "Drop Music Here")
                    .font(.title2.weight(.semibold))
                Text("Songs or whole album folders – FLAC, Apple Lossless, AAC and MP3. Edit their tags and covers, look them up on MusicBrainz and save the changes into the files.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Choose Music…") { editor.chooseAndAdd() }
                .buttonStyle(.glassProminent)
                .padding(.top, 4)
            if let notice = editor.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(36)
        .frame(maxWidth: 460)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.03))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
                              style: StrokeStyle(lineWidth: isTargeted ? 3 : 2, dash: isTargeted ? [] : [8, 6]))
        }
        .scaleEffect(isTargeted ? 1.02 : 1)
        .animation(.spring(duration: 0.25), value: isTargeted)
        .padding(24)
    }
}

// MARK: - Overview

/// The Tag Editor page: every loaded album as a cover grid, or an invitation to add music. Albums can be selected
/// like files in Finder (click, ⌘-click, ⇧-click) and then edited together in the inspector; a double-click opens one.
struct TagLibraryView: View {
    @Binding var selection: SidebarItem?
    @Binding var albumSelection: Set<UUID>
    @EnvironmentObject var editor: TagEditor
    @ViewState private var dropTargeted = false

    private var isEmpty: Bool { editor.albums.isEmpty && editor.loading == nil }

    var body: some View {
        Group {
            if isEmpty {
                TagDropWell(isTargeted: dropTargeted)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Double-click an album to edit its songs. Select several albums (⌘-click, ⇧-click) to edit them together in the inspector. Drop more songs or folders here to add them. Nothing is written into the files until you save.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        status
                        let entries = editor.sortedAlbums
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20, alignment: .top)],
                                  alignment: .leading, spacing: 24) {
                            ForEach(entries, id: \.album.id) { entry in
                                AlbumCard(album: entry.album, summary: entry.summary,
                                          isSelected: albumSelection.contains(entry.album.id),
                                          menuAlbums: menuAlbums(for: entry.album, in: entries.map(\.album))) {
                                    click(entry.album.id, order: entries.map(\.album.id))
                                } open: {
                                    selection = .tagAlbum(entry.album.id)
                                }
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A click on the empty page clears the selection, as in Finder.
                .background { Color.clear.contentShape(Rectangle()).onTapGesture { albumSelection = [] } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .navigationTitle("Tag Editor")
        // The empty page shows the drop well instead of the ring.
        .musicDropTarget(showsRing: !isEmpty, isTargeted: $dropTargeted)
    }

    /// Click: select only this album. ⌘-click: add or remove it. ⇧-click: select the range from the last selected one.
    private func click(_ id: UUID, order: [UUID]) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            if albumSelection.contains(id) { albumSelection.remove(id) } else { albumSelection.insert(id) }
        } else if modifiers.contains(.shift), let anchor = order.lastIndex(where: albumSelection.contains),
                  let index = order.firstIndex(of: id) {
            albumSelection.formUnion(order[min(anchor, index)...max(anchor, index)])
        } else {
            albumSelection = [id]
        }
    }

    /// A context menu acts on the whole selection when the clicked album is part of it, as in Finder.
    private func menuAlbums(for album: LibraryAlbum, in all: [LibraryAlbum]) -> [LibraryAlbum] {
        albumSelection.contains(album.id) ? all.filter { albumSelection.contains($0.id) } : [album]
    }

    @ViewBuilder
    private var status: some View {
        if let loading = editor.loading {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(loading.done), total: Double(max(loading.total, 1)))
                    .frame(maxWidth: 360)
                Text("Reading \(loading.done) of \(loading.total) files…").font(.callout).foregroundStyle(.secondary)
            }
        }
        if let notice = editor.notice {
            Label(notice, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
        let songs = editor.tracks.count, changed = editor.modifiedCount
        HStack(spacing: 8) {
            Text("\(editor.albums.count) album\(editor.albums.count == 1 ? "" : "s") · \(songs) song\(songs == 1 ? "" : "s")")
            if changed > 0 { UnsavedBadge(count: changed) }
            Spacer()
            if !albumSelection.isEmpty {
                Text("\(albumSelection.count) selected").foregroundStyle(.secondary)
                Button("Deselect") { albumSelection = [] }
            }
            Button("Select All") { albumSelection = Set(editor.albums.map(\.id)) }
                .disabled(albumSelection.count == editor.albums.count)
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

private struct AlbumCard: View {
    let album: LibraryAlbum
    let summary: LibraryAlbumSummary
    let isSelected: Bool
    let menuAlbums: [LibraryAlbum]
    let click: () -> Void
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            CoverImageView(cover: summary.cover, size: 150)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if summary.modifiedCount > 0 {
                        Circle().fill(.orange).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1.5))
                            .padding(6)
                            .help("\(summary.modifiedCount) unsaved change\(summary.modifiedCount == 1 ? "" : "s")")
                    }
                }
                .padding(.bottom, 4)
            Text(summary.title).font(.headline).lineLimit(1)
            Text(summary.artist).foregroundStyle(.secondary).lineLimit(1)
            Text([summary.year, "\(summary.trackCount) song\(summary.trackCount == 1 ? "" : "s")", summary.formats]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 150, alignment: .leading)
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .onTapGesture(perform: click)
        .contextMenu {
            if menuAlbums.count == 1 { Button("Open") { open() }; Divider() }
            TagAlbumMenu(albums: menuAlbums)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.title) by \(summary.artist), \(summary.trackCount) songs")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Open", open)
    }
}

/// Context menu of albums in the sidebar and the cover grid.
struct TagAlbumMenu: View {
    let albums: [LibraryAlbum]
    @EnvironmentObject var editor: TagEditor

    var body: some View {
        let ids = albums.flatMap(\.trackIDs)
        let modified = ids.filter { editor.tracks[$0]?.isModified == true }
        let saving = albums.contains(where: editor.isSaving)
        Button(albums.count == 1 ? "Save Changes" : "Save Changes of \(albums.count) Albums") {
            Task { await editor.save(modified) }
        }
        .disabled(modified.isEmpty || saving)
        Button("Revert Changes") { editor.revert(modified) }
            .disabled(modified.isEmpty || saving)
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(albums.map(\.folder)) }
        Button(albums.count == 1 ? "Remove from Tag Editor" : "Remove \(albums.count) Albums from Tag Editor") {
            editor.remove(ids)
        }
        .disabled(saving)
    }
}

struct UnsavedBadge: View {
    let count: Int
    var body: some View {
        Text("\(count) unsaved change\(count == 1 ? "" : "s")")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(.orange)
    }
}

// MARK: - Sidebar

struct TagAlbumRow: View {
    let summary: LibraryAlbumSummary

    var body: some View {
        HStack(spacing: 10) {
            TagCoverThumbnail(cover: summary.cover, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title).lineLimit(1)
                HStack(spacing: 4) {
                    if summary.errorCount > 0 {
                        Circle().fill(.red).frame(width: 6, height: 6)
                    } else if summary.modifiedCount > 0 {
                        Circle().fill(.orange).frame(width: 6, height: 6)
                    }
                    Text("\(summary.artist) · \(summary.trackCount) song\(summary.trackCount == 1 ? "" : "s")")
                }
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.title), \(summary.artist)" + (summary.modifiedCount > 0 ? ", unsaved changes" : ""))
    }
}

/// Cover if there is one, otherwise a tinted note tile – like the thumbnails of jobs.
struct TagCoverThumbnail: View {
    let cover: CoverImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let cover, let image = CoverCache.image(for: cover, points: size) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.45, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(DiscType.audioCD.tint.gradient)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
        .accessibilityHidden(true)
    }
}

// MARK: - Album page

/// The middle column for an album: cover and summary on top, its songs as an editable table below.
struct TagAlbumView: View {
    let albumID: UUID
    @Binding var selection: Set<UUID>
    @Binding var sheet: TagSheet?
    @EnvironmentObject var editor: TagEditor

    var body: some View {
        if let album = editor.album(albumID) {
            let summary = editor.summary(album)
            let list = editor.tracks(in: album)
            VStack(spacing: 0) {
                TagAlbumHeader(album: album, summary: summary, sheet: $sheet)
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 14)
                if let failed = list.first(where: { $0.error != nil }), let error = failed.error {
                    let count = list.count { $0.error != nil }
                    Banner(symbol: "exclamationmark.triangle.fill", tint: .red,
                           title: count == 1 ? "\(failed.fileName) could not be saved" : "\(count) files could not be saved",
                           message: error)
                        .padding(.horizontal, 24).padding(.bottom, 12)
                }
                if let notice = editor.notice {
                    HStack(alignment: .top) {
                        Banner(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "Adding music", message: notice)
                        Button { editor.notice = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Dismiss")
                    }
                    .padding(.horizontal, 24).padding(.bottom, 12)
                }
                Divider()
                TagTrackTable(album: album, tracks: list, selection: $selection, sheet: $sheet)
            }
            .navigationTitle(summary.title)
            .navigationSubtitle(summary.artist)
            .musicDropTarget()
        }
    }
}

private struct TagAlbumHeader: View {
    let album: LibraryAlbum
    let summary: LibraryAlbumSummary
    @Binding var sheet: TagSheet?
    @EnvironmentObject var editor: TagEditor
    @ViewState private var dropTargeted = false

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            CoverImageView(cover: summary.cover, size: 112)
                .overlay {
                    if dropTargeted { RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 3) }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true })
                    else { return false }
                    try? editor.useCoverFile(url, for: album.trackIDs)
                    return true
                } isTargeted: { dropTargeted = $0 }
                .help("Drop an image here to use it as the album's cover")
            VStack(alignment: .leading, spacing: 6) {
                Text(kindLine)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Text(summary.hasAlbumTag ? summary.title : "No Album")
                    .font(.system(.title, weight: .bold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                if !subtitle.isEmpty {
                    Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    if editor.isSaving(album) {
                        ProgressView().controlSize(.small)
                        Text("Saving…").font(.callout).foregroundStyle(.secondary)
                    } else if summary.modifiedCount > 0 {
                        UnsavedBadge(count: summary.modifiedCount)
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([album.folder])
                    } label: {
                        Label(album.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("Show the folder in Finder")
                }
                .padding(.top, 2)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
    }

    private var kindLine: String {
        var parts = [summary.hasAlbumTag ? "Album" : "Songs", "\(summary.trackCount) song\(summary.trackCount == 1 ? "" : "s")"]
        if !summary.formats.isEmpty { parts.append(summary.formats) }
        return parts.joined(separator: " · ")
    }

    private var subtitle: String {
        let minutes = Int(summary.duration / 60)
        let length = summary.duration > 0 ? (minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min") : ""
        return [summary.hasAlbumTag ? summary.artist : album.folder.lastPathComponent, summary.year, summary.genre, length]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct TagTrackTable: View {
    let album: LibraryAlbum
    let tracks: [LibraryTrack]
    @Binding var selection: Set<UUID>
    @Binding var sheet: TagSheet?
    @EnvironmentObject var editor: TagEditor

    private var multiDisc: Bool { tracks.contains { $0.tags.discTotal > 1 || $0.tags.disc > 1 } }

    var body: some View {
        Table(tracks, selection: $selection) {
            TableColumn("") { track in
                TrackStateIcon(track: track, saving: editor.saving.contains(track.id))
            }
            .width(18)
            TableColumn("#") { track in
                Text(position(track)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(multiDisc ? 40 : 28)
            TableColumn("Title") { track in
                CommitTextField(track.displayTitle, value: track.tags.title) { value in
                    editor.edit([track.id]) { $0.title = value }
                }
                .textFieldStyle(.plain)
                .disabled(editor.saving.contains(track.id))
                .accessibilityLabel("Title of \(track.fileName)")
            }
            .width(min: 110, ideal: 260)
            TableColumn("Artist") { track in
                CommitTextField(track.tags.albumArtist, value: track.tags.artist) { value in
                    editor.edit([track.id]) { $0.artist = value }
                }
                .textFieldStyle(.plain)
                .disabled(editor.saving.contains(track.id))
                .accessibilityLabel("Artist of \(track.fileName)")
            }
            .width(min: 80, ideal: 170)
            TableColumn("Time") { track in
                Text(Self.time(track.info.duration)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(46)
            TableColumn("File") { track in
                Text(track.fileName).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(track.url.path)
            }
            .width(min: 60, ideal: 150)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: UUID.self) { ids in
            menu(for: tracks.map(\.id).filter(ids.contains))
        }
    }

    @ViewBuilder
    private func menu(for ids: [UUID]) -> some View {
        if !ids.isEmpty {
            let modified = ids.filter { editor.tracks[$0]?.isModified == true }
            if ids.count == 1, let id = ids.first {
                Button("Look Up Song on MusicBrainz…") { sheet = .songLookup(id) }
            }
            Button("Look Up Album on MusicBrainz…") { sheet = .albumLookup(ids) }
            Button("Find Covers…") { sheet = .covers(ids) }
            Divider()
            Button("Number Tracks in This Order") { editor.numberTracks(ids) }
            Button("Capitalize Titles") { editor.capitalizeTitles(ids) }
            Button("Tags from File Names") { editor.tagsFromFileNames(ids) }
            Button("Rename Files…") { sheet = .rename(ids) }
            Divider()
            Button("Save Changes") { Task { await editor.save(modified) } }
                .disabled(modified.isEmpty)
            Button("Revert Changes") { editor.revert(modified) }
                .disabled(modified.isEmpty)
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(ids.compactMap { editor.tracks[$0]?.url })
            }
            Button("Remove from Tag Editor") { editor.remove(ids) }
        }
    }

    private func position(_ track: LibraryTrack) -> String {
        guard track.tags.track > 0 else { return "–" }
        let number = String(format: "%02d", track.tags.track)
        return multiDisc ? "\(max(track.tags.disc, 1))-\(number)" : number
    }

    static func time(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? DiscTitle.format(seconds: s) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct TrackStateIcon: View {
    let track: LibraryTrack
    let saving: Bool

    var body: some View {
        Group {
            if saving {
                ProgressView().controlSize(.mini)
            } else if track.error != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .help(track.error ?? "")
            } else if track.isModified {
                Circle().fill(.orange).frame(width: 7, height: 7).help("Unsaved changes")
            } else {
                Color.clear
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityLabel(saving ? "Saving" : track.error != nil ? "Error" : track.isModified ? "Unsaved changes" : "Saved")
    }
}

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: ConfigStore
    @ViewState private var tab = Self.initialTab

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            VideoSettings().tabItem { Label("Video", systemImage: "film") }.tag("video")
            AudioSettings().tabItem { Label("Audio & Data", systemImage: "music.note") }.tag("audio")
            MetadataSettings().tabItem { Label("Metadata", systemImage: "magnifyingglass") }.tag("metadata")
            NotificationSettings().tabItem { Label("Notifications", systemImage: "bell") }.tag("notifications")
            AdvancedSettings().tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }.tag("advanced")
        }
        .frame(width: 640, height: 600)
    }

    private static var initialTab: String {
        #if DEBUG
        ProcessInfo.processInfo.environment["MACRIPPER_SETTINGS_TAB"] ?? "general"
        #else
        "general"
        #endif
    }
}

private struct PathField: View {
    let title: String
    @Binding var path: String
    var directory = true

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField("", text: $path).labelsHidden()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = directory
                    panel.canChooseFiles = !directory
                    panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let url = panel.url {
                        path = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                    }
                }
            }
        }
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var store: ConfigStore
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Look", selection: $store.config.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
            }
            Section {
                Toggle("Show icon in the Dock", isOn: $store.config.showDockIcon)
                    .disabled(store.config.showDockIcon && !store.config.showMenuBarIcon)
                Toggle("Show icon in the menu bar", isOn: $store.config.showMenuBarIcon)
                    .disabled(store.config.showMenuBarIcon && !store.config.showDockIcon)
            } header: {
                Text("App Icon")
            } footer: {
                Text("One of the two always stays visible so MacRipper remains reachable.")
                    .foregroundStyle(.secondary)
            }
            Section("Workflow") {
                Toggle("Rip automatically when a disc is inserted", isOn: $store.config.autoRip)
                Toggle("Wait for corrections before ripping", isOn: $store.config.manualWaitEnabled)
                Stepper("Wait time: \(store.config.manualWaitSeconds) s", value: $store.config.manualWaitSeconds,
                        in: 5...1800, step: 5)
                    .disabled(!store.config.manualWaitEnabled)
                Toggle("Eject disc after ripping", isOn: $store.config.autoEject)
                Toggle("Eject disc on failure", isOn: $store.config.ejectOnFailure)
            }
            Section("Folders") {
                PathField(title: "Raw files", path: $store.config.rawPath)
                PathField(title: "Transcode", path: $store.config.transcodePath)
                PathField(title: "Finished videos", path: $store.config.completedPath)
                PathField(title: "Music", path: $store.config.musicPath)
                PathField(title: "ISO images", path: $store.config.dataPath)
            }
        }
        .formStyle(.grouped)
    }
}

private struct VideoSettings: View {
    @EnvironmentObject var store: ConfigStore
    var body: some View {
        Form {
            Section("Ripping (MakeMKV)") {
                Picker("Method", selection: $store.config.ripMethod) {
                    ForEach(VideoRipMethod.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Rip main feature only", isOn: $store.config.mainFeatureOnly)
                Stepper("Minimum length: \(DiscTitle.format(seconds: store.config.minLengthSeconds))",
                        value: $store.config.minLengthSeconds, in: 0...7200, step: 60)
                Stepper("Maximum length: \(DiscTitle.format(seconds: store.config.maxLengthSeconds))",
                        value: $store.config.maxLengthSeconds, in: 60...99_999, step: 600)
                Toggle("Fake title protection (≥ 99 titles → main feature only)", isOn: $store.config.preventFakeTitles)
                TextField("Additional makemkvcon arguments", text: $store.config.makemkvArgs)
            }
            Section("Transcoding") {
                Toggle("Skip transcoding (keep MKV as is)", isOn: $store.config.skipTranscode)
                Picker("Transcoder", selection: $store.config.transcoder) {
                    ForEach(Transcoder.allCases) { Text($0.label).tag($0) }
                }
                if store.config.transcoder == .handbrake {
                    TextField("DVD preset", text: $store.config.handbrakePresetDVD)
                    TextField("Blu-ray preset", text: $store.config.handbrakePresetBD)
                    TextField("Additional HandBrake arguments", text: $store.config.handbrakeExtraArgs)
                } else {
                    TextField("FFmpeg arguments", text: $store.config.ffmpegArgs)
                }
                TextField("File extension", text: $store.config.destinationExtension)
                Stepper("Concurrent transcodes: \(store.config.maxConcurrentTranscodes)",
                        value: $store.config.maxConcurrentTranscodes, in: 1...8)
            }
            Section("Output") {
                Toggle("Delete raw files when done", isOn: $store.config.deleteRawFiles)
                TextField("Extras subfolder", text: $store.config.extrasSubfolder)
                Toggle("Download posters", isOn: $store.config.ripPosters)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AudioSettings: View {
    @EnvironmentObject var store: ConfigStore
    var body: some View {
        Form {
            Section("Audio CD") {
                Picker("Format", selection: $store.config.audioFormat) {
                    ForEach(AudioFormat.allCases) { Text($0.label).tag($0) }
                }
                if store.config.audioFormat == .aac {
                    Picker("Bitrate", selection: $store.config.aacBitrate) {
                        ForEach([128_000, 192_000, 256_000, 320_000], id: \.self) { Text("\($0 / 1000) kbit/s").tag($0) }
                    }
                }
            }
            Section {
                Toggle("Look up metadata on MusicBrainz", isOn: $store.config.musicBrainzLookup)
                Toggle("Wait for me when a CD is not found", isOn: $store.config.audioWaitWhenUnknown)
            } header: {
                Text("Metadata")
            } footer: {
                Text("Unknown CDs are not ripped until you entered or searched the album and clicked Start Now.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Also search Apple Music (up to 3000 × 3000 px)", isOn: $store.config.audioCoverFromAppleMusic)
                Picker("Embed in files", selection: $store.config.audioEmbedCoverMaxPixels) {
                    Text("Original (max. 3000 px)").tag(3000)
                    Text("Up to 1600 px").tag(1600)
                    Text("Up to 1000 px").tag(1000)
                    Text("Up to 600 px").tag(600)
                    Text("Don’t embed").tag(0)
                }
                Picker("Save next to the music as", selection: $store.config.audioCoverFileName) {
                    Text("cover.jpg / .png").tag("cover")
                    Text("folder.jpg / .png").tag("folder")
                    Text("front.jpg / .png").tag("front")
                }
            } header: {
                Text("Cover Art")
            } footer: {
                Text("The cover file next to the music is always the original in full resolution. Larger covers are scaled down only for embedding, which keeps every track small and compatible with car stereos and older players.")
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Folder pattern", text: $store.config.audioFolderPattern)
                TextField("File pattern", text: $store.config.audioFilePattern)
            } header: {
                Text("File Names")
            } footer: {
                Text("Placeholders: {artist} (album artist) {trackartist} {album} {year} {genre} {disc} {track} {title}. Albums with several discs get a “{disc}-” prefix automatically unless the pattern uses {disc}.")
                    .foregroundStyle(.secondary)
            }
            Section("Data Disc") {
                Picker("Image", selection: $store.config.dataImageFormat) {
                    ForEach(DataImageFormat.allCases) { Text($0.label).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct MetadataSettings: View {
    @EnvironmentObject var store: ConfigStore
    var body: some View {
        Form {
            Section("Video") {
                Toggle("Identify titles automatically", isOn: $store.config.getVideoTitle)
                Picker("Provider", selection: $store.config.metadataProvider) {
                    ForEach(MetadataProvider.allCases) { Text($0.label).tag($0) }
                }
                SecureField("OMDb API key", text: $store.config.omdbAPIKey)
                SecureField("TMDb API key / token", text: $store.config.tmdbAPIKey)
                Link("Get an OMDb key", destination: URL(string: "https://www.omdbapi.com/apikey.aspx")!)
                Link("Get a TMDb key", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
            }
        }
        .formStyle(.grouped)
    }
}

private struct NotificationSettings: View {
    @EnvironmentObject var store: ConfigStore
    @ViewState private var testing = false
    @ViewState private var showVariables = false

    var body: some View {
        Form {
            Section("Notify Me When") {
                ForEach(NotificationEvent.allCases) { event in
                    Toggle(event.label, isOn: $store.config[dynamicMember: event.isEnabledKeyPath])
                }
            }

            Section {
                ForEach(NotificationEvent.allCases) { event in
                    TemplateEditor(event: event)
                }
                Button("Restore Default Messages") {
                    let defaults = AppConfig()
                    for event in NotificationEvent.allCases {
                        store.config[keyPath: event.titleKeyPath] = defaults[keyPath: event.titleKeyPath]
                        store.config[keyPath: event.bodyKeyPath] = defaults[keyPath: event.bodyKeyPath]
                    }
                }
            } header: {
                HStack {
                    Text("Messages")
                    Button { showVariables = true } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless)
                        .help("Show the variables you can use in messages")
                        .accessibilityLabel("Available variables")
                        .popover(isPresented: $showVariables, arrowEdge: .bottom) { VariableHelp() }
                }
            } footer: {
                Text("Write {variable} to insert job details, e.g. {title} or {duration}. The messages are used by every service below.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("macOS notifications", isOn: $store.config.notifyLocal)
            }

            ServiceSection(title: "Pushover", isOn: $store.config.pushoverEnabled) {
                SecureField("User key", text: $store.config.pushoverUserKey)
                SecureField("App token", text: $store.config.pushoverAppToken)
                Picker("Priority", selection: $store.config.pushoverPriority) {
                    Text("Lowest").tag(-2)
                    Text("Low").tag(-1)
                    Text("Normal").tag(0)
                    Text("High").tag(1)
                }
                TextField("Sound", text: $store.config.pushoverSound, prompt: Text("Default"))
                TextField("Device", text: $store.config.pushoverDevice, prompt: Text("All devices"))
            }
            ServiceSection(title: "Pushbullet", isOn: $store.config.pushbulletEnabled) {
                SecureField("Access token", text: $store.config.pushbulletKey)
            }
            ServiceSection(title: "IFTTT", isOn: $store.config.iftttEnabled) {
                SecureField("Webhook key", text: $store.config.iftttKey)
                TextField("Event name", text: $store.config.iftttEvent)
            }
            ServiceSection(title: "ntfy", isOn: $store.config.ntfyEnabled) {
                TextField("Topic URL", text: $store.config.ntfyURL, prompt: Text("https://ntfy.sh/my-topic"))
            }
            ServiceSection(title: "JSON Webhook", isOn: $store.config.webhookEnabled) {
                TextField("URL", text: $store.config.webhookURL)
            }
            ServiceSection(title: "Apprise", isOn: $store.config.appriseEnabled) {
                VStack(alignment: .leading) {
                    Text("Apprise URLs (one per line, requires `apprise`)")
                    TextEditor(text: $store.config.appriseURLs).font(.body.monospaced()).frame(height: 60)
                }
            }

            Section {
                Button(testing ? "Sending…" : "Send Test Notification") {
                    testing = true
                    Task {
                        await Notifier.send(.finished, job: NotificationTemplate.sampleJob, config: store.config, force: true)
                        testing = false
                    }
                }
                .disabled(testing)
            } footer: {
                Text("Sends the “Job finished” message with an example movie to every enabled service.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Section whose header switch turns a notification service on or off.
private struct ServiceSection<Content: View>: View {
    let title: String
    @Binding var isOn: Bool
    @ViewBuilder var content: Content

    var body: some View {
        Section {
            content.disabled(!isOn)
        } header: {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

private struct TemplateEditor: View {
    let event: NotificationEvent
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(event.label).font(.headline)
            TextField("Title", text: $store.config[dynamicMember: event.titleKeyPath])
            TextField("Message", text: $store.config[dynamicMember: event.bodyKeyPath], axis: .vertical)
                .lineLimit(1...4)
            let preview = NotificationTemplate.render(event, job: previewJob, config: store.config)
            Text("Preview: \(preview.title) — \(preview.body)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    private var previewJob: Job {
        var job = NotificationTemplate.sampleJob
        switch event {
        case .ripStarted:
            job.status = .ripping
            job.finished = nil
            job.created = Date().addingTimeInterval(-75)
        case .finished: break
        case .failed:
            job.status = .failed
            job.errorMessage = "makemkvcon exited with code 1"
        }
        return job
    }
}

/// Reference of all template variables, shown from the info button.
private struct VariableHelp: View {
    var body: some View {
        let example = NotificationTemplate.values(for: NotificationTemplate.sampleJob)
        VStack(alignment: .leading, spacing: 10) {
            Text("Message Variables").font(.headline)
            Text("Put a variable in braces, e.g. {title} finished in {duration}. Unknown variables are left as typed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        Text("Variable").bold()
                        Text("Meaning").bold()
                        Text("Example").bold()
                    }
                    Divider()
                    ForEach(NotificationTemplate.variables) { variable in
                        GridRow {
                            Text("{\(variable.name)}").font(.body.monospaced()).textSelection(.enabled)
                            Text(variable.description).fixedSize(horizontal: false, vertical: true)
                            Text(example[variable.name].flatMap { $0.isEmpty ? nil : $0 } ?? "–")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 180, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: 620, height: 460)
    }
}

private struct AdvancedSettings: View {
    @EnvironmentObject var store: ConfigStore
    @ViewState private var confirmReset = false
    var body: some View {
        Form {
            Section {
                Toggle("Enable web interface", isOn: $store.config.webServerEnabled)
                Toggle("Allow access from other devices", isOn: $store.config.webServerAllowRemote)
                    .disabled(!store.config.webServerEnabled)
                TextField("Port", value: $store.config.webServerPort, format: .number.grouping(.never))
                if store.config.webServerEnabled, let url = store.config.webInterfaceURL {
                    LabeledContent("Address") {
                        HStack {
                            Button("Copy Link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            }
                            Button("Open") { NSWorkspace.shared.open(url) }
                        }
                    }
                    LabeledContent("Access token") {
                        Button("Generate New Token") { store.config.webServerToken = WebServer.generateToken() }
                    }
                }
            } header: {
                Text("Web Interface")
            } footer: {
                Text("Every request needs the access token, which is part of the link. Without “Allow access from other devices” the interface is only reachable on this Mac.")
                    .foregroundStyle(.secondary)
            }
            Section("Tool paths (empty = automatic)") {
                PathField(title: "makemkvcon", path: $store.config.makemkvconPath, directory: false)
                PathField(title: "HandBrakeCLI", path: $store.config.handbrakeCLIPath, directory: false)
                PathField(title: "ffmpeg", path: $store.config.ffmpegPath, directory: false)
            }
            Section("After the Job") {
                PathField(title: "Script", path: $store.config.postJobScript, directory: false)
                Text("Called with the arguments title, output path, disc type and status.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Reset All Settings…", role: .destructive) { confirmReset = true }
                    .confirmationDialog("Reset all settings?", isPresented: $confirmReset) {
                        Button("Reset", role: .destructive) { store.config = AppConfig() }
                    } message: {
                        Text("All options, API keys and notification settings are set back to their defaults.")
                    }
            }
        }
        .formStyle(.grouped)
    }
}

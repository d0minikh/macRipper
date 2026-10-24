import SwiftUI
import Combine

@MainActor
final class AppModel: ObservableObject {
    let configStore = ConfigStore()
    let monitor = DiscMonitor()
    let manager: JobManager
    let webServer: WebServer
    let toolManager: ToolManager
    private var cancellables: Set<AnyCancellable> = []

    init() {
        manager = JobManager(configStore: configStore, monitor: monitor)
        webServer = WebServer(manager: manager)
        toolManager = ToolManager(configStore: configStore)
        // The App body reads only the menu bar setting; re-render it just when that changes; any broader
        // forwarding loops, because inserting the menu bar item writes the binding back.
        configStore.$config
            .map(\.showMenuBarIcon)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        applyDockIcon(configStore.config.showDockIcon)
        // @Published emits before the value is stored; hop to the next run loop turn so changes
        // made here (the generated token) apply on top of the new value.
        Publishers.CombineLatest(configStore.$config, configStore.$secretsLoaded)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cfg, secretsLoaded in
                guard let self else { return }
                if !cfg.showDockIcon, !cfg.showMenuBarIcon {
                    // The app must stay reachable; this also catches the menu bar icon being dragged away.
                    self.configStore.config.showDockIcon = true
                    return
                }
                self.applyDockIcon(cfg.showDockIcon)
                // App-wide, so the inspector, Settings, sheets and menus all follow – not just one SwiftUI hierarchy.
                NSApplication.shared.appearance = cfg.appearance.nsAppearance
                // The saved token arrives with the Keychain; only create a new one if there is none.
                guard secretsLoaded else { return }
                if cfg.webServerEnabled, cfg.webServerToken.isEmpty {
                    // Re-enters this sink with the generated token.
                    self.configStore.config.webServerToken = WebServer.generateToken()
                    return
                }
                self.webServer.apply(cfg)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.manager.cancelAll() }
            .store(in: &cancellables)
        monitor.start()
        Notifier.requestAuthorization()
        #if DEBUG
        DebugSupport.setUp(manager)
        #endif
    }

    private func applyDockIcon(_ visible: Bool) {
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        guard NSApp == nil || NSApp.activationPolicy() != policy else { return }
        NSApplication.shared.setActivationPolicy(policy)
        // Switching to .accessory deactivates the app; keep its windows in front.
        if !visible { NSApplication.shared.activate() }
    }

    var menuBarIconInserted: Binding<Bool> {
        Binding(get: { self.configStore.config.showMenuBarIcon },
                set: { if self.configStore.config.showMenuBarIcon != $0 { self.configStore.config.showMenuBarIcon = $0 } })
    }
}

@main
struct MacRipperApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("MacRipper", id: "main") {
            ContentView()
                .environmentObject(model.manager)
                .environmentObject(model.configStore)
                .environmentObject(model.monitor)
                .environmentObject(model.toolManager)
                // Room for sidebar, a usable viewer and the inspector.
                .frame(minWidth: 1080, minHeight: 620)
        }
        .defaultSize(width: 1320, height: 820)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { MacRipperCommands(manager: model.manager, monitor: model.monitor) }

        Settings {
            SettingsView()
                .environmentObject(model.configStore)
        }

        MenuBarExtra(isInserted: model.menuBarIconInserted) {
            MenuBarView()
                .environmentObject(model.manager)
                .environmentObject(model.monitor)
        } label: {
            MenuBarIcon(manager: model.manager)
        }
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var manager: JobManager
    var body: some View {
        Image(systemName: manager.activeJobs.isEmpty ? "opticaldiscdrive" : "opticaldiscdrive.fill")
    }
}

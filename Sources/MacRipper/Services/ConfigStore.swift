import Foundation
import Combine
import Security

/// Persists the configuration. Secrets (API keys, tokens, notification URLs) live in the Keychain;
/// config.json only holds the non-sensitive options.
@MainActor
final class ConfigStore: ObservableObject {
    @Published var config: AppConfig
    /// False until the Keychain has been read. Reading can show a permission dialog (e.g. after an
    /// update of an ad-hoc signed build), so it runs in the background and never blocks the UI.
    @Published private(set) var secretsLoaded = false
    private var cancellable: AnyCancellable?
    private var savedSecrets: [String: String] = [:]
    private let keychainQueue = DispatchQueue(label: "MacRipper.keychain")

    init() {
        var cfg = AppConfig()
        var fileSecrets: [String: String] = [:]
        if let data = try? Data(contentsOf: AppPaths.configFile), let stored = try? AppConfig.decodeMerged(from: data) {
            cfg = stored
            fileSecrets = stored.secrets.filter { !$0.value.isEmpty }
        }
        config = cfg

        cancellable = $config
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] cfg in self?.save(cfg) }

        Task.detached(priority: .userInitiated) {
            let keychain = SecretStore.load()
            await MainActor.run { self.secretsLoaded(keychain, migrating: fileSecrets) }
        }
    }

    private func secretsLoaded(_ keychain: [String: String], migrating fileSecrets: [String: String]) {
        savedSecrets = keychain
        // Fill only fields the user has not typed into while the Keychain was being read.
        for (key, value) in keychain where !value.isEmpty {
            if let path = AppConfig.secretKeys[key], config[keyPath: path].isEmpty { config[keyPath: path] = value }
        }
        secretsLoaded = true
        // Secrets still in an older config.json move to the Keychain.
        if !fileSecrets.isEmpty { save(config) }
    }

    private func save(_ cfg: AppConfig) {
        let secrets = cfg.secrets
        if secretsLoaded, secrets != savedSecrets {
            savedSecrets = secrets
            // Serial queue keeps writes in order; a Keychain dialog must not freeze the UI.
            keychainQueue.async { SecretStore.save(secrets) }
        }
        var stripped = cfg
        // Until the Keychain was read, keep any secrets of an old config file on disk instead of losing them.
        if secretsLoaded {
            for key in AppConfig.secretKeys.keys { stripped.setSecret(key, "") }
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(stripped) { try? AppPaths.writePrivate(data, to: AppPaths.configFile) }
    }
}

extension AppConfig {
    static let secretKeys: [String: WritableKeyPath<AppConfig, String>] = [
        "omdbAPIKey": \.omdbAPIKey, "tmdbAPIKey": \.tmdbAPIKey,
        "pushoverUserKey": \.pushoverUserKey, "pushoverAppToken": \.pushoverAppToken,
        "pushbulletKey": \.pushbulletKey, "iftttKey": \.iftttKey, "ntfyURL": \.ntfyURL,
        "webhookURL": \.webhookURL, "appriseURLs": \.appriseURLs, "webServerToken": \.webServerToken,
    ]

    var secrets: [String: String] { Self.secretKeys.mapValues { self[keyPath: $0] } }

    mutating func setSecret(_ key: String, _ value: String) {
        if let path = Self.secretKeys[key] { self[keyPath: path] = value }
    }
}

/// All secrets as one JSON blob in a single generic password item.
enum SecretStore {
    #if DEBUG
    // Debug builds have a different code signature; a separate item avoids Keychain prompts for the real one.
    private static let service = "local.macripper.MacRipper.debug"
    #else
    private static let service = "local.macripper.MacRipper"
    #endif
    private static let account = "settings"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> [String: String] {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    @discardableResult
    static func save(_ secrets: [String: String]) -> Bool {
        let nonEmpty = secrets.filter { !$0.value.isEmpty }
        if nonEmpty.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        guard let data = try? JSONEncoder().encode(nonEmpty) else { return false }
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attrs) { $1 } as CFDictionary, nil)
        }
        return status == errSecSuccess
    }
}

/// Limits how many transcodes run at the same time (ARM: MAX_CONCURRENT_TRANSCODES).
actor TranscodeLimiter {
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire(limit: Int) async {
        if running < max(1, limit) { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }
}

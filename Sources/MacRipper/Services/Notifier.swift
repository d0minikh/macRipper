import Foundation
import UserNotifications

/// Sends job notifications to every configured channel (ARM: Pushbullet, Pushover, IFTTT,
/// Apprise, JSON webhook) plus native macOS notifications.
enum Notifier {
    static func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Sends a job event with the user's message template. `force` skips the per-event switch (test button).
    static func send(_ event: NotificationEvent, job: Job, config: AppConfig, log: JobLogger? = nil,
                     force: Bool = false) async {
        guard force || config[keyPath: event.isEnabledKeyPath] else { return }
        let message = NotificationTemplate.render(event, job: job, config: config)
        await send(title: message.title, body: message.body, job: job, config: config, log: log)
    }

    static func send(title: String, body: String, job: Job?, config: AppConfig, log: JobLogger? = nil) async {
        log?.write("Notification: \(title) – \(body)")

        if config.notifyLocal, Bundle.main.bundleIdentifier != nil {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            try? await UNUserNotificationCenter.current()
                .add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }

        if config.pushoverEnabled, !config.pushoverUserKey.isEmpty, !config.pushoverAppToken.isEmpty {
            var form = ["token": config.pushoverAppToken, "user": config.pushoverUserKey, "title": title,
                        "message": body, "priority": "\(config.pushoverPriority)"]
            if !config.pushoverSound.isEmpty { form["sound"] = config.pushoverSound }
            if !config.pushoverDevice.isEmpty { form["device"] = config.pushoverDevice }
            if let imdb = job?.imdbID, !imdb.isEmpty {
                form["url"] = "https://www.imdb.com/title/\(imdb)/"
                form["url_title"] = "IMDb"
            }
            await post("https://api.pushover.net/1/messages.json", form: form, log: log)
        }
        if config.pushbulletEnabled, !config.pushbulletKey.isEmpty {
            await post("https://api.pushbullet.com/v2/pushes",
                       json: ["type": "note", "title": title, "body": body],
                       headers: ["Access-Token": config.pushbulletKey], log: log)
        }
        if config.iftttEnabled, !config.iftttKey.isEmpty {
            let event = config.iftttEvent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            let key = config.iftttKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            await post("https://maker.ifttt.com/trigger/\(event)/with/key/\(key)",
                       json: ["value1": title, "value2": body], log: log)
        }
        if config.ntfyEnabled, !config.ntfyURL.isEmpty, let url = URL(string: config.ntfyURL) {
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.httpMethod = "POST"
            req.setValue(headerSafe(title), forHTTPHeaderField: "Title")
            req.httpBody = Data(body.utf8)
            await perform(req, log: log)
        }
        if config.webhookEnabled, !config.webhookURL.isEmpty {
            var payload: [String: Any] = ["title": title, "body": body, "message": "\(title): \(body)"]
            if let job {
                payload["job"] = NotificationTemplate.values(for: job)
                    .merging(["disctype": job.discType.rawValue, "state": job.status.rawValue]) { $1 }
            }
            await post(config.webhookURL, json: payload, log: log)
        }
        let appriseURLs = config.appriseURLs.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        if config.appriseEnabled, !appriseURLs.isEmpty, let apprise = Tools.apprise {
            _ = try? await ProcessRunner().run(apprise, ["-t", title, "-b", body] + appriseURLs, log: log)
        }
    }

    /// HTTP header values must be ASCII; ntfy accepts RFC 2047 encoded words for anything else.
    static func headerSafe(_ value: String) -> String {
        let oneLine = value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        guard !oneLine.allSatisfy(\.isASCII) else { return oneLine }
        return "=?UTF-8?B?\(Data(oneLine.utf8).base64EncodedString())?="
    }

    private static func post(_ urlString: String, form: [String: String]? = nil, json: [String: Any]? = nil,
                             headers: [String: String] = [:], log: JobLogger?) async {
        guard let url = URL(string: urlString) else { return }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        if let form {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(formEncode(form).utf8)
        } else if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        await perform(req, log: log)
    }

    /// application/x-www-form-urlencoded body; only unreserved characters stay unescaped.
    static func formEncode(_ form: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return form.sorted { $0.key < $1.key }.map { "\(enc($0.key))=\(enc($0.value))" }.joined(separator: "&")
    }

    private static func perform(_ req: URLRequest, log: JobLogger?) async {
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                log?.write("Notification to \(req.url?.host ?? "?") failed: HTTP \(http.statusCode)")
            }
        } catch {
            log?.write("Notification to \(req.url?.host ?? "?") failed: \(error.localizedDescription)")
        }
    }
}

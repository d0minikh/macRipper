import Foundation
import Network
import Security

/// Small web interface for monitoring jobs (ARM's web UI). Every request needs the access token;
/// by default the server only listens on localhost.
@MainActor
final class WebServer {
    private var listener: NWListener?
    private weak var manager: JobManager?
    private var token = ""
    private(set) var port: UInt16 = 0
    private var allowRemote = false

    init(manager: JobManager) { self.manager = manager }

    func apply(_ config: AppConfig) {
        // Without a token the server stays off, so it can never run unauthenticated.
        let enabled = config.webServerEnabled && !config.webServerToken.isEmpty
        let wanted = enabled ? UInt16(clamping: config.webServerPort) : 0
        token = config.webServerToken
        guard wanted != port || config.webServerAllowRemote != allowRemote else { return }
        stop()
        allowRemote = config.webServerAllowRemote
        guard wanted > 0, let nwPort = NWEndpoint.Port(rawValue: wanted) else { return }
        let params = NWParameters.tcp
        if !allowRemote {
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        }
        guard let listener = try? (allowRemote ? NWListener(using: params, on: nwPort) : NWListener(using: params))
        else { return }
        listener.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.handle(conn) }
        }
        listener.start(queue: .main)
        self.listener = listener
        port = wanted
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        // Drop clients that connect but never send a request.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { conn.cancel() }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self, let data, let request = String(data: data, encoding: .utf8) else { conn.cancel(); return }
                let (status, type, body) = self.respond(to: request)
                var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
                head += "Connection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
                head += "X-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\n"
                head += "Content-Security-Policy: default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'\r\n\r\n"
                conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }

    /// Constant-time comparison so the token cannot be guessed byte by byte from response timing.
    nonisolated static func tokensMatch(_ given: String, _ expected: String) -> Bool {
        let a = Array(given.utf8), b = Array(expected.utf8)
        guard !b.isEmpty, a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func respond(to request: String) -> (String, String, Data) {
        let firstLine = request.split(separator: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, let manager else { return ("400 Bad Request", "text/plain", Data()) }
        let method = String(parts[0])
        let comps = URLComponents(string: String(parts[1]))
        let path = comps?.path ?? "/"
        let queryToken = comps?.queryItems?.first { $0.name == "token" }?.value
        let headerToken = request.split(separator: "\r\n").first { $0.lowercased().hasPrefix("x-macripper-token:") }
            .map { String($0.dropFirst("x-macripper-token:".count)).trimmingCharacters(in: .whitespaces) }
        guard Self.tokensMatch(headerToken ?? queryToken ?? "", token) else {
            return ("401 Unauthorized", "text/plain; charset=utf-8", Data("Token missing or wrong (?token=…)".utf8))
        }

        let segments = path.split(separator: "/").map(String.init)
        switch (method, segments.count) {
        case ("GET", 0):
            return ("200 OK", "text/html; charset=utf-8", Data(Self.page.utf8))
        case ("GET", 2) where segments == ["api", "jobs"]:
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            let jobs = manager.jobs.sorted { $0.created > $1.created }
            return ("200 OK", "application/json", (try? enc.encode(jobs)) ?? Data("[]".utf8))
        case ("GET", 4) where segments[0] == "api" && segments[3] == "log":
            guard let id = UUID(uuidString: segments[2]), let job = manager.job(id) else { break }
            let log = (try? String(contentsOf: job.logURL, encoding: .utf8)) ?? ""
            return ("200 OK", "text/plain; charset=utf-8", Data(log.utf8))
        case ("POST", 4) where segments[0] == "api":
            guard let id = UUID(uuidString: segments[2]) else { break }
            switch segments[3] {
            case "abandon": manager.abandon(id)
            case "start": manager.startNow(id)
            default: return ("404 Not Found", "text/plain", Data())
            }
            return ("200 OK", "application/json", Data("{\"ok\":true}".utf8))
        default: break
        }
        return ("404 Not Found", "text/plain", Data("Not found".utf8))
    }

    private static let page = """
    <!doctype html><html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1"><title>MacRipper</title>
    <style>
    :root{color-scheme:light dark;--bg:#f5f5f7;--card:#fff;--fg:#1d1d1f;--mut:#6e6e73;--acc:#0071e3;--bar:#e5e5ea}
    @media (prefers-color-scheme:dark){:root{--bg:#1c1c1e;--card:#2c2c2e;--fg:#f5f5f7;--mut:#98989d;--bar:#3a3a3c;--acc:#0a84ff}}
    body{font:15px -apple-system,system-ui,sans-serif;background:var(--bg);color:var(--fg);margin:0;padding:16px}
    h1{font-size:22px;margin:0 0 16px}h2{font-size:15px;color:var(--mut);font-weight:600;margin:24px 0 8px}
    .job{background:var(--card);border-radius:12px;padding:14px 16px;margin-bottom:10px}
    .row{display:flex;justify-content:space-between;gap:8px;flex-wrap:wrap}.t{font-weight:600}
    .m{color:var(--mut);font-size:13px}.bar{height:6px;background:var(--bar);border-radius:3px;margin:10px 0 6px;overflow:hidden}
    .bar>div{height:100%;background:var(--acc)}button{border:0;border-radius:6px;padding:5px 10px;margin-left:6px;cursor:pointer}
    .err{color:#ff453a;font-size:13px}a{color:var(--acc)}
    </style></head><body><h1>MacRipper</h1><h2>Active</h2><div id="a"></div><h2>History</h2><div id="h"></div>
    <script>
    const q=location.search;const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
    const active=['identifying','waiting','ripping','transcoding','finishing'];
    function name(j){if(j.discType==='audio_cd'&&j.album)return (j.artist?j.artist+' – ':'')+j.album;
      return j.title?(j.year?j.title+' ('+j.year+')':j.title):(j.discLabel||'Untitled Disc')}
    function fmt(s){const h=Math.floor(s/3600),m=Math.round((s%3600)/60);return h?h+' h '+m+' min':(s<120?s+' s':m+' min')}
    async function act(id,a){await fetch('/api/jobs/'+id+'/'+a+q,{method:'POST'});load()}
    function card(j){const act_=active.includes(j.status);return `<div class="job"><div class="row"><span class="t">${esc(name(j))}</span>
      <span class="m">${esc(j.discType)} · ${esc(j.status)}</span></div>
      ${act_?`<div class="bar"><div style="width:${(j.progress*100).toFixed(1)}%"></div></div>`:''}
      <div class="row"><span class="m">${esc(j.stage)}${act_&&j.remainingSeconds!=null?' · about '+esc(fmt(j.remainingSeconds))+' remaining':''}</span><span>
      ${j.status==='waiting'?`<button onclick="act('${j.id}','start')">Start Now</button>`:''}
      ${act_?`<button onclick="act('${j.id}','abandon')">Abbrechen</button>`:''}
      <a class="m" href="/api/jobs/${j.id}/log${q}" target="_blank">Log</a></span></div>
      ${j.errorMessage?`<div class="err">${esc(j.errorMessage)}</div>`:''}</div>`}
    async function load(){const r=await fetch('/api/jobs'+q);if(!r.ok)return;const js=await r.json();
      document.getElementById('a').innerHTML=js.filter(j=>active.includes(j.status)).map(card).join('')||'<p class="m">No active jobs</p>';
      document.getElementById('h').innerHTML=js.filter(j=>!active.includes(j.status)).slice(0,50).map(card).join('')||'<p class="m">No jobs yet</p>'}
    load();setInterval(load,2000);
    </script></body></html>
    """
}

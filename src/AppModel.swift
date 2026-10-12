import AppKit
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case chat, monitor, about, server
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .chat: return "bubble.left"
        case .monitor: return "waveform.path.ecg.rectangle"
        case .about: return "info.circle"
        case .server: return "server.rack"
        }
    }
}

/// The stack as one state, the way StrataHome shows Strata's: the endpoint (gateway) plus the engine behind it.
enum RunState: Equatable {
    case stopped      // the endpoint is off
    case starting
    case loading      // the engine is loading the model
    case ready        // the model is loaded
    case unloaded     // the endpoint is up, the model is not loaded; the next request loads it
    case stopping
    case error

    var title: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .loading: return "Loading the model"
        case .ready: return "Ready"
        case .unloaded: return "Idle · model unloaded"
        case .stopping: return "Stopping"
        case .error: return "Problem"
        }
    }

    var tone: Tone {
        switch self {
        case .ready: return .accent
        case .unloaded: return .info
        case .error: return .danger
        case .stopped: return .muted
        default: return .warn
        }
    }

    /// The endpoint answers, so Chat can send (an unloaded model loads on the request).
    var canChat: Bool { self == .ready || self == .unloaded || self == .loading }
}

/// Small JSON-over-HTTP helpers for the gateway (always on this Mac).
enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]
        c.timeoutIntervalForRequest = 4
        c.httpAdditionalHeaders = ["User-Agent": AppModel.userAgent]
        return URLSession(configuration: c)
    }()

    static func json(_ url: String, timeout: TimeInterval = 2.5) async -> J? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let j = J.parse(data)
        return j.isNull ? nil : j
    }

    static func post(_ url: String, _ body: Any, timeout: TimeInterval = 5) async -> (Int, J) {
        guard let u = URL(string: url), let data = try? JSONSerialization.data(withJSONObject: body) else { return (0, J(nil)) }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        guard let (out, resp) = try? await session.data(for: req) else { return (0, J(nil)) }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, J.parse(out))
    }
}

@MainActor
final class AppModel: ObservableObject {
    nonisolated static let version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    nonisolated static let userAgent = "UzuHome/\(version)"
    nonisolated static let bundleID = "io.github.majieddd.uzuhome"

    @Published var tab: Tab = .chat
    @Published var status = J(nil)          // gateway /uzu/status
    @Published var metrics = J(nil)         // gateway /uzu/metrics
    @Published var perf = J(nil)            // gateway /uzu/perf
    @Published var gatewayUp = false
    @Published var polled = false           // at least one poll has finished
    @Published var transition: RunState?    // .starting / .stopping while that command runs
    @Published var working: Set<String> = []
    @Published var toasts: [Toast] = []
    @Published var drawerOpen = false
    @Published var settings = Settings.load() { didSet { if persist && settings != oldValue { settings.save() } } }
    @Published var config: [String: String] = [:]
    @Published var models: [ModelEntry] = []
    @Published var hw = HardwareSample()
    @Published var hwHistory: [String: [Double]] = [:]
    @Published var systemDark = false
    @Published var showAllRequests = false
    @Published var catalog: [CatalogModel] = []
    @Published var converting = false
    @Published var convertOutput = ""

    var windowVisible = true
    var persist = true                        // false for --screenshot / --probe runs: nothing is saved
    var chatStreaming = false
    var onChange: (() -> Void)?               // the menu bar item redraws from this
    var showWindow: (() -> Void)?

    private let monitor = HardwareMonitor()
    private var filesStamp: [Date?] = []
    private var lastPerf = Date.distantPast
    private var polling = false
    private(set) lazy var updater = SelfUpdater(model: self)
    private(set) lazy var engineUpdates = EngineUpdates(model: self)

    init() {
        reloadFiles(force: true)
    }

    // MARK: derived

    var dark: Bool { settings.theme == "dark" || (settings.theme == "system" && systemDark) }
    var pal: Palette { dark ? .night : .light }
    var gatewayPort: Int { Int(config["GATEWAY_PORT"] ?? "") ?? 8585 }
    var base: String { "http://127.0.0.1:\(gatewayPort)" }
    var apiURL: String { "\(base)/v1" }
    var servedName: String { config["SERVED_NAME"].flatMap { $0.isEmpty ? nil : $0 } ?? "uzu" }
    var context: Int { Int(config["CONTEXT"] ?? "") ?? 65536 }
    var sessions: Int { max(1, Int(config["SESSIONS"] ?? "") ?? 1) }
    var memoryMode: String {
        if let m = config["MEMORY_MODE"], !m.isEmpty { return m }
        return (Double(config["IDLE_MINUTES"] ?? "30") ?? 30) > 0 ? "idle" : "always"
    }
    var idleMinutes: Int { Int(Double(config["IDLE_MINUTES"] ?? "30") ?? 30) }
    var thinkingDefault: Bool { config["THINKING"] == "on" }
    var share: Bool { config["SHARE_ON_NETWORK"] == "1" }
    var requireKey: Bool { config["REQUIRE_KEY"] == "1" }
    var endpointAtLogin: Bool { (config["ENDPOINT_AT_LOGIN"] ?? "1") == "1" }
    var autoUpdateEngine: Bool { (config["AUTO_UPDATE"] ?? "1") == "1" }
    var apiKey: String { ((try? String(contentsOf: Paths.apiKey, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    var currentModelKey: String { config["MODEL"] ?? status["model"]["key"].str }
    var currentModel: ModelEntry? { models.first { $0.key == currentModelKey } }
    var modelLabel: String { currentModel?.label ?? status["model"]["label"].string ?? "The model" }
    var backendInstalled: Bool { FileManager.default.isExecutableFile(atPath: Paths.ctl) }
    var engineLoaded: Bool { status["engine"].str == "running" }

    var runState: RunState {
        if let t = transition { return t }
        guard gatewayUp else { return .stopped }
        switch status["engine"].str {
        case "running": return .ready
        case "loading": return .loading
        case "error": return .error
        default: return .unloaded
        }
    }

    /// The header pill: what the model is doing right now.
    var pill: (text: String, tone: Tone, halo: Bool) {
        let s = runState
        if gatewayUp && transition == nil {
            let live = metrics["live"]
            let queued = live["queued"].double ?? 0
            if queued > 0 { return ("\(Fmt.n(queued)) queued", .warn, false) }
            switch live["state"].str {
            case "loading": return ("Loading the model", .warn, true)
            case "reading": return ("Reading prompt", .info, true)
            case "generating": return ("Generating · \(Fmt.n(live["tok_s"].double, 1)) tok/s", .accent, true)
            default: break
            }
            if s == .ready { return ("Idle", .muted, false) }
        }
        if !polled { return ("Connecting…", .muted, false) }
        return (s.title, s == .unloaded ? .muted : s.tone == .accent ? .muted : s.tone, false)
    }

    func isWorking(_ key: String) -> Bool { working.contains(key) }

    // MARK: polling

    func startPolling() {
        guard !polling else { return }
        polling = true
        Task { @MainActor in
            while true {
                await refresh()
                let fast = windowVisible || chatStreaming || transition != nil
                try? await Task.sleep(nanoseconds: fast ? 1_000_000_000 : 5_000_000_000)
            }
        }
    }

    func refresh() async {
        reloadFiles()
        async let s = HTTP.json("\(base)/uzu/status")
        async let m = HTTP.json("\(base)/uzu/metrics")
        let (st, me) = await (s, m)
        gatewayUp = st != nil
        if let st { status = st }
        metrics = me ?? J(nil)
        if !gatewayUp { status = J(nil) }
        polled = true
        if windowVisible {
            let sample = monitor.sample(enginePid: status["engine_pid"].int)
            hw = sample
            push("cpu", sample.cpu); push("mem", sample.memUsed); push("gpu", sample.gpuUtil); push("gpumem", sample.gpuMem)
            push("disk", sample.diskRead); push("thermal", Double(sample.thermal)); push("engine", sample.engineFootprint)
            push("swap", sample.swapUsed)
        }
        let perfEvery: TimeInterval = tab == .monitor && windowVisible ? 5 : 60
        if gatewayUp, Date().timeIntervalSince(lastPerf) > perfEvery {
            lastPerf = Date()
            if let p = await HTTP.json("\(base)/uzu/perf") { perf = p }
        }
        if settings.theme == "system" {
            let d = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if d != systemDark { systemDark = d }
        }
        updater.tick()
        onChange?()
    }

    private func push(_ key: String, _ v: Double?) {
        var a = hwHistory[key] ?? []
        a.append(v ?? 0)
        if a.count > 120 { a.removeFirst(a.count - 120) }
        hwHistory[key] = a
    }

    /// config.env and models.conf, re-read when either changes (uzuctl and the menu can edit them too).
    func reloadFiles(force: Bool = false) {
        let stamp = [Paths.configEnv, Paths.modelsConf].map {
            (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate]) as? Date
        }
        guard force || stamp != filesStamp else { return }
        filesStamp = stamp
        config = EnvFile(url: Paths.configEnv).read()
        models = ModelEntry.load()
    }

    // MARK: toasts and the activity log

    func toast(_ kind: ToastKind, _ title: String, _ text: String = "", seconds: Double = 3.5,
               action: String? = nil, _ handler: (() -> Void)? = nil) {
        var t = Toast(kind: kind, title: title, text: text)
        t.actionLabel = action
        t.action = handler
        withAnimation(.easeOut(duration: 0.2)) { toasts.append(t) }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.dismiss(t) }
    }

    func dismiss(_ t: Toast) {
        withAnimation(.easeIn(duration: 0.15)) { toasts.removeAll { $0.id == t.id } }
    }

    func log(_ s: String) { Paths.diag(s) }

    // MARK: actions (all through uzuctl, so the menu bar, the CLI and this window agree)

    @discardableResult
    func ctl(_ key: String, _ args: [String]) async -> (Int32, String) {
        working.insert(key)
        defer { working.remove(key) }
        log("uzuctl \(args.joined(separator: " "))")
        let r = await Shell.ctl(args)
        let out = r.1.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.0 != 0 { log("uzuctl \(args.first ?? "") exited \(r.0): \(out.suffix(400))") }
        reloadFiles()
        return r
    }

    private func failed(_ title: String, _ r: (Int32, String)) -> Bool {
        guard r.0 != 0 else { return false }
        let tail = r.1.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").suffix(2).joined(separator: " ")
        toast(.error, title, tail.isEmpty ? "uzuctl exited with \(r.0). See the Server log." : tail, seconds: 8)
        return true
    }

    func start() {
        guard backendInstalled else { tab = .server; toast(.warn, "uzu is not set up", "Use Set up on the Server tab first.", seconds: 6); return }
        Task {
            transition = .starting
            let r = await ctl("server", ["gateway", "start"])
            if !failed("The endpoint did not start", r), memoryMode != "ondemand" {
                _ = failed("The model did not start", await ctl("server", ["engine", "start", "--no-wait"]))
            }
            await refresh()
            transition = nil
            await refresh()
        }
    }

    func stop() {
        Task {
            transition = .stopping
            await ctl("server", ["engine", "stop"])
            await ctl("server", ["gateway", "stop"])
            await refresh()
            transition = nil
        }
    }

    func restart() {
        guard gatewayUp else { start(); return }
        Task {
            _ = failed("Restart failed", await ctl("server", ["engine", "restart", "--no-wait"]))
            await refresh()
        }
    }

    /// StrataHome's "Free GPU" / "Load now": unload the model but keep the endpoint (the next request loads it again).
    func toggleMemory() {
        if !gatewayUp { start(); return }
        let unload = engineLoaded || runState == .loading
        Task {
            _ = failed(unload ? "Could not unload" : "Could not load", await ctl("server", ["engine", unload ? "stop" : "start", "--no-wait"]))
            await refresh()
            if unload { toast(.success, "Memory freed", "The model is unloaded. The next request loads it again.") }
        }
    }

    func copyURL() {
        Clip.copy(apiURL)
        toast(.success, "Copied", apiURL, seconds: 2)
    }

    func useModel(_ m: ModelEntry) {
        guard m.key != currentModelKey else { return }
        let loaded = engineLoaded || runState == .loading
        Task {
            if failed("Could not switch the model", await ctl("model", ["use", m.key, "--no-wait"])) { return }
            await refresh()
            toast(.success, "Model set to \(m.label)",
                  loaded ? "Loading it now." + (m.cachedBytes == nil && m.source == "mirai" ? " The first start downloads it." : "")
                         : "It loads with the next request or Start.", seconds: 5)
        }
    }

    func setMode(_ mode: String, minutes: Int? = nil) {
        var args = ["mode", mode]
        if mode != "always" { args.append(String(max(1, min(1440, minutes ?? idleMinutes)))) }
        Task { _ = failed("Memory mode not saved", await ctl("mode", args)); await refresh() }
    }

    func setIdleMinutes(_ n: Int) {
        guard n >= 1, n <= 1440, n != idleMinutes else { return }
        Task { await ctl("mode", ["idle", String(n)]) }
    }

    func setThinkingDefault(_ on: Bool) {
        Task {
            if failed("Not saved", await ctl("thinking", ["thinking", on ? "on" : "off"])) { return }
            toast(.success, on ? "Thinking on by default" : "Thinking off by default",
                  "Applies from the next request that does not choose for itself.", seconds: 4)
        }
    }

    func setContext(_ n: Int, restart: Bool) {
        EnvFile(url: Paths.configEnv).set("CONTEXT", String(n))
        reloadFiles(force: true)
        if restart && (engineLoaded || runState == .loading) {
            toast(.info, "Restarting the model", "With a \(Fmt.k(Double(n))) context.", seconds: 4)
            self.restart()
        } else if engineLoaded {
            toast(.success, "Context saved", "\(Fmt.k(Double(n))) is used from the next start.", seconds: 8, action: "Restart now") { [weak self] in self?.restart() }
        } else {
            toast(.success, "Context saved", "\(Fmt.k(Double(n))) is used when the model next loads.")
        }
    }

    func setSessions(_ n: Int) {
        guard n != sessions else { return }
        Task {
            if failed("Not saved", await ctl("sessions", ["sessions", String(n), "--no-wait"])) { return }
            toast(.success, n == 1 ? "One conversation at a time" : "\(n) conversations kept",
                  engineLoaded ? "The model restarts to apply it." : "Applies when the model next loads.", seconds: 5)
        }
    }

    func setShare(_ on: Bool) {
        Task {
            if failed("Network setting not saved", await ctl("share", ["share", on ? "on" : "off"])) { return }
            await refresh()
            toast(on ? .warn : .success, on ? "Serving on the network" : "This Mac only",
                  on ? (requireKey ? "Other computers must send the API key." : "No API key: anyone on your network can use the model.")
                     : "The endpoint listens on 127.0.0.1 again.", seconds: 5)
        }
    }

    func setRequireKey(_ on: Bool) {
        Task { _ = failed("Key setting not saved", await ctl("share", ["key", on ? "on" : "off"])); await refresh() }
    }

    func generateKey() {
        Task {
            if failed("No key written", await ctl("share", ["key", "generate"])) { return }
            objectWillChange.send()
            toast(.success, "New key", "Clients on other computers must send it as their API key. It applies right away.", seconds: 5)
        }
    }

    func setEndpointAtLogin(_ on: Bool) { Task { _ = failed("Not saved", await ctl("login", ["login", on ? "on" : "off"])); await refresh() } }

    func setAutoUpdateEngine(_ on: Bool) { Task { _ = failed("Not saved", await ctl("autoupdate", ["autoupdate", on ? "on" : "off"])) } }

    // MARK: models: Mirai's catalog, conversions, the list

    func loadCatalog() {
        Task {
            let (code, out) = await Shell.ctl(["catalog"], timeout: 30)
            catalog = code == 0 ? CatalogModel.parse(out) : []
        }
    }

    func addCatalogModel(_ id: String) {
        Task {
            if failed("Not added", await ctl("add", ["add", id])) { return }
            toast(.success, "Model added", "Select it to use it. The first start downloads it.", seconds: 5)
        }
    }

    func removeModel(_ m: ModelEntry) {
        Task {
            if failed("Not removed", await ctl("remove", ["remove", m.key])) { return }
            toast(.success, "\(m.label) is off the list", m.source == "local" ? "Its folder is kept: \(m.ref)" : "Its download is kept in ~/.cache/mirai.", seconds: 6)
        }
    }

    /// Converts a Qwen3.5 MLX build from Hugging Face with uzu-convert, its output streaming into convertOutput.
    func convert(repo: String, identity: String) {
        guard !converting else { return }
        let r = repo.trimmingCharacters(in: .whitespaces)
        guard ModelEntry.isRepo(r) else { toast(.warn, "Use the Hugging Face name", "Like ahmedandaloes/Qwythos-9B-v2-MLX-4bit.", seconds: 5); return }
        converting = true
        convertOutput = ""
        var argv = ["/bin/bash", Paths.ctl, "convert", r]
        let id = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty { argv += ["--identity", id] }
        log("uzuctl convert \(r)")
        Streaming.run(argv, output: { [weak self] text in
            guard let self else { return }
            self.convertOutput += text
            if self.convertOutput.count > 30_000 { self.convertOutput = String(self.convertOutput.suffix(20_000)) }
        }, done: { [weak self] code in
            guard let self else { return }
            self.converting = false
            self.reloadFiles(force: true)
            self.log("convert \(r) exited \(code)")
            if code == 0 {
                self.toast(.success, "Converted", "\(r) is on the model list. Select it to use it.", seconds: 8)
            } else {
                self.toast(.error, "Conversion stopped", "The output says why. See also the Convert log.", seconds: 8)
            }
        })
    }

    // MARK: launch at login (a LaunchAgent that opens the app hidden)

    static var loginAgent: URL { Paths.home.appendingPathComponent("Library/LaunchAgents/\(bundleID).plist") }

    var openAtLogin: Bool { FileManager.default.fileExists(atPath: Self.loginAgent.path) }

    func setOpenAtLogin(_ on: Bool) {
        if on {
            let plist: [String: Any] = [
                "Label": Self.bundleID,
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath, "--args", "--minimized"],
                "RunAtLoad": true, "ProcessType": "Interactive",
            ]
            try? FileManager.default.createDirectory(at: Self.loginAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
            (plist as NSDictionary).write(to: Self.loginAgent, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: Self.loginAgent)
        }
        objectWillChange.send()
    }

    // MARK: open and quit

    func autoStartIfWanted(noStart: Bool) async {
        await refresh()
        guard settings.autoStart, !noStart, backendInstalled else { return }
        if !gatewayUp { start(); return }
        if status["engine"].str == "stopped" && memoryMode != "ondemand" {
            await ctl("server", ["engine", "start", "--no-wait"])
            await refresh()
        }
    }

    /// What Quit should do: unload the model unless the user keeps it; stop the endpoint only when it does not run
    /// from login (Hermes wakes it otherwise). Returns the uzuctl argument lists, run off the main thread.
    func quitCommands() -> [[String]] {
        guard settings.freeOnQuit, backendInstalled else { return [] }
        var out: [[String]] = []
        if engineLoaded || runState == .loading { out.append(["engine", "stop"]) }
        if !endpointAtLogin && gatewayUp { out.append(["gateway", "stop"]) }
        return out
    }

    // MARK: logs

    func logText(_ source: String) -> String {
        let url: URL
        switch source {
        case "app": url = Paths.logs.appendingPathComponent("app.log")
        default: url = Paths.backendLogs.appendingPathComponent("\(source).log")
        }
        guard let h = try? FileHandle(forReadingFrom: url) else { return "No \(source) log yet." }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 48_000 ? size - 48_000 : 0)
        var text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        if size > 48_000, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        return text.replacingOccurrences(of: Paths.home.path, with: "~")
    }
}

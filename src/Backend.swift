import Foundation

/// The backend (engine launcher, endpoint gateway, updater, converter, uzuctl) and the uzu engine ship inside the app in
/// Resources/backend and are installed to ~/Library/Application Support/UzuHome/backend. Settings there (config.env,
/// models.conf) and converted models are kept.
@MainActor
final class BackendSetup: ObservableObject {
    struct Check {
        let name: String
        let ok: Bool
        let detail: String
        var optional = false
    }

    @Published var checks: [Check] = []
    @Published var running = false
    @Published var output = ""

    static var bundled: URL? {
        let u = Bundle.main.resourceURL?.appendingPathComponent("backend")
        return u.flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("bin/uzuctl").path) ? $0 : nil }
    }

    init() { refresh() }

    var ready: Bool { checks.filter { !$0.optional }.allSatisfy(\.ok) }

    static var installedEngineVersion: String {
        ((try? String(contentsOf: Paths.backend.appendingPathComponent("engine/VERSION"), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func refresh() {
        let fm = FileManager.default
        let b = Paths.backend
        let python = EnvFile(url: Paths.configEnv).read()["PYTHON"] ?? ""
        let engineVersion = Self.installedEngineVersion
        checks = [
            Check(name: "uzu engine", ok: fm.isExecutableFile(atPath: Paths.engine),
                  detail: engineVersion.isEmpty ? "ships with this app; Set up installs it" : "uzu \(engineVersion)"),
            Check(name: "Endpoint and uzuctl", ok: fm.isExecutableFile(atPath: Paths.ctl) && fm.fileExists(atPath: Paths.configEnv.path),
                  detail: b.path.replacingOccurrences(of: Paths.home.path, with: "~")),
            Check(name: "Python for the endpoint", ok: !python.isEmpty && fm.isExecutableFile(atPath: python),
                  detail: python.isEmpty ? "chosen by Set up (the Command Line Tools' or Homebrew's)" : python),
            Check(name: "Model converter (lalamo)", ok: fm.isExecutableFile(atPath: b.appendingPathComponent("lalamo/.venv/bin/python").path),
                  detail: "optional: set up the first time you convert a model from Hugging Face", optional: true),
        ]
    }

    /// Copies the bundled scripts over the installed ones when this app's copy differs (a new app version), and installs
    /// the bundled engine when it is newer than the installed one. Returns true when the endpoint gateway's code changed.
    @discardableResult
    static func syncBundled() -> Bool {
        guard let src = bundled else { return false }
        let fm = FileManager.default
        let stampFile = Paths.backend.appendingPathComponent("bin/.bundle-version")
        let stamp = (try? String(contentsOf: src.appendingPathComponent("VERSION"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let installed = (try? String(contentsOf: stampFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stamp.isEmpty, stamp != installed else { return false }
        // only refresh an existing install here; a new Mac goes through Set up
        guard fm.fileExists(atPath: Paths.backend.appendingPathComponent("bin").path) else { return false }
        var gatewayChanged = false
        for name in (try? fm.contentsOfDirectory(atPath: src.appendingPathComponent("bin").path)) ?? [] where !name.hasPrefix(".") {
            let from = src.appendingPathComponent("bin/\(name)"), to = Paths.backend.appendingPathComponent("bin/\(name)")
            if fm.contentsEqual(atPath: from.path, andPath: to.path) { continue }
            if name == "uzu-gateway.py" { gatewayChanged = true }
            try? fm.removeItem(at: to)
            try? fm.copyItem(at: from, to: to)
            try? fm.setAttributes([.posixPermissions: name.hasSuffix(".sh") ? 0o644 : 0o755], ofItemAtPath: to.path)
        }
        for dir in ["lib", "share", "patches"] {
            let to = Paths.backend.appendingPathComponent(dir)
            try? fm.removeItem(at: to)
            try? fm.copyItem(at: src.appendingPathComponent(dir), to: to)
        }
        for (file, def) in [("config.env", "config.env.default"), ("models.conf", "models.conf")] {
            let to = Paths.backend.appendingPathComponent(file)
            if !fm.fileExists(atPath: to.path) { try? fm.copyItem(at: src.appendingPathComponent(def), to: to) }
        }
        installBundledEngineIfNewer(src)
        try? stamp.write(to: stampFile, atomically: true, encoding: .utf8)
        Paths.diag("backend scripts updated to \(stamp)" + (gatewayChanged ? " (gateway changed)" : ""))
        return gatewayChanged
    }

    /// The engine this app ships replaces the installed one when it is a newer uzu release, or the same release built
    /// with other patches (an engine of a newer release that uzu-update installed stays). The one it replaces is kept
    /// in engine/previous.
    static func installBundledEngineIfNewer(_ src: URL) {
        let fm = FileManager.default
        let bundledBin = src.appendingPathComponent("engine/uzu")
        guard fm.isExecutableFile(atPath: bundledBin.path) else { return }
        let bundled = ((try? String(contentsOf: src.appendingPathComponent("engine/VERSION"), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let installed = installedEngineVersion
        let tag = { (v: String) in String(v.split(separator: "+").first ?? "") }
        let order = SelfUpdater.compare(tag(bundled), tag(installed))
        guard installed.isEmpty || order > 0 || (order == 0 && bundled != installed) else { return }
        let engineDir = Paths.backend.appendingPathComponent("engine")
        let previous = engineDir.appendingPathComponent("previous")
        try? fm.createDirectory(at: previous, withIntermediateDirectories: true)
        if fm.fileExists(atPath: Paths.engine) {
            try? fm.removeItem(at: previous.appendingPathComponent("uzu"))
            try? fm.copyItem(atPath: Paths.engine, toPath: previous.appendingPathComponent("uzu").path)
            try? fm.removeItem(at: previous.appendingPathComponent("VERSION"))
            try? fm.copyItem(at: engineDir.appendingPathComponent("VERSION"), to: previous.appendingPathComponent("VERSION"))
        }
        try? fm.removeItem(atPath: Paths.engine)
        try? fm.copyItem(at: bundledBin, to: URL(fileURLWithPath: Paths.engine))
        try? (bundled + "\n").write(to: engineDir.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        Paths.diag("engine \(installed.isEmpty ? "installed" : "updated from \(installed)") to uzu \(bundled)")
    }

    /// Runs the bundled install.sh, showing its output as it goes.
    func install(model: AppModel) {
        guard !running, let src = Self.bundled else {
            if Self.bundled == nil { model.toast(.error, "Set up is not available", "This build has no bundled backend.", seconds: 6) }
            return
        }
        running = true
        output = ""
        run(["/bin/bash", src.appendingPathComponent("install.sh").path]) { [weak self] code in
            guard let self else { return }
            self.running = false
            self.refresh()
            model.reloadFiles(force: true)
            Paths.diag("setup exited \(code)")
            if code == 0 {
                model.toast(.success, "uzu is set up", "Press Start to load the model. The first start downloads it.", seconds: 8)
            } else {
                model.toast(.error, "Set up stopped", "The output above says where. You can run it again.", seconds: 8)
            }
        }
    }

    /// Runs a command with its output streamed into `output`; `done` gets the exit code on the main queue.
    func run(_ argv: [String], done: @escaping (Int32) -> Void) {
        Streaming.run(argv, output: { [weak self] s in
            guard let self else { return }
            self.output += s
            if self.output.count > 30_000 { self.output = String(self.output.suffix(20_000)) }
        }, done: done)
    }
}

/// Runs a command off the main thread, handing its output (stdout and stderr, carriage returns as new lines) to
/// `output` and its exit code to `done`, both on the main queue.
enum Streaming {
    static func run(_ argv: [String], output: @escaping @MainActor (String) -> Void, done: @escaping @MainActor (Int32) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:\(Paths.home.path)/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            guard !s.isEmpty else { return }
            let text = s.replacingOccurrences(of: "\r", with: "\n")
            DispatchQueue.main.async { MainActor.assumeIsolated { output(text) } }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let code = proc.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { done(code) } }
        }
        do { try p.run() } catch {
            let msg = "Could not run \(argv.joined(separator: " ")): \(error.localizedDescription)\n"
            DispatchQueue.main.async { MainActor.assumeIsolated { output(msg); done(127) } }
        }
    }
}

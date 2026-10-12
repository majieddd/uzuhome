import AppKit
import SwiftUI

/// The Server tab: start and stop, the model, the memory mode, the network, the options, updates and the logs.
struct ServerView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var setup: BackendSetup

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                StatusCard()
                if !setup.ready || setup.running { SetupCard() }
                ModelCard()
                NetworkCard()
                OptionsCard()
                UpdatesCard(engine: model.engineUpdates, app: model.updater)
                LogCard()
            }
            .frame(maxWidth: 860)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - status

private struct StatusCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal

    var body: some View {
        let s = model.runState
        let busy = model.isWorking("server")
        Card {
            HStack(alignment: .center, spacing: 14) {
                Circle().fill(pal.tone(s.tone)).frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).outfit(24, .black).foregroundStyle(pal.ink)
                    Text(detail(s)).outfit(14).foregroundStyle(pal.inkMuted).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Button("Start") { model.start() }.buttonStyle(PrimaryButtonStyle())
                    .disabled(busy || s != .stopped)
                Button("Stop") { model.stop() }.buttonStyle(SecondaryButtonStyle())
                    .disabled(busy || s == .stopped || s == .stopping)
                Button("Restart") { model.restart() }.buttonStyle(SecondaryButtonStyle())
                    .disabled(busy || s == .stopped || s == .stopping || s == .starting)
                Button(model.engineLoaded || s == .loading ? "Free memory" : "Load now") { model.toggleMemory() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(busy || s == .stopped || s == .starting || s == .stopping)
                    .help("Unload the model and give its memory back to macOS; the endpoint stays and loads it again on the next request.")
                Button("Copy API URL") { model.copyURL() }.buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, 18)
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 6) {
                GridRow {
                    Text("Endpoint").outfit(14).foregroundStyle(pal.inkMuted).frame(width: 160, alignment: .leading)
                    Text(model.apiURL).font(Fonts.mono(13)).foregroundStyle(pal.inkSoft).textSelection(.enabled)
                }
                GridRow {
                    Text("Uptime").outfit(14).foregroundStyle(pal.inkMuted)
                    Text(uptime).outfit(14).foregroundStyle(pal.inkSoft)
                }
                if let r = model.status["idle_remaining_s"].double, model.engineLoaded {
                    GridRow {
                        Text("Unloads").outfit(14).foregroundStyle(pal.inkMuted)
                        Text("in \(Fmt.n(max(1, r / 60))) min without a request").outfit(14).foregroundStyle(pal.inkSoft)
                    }
                }
            }
            .padding(.top, 14)
        }
    }

    var uptime: String {
        guard model.engineLoaded, let since = model.status["engine_up_since"].double else { return "–" }
        var t = Fmt.duration(Date().timeIntervalSince1970 - since)
        if let l = model.status["engine_facts"]["load_seconds"].double { t += "   (model loaded in \(Fmt.n(l)) s)" }
        return t
    }

    func detail(_ s: RunState) -> String {
        let label = model.modelLabel
        switch s {
        case .ready: return "Serving \(label) at \(model.apiURL)"
        case .unloaded: return "The endpoint is up at \(model.apiURL). \(label) loads with the next request."
        case .loading:
            return "Loading \(label)…" + (model.currentModel?.cachedBytes == nil && model.currentModel?.source == "mirai" ? " The first start downloads it." : "")
        case .starting: return "Starting the endpoint…"
        case .stopping: return "Stopping…"
        case .error:
            let code = model.status["engine_last_exit"].int.map { " with code \($0)" } ?? ""
            return "The engine exited\(code). The Engine log below says why."
        case .stopped:
            return model.backendInstalled ? "Start runs the endpoint and loads \(label). Hermes and other apps reach it at \(model.apiURL)."
                                          : "uzu is not set up on this Mac yet. Use Set up below."
        }
    }
}

// MARK: - first-run setup

private struct SetupCard: View {
    @EnvironmentObject var setup: BackendSetup
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal

    var body: some View {
        TitledCard(title: "Set up uzu",
                   note: "Installs what uzu Home drives: the uzu engine (it ships with this app, with a small patch so the context can reach Hermes's 64K), the endpoint, uzuctl and the daily engine check. Nothing else is needed. Models download the first time they start.") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(setup.checks, id: \.name) { c in
                    HStack(spacing: 10) {
                        Image(systemName: c.ok ? "checkmark.circle.fill" : c.optional ? "circle.dashed" : "xmark.circle")
                            .foregroundStyle(c.ok ? pal.accent : c.optional ? pal.inkMuted : pal.danger)
                        Text(c.name).outfit(14, .medium).foregroundStyle(pal.inkSoft)
                        Text(c.detail).outfit(12).foregroundStyle(pal.inkMuted).lineLimit(1)
                    }
                }
            }
            .padding(.top, 14)
            HStack(spacing: 12) {
                Button(setup.running ? "Setting up…" : "Set up") { setup.install(model: model) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(setup.running)
            }
            .padding(.top, 16)
            if !setup.output.isEmpty { OutputBox(text: setup.output).padding(.top, 12) }
        }
    }
}

/// A command's output as it runs (Set up, conversions).
private struct OutputBox: View {
    let text: String
    @Environment(\.pal) var pal

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text).font(Fonts.mono(11)).foregroundStyle(pal.codeInk)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(12)
                Color.clear.frame(height: 1).id("end")
            }
            .frame(height: 180)
            .background(RoundedRectangle(cornerRadius: 12).fill(pal.codeBg))
            .onChange(of: text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

// MARK: - model + memory

private struct ModelCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal
    @State private var sizes: [String: Double] = [:]
    @State private var speculators: Set<String> = []
    @State private var adding = false
    @State private var addKind = "catalog"
    @State private var catalogPick = ""
    @State private var repo = ""
    @State private var identity = ""
    @State private var idleText = ""

    var body: some View {
        Card {
            CardTitle(text: "Model")
            VStack(spacing: 8) {
                if model.models.isEmpty {
                    Text("No models listed. Add one below, or set up uzu first.").outfit(14).foregroundStyle(pal.dangerText)
                }
                ForEach(model.models) { m in
                    HStack(spacing: 8) {
                        RadioRow(selected: m.key == model.currentModelKey, action: { model.useModel(m) }) {
                            HStack(spacing: 8) {
                                Text(m.label).outfit(14, .bold).foregroundStyle(pal.ink)
                                if model.isWorking("model") && m.key == model.currentModelKey { ProgressView().controlSize(.small) }
                            }
                            Text(detail(m)).outfit(12).foregroundStyle(pal.inkMuted).lineLimit(1).truncationMode(.middle)
                        }
                        .disabled(model.isWorking("model"))
                        // the current model can't be removed; its slot stays so the rows line up
                        IconButton(symbol: "minus.circle", help: "Take it off the list (its files stay)", size: 34) { model.removeModel(m) }
                            .disabled(model.isWorking("remove") || m.key == model.currentModelKey)
                            .opacity(m.key == model.currentModelKey ? 0 : 1)
                    }
                }
            }
            .padding(.top, 12)
            HStack {
                Button(adding ? "Close" : "Add a model…") {
                    adding.toggle()
                    if adding { model.loadCatalog() }
                }
                .buttonStyle(SecondaryButtonStyle(height: 32))
                Spacer()
            }
            .padding(.top, 4)
            if adding { addForm }
            Muted(text: "Switching restarts the model if it is loaded. uzu runs models in its own format: Mirai's catalog has ready-made builds (trymirai.com/local-models), and Qwen3.5 MLX builds from Hugging Face can be converted here. GGUF files from LM Studio do not run in uzu.", size: 12)
                .padding(.top, 12)

            CardTitle(text: "Memory").padding(.top, 22)
            Muted(text: "A loaded model holds several GB of unified memory. The endpoint stays up either way and loads the model when a request arrives.", size: 13)
                .padding(.top, 6).padding(.bottom, 10)
            VStack(spacing: 8) {
                modeRow("always", "Keep the model loaded", "Fastest replies; holds the memory the whole time.")
                modeRow("idle", "Unload when idle", "Frees the memory after a while without requests; the next request loads it again.")
                modeRow("ondemand", "Load on first request", "Nothing is loaded when the app opens; also unloads when idle.")
            }
            .disabled(model.isWorking("mode"))
            if model.memoryMode != "always" {
                HStack(spacing: 10) {
                    Text("Unload after").outfit(14).foregroundStyle(pal.inkSoft)
                    TextField("", text: $idleText).field().frame(width: 80)
                        .onSubmit { commitIdle() }
                    Text("minutes without a request").outfit(14).foregroundStyle(pal.inkSoft)
                    if Int(idleText) != model.idleMinutes {
                        Button("Save") { commitIdle() }.buttonStyle(SecondaryButtonStyle(height: 34))
                    }
                }
                .padding(.top, 8).padding(.leading, 4)
            }
        }
        .onAppear { idleText = String(model.idleMinutes); loadSizes() }
        .onChange(of: model.idleMinutes) { _, v in idleText = String(v) }
        .onChange(of: model.models) { _, _ in loadSizes() }
    }

    func detail(_ m: ModelEntry) -> String {
        var parts = [m.sourceName]
        if let b = sizes[m.key] {
            parts.append("\(Fmt.n(b / 1e9, 1)) GB" + (m.source == "mirai" ? " downloaded" : ""))
        } else if m.source == "mirai" {
            let size = model.catalog.first { $0.id == m.ref }.map { " (\(Fmt.n($0.bytes / 1e9, 1)) GB)" } ?? ""
            parts.append("downloads on the first start\(size)")
        } else {
            parts.append("folder missing")
        }
        if speculators.contains(m.key) { parts.append("speculator") }
        parts.append(m.ref.replacingOccurrences(of: Paths.home.path, with: "~"))
        return parts.joined(separator: " · ")
    }

    var addForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Segmented(options: [("catalog", "From Mirai's catalog"), ("convert", "Convert from Hugging Face")], selection: $addKind, fill: false)
            if addKind == "catalog" {
                let listed = Set(model.models.map(\.ref))
                let choices = model.catalog.filter { !listed.contains($0.id) }
                if model.catalog.isEmpty {
                    Muted(text: "Mirai's catalog is fetched the first time the engine starts. Start it once, then come back here.", size: 13)
                } else {
                    HStack(spacing: 12) {
                        Picker("", selection: $catalogPick) {
                            Text("Choose a model…").tag("")
                            ForEach(choices) { c in Text(c.label).tag(c.id) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 520)
                        Spacer()
                        Button("Add") {
                            model.addCatalogModel(catalogPick)
                            catalogPick = ""
                        }
                        .buttonStyle(PrimaryButtonStyle(height: 36))
                        .disabled(catalogPick.isEmpty || model.isWorking("add"))
                    }
                    Muted(text: "Mirai's own quantizations, ready for uzu. Medium is 4-bit; Large is 8-bit, slower and closer to the original. Only the 9B builds come with a speculator. The download starts the first time the model loads.", size: 12)
                }
            } else {
                TextField("Hugging Face name, e.g. ahmedandaloes/Qwythos-9B-v2-MLX-4bit", text: $repo).field(mono: true)
                TextField("Identity line (optional: only for models whose chat template adds one to every system message)", text: $identity).field()
                HStack(spacing: 12) {
                    Muted(text: "Qwen3.5 MLX builds (4- or 8-bit). Converted with lalamo, Mirai's converter, set up the first time (about 0.7 GB). 9B models get Mirai's speculator. The original download stays in the Hugging Face cache.", size: 12)
                    Spacer()
                    Button(model.converting ? "Converting…" : "Convert") { model.convert(repo: repo, identity: identity) }
                        .buttonStyle(PrimaryButtonStyle(height: 36))
                        .disabled(model.converting || repo.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !model.convertOutput.isEmpty { OutputBox(text: model.convertOutput) }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(pal.surface2))
        .padding(.top, 10)
    }

    func modeRow(_ key: String, _ title: String, _ sub: String) -> some View {
        RadioRow(selected: model.memoryMode == key, action: { model.setMode(key, minutes: Int(idleText)) }) {
            Text(title).outfit(14, .bold).foregroundStyle(pal.ink)
            Text(sub).outfit(12).foregroundStyle(pal.inkMuted)
        }
    }

    func commitIdle() {
        guard let n = Int(idleText.trimmingCharacters(in: .whitespaces)), n >= 1, n <= 1440 else {
            model.toast(.warn, "Minutes from 1 to 1440", "", seconds: 3)
            idleText = String(model.idleMinutes)
            return
        }
        model.setIdleMinutes(n)
    }

    func loadSizes() {
        let list = model.models
        DispatchQueue.global(qos: .utility).async {
            var out: [String: Double] = [:]
            var spec: Set<String> = []
            for m in list {
                if let b = m.cachedBytes { out[m.key] = b }
                if m.hasSpeculator { spec.insert(m.key) }
            }
            DispatchQueue.main.async { sizes = out; speculators = spec }
        }
    }
}

// MARK: - network

private struct NetworkCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal

    var body: some View {
        let busy = model.isWorking("share")
        Card {
            CardTitle(text: "Network")
            ToggleRow(title: "Serve the model on the network",
                      sub: "Off: only this Mac (127.0.0.1). On: other computers on your network reach the same model over your LAN address, the way LM Studio's network server does. The endpoint restarts to apply it; a reply in progress is cut off.",
                      isOn: Binding(get: { model.share }, set: { model.setShare($0) }))
                .disabled(busy)
            if model.share {
                ToggleRow(title: "Require an API key",
                          sub: "Optional. Off: anyone who can reach this Mac can use the model. On: other computers must send the key below (Authorization: Bearer <key> or x-api-key). Requests from this Mac never need it.",
                          isOn: Binding(get: { model.requireKey }, set: { model.setRequireKey($0) }))
                    .disabled(busy)
                if model.requireKey {
                    HStack(spacing: 10) {
                        Text(model.apiKey.isEmpty ? "no key yet" : model.apiKey).font(Fonts.mono(13)).foregroundStyle(pal.inkSoft)
                            .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 14).fill(pal.surface2))
                        Button("Generate") { model.generateKey() }.buttonStyle(SecondaryButtonStyle(height: 38)).disabled(busy)
                        IconButton(symbol: "doc.on.doc", help: "Copy the key", size: 38) {
                            Clip.copy(model.apiKey)
                            model.toast(.success, "Copied", "The key is on your clipboard.", seconds: 2)
                        }
                        .disabled(model.apiKey.isEmpty)
                    }
                    .padding(.top, 12)
                } else {
                    Text("No API key: anyone who can reach this Mac can use the model. A key is recommended beyond a trusted home network.")
                        .outfit(13).foregroundStyle(pal.warnText).padding(.top, 12)
                }
                let ips = Net.lanAddresses()
                VStack(alignment: .leading, spacing: 4) {
                    Muted(text: ips.isEmpty ? "From another computer: this Mac has no network address right now." : "From another computer (OpenAI base URL):", size: 13)
                    ForEach(ips, id: \.self) { CopyValue(value: "http://\($0):\(model.gatewayPort)/v1") }
                }
                .padding(.top, 12)
                Muted(text: "If macOS asks whether Python may accept incoming network connections, choose Allow (the endpoint runs on Python). Switch sharing off when you are done.")
                    .padding(.top, 10)
            }
        }
    }
}

// MARK: - options

private struct OptionsCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal

    var body: some View {
        Card {
            CardTitle(text: "Options")
            ToggleRow(title: "Start uzu when this app opens", sub: "Starts the endpoint and loads the model (unless it loads on first request). Otherwise use Start on this page.",
                      isOn: $model.settings.autoStart)
            ToggleRow(title: "Open this app at login", sub: "Hidden, in the menu bar. Off by default.",
                      isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
            ToggleRow(title: "Keep the endpoint running from login",
                      sub: "So Hermes and other apps can always reach \(model.apiURL); it loads the model when a request arrives. It costs almost nothing while the model is unloaded.",
                      isOn: Binding(get: { model.endpointAtLogin }, set: { model.setEndpointAtLogin($0) }))
                .disabled(model.isWorking("login"))
            ToggleRow(title: "Unload the model when this app quits",
                      sub: "Gives the memory back when you quit. The endpoint stays if it runs from login, and loads the model again on the next request.",
                      isOn: $model.settings.freeOnQuit)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Command line").outfit(14, .medium).foregroundStyle(pal.inkSoft)
                    Muted(text: "uzuctl status, uzuctl use MODEL, uzuctl endpoint, uzuctl convert REPO, uzuctl logs engine: the same controls in Terminal.")
                }
                Spacer()
                Button("Show files") { NSWorkspace.shared.activateFileViewerSelecting([Paths.configEnv]) }.buttonStyle(SecondaryButtonStyle(height: 34))
            }
            .padding(.top, 16)
        }
    }
}

// MARK: - updates

private struct UpdatesCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var engine: EngineUpdates
    @ObservedObject var app: SelfUpdater
    @Environment(\.pal) var pal

    var body: some View {
        Card {
            CardTitle(text: "uzu engine updates")
            ToggleRow(title: "Update the uzu engine automatically",
                      sub: "Every day at \(String(format: "%02d:%02d", Int(model.config["UPDATE_HOUR"] ?? "4") ?? 4, Int(model.config["UPDATE_MINUTE"] ?? "45") ?? 45)) (or when the Mac next wakes), uzu Home checks for a new uzu release. If Mirai's own build runs on this macOS and has the context option, it is used; otherwise, when Rust and Xcode are on this Mac, the release is built from source with uzu Home's patch; otherwise the next uzu Home release brings it. A new engine has to start before it is kept, or the one you had comes back. A busy model is not restarted.",
                      isOn: Binding(get: { model.autoUpdateEngine }, set: { model.setAutoUpdateEngine($0) }))
            Text(engine.summary).outfit(13).foregroundStyle(pal.inkSoft).padding(.top, 16).fixedSize(horizontal: false, vertical: true)
            let comps = engine.report["components"].array
            if !comps.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    ForEach(Array(comps.enumerated()), id: \.offset) { _, c in
                        GridRow {
                            Text(c["name"].str).outfit(13, .medium).foregroundStyle(pal.inkSoft)
                            Text(c["before"].str.isEmpty ? "–" : c["before"].str).font(Fonts.mono(12)).foregroundStyle(pal.inkMuted)
                            Text(c["status"].str == "current" ? "" : "→ \(c["after"].str)").font(Fonts.mono(12)).foregroundStyle(pal.inkMuted)
                            Badge(text: c["status"].str, tone: tone(c["status"].str))
                        }
                    }
                }
                .padding(.top, 10)
            }
            HStack(spacing: 10) {
                Button(engine.running == "check" ? "Checking…" : "Check now") { engine.check() }.buttonStyle(SecondaryButtonStyle())
                Button(engine.running == "update" ? "Updating…" : "Update now") { engine.updateNow() }.buttonStyle(PrimaryButtonStyle())
            }
            .disabled(engine.running != nil || !model.backendInstalled)
            .padding(.top, 14)
            Muted(text: "Installed: uzu \(BackendSetup.installedEngineVersion.isEmpty ? "–" : BackendSetup.installedEngineVersion). Checking asks GitHub; a source build takes a few minutes. Models and settings are kept.").padding(.top, 8)

            Rectangle().fill(pal.lineSoft).frame(height: 1).padding(.vertical, 22)

            CardTitle(text: "uzu Home updates")
            ToggleRow(title: "Check for uzu Home updates",
                      sub: "Checks this app's GitHub releases on startup and every six hours. A new version is downloaded only when you press Update, and goes in when the app quits.",
                      isOn: $model.settings.autoUpdateApp)
            Text(app.status).outfit(13).foregroundStyle(pal.inkSoft).padding(.top, 16).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(app.checking ? "Checking…" : "Check now") { app.checkNow() }.buttonStyle(SecondaryButtonStyle())
                    .disabled(app.checking || app.busy)
                Button(appButton) { app.staged ? NSApp.terminate(nil) : app.updateNow() }.buttonStyle(PrimaryButtonStyle())
                    .disabled(app.checking || app.busy || (!app.available && !app.staged && !app.latest.isEmpty))
            }
            .padding(.top, 14)
            Muted(text: "Version \(AppModel.version). The download's SHA-256 is checked against the one GitHub publishes for the release before anything is staged; the version you had is kept in ~/Library/Application Support/UzuHome/updates/app-before-<version>.")
                .padding(.top, 8)
        }
    }

    var appButton: String {
        if app.busy { return "Downloading…" }
        if app.staged { return "Quit and install" }
        if app.available { return "Update uzu Home" }
        return app.latest.isEmpty ? "Update uzu Home" : "Up to date"
    }

    func tone(_ s: String) -> Tone {
        switch s {
        case "current", "not installed": return .muted
        case "updated": return .accent
        case "available": return .info
        default: return .warn
        }
    }
}

// MARK: - logs

private struct LogCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal
    @State private var text = ""

    var body: some View {
        Card {
            HStack {
                CardTitle(text: "Logs")
                Spacer()
                Button("Open log folder") { NSWorkspace.shared.open(Paths.backendLogs) }.buttonStyle(SecondaryButtonStyle(height: 32))
            }
            Segmented(options: [("engine", "Engine"), ("gateway", "Endpoint"), ("update", "Updates"), ("convert", "Conversions"), ("app", "This app")],
                      selection: $model.settings.logSource)
                .padding(.top, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text).font(Fonts.mono(11.5)).foregroundStyle(pal.codeInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(14)
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(height: 300)
                .background(RoundedRectangle(cornerRadius: 14).fill(pal.codeBg))
                .onChange(of: text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            .padding(.top, 12)
        }
        .task(id: model.settings.logSource) {
            while !Task.isCancelled {
                let t = model.logText(model.settings.logSource)
                if t != text { text = t }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}

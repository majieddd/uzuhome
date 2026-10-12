import SwiftUI

/// The About tab: the model and engine, this Mac, the addresses for other tools (with Hermes's config), settings,
/// and the model settings uzu runs with (context length, thinking by default).
struct AboutView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                EngineCard()
                MacCard()
                ConnectCard()
                SettingsCard()
                ModelSettingsCard()
            }
            .frame(maxWidth: 860)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct EngineCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let st = model.status, facts = st["engine_facts"], info = st["model_info"]
        let m = model.currentModel
        var rows: [(String, String)] = []
        rows.append(("Model", model.modelLabel))
        if let m {
            rows.append((m.source == "mirai" ? "Mirai catalog id" : "Folder", m.ref.replacingOccurrences(of: Paths.home.path, with: "~")))
        }
        if let from = info["converted_from"].string { rows.append(("Converted from", "\(from) (Hugging Face)")) }
        if let q = info["quantization"].string { rows.append(("Quantization", q)) }
        if info["cached"].bool {
            if let s = info["size_gb"].double { rows.append(("On disk", "\(Fmt.n(s, 1)) GB")) }
            rows.append(("Speculator", info["speculator"].bool ? "Mirai's Qwen3.5-9B speculator: drafts several tokens, the model checks them in one step"
                                                              : "none: one token per step"))
        } else if m != nil {
            rows.append(("On disk", m?.source == "mirai" ? "not downloaded yet: the first start fetches it" : "the folder is missing"))
        }
        let version = st["engine_version"].string ?? BackendSetup.installedEngineVersion
        let patched = version.range(of: #"\.p[0-9a-f]{6}$"#, options: .regularExpression) != nil || version.hasSuffix(".patched")
        let line = "uzu \(version.isEmpty ? "–" : version)" + (patched ? " (with uzu Home's patches)" : "")
        rows.append(("Engine", model.engineLoaded ? line : "\(line) · not loaded"))
        rows.append(("Context", "\(Fmt.n(Double(model.context))) tokens" + (model.sessions > 1 ? " × \(model.sessions) conversations" : "")))
        if let p = facts["prefix_cache"].string { rows.append(("Prompt cache", p == "enabled" ? "on: a request that continues the last one skips what was already read" : p)) }
        rows.append(("Thinking default", model.thinkingDefault ? "on" : "off (a request can turn it on)"))
        if let l = facts["load_seconds"].double { rows.append(("Load time", "\(Fmt.n(l, 1)) s")) }
        return TitledCard(title: "Model and engine") { Facts(rows: rows, labelWidth: 200).padding(.top, 14) }
    }
}

private struct MacCard: View {
    let f = MacFacts.current
    var body: some View {
        TitledCard(title: "This Mac") {
            Facts(rows: [
                ("Chip", f.chip),
                ("GPU", f.gpuCores.map { "\($0)-core GPU, unified memory" } ?? "Apple GPU"),
                ("CPU", f.coresText),
                ("Memory", "\(Fmt.gb(f.memory, 0)) GB"),
                ("GPU memory limit", f.gpuBudget.map { "\(Fmt.gb($0)) GB (what Metal lets one app use)" } ?? "–"),
                ("System", f.os),
            ], labelWidth: 200).padding(.top, 14)
        }
    }
}

private struct ConnectCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal

    var hermes: String {
        """
        model:
          provider: custom
          base_url: \(model.apiURL)
          default: \(model.servedName)
          context_length: \(model.context)
        """
    }

    var body: some View {
        TitledCard(title: "Connect your tools",
                   note: "Any OpenAI-compatible client works with this address: Hermes, Open WebUI, editors, scripts. Whatever model name a client sends is answered by the loaded model. (uzu speaks OpenAI's chat completions; there is no Anthropic endpoint.)") {
            VStack(alignment: .leading, spacing: 10) {
                row("OpenAI base URL", model.apiURL)
                row("Model id", model.servedName)
                if model.share {
                    ForEach(Net.lanAddresses(), id: \.self) { ip in row("From the network", "http://\(ip):\(model.gatewayPort)/v1") }
                }
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("API key").outfit(14).foregroundStyle(pal.inkMuted).frame(width: 200, alignment: .leading)
                    Text(model.share && model.requireKey ? "required from other computers (Server > Network)" : "none needed on this Mac (send any value if a client insists)")
                        .outfit(14).foregroundStyle(pal.inkSoft)
                }
                row("Context window", "\(Fmt.n(Double(model.context))) tokens", copy: false)
            }
            .padding(.top, 14)
            HStack {
                Text("Hermes (~/.hermes/config.yaml)").outfit(13, .medium).foregroundStyle(pal.inkSoft)
                Spacer()
            }
            .padding(.top, 18).padding(.bottom, 8)
            MarkdownView(text: "```yaml\n\(hermes)\n```")
        }
    }

    func row(_ label: String, _ value: String, copy: Bool = true) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Text(label).outfit(14).foregroundStyle(pal.inkMuted).frame(width: 200, alignment: .leading)
            if copy { CopyValue(value: value) } else { Text(value).outfit(14).foregroundStyle(pal.inkSoft) }
            Spacer(minLength: 0)
        }
    }
}

private struct SettingsCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal

    var body: some View {
        TitledCard(title: "Settings") {
            HStack {
                Text("Theme").outfit(13, .medium).foregroundStyle(pal.inkSoft)
                Spacer()
                Segmented(options: [("system", "Match macOS"), ("light", "Light"), ("dark", "Dark")],
                          selection: Binding(get: { model.settings.theme }, set: { model.setTheme($0) }), fill: false)
            }
            .padding(.top, 16)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    Text("Chats and settings are kept on this Mac only. ").outfit(12).foregroundStyle(pal.inkMuted)
                    Link("uzu on GitHub", destination: URL(string: "https://github.com/trymirai/uzu")!)
                        .font(Fonts.outfit(12, .medium)).foregroundStyle(pal.accentText)
                    Text(" · ").outfit(12).foregroundStyle(pal.inkMuted)
                    Link("uzu Home", destination: URL(string: "https://github.com/\(SelfUpdater.repo)")!)
                        .font(Fonts.outfit(12, .medium)).foregroundStyle(pal.accentText)
                }
                Muted(text: "uzu Home \(AppModel.version) · unofficial · MIT. Not affiliated with Mirai (the makers of uzu). The window follows the look of StrataHome.")
            }
            .padding(.top, 16)
        }
    }
}

private struct ModelSettingsCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pal) var pal
    @State private var pick = 0
    static let sizes = [16384, 32768, 65536, 131072, 262144]

    var body: some View {
        let now = model.context
        let sizes = (Self.sizes.contains(now) ? Self.sizes : (Self.sizes + [now]).sorted())
        TitledCard(title: "Model settings", trailing: "now \(Fmt.k(Double(now))) tokens",
                   note: "What uzu runs the model with. They are kept in config.env, so uzuctl, the menu bar and Hermes see the same values.") {
            Text("Context length").outfit(13, .medium).foregroundStyle(pal.inkSoft).padding(.top, 16)
            Muted(text: "How much one conversation can hold, prompt plus reply. A longer context keeps more of a long chat or a big file in view and reserves more memory up front: a 9B Qwen3.5 with its speculator takes about 8.4 GB at 32K and 10 GB at 64K.")
                .padding(.top, 4).padding(.bottom, 10)
            Segmented(options: sizes.map { ($0, Fmt.k(Double($0))) }, selection: $pick, fill: false)
            Muted(text: hint(pick, now)).padding(.top, 10)
            HStack(spacing: 10) {
                Button("Save and restart") { model.setContext(pick, restart: true) }.buttonStyle(PrimaryButtonStyle())
                Button("Save for next start") { model.setContext(pick, restart: false) }.buttonStyle(SecondaryButtonStyle())
            }
            .disabled(pick == now || pick == 0)
            .padding(.top, 14)
            Rectangle().fill(pal.lineSoft).frame(height: 1).padding(.vertical, 18)
            ToggleRow(title: "Keep a second conversation",
                      sub: "uzu keeps what it has read of the conversation it is in. With a second one, a short side request (Hermes's chat titles) goes there, so the next turn of a long conversation doesn't read its whole prompt again (about 35 s for Hermes). Costs about 3 GB more at 64K (a 9B model takes about 13 GB instead of 10). Restarts the model.",
                      isOn: Binding(get: { model.sessions >= 2 }, set: { model.setSessions($0 ? 2 : 1) }))
                .padding(.top, -16)
            ToggleRow(title: "Think by default",
                      sub: "Whether a request that doesn't say opens a reasoning block. Off answers sooner. Chat's Sampling drawer sets it per message, and Hermes sends its own. It applies from the next request; no restart.",
                      isOn: Binding(get: { model.thinkingDefault }, set: { model.setThinkingDefault($0) }))
                .padding(.top, -16)
        }
        .onAppear { pick = now }
        .onChange(of: now) { _, v in pick = v }
    }

    func hint(_ n: Int, _ now: Int) -> String {
        guard n > 0 else { return "" }
        var t = "\(Fmt.n(Double(n))) tokens"
        if n < 64000 { t += ". Hermes refuses endpoints under 64,000 tokens" }
        if n > 131072 { t += ". Long contexts need more memory; if the model fails to load, pick a smaller size" }
        if n != now { t += ". Changes from \(Fmt.k(Double(now)))" }
        return t + "."
    }
}

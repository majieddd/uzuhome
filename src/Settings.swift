import Foundation

/// The app's own settings (the backend's live in config.env, which `uzuctl` owns). Kept in
/// ~/Library/Application Support/UzuHome/settings.json.
struct Settings: Codable, Equatable {
    var theme = "system"            // system | light | dark
    var effort = "none"             // thinking: none | low | medium | high (uzu Home starts with it off: faster)
    var temperature = 0.0           // 0 = greedy: always the most likely token
    var topP = 0.95
    var topK = 20
    var maxTokens = ""              // empty = until done
    var seed = ""                   // empty = random
    var showThinking = true
    var autoStart = true            // start the endpoint (and load the model unless "load on first request") when the app opens
    var freeOnQuit = true           // unload the model when the app quits; the endpoint stays for Hermes
    var autoUpdateApp = true        // uzu Home's own releases, checked on startup and every six hours
    var logSource = "engine"        // Server log: engine | gateway | update | convert | app

    static var url: URL { Paths.app.appendingPathComponent("settings.json") }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: url) else { return Settings() }
        return (try? JSONDecoder().decode(Settings.self, from: data)) ?? Settings()
    }

    func save() {
        Paths.ensure()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: Settings.url, options: .atomic) }
    }

    init() {}

    // Missing keys keep their defaults, so a settings file from an older version still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        theme = (try? c.decode(String.self, forKey: .theme)) ?? d.theme
        effort = (try? c.decode(String.self, forKey: .effort)) ?? d.effort
        temperature = (try? c.decode(Double.self, forKey: .temperature)) ?? d.temperature
        topP = (try? c.decode(Double.self, forKey: .topP)) ?? d.topP
        topK = (try? c.decode(Int.self, forKey: .topK)) ?? d.topK
        maxTokens = (try? c.decode(String.self, forKey: .maxTokens)) ?? d.maxTokens
        seed = (try? c.decode(String.self, forKey: .seed)) ?? d.seed
        showThinking = (try? c.decode(Bool.self, forKey: .showThinking)) ?? d.showThinking
        autoStart = (try? c.decode(Bool.self, forKey: .autoStart)) ?? d.autoStart
        freeOnQuit = (try? c.decode(Bool.self, forKey: .freeOnQuit)) ?? d.freeOnQuit
        autoUpdateApp = (try? c.decode(Bool.self, forKey: .autoUpdateApp)) ?? d.autoUpdateApp
        logSource = (try? c.decode(String.self, forKey: .logSource)) ?? d.logSource
    }
}

/// One line of models.conf: key|label|source|model. Source mirai: a model from Mirai's catalog (model = its id; uzu
/// downloads it on the first start). Source local: a folder converted for uzu (model = the folder).
struct ModelEntry: Identifiable, Equatable {
    let key, label, source, ref: String
    var id: String { key }

    var sourceName: String {
        switch source {
        case "mirai": return "Mirai catalog"
        case "local": return "converted for uzu"
        default: return source
        }
    }

    static func load(_ conf: URL = Paths.modelsConf) -> [ModelEntry] {
        guard let text = try? String(contentsOf: conf, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let p = line.components(separatedBy: "|") + ["", "", ""]
            return p[0].isEmpty ? nil : ModelEntry(key: p[0], label: p[1].isEmpty ? p[0] : p[1], source: p[2], ref: p[3])
        }
    }

    /// The folder uzu runs it from: the converted folder, or the checkpoint uzu downloaded into ~/.cache/mirai.
    var folder: URL? {
        if source == "local" { return URL(fileURLWithPath: ref) }
        let base = Paths.home.appendingPathComponent(".cache/mirai/models/mirai/\(ref.replacingOccurrences(of: ":", with: "-"))")
        let fm = FileManager.default
        guard let versions = try? fm.contentsOfDirectory(atPath: base.path).sorted() else { return nil }
        for v in versions.reversed() {
            let d = base.appendingPathComponent(v)
            if fm.fileExists(atPath: d.appendingPathComponent("model.safetensors").path),
               !fm.fileExists(atPath: d.appendingPathComponent("model.safetensors.lock").path) { return d }
        }
        return nil
    }

    /// Size on disk once it is there (downloaded or converted), or nil.
    var cachedBytes: Double? {
        guard let dir = folder, FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path) else { return nil }
        var total = 0.0
        if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let u as URL in e { total += Double((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return total > 0 ? total : nil
    }

    var hasSpeculator: Bool {
        folder.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("speculator/model.safetensors").path) } ?? false
    }

    /// A catalog id as uzu writes them: vendor:family:size[:variant]:mirai:method:bits.
    static func isCatalogID(_ s: String) -> Bool {
        s.range(of: #"^[a-z0-9._-]+(:[a-z0-9._-]+){3,}$"#, options: .regularExpression) != nil
    }

    /// A Hugging Face repo name, owner/name.
    static func isRepo(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+$"#, options: .regularExpression) != nil
    }
}

/// One chat model in Mirai's catalog (`uzuctl catalog`: id|bytes|label).
struct CatalogModel: Identifiable, Hashable {
    let id: String
    let bytes: Double
    let label: String

    static func parse(_ text: String) -> [CatalogModel] {
        text.split(separator: "\n").compactMap { line in
            let p = line.components(separatedBy: "|")
            guard p.count >= 3, ModelEntry.isCatalogID(p[0]) else { return nil }
            return CatalogModel(id: p[0], bytes: Double(p[1]) ?? 0, label: p[2...].joined(separator: "|"))
        }
    }
}

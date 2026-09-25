import Foundation

/// A saved connection profile: one transport + its document(s)/credentials.
/// A Yandex profile can hold SEVERAL documents — they are fanned out into one
/// logical channel on both client and exit (MultiTransport) for more
/// throughput and resilience. The exit node must be configured with the SAME
/// set of documents in the same order.
struct Profile: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var transport: String   // "yandex" | "oneme"
    var urls: [String]      // Yandex document URLs (one or more)
    var maxToken: String    // MAX token (oneme)
    var maxUid: String      // MAX user id (oneme)
    /// App-layer codec; must match the exit's --codec. "legacy" for our
    /// hand-run exits, "batched" for WEB PANEL PROXY (2.4+) exits.
    var codec: String

    init(id: UUID = UUID(), name: String, transport: String = "yandex",
         urls: [String] = [], maxToken: String = "", maxUid: String = "",
         codec: String = "legacy") {
        self.id = id
        self.name = name
        self.transport = transport
        self.urls = urls
        self.maxToken = maxToken
        self.maxUid = maxUid
        self.codec = codec
    }

    var batched: Bool { codec == "batched" }

    // Backward-compatible decode: earlier builds stored a single `url` string.
    private enum CodingKeys: String, CodingKey {
        case id, name, transport, urls, url, maxToken, maxUid, codec
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Профиль"
        transport = (try? c.decode(String.self, forKey: .transport)) ?? "yandex"
        maxToken = (try? c.decode(String.self, forKey: .maxToken)) ?? ""
        maxUid = (try? c.decode(String.self, forKey: .maxUid)) ?? ""
        codec = (try? c.decode(String.self, forKey: .codec)) ?? "legacy"
        if let arr = try? c.decode([String].self, forKey: .urls) {
            urls = arr
        } else if let single = try? c.decode(String.self, forKey: .url) {
            urls = single.isEmpty ? [] : [single]
        } else {
            urls = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(transport, forKey: .transport)
        try c.encode(urls, forKey: .urls)
        try c.encode(maxToken, forKey: .maxToken)
        try c.encode(maxUid, forKey: .maxUid)
        try c.encode(codec, forKey: .codec)
    }

    /// Non-empty, trimmed document URLs.
    var cleanURLs: [String] {
        urls.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Comma-separated URL list passed to the Go layer (splitDocURLs parses it).
    var joinedURLs: String { cleanURLs.joined(separator: ",") }

    /// First URL, for compact one-line display.
    var primaryURL: String { cleanURLs.first ?? "" }

    /// Whether this profile has enough info to connect.
    var isComplete: Bool {
        switch transport {
        case "oneme": return !maxToken.isEmpty && !maxUid.isEmpty
        default:      return !cleanURLs.isEmpty
        }
    }

    /// Short human summary of the transport target for the profile row.
    var subtitle: String {
        let panel = batched ? "панель • " : ""
        if transport == "oneme" { return "\(panel)MAX • uid \(maxUid)" }
        let n = cleanURLs.count
        if n == 0 { return "нет документов" }
        if n == 1 { return panel + primaryURL }
        return "\(panel)\(n) документа • \(primaryURL)"
    }
}

/// Persists the profile list and the current selection in UserDefaults.
@MainActor
final class ProfileStore: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var selectedID: UUID?

    private let profilesKey = "profiles.v1"
    private let selectedKey = "profiles.selected.v1"

    init() { load() }

    var selected: Profile? {
        if let id = selectedID, let p = profiles.first(where: { $0.id == id }) { return p }
        return profiles.first
    }

    func load() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: profilesKey),
           let arr = try? JSONDecoder().decode([Profile].self, from: data) {
            profiles = arr
        }
        if let s = d.string(forKey: selectedKey), let uid = UUID(uuidString: s) {
            selectedID = uid
        }
        if selectedID == nil { selectedID = profiles.first?.id }
    }

    func save() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(profiles) {
            d.set(data, forKey: profilesKey)
        }
        d.set(selectedID?.uuidString, forKey: selectedKey)
    }

    func add(_ p: Profile) {
        profiles.append(p)
        if selectedID == nil { selectedID = p.id }
        save()
    }

    func update(_ p: Profile) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) {
            profiles[i] = p
            save()
        }
    }

    func delete(at offsets: IndexSet) {
        let removed = offsets.map { profiles[$0] }
        profiles.remove(atOffsets: offsets)
        if let sel = selectedID, removed.contains(where: { $0.id == sel }) {
            selectedID = profiles.first?.id
        }
        save()
    }

    func select(_ id: UUID) {
        selectedID = id
        save()
    }
}

import Foundation

/// A saved connection profile: one transport + its document/credentials.
/// Multiple profiles let the user keep several Yandex documents (or a MAX
/// config) and switch between them from the main screen.
struct Profile: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var transport: String   // "yandex" | "oneme"
    var url: String         // Yandex document URL (yandex)
    var maxToken: String    // MAX token (oneme)
    var maxUid: String      // MAX user id (oneme)

    init(id: UUID = UUID(), name: String, transport: String = "yandex",
         url: String = "", maxToken: String = "", maxUid: String = "") {
        self.id = id
        self.name = name
        self.transport = transport
        self.url = url
        self.maxToken = maxToken
        self.maxUid = maxUid
    }

    /// Whether this profile has enough info to connect.
    var isComplete: Bool {
        switch transport {
        case "oneme": return !maxToken.isEmpty && !maxUid.isEmpty
        default:      return !url.trimmingCharacters(in: .whitespaces).isEmpty
        }
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

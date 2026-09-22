import Foundation
import NetworkExtension

/// RU-direct split tunnel. The set of Russian IPv4 ranges that should bypass the
/// VPN and go straight out the physical interface, loaded from the bundled
/// `ru-cidr.txt` (ipdeny aggregated snapshot) and returned as NEIPv4Route routes
/// to add to the tunnel's `excludedRoutes`. Keeping RU domestic traffic off the
/// transport also cuts the load that triggers close-1005 storms on the doc.
enum RussiaRanges {

    /// Parsed RU routes, computed once. Empty if the resource is missing or
    /// unreadable — the caller then simply keeps a full tunnel (fail-safe).
    static let excludedRoutes: [NEIPv4Route] = load()

    private static func load() -> [NEIPv4Route] {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "ru-cidr", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        var routes: [NEIPv4Route] = []
        routes.reserveCapacity(9000)
        text.enumerateLines { line, _ in
            if let r = route(fromCIDR: line) { routes.append(r) }
        }
        return routes
    }

    /// "a.b.c.d/prefix" -> NEIPv4Route(destinationAddress:, subnetMask:).
    /// Returns nil for comment/blank/malformed lines.
    private static func route(fromCIDR raw: String) -> NEIPv4Route? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard let slash = line.firstIndex(of: "/"),
              let prefix = Int(line[line.index(after: slash)...]),
              prefix >= 0, prefix <= 32 else { return nil }
        let addr = String(line[line.startIndex..<slash])
        let octets = addr.split(separator: ".")
        guard octets.count == 4 else { return nil }
        for o in octets {
            guard let v = Int(o), v >= 0, v <= 255 else { return nil }
        }
        return NEIPv4Route(destinationAddress: addr, subnetMask: mask(prefix: prefix))
    }

    /// Prefix length -> dotted subnet mask (22 -> "255.255.252.0").
    private static func mask(prefix: Int) -> String {
        let m: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
        return "\((m >> 24) & 0xff).\((m >> 16) & 0xff).\((m >> 8) & 0xff).\(m & 0xff)"
    }
}

/// Resolves the bundle that contains this class (the extension bundle) so the
/// resource lookup works from inside the appex.
private final class BundleToken {}

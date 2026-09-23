import Foundation
import NetworkExtension
import Combine

/// Installs and controls the system VPN profile backed by the packet-tunnel
/// extension. The transport config (URL / MAX creds) is passed to the extension
/// through the tunnel protocol's providerConfiguration.
@MainActor
final class VPNController: ObservableObject {
    @Published var status: String = "Disconnected"
    @Published var active = false
    /// Diagnostic log pulled from the packet-tunnel extension (separate process).
    @Published var vpnLog: String = ""

    private var manager: NETunnelProviderManager?
    private let extensionBundleId = "com.p1neapplexpress-saharev.openflux.tunnel"
    private var logTimer: Timer?
    /// Whether we've already pulled the full on-disk history this session.
    private var didDumpLog = false
    /// How many VPN configs were loaded (a stale duplicate could mean we hold
    /// the wrong session, so sendProviderMessage would go nowhere).
    private var managerCount = 0
    /// Poll counter, used to rate-limit the app-side channel diagnostics.
    private var polls = 0

    /// App Group shared with the packet-tunnel extension. The extension writes
    /// its diagnostic log to a file in this container; we read it directly,
    /// bypassing the sendProviderMessage IPC channel (which delivered nothing on
    /// the user's signed build — only the app's own "polling" line showed).
    private let appGroup = "group.com.p1neapplexpress-saharev.openflux"
    private lazy var sharedLogURL: URL? = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
        .appendingPathComponent("openflux-diag.log")

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(statusChanged),
            name: .NEVPNStatusDidChange, object: nil)
        Task { await load() }
    }

    private func load() async {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        managerCount = managers.count
        manager = managers.first
        refreshStatus()
    }

    func start(transport: String, url: String, maxToken: String, maxUid: String,
               tunnelUDP: Bool = false, splitTunnelRU: Bool = true) {
        Task {
            let m = manager ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = extensionBundleId
            proto.serverAddress = "OpenFlux"
            proto.providerConfiguration = [
                "transport": transport, "url": url,
                "maxToken": maxToken, "maxUid": maxUid,
                "tunnelUDP": NSNumber(value: tunnelUDP),
                "splitTunnelRU": NSNumber(value: splitTunnelRU),
            ]
            m.protocolConfiguration = proto
            m.localizedDescription = "OpenFlux"
            m.isEnabled = true

            // On-demand: reconnect automatically whenever there is a network,
            // including after the extension tears itself down on a dead
            // transport (see PacketTunnelProvider health monitor). Without this,
            // a dropped tunnel stays dropped until the user reconnects by hand —
            // the main cause of "туннель отваливается".
            let connectRule = NEOnDemandRuleConnect()
            connectRule.interfaceTypeMatch = .any
            m.onDemandRules = [connectRule]
            m.isOnDemandEnabled = true

            do {
                try await m.saveToPreferences()
                try await m.loadFromPreferences()   // required before starting
                self.manager = m
                try m.connection.startVPNTunnel()
            } catch {
                self.status = "Error: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        // Disable on-demand first, otherwise the system immediately reconnects
        // the tunnel and the user can't actually turn it off.
        Task {
            guard let m = manager else { return }
            m.isOnDemandEnabled = false
            do {
                try await m.saveToPreferences()
                try await m.loadFromPreferences()
            } catch {
                self.status = "Error: \(error.localizedDescription)"
            }
            m.connection.stopVPNTunnel()
        }
    }

    @objc private func statusChanged() { refreshStatus() }

    private func refreshStatus() {
        guard let conn = manager?.connection else { active = false; status = "Disconnected"; return }
        switch conn.status {
        case .connected:     status = "Connected";     active = true
        case .connecting:    status = "Connecting…";   active = true
        case .disconnecting: status = "Disconnecting…"; active = true
        case .reasserting:   status = "Reasserting…";  active = true
        default:             status = "Disconnected";  active = false
        }
        // Poll the extension for its diagnostic log while there is a session.
        if conn.status == .disconnected || conn.status == .invalid {
            stopLogPolling()
        } else {
            startLogPolling()
        }
    }

    private func startLogPolling() {
        guard logTimer == nil else { return }
        didDumpLog = false
        polls = 0
        vpnLog = ""     // rebuilt from the extension's on-disk history (logdump)
        appendVPNLog("[app] --- polling extension log --- (managers=\(managerCount), appgroup=\(sharedLogURL == nil ? "NO" : "yes"))")
        logTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pullExtensionLog() }
        }
    }

    private func stopLogPolling() {
        logTimer?.invalidate()
        logTimer = nil
    }

    private func pullExtensionLog() {
        polls += 1
        // Preferred path: read the App Group shared file the extension writes to,
        // directly off disk. No IPC handshake, always current, and it already
        // contains the full persisted history (incl. the PREV SESSION verdict).
        if let url = sharedLogURL {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                let shown = text.count > 200_000 ? String(text.suffix(200_000)) : text
                if shown != vpnLog { vpnLog = shown }
                return
            }
            if polls <= 2 { appendVPNLog("[app] app-group container present but log file empty/missing") }
        }
        // Fallback: legacy sendProviderMessage polling. Instrument every failure
        // mode so the app's OWN (visible) log tells us which link is broken —
        // the extension->app channel itself is the thing under investigation.
        guard let conn = manager?.connection else {
            if polls <= 2 { appendVPNLog("[app] no manager/connection (managers=\(managerCount))") }
            return
        }
        guard let session = conn as? NETunnelProviderSession else {
            if polls <= 2 { appendVPNLog("[app] connection is \(type(of: conn)), not NETunnelProviderSession") }
            return
        }
        let cmd = didDumpLog ? "log" : "logdump"
        do {
            try session.sendProviderMessage(Data(cmd.utf8)) { [weak self] resp in
                Task { @MainActor in
                    guard let self = self else { return }
                    if let resp = resp, let s = String(data: resp, encoding: .utf8), !s.isEmpty {
                        self.appendVPNLog(s)
                    } else if self.polls <= 3 {
                        self.appendVPNLog("[app] IPC responded but empty (bytes=\(resp?.count ?? -1))")
                    }
                }
            }
            if cmd == "logdump" { didDumpLog = true }
        } catch {
            if polls <= 3 { appendVPNLog("[app] sendProviderMessage threw: \(error.localizedDescription)") }
        }
    }

    private func appendVPNLog(_ s: String) {
        vpnLog += (vpnLog.isEmpty ? "" : "\n") + s
        if vpnLog.count > 200_000 {
            vpnLog = String(vpnLog.suffix(200_000))
        }
    }
}

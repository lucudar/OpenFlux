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
    /// Flag written by the extension when the user switches the VPN off from
    /// iOS (Settings / Control Center); see PacketTunnelProvider.userOffKey.
    private let shared = UserDefaults(suiteName: "group.com.p1neapplexpress-saharev.openflux")
    private let userOffKey = "userSwitchedOff"
    private var userSwitchedOff: Bool { shared?.bool(forKey: userOffKey) ?? false }
    private var disarming = false

    private lazy var sharedLogURL: URL? = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
        .appendingPathComponent("openflux-diag.log")

    /// On-demand is armed: iOS will (re)launch the tunnel by itself. While
    /// armed the VPN counts as "on" for the UI even in the gaps between
    /// relaunches, so a tap in such a gap turns it OFF instead of re-starting it
    /// (the old button read only the momentary status and flipped back on).
    @Published var armed = false
    /// A user-requested stop is in flight; the button ignores taps meanwhile.
    @Published var stopping = false

    /// The VPN is on from the user's point of view (connected, connecting,
    /// or armed to reconnect).
    var isOn: Bool { !stopping && (active || armed) }

    /// When the current session reached "connected" (for the session timer).
    var connectedDate: Date? { manager?.connection.connectedDate }

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(statusChanged),
            name: .NEVPNStatusDidChange, object: nil)
        // Turning the VPN off in iOS Settings disables on-demand behind our
        // back; reload so `armed` doesn't stay stale.
        NotificationCenter.default.addObserver(
            self, selector: #selector(configChanged),
            name: .NEVPNConfigurationChange, object: nil)
        Task { await load() }
    }

    /// Loads our VPN configuration. An app only sees the configurations it
    /// created, so every manager here is ours; extras are stale duplicates
    /// (e.g. from reinstalls) that keep their own on-demand rules and can
    /// relaunch the tunnel after we "stopped" the other one — remove them.
    private func load() async {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        managerCount = managers.count
        manager = managers.first
        for extra in managers.dropFirst() {
            extra.isOnDemandEnabled = false
            try? await extra.saveToPreferences()
            extra.connection.stopVPNTunnel()
            try? await extra.removeFromPreferences()
        }
        refreshStatus()
    }

    struct Options {
        var tunnelUDP = false
        var splitTunnelRU = true
        var bypassLAN = true
        var autoReconnect = true
        var disconnectOnSleep = false
        var deadGrace = 45
        var batched = false
    }

    func start(transport: String, url: String, maxToken: String, maxUid: String,
               options o: Options) {
        guard !stopping else { return }
        armed = o.autoReconnect
        // Cleared before on-demand is re-armed, or the extension would refuse
        // an on-demand launch that races our own start.
        shared?.set(false, forKey: userOffKey)
        Task {
            if manager == nil { await load() }
            let m = manager ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = extensionBundleId
            proto.serverAddress = "OpenFlux"
            proto.disconnectOnSleep = o.disconnectOnSleep
            proto.providerConfiguration = [
                "transport": transport, "url": url,
                "maxToken": maxToken, "maxUid": maxUid,
                "tunnelUDP": NSNumber(value: o.tunnelUDP),
                "splitTunnelRU": NSNumber(value: o.splitTunnelRU),
                "bypassLAN": NSNumber(value: o.bypassLAN),
                "deadGrace": NSNumber(value: o.deadGrace),
                "batched": NSNumber(value: o.batched),
            ]
            m.protocolConfiguration = proto
            m.localizedDescription = "OpenFlux"
            m.isEnabled = true

            // On-demand (optional): iOS relaunches the tunnel whenever there
            // is a network, incl. after the extension tears itself down on a
            // dead transport (PacketTunnelProvider health monitor).
            let connectRule = NEOnDemandRuleConnect()
            connectRule.interfaceTypeMatch = .any
            m.onDemandRules = [connectRule]
            m.isOnDemandEnabled = o.autoReconnect

            do {
                try await m.saveToPreferences()
                try await m.loadFromPreferences()   // required before starting
                self.manager = m
                try m.connection.startVPNTunnel()
            } catch {
                self.armed = false
                self.status = "Error: \(error.localizedDescription)"
            }
            refreshStatus()
        }
    }

    /// Turns the VPN fully off. On-demand is disarmed and SAVED before the
    /// stop, otherwise iOS immediately relaunches the tunnel.
    func stop() {
        guard !stopping else { return }
        stopping = true
        armed = false
        Task {
            // Fresh copies: the cached manager may be stale or missing.
            let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
            for m in managers {
                if m.isOnDemandEnabled {
                    m.isOnDemandEnabled = false
                    do { try await m.saveToPreferences() } catch {
                        self.status = "Error: \(error.localizedDescription)"
                    }
                }
                m.connection.stopVPNTunnel()
            }
            if let first = managers.first { manager = first }
            // A relaunch that was already in flight when on-demand got disarmed
            // can still come up; wait for it to settle and stop it again.
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let live = managers.filter {
                    let st = $0.connection.status
                    return st != .disconnected && st != .invalid
                }
                if live.isEmpty { break }
                live.forEach { $0.connection.stopVPNTunnel() }
            }
            stopping = false
            refreshStatus()
        }
    }

    /// The user switched the VPN off from iOS while on-demand was armed: the
    /// extension refuses the relaunches, and here we disarm on-demand for good
    /// so iOS stops trying and the app shows "off".
    private func disarmAfterSystemStop() {
        guard !disarming, !stopping, let m = manager, m.isOnDemandEnabled else { return }
        disarming = true
        Task {
            m.isOnDemandEnabled = false
            try? await m.saveToPreferences()
            disarming = false
            refreshStatus()
        }
    }

    /// Removes the iOS VPN configuration entirely (Settings → VPN entry).
    /// Fixes a stale/duplicate profile without reinstalling the app; the
    /// next connect creates a fresh one.
    func resetConfiguration() {
        stopping = true
        armed = false
        Task {
            let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
            for m in managers {
                m.isOnDemandEnabled = false
                try? await m.saveToPreferences()
                m.connection.stopVPNTunnel()
                try? await m.removeFromPreferences()
            }
            manager = nil
            managerCount = 0
            stopping = false
            refreshStatus()
        }
    }

    /// Clears the extension's persisted diagnostic log and the on-screen copy.
    func clearLog() {
        vpnLog = ""
        if let url = sharedLogURL { try? FileManager.default.removeItem(at: url) }
        if let session = manager?.connection as? NETunnelProviderSession {
            try? session.sendProviderMessage(Data("clearlog".utf8)) { _ in }
        }
    }

    @objc private func statusChanged() { refreshStatus() }

    @objc private func configChanged() {
        Task { @MainActor in
            try? await manager?.loadFromPreferences()
            refreshStatus()
        }
    }

    private func refreshStatus() {
        if !stopping { armed = (manager?.isOnDemandEnabled ?? false) && !userSwitchedOff }
        guard let conn = manager?.connection else { active = false; status = "Disconnected"; return }
        if conn.status == .disconnected && userSwitchedOff { disarmAfterSystemStop() }
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

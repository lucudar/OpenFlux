import NetworkExtension
import os

/// System VPN entry point. Bridges the device's IP packets to the OpenFlux Go
/// tun2socks stack (TCP forwarded through the transport; DNS proxied over TCP).
class PacketTunnelProvider: NEPacketTunnelProvider {

    /// Networks that must NOT go through the tunnel: the Yandex backend the
    /// transport talks to, plus the DoT DNS resolvers. Otherwise the
    /// extension's own traffic loops back into itself.
    static let bypassRoutes: [NEIPv4Route] = {
        let cidrs: [(String, String)] = [
            ("5.45.192.0", "255.255.192.0"),
            ("5.255.192.0", "255.255.192.0"),
            ("37.9.64.0", "255.255.192.0"),
            ("37.140.128.0", "255.255.192.0"),
            ("77.88.0.0", "255.255.192.0"),
            ("84.201.128.0", "255.255.192.0"),
            ("87.250.224.0", "255.255.224.0"),
            ("90.156.176.0", "255.255.252.0"),
            ("93.158.128.0", "255.255.192.0"),
            ("95.108.128.0", "255.255.128.0"),
            ("100.43.64.0", "255.255.224.0"),
            ("178.154.128.0", "255.255.128.0"),
            ("213.180.192.0", "255.255.224.0"),
            // DoT DNS resolvers used by the Go client.
            ("8.8.8.8", "255.255.255.255"),
            ("1.1.1.1", "255.255.255.255"),
        ]
        return cidrs.map { NEIPv4Route(destinationAddress: $0.0, subnetMask: $0.1) }
    }()


    /// Serial queue guarding the health monitor timer.
    private let monitorQueue = DispatchQueue(label: "com.openflux.tunnel.monitor")
    /// Separate queue for the diagnostic log so it is never blocked by the
    /// connection-wait loop (which sleeps on monitorQueue for up to 25s) — that
    /// is why the app previously saw only "polling" lines and no extension log.
    private let logQueue = DispatchQueue(label: "com.openflux.tunnel.log")
    private var healthTimer: DispatchSourceTimer?
    /// Wall-clock instant the transport was last seen connected. Used to decide
    /// when a disconnect has lasted long enough to tear the tunnel down.
    private var lastConnected = Date()
    /// How long the transport may stay disconnected before we give up on the
    /// in-process reconnect and hand control back to the system (on-demand then
    /// relaunches the extension fresh). The Go transport reconnects with backoff
    /// on its own; this is the outer safety net for a wedged session.
    private let deadTransportGrace: TimeInterval = 45

    // ---- diagnostic log, pulled by the app over handleAppMessage ----
    // The extension is a separate process, so its logs aren't visible in the
    // app UI. We keep a small always-on ring of lifecycle/health/memory events
    // that the app polls and displays, to diagnose reconnects and memory kills.
    private var diagLines: [String] = []
    private var lastConnState = false
    private var healthTick = 0

    private func diag(_ s: String) {
        let ts = Self.ts()
        logQueue.async {
            self.diagLines.append("\(ts) [EXT] \(s)")
            if self.diagLines.count > 400 {
                self.diagLines.removeFirst(self.diagLines.count - 400)
            }
        }
    }

    private static func ts() -> String {
        let d = Date()
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    /// Bytes the extension may still allocate before iOS kills it. Near-zero
    /// right before a restart is the signature of a memory kill.
    private func availMemMB() -> Int {
        return Int(os_proc_available_memory() / (1024 * 1024))
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let conf = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        let transport = (conf["transport"] as? String) ?? "yandex"
        let url = (conf["url"] as? String) ?? ""
        let maxToken = (conf["maxToken"] as? String) ?? ""
        let maxUid = (conf["maxUid"] as? String) ?? ""
        // Forward non-DNS UDP (QUIC) over the transport. Off by default; only
        // enable against a UDP-capable exit node.
        let tunnelUDP = ((conf["tunnelUDP"] as? NSNumber)?.boolValue) ?? false
        // RU-direct split tunnel: route Russian IP ranges outside the VPN (out
        // the physical interface), everything else through it. Also cuts the
        // number of flows on the doc transport, which is what triggers the
        // close-1005 storms under heavy load.
        let splitTunnelRU = ((conf["splitTunnelRU"] as? NSNumber)?.boolValue) ?? false

        // Turn on Go-side verbose logging in THIS (extension) process so the
        // app can pull transport reconnect events via handleAppMessage. The
        // yandex client path logs only connect/reconnect, not per-packet.
        OpenFluxSetDebug(1)
        diag("startTunnel transport=\(transport) udp=\(tunnelUDP) splitRU=\(splitTunnelRU) availMem=\(availMemMB())MB")

        // Virtual interface: capture all IPv4 + all DNS.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        // 10.10.10.2 is the address the exit node expects the client to use
        // (it hardcodes return packets to 10.10.10.2), enabling pure L3
        // forwarding with no gvisor stack in the extension.
        let ipv4 = NEIPv4Settings(addresses: ["10.10.10.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        // Exclude the transport's own backend (Yandex ranges) and the DoT DNS
        // servers so the extension's own connections bypass the tunnel instead
        // of looping back into it.
        var excluded = Self.bypassRoutes
        if splitTunnelRU {
            let ru = RussiaRanges.excludedRoutes
            excluded += ru
            diag("split-tunnel RU on: \(ru.count) RU ranges bypass the VPN (direct)")
        }
        ipv4.excludedRoutes = excluded
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        // A benign in-tunnel DNS address: queries to it are captured and
        // answered locally over DoT (the real resolvers are excluded above).
        let dns = NEDNSSettings(servers: ["198.18.0.1"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                completionHandler(error)
                return
            }
            let rc = transport.withCString { tt in
                url.withCString { u in
                    maxToken.withCString { tok in
                        maxUid.withCString { uid in
                            OpenFluxStartPacketTunnel(
                                UnsafeMutablePointer(mutating: tt),
                                UnsafeMutablePointer(mutating: u),
                                UnsafeMutablePointer(mutating: tok),
                                UnsafeMutablePointer(mutating: uid),
                                Int32(tunnelUDP ? 1 : 0))
                        }
                    }
                }
            }
            if rc != 0 {
                completionHandler(NSError(domain: "OpenFlux", code: Int(rc),
                    userInfo: [NSLocalizedDescriptionKey: "start failed (\(rc))"]))
                return
            }
            // Pump packets immediately: the transport reconnects in the
            // background, so packets can start flowing the moment it is up.
            self.startReadLoop()
            self.startWriteLoop()

            // Don't report success until the transport has actually connected.
            // OpenFluxStartPacketTunnel returns as soon as the connect goroutine
            // is spawned, so reporting success here (as before) made iOS show
            // "Connected" with no working link. Poll for a real connection with
            // a bounded timeout instead.
            self.waitForConnection(timeout: 25) { connected in
                if connected {
                    self.lastConnected = Date()
                    self.lastConnState = true
                    self.diag("transport connected; tunnel up")
                    self.startHealthMonitor()
                    completionHandler(nil)
                } else {
                    // Never came up within the window. Tear down and report the
                    // failure so the UI shows a real error and on-demand can
                    // retry from a clean slate instead of a half-open tunnel.
                    self.diag("transport did NOT connect within 25s; failing start")
                    OpenFluxStopPacketTunnel()
                    completionHandler(NSError(domain: "OpenFlux", code: -1001,
                        userInfo: [NSLocalizedDescriptionKey: "transport did not connect in time"]))
                }
            }
        }
    }

    /// Polls the Go transport's connection status until it reports connected or
    /// the timeout elapses. Runs off the main path; `done` is called once.
    private func waitForConnection(timeout: TimeInterval, done: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        monitorQueue.async {
            while Date() < deadline {
                if OpenFluxPacketTunnelConnected() != 0 {
                    done(true)
                    return
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            done(OpenFluxPacketTunnelConnected() != 0)
        }
    }

    /// Watches the transport after a successful start. If it stays disconnected
    /// past `deadTransportGrace`, cancels the tunnel so the system (on-demand)
    /// relaunches the extension fresh — the fix for the "connected but no
    /// traffic" zombie state.
    private func startHealthMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let connected = OpenFluxPacketTunnelConnected() != 0
            // Log every ~15s (every 3rd tick) plus on any state change, so the
            // memory trend is visible without flooding.
            self.healthTick += 1
            if connected != self.lastConnState || self.healthTick % 3 == 0 {
                self.diag("health connected=\(connected) availMem=\(self.availMemMB())MB")
            }
            self.lastConnState = connected
            if connected {
                self.lastConnected = Date()
                return
            }
            if Date().timeIntervalSince(self.lastConnected) > self.deadTransportGrace {
                self.diag("transport lost >\(Int(self.deadTransportGrace))s; tearing down for relaunch")
                self.stopHealthMonitor()
                OpenFluxStopPacketTunnel()
                // A non-nil error makes the system re-evaluate on-demand rules
                // and relaunch the tunnel, rather than leaving it stopped.
                self.cancelTunnelWithError(NSError(domain: "OpenFlux", code: -1002,
                    userInfo: [NSLocalizedDescriptionKey: "transport lost; relaunching"]))
            }
        }
        healthTimer = timer
        timer.resume()
    }

    private func stopHealthMonitor() {
        healthTimer?.cancel()
        healthTimer = nil
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        diag("stopTunnel reason=\(reason.rawValue) availMem=\(availMemMB())MB")
        stopHealthMonitor()
        OpenFluxStopPacketTunnel()
        completionHandler()
    }

    /// The app polls this to pull the extension's diagnostic log (it runs in a
    /// separate process, so the log is invisible to the app otherwise). Also
    /// drains the Go-side log ring when verbose logging is on.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        logQueue.async {
            var out = self.diagLines
            self.diagLines.removeAll(keepingCapacity: true)
            // Append any Go-side lines (transport reconnects etc.) if present.
            if let c = OpenFluxReadLog() {
                let s = String(cString: c)
                OpenFluxFreeString(c)
                if !s.isEmpty {
                    for line in s.split(separator: "\n") { out.append(String(line)) }
                }
            }
            let joined = out.joined(separator: "\n")
            completionHandler?(joined.isEmpty ? Data() : Data(joined.utf8))
        }
    }

    /// Device -> Go stack.
    private func startReadLoop() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self = self else { return }
            for p in packets {
                p.withUnsafeBytes { raw in
                    if let base = raw.bindMemory(to: CChar.self).baseAddress {
                        OpenFluxTunWritePacket(UnsafeMutablePointer(mutating: base), Int32(p.count))
                    }
                }
            }
            self.startReadLoop()
        }
    }

    /// Go stack -> device.
    private func startWriteLoop() {
        DispatchQueue.global(qos: .userInitiated).async {
            let maxLen: Int32 = 4096
            let buf = UnsafeMutablePointer<CChar>.allocate(capacity: Int(maxLen))
            defer { buf.deallocate() }
            while true {
                let n = OpenFluxTunReadPacket(buf, maxLen)
                if n <= 0 { break }
                let data = Data(bytes: buf, count: Int(n))
                self.packetFlow.writePackets([data], withProtocols: [NSNumber(value: AF_INET)])
            }
        }
    }
}

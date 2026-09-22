import NetworkExtension

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
    private var healthTimer: DispatchSourceTimer?
    /// Wall-clock instant the transport was last seen connected. Used to decide
    /// when a disconnect has lasted long enough to tear the tunnel down.
    private var lastConnected = Date()
    /// How long the transport may stay disconnected before we give up on the
    /// in-process reconnect and hand control back to the system (on-demand then
    /// relaunches the extension fresh). The Go transport reconnects with backoff
    /// on its own; this is the outer safety net for a wedged session.
    private let deadTransportGrace: TimeInterval = 45

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let conf = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        let transport = (conf["transport"] as? String) ?? "yandex"
        let url = (conf["url"] as? String) ?? ""
        let maxToken = (conf["maxToken"] as? String) ?? ""
        let maxUid = (conf["maxUid"] as? String) ?? ""
        // Forward non-DNS UDP (QUIC) over the transport. Off by default; only
        // enable against a UDP-capable exit node.
        let tunnelUDP = ((conf["tunnelUDP"] as? NSNumber)?.boolValue) ?? false

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
        ipv4.excludedRoutes = Self.bypassRoutes
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
                    self.startHealthMonitor()
                    completionHandler(nil)
                } else {
                    // Never came up within the window. Tear down and report the
                    // failure so the UI shows a real error and on-demand can
                    // retry from a clean slate instead of a half-open tunnel.
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
            if OpenFluxPacketTunnelConnected() != 0 {
                self.lastConnected = Date()
                return
            }
            if Date().timeIntervalSince(self.lastConnected) > self.deadTransportGrace {
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
        stopHealthMonitor()
        OpenFluxStopPacketTunnel()
        completionHandler()
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

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
    /// Overridable from the app ("deadGrace" in providerConfiguration).
    private var deadTransportGrace: TimeInterval = 45

    /// Private LAN / link-local ranges, kept off the tunnel when "bypassLAN"
    /// is on (router admin page, printers, AirPlay, local file shares).
    /// 10/8 is left out: it contains our own 10.10.10.2 tunnel address.
    static let lanRoutes: [NEIPv4Route] = {
        let cidrs: [(String, String)] = [
            ("172.16.0.0", "255.240.0.0"),
            ("192.168.0.0", "255.255.0.0"),
            ("169.254.0.0", "255.255.0.0"),
            ("224.0.0.0", "240.0.0.0"),
        ]
        return cidrs.map { NEIPv4Route(destinationAddress: $0.0, subnetMask: $0.1) }
    }()

    // ---- diagnostic log, pulled by the app over handleAppMessage ----
    // The extension is a separate process, so its logs aren't visible in the
    // app UI. We keep a small always-on ring of lifecycle/health/memory events
    // that the app polls and displays, to diagnose reconnects and memory kills.
    private var diagLines: [String] = []
    private var lastConnState = false
    private var healthTick = 0
    private var persistWrites = 0

    /// App Group shared by the app + this extension, so the app can read the
    /// diagnostic log DIRECTLY off disk. The sendProviderMessage IPC channel
    /// proved unreliable on the user's signed build (only the app's own
    /// "polling" line ever appeared, never an [EXT] line), so we no longer
    /// depend on it for the log.
    static let appGroup = "group.com.p1neapplexpress-saharev.openflux"

    /// Set when the user switches the VPN off (iOS Settings, the Control
    /// Center VPN toggle or our own button). On-demand would otherwise bring
    /// the tunnel straight back, so on-demand relaunches are refused until the
    /// user starts it again by hand. Shared with the app, which also disarms
    /// on-demand once it sees the flag.
    static let userOffKey = "userSwitchedOff"
    static let shared = UserDefaults(suiteName: appGroup) ?? .standard

    /// Persistent diagnostic log file (survives extension process restarts, so
    /// an iOS memory-kill no longer erases the evidence of why we died).
    /// Prefer the App Group container (readable by the main app); fall back to
    /// the extension's private Caches if the group is somehow unavailable.
    private lazy var diagFileURL: URL? = {
        let fm = FileManager.default
        if let g = fm.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) {
            return g.appendingPathComponent("openflux-diag.log")
        }
        return fm.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("openflux-diag.log")
    }()

    private func diag(_ s: String) {
        let line = "\(Self.ts()) [EXT] \(s)"
        logQueue.async {
            self.diagLines.append(line)
            if self.diagLines.count > 1200 {
                self.diagLines.removeFirst(self.diagLines.count - 1200)
            }
            self.persist(line)
        }
    }

    /// Append one line to the persistent file. logQueue-only (serial).
    private func persist(_ line: String) {
        guard let url = diagFileURL else { return }
        let data = Data((line + "\n").utf8)
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
        persistWrites += 1
        if persistWrites % 64 == 0 { rotateIfNeeded() }
    }

    /// Keep the persistent log bounded (trim to the last ~128 KB past 256 KB).
    private func rotateIfNeeded() {
        guard let url = diagFileURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue, size > 262_144,
              let data = try? Data(contentsOf: url) else { return }
        try? data.suffix(131_072).write(to: url)
    }

    /// Read the PREVIOUS session's persisted log and emit a one-line verdict on
    /// how it ended — the storm-vs-memory discriminator that a wiped in-memory
    /// ring couldn't give us. Scans only from the last `startTunnel` marker.
    private func logPreviousSessionSummary() {
        guard let url = diagFileURL,
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else {
            diag("no previous-session log (fresh install)")
            return
        }
        let scope: Substring
        if let r = text.range(of: "startTunnel", options: .backwards) {
            let ls = text[..<r.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            scope = text[ls...]
        } else {
            scope = text[...]
        }
        var minMem = Int.max
        for l in scope.split(separator: "\n") {
            guard let r = l.range(of: "availMem=") else { continue }
            let num = l[r.upperBound...].prefix { $0.isNumber }
            if let v = Int(num) { minMem = min(minMem, v) }
        }
        func has(_ s: String) -> Bool { scope.range(of: s) != nil }
        let verdict: String
        if has("tearing down for relaunch") {
            verdict = "transport lost > grace -> teardown (LOAD/storm)"
        } else if has("did NOT connect") {
            verdict = "transport never connected"
        } else if has("stopTunnel reason=") {
            verdict = "clean stopTunnel (user/system)"
        } else {
            verdict = "NO stop line -> KILLED (memory/jetsam or crash)"
        }
        let mem = minMem == Int.max ? "?" : "\(minMem)"
        diag("=== PREV SESSION: \(verdict); minAvailMem=\(mem)MB ===")
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
        let onDemand = (options?["is-on-demand"] as? NSNumber)?.boolValue ?? false
        if onDemand && Self.shared.bool(forKey: Self.userOffKey) {
            diag("on-demand relaunch refused: VPN was switched off by the user")
            completionHandler(NSError(domain: "OpenFlux", code: -1003,
                userInfo: [NSLocalizedDescriptionKey: "switched off by the user"]))
            return
        }
        Self.shared.set(false, forKey: Self.userOffKey)
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
        let bypassLAN = ((conf["bypassLAN"] as? NSNumber)?.boolValue) ?? true
        // Codec must match the exit: batched for WEB PANEL PROXY exits.
        let batched = ((conf["batched"] as? NSNumber)?.boolValue) ?? false
        if let g = (conf["deadGrace"] as? NSNumber)?.doubleValue, g >= 15 {
            deadTransportGrace = g
        }

        // Turn on Go-side verbose logging in THIS (extension) process so the
        // app can pull transport reconnect events via handleAppMessage. The
        // yandex client path logs only connect/reconnect, not per-packet.
        OpenFluxSetDebug(1)
        logPreviousSessionSummary()
        OpenFluxSetCodec(batched ? 1 : 0)
        diag("startTunnel transport=\(transport) codec=\(batched ? "batched" : "legacy") udp=\(tunnelUDP) splitRU=\(splitTunnelRU) lan=\(bypassLAN) grace=\(Int(deadTransportGrace))s availMem=\(availMemMB())MB")

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
        if bypassLAN {
            excluded += Self.lanRoutes
        }
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
        // 10s cadence with generous leeway so iOS can coalesce the wake-up
        // with other work: a 3s timer plus a log write per tick kept the CPU
        // waking all day and was a big battery cost. Dead-link detection still
        // lands well inside deadTransportGrace (>= 15s).
        timer.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(3))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let connected = OpenFluxPacketTunnelConnected() != 0
            let mem = self.availMemMB()
            self.healthTick += 1
            // Log on a state change, when memory runs low, and otherwise once
            // every ~5 min: a file write per tick was pure battery cost.
            if connected != self.lastConnState || mem < 20 || self.healthTick % 30 == 0 {
                self.diag("health connected=\(connected) availMem=\(mem)MB tick=\(self.healthTick)")
            }
            if mem < 12 {
                self.diag("LOW MEMORY availMem=\(mem)MB — near iOS extension kill threshold")
            }
            self.drainGoLog()
            self.lastConnState = connected
            if connected {
                self.lastConnected = Date()
                return
            }
            let down = Int(Date().timeIntervalSince(self.lastConnected))
            self.diag("transport DOWN for \(down)s (grace \(Int(self.deadTransportGrace))s)")
            if Double(down) > self.deadTransportGrace {
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

    /// Drain the Go-side log ring into the diagnostic stream (so transport
    /// reconnect events get persisted too). Single drain point — the app poll
    /// no longer reads the Go log, which would race with this one.
    private func drainGoLog() {
        guard let c = OpenFluxReadLog() else { return }
        let s = String(cString: c)
        OpenFluxFreeString(c)
        guard !s.isEmpty else { return }
        for line in s.split(separator: "\n") { self.diag("[go] \(line)") }
    }

    private func stopHealthMonitor() {
        healthTimer?.cancel()
        healthTimer = nil
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        diag("stopTunnel reason=\(reason.rawValue) availMem=\(availMemMB())MB")
        if reason == .userInitiated {
            Self.shared.set(true, forKey: Self.userOffKey)
        }
        stopHealthMonitor()
        OpenFluxStopPacketTunnel()
        completionHandler()
    }

    /// The app polls this to pull the extension's diagnostic log.
    ///  - "logdump": the full on-disk history (survives restarts) — sent once
    ///    per connection so the app sees what happened before the last kill.
    ///  - "log": drains the in-memory ring of new lines (Go transport lines are
    ///    folded in by the health monitor's drainGoLog).
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let cmd = String(data: messageData, encoding: .utf8) ?? "log"
        logQueue.async {
            if cmd == "clearlog" {
                self.diagLines.removeAll(keepingCapacity: true)
                if let url = self.diagFileURL { try? Data().write(to: url) }
                completionHandler?(Data())
                return
            }
            if cmd == "logdump" {
                var text = ""
                if let url = self.diagFileURL,
                   let f = try? String(contentsOf: url, encoding: .utf8) { text = f }
                // Clear the in-memory ring so the following "log" polls return
                // only NEW lines (no duplication with the dump just returned).
                self.diagLines.removeAll(keepingCapacity: true)
                completionHandler?(Data(text.utf8))
                return
            }
            let out = self.diagLines
            self.diagLines.removeAll(keepingCapacity: true)
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

    /// Go stack -> device. Blocks for the first packet, then drains whatever
    /// else is already queued so iOS gets one writePackets call per burst
    /// instead of one per packet (each call is a syscall into the kernel).
    private func startWriteLoop() {
        DispatchQueue.global(qos: .userInitiated).async {
            let maxLen: Int32 = 4096
            let maxBatch = 64
            let buf = UnsafeMutablePointer<CChar>.allocate(capacity: Int(maxLen))
            defer { buf.deallocate() }
            let proto = NSNumber(value: AF_INET)
            var packets: [Data] = []
            var protos: [NSNumber] = []
            packets.reserveCapacity(maxBatch)
            protos.reserveCapacity(maxBatch)
            while true {
                let n = OpenFluxTunReadPacket(buf, maxLen)
                if n <= 0 { break }
                packets.append(Data(bytes: buf, count: Int(n)))
                protos.append(proto)
                while packets.count < maxBatch {
                    let m = OpenFluxTunTryReadPacket(buf, maxLen)
                    if m <= 0 { break }
                    packets.append(Data(bytes: buf, count: Int(m)))
                    protos.append(proto)
                }
                self.packetFlow.writePackets(packets, withProtocols: protos)
                packets.removeAll(keepingCapacity: true)
                protos.removeAll(keepingCapacity: true)
            }
        }
    }
}

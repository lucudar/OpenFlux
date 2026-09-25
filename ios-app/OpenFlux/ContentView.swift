import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var store = ProfileStore()
    @StateObject private var tunnel = TunnelController()
    @StateObject private var vpn = VPNController()

    @State private var showSettings = false
    @State private var showInfo = false
    @State private var rotate = false
    @State private var pulse = false
    @State private var flow: CGFloat = 0
    @AppStorage("tunnelUDP") private var tunnelUDP: Bool = false
    @AppStorage("splitTunnelRU") private var splitTunnelRU: Bool = true
    @AppStorage("bypassLAN") private var bypassLAN: Bool = true
    @AppStorage("autoReconnect") private var autoReconnect: Bool = true
    @AppStorage("disconnectOnSleep") private var disconnectOnSleep: Bool = false
    @AppStorage("deadGrace") private var deadGrace: Int = 45

    private var selected: Profile? { store.selected }
    private var canConnect: Bool { selected?.isComplete ?? false }
    private var isConnected: Bool { vpn.isOn && vpn.status == "Connected" }
    /// Connecting, or armed on-demand waiting to relaunch — still "on".
    private var isConnecting: Bool { vpn.isOn && vpn.status != "Connected" }
    private var buttonDisabled: Bool { vpn.stopping || (!vpn.isOn && !canConnect) }

    private enum Phase { case off, connecting, connected, stopping }
    private var phase: Phase {
        if vpn.stopping { return .stopping }
        if isConnected { return .connected }
        if isConnecting { return .connecting }
        return .off
    }

    /// Accent colour reflects the tunnel state at a glance.
    private var accent: Color {
        switch phase {
        case .connected: return Theme.teal
        case .connecting, .stopping: return Theme.amber
        case .off: return Theme.violet
        }
    }

    private var orbColors: [Color] {
        switch phase {
        case .connected: return [Theme.teal, Theme.sky]
        case .connecting, .stopping: return [Theme.amber, Theme.coral]
        case .off: return [Theme.violet.opacity(0.55), Theme.indigo]
        }
    }

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    header
                    orb
                        .padding(.top, 8)
                    statusBlock
                    profileCard
                    routingCard
                    checkCard
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { rotate = true }
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true }
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { flow = 2 * .pi }
        }
        .onChange(of: vpn.isOn) { _ in tunnel.check = .idle }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store, tunnel: tunnel, vpn: vpn)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showInfo) {
            InfoView().preferredColorScheme(.dark)
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            LogoMark()
                .frame(width: 30, height: 30)
            Text("OpenFlux")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundColor(.white)
            Spacer()
            headerButton("info.circle") { showInfo = true }
            headerButton("gearshape.fill") { showSettings = true }
        }
    }

    private func headerButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        }
    }

    // MARK: connect orb

    private let orbSize: CGFloat = 196

    private var orb: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            toggle()
        } label: {
            ZStack {
                // Soft halo.
                Circle()
                    .fill(RadialGradient(colors: [accent.opacity(phase == .off ? 0.25 : 0.55), .clear],
                                         center: .center, startRadius: orbSize * 0.3, endRadius: orbSize * 0.85))
                    .frame(width: orbSize * 1.7, height: orbSize * 1.7)

                // Expanding pulse rings while connecting.
                ForEach(0..<2) { i in
                    Circle()
                        .stroke(accent, lineWidth: 2)
                        .frame(width: orbSize, height: orbSize)
                        .scaleEffect(pulse ? 1.45 : 1.0)
                        .opacity(phase == .connecting ? (pulse ? 0 : 0.7) : 0)
                        .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)
                                    .delay(Double(i) * 0.9), value: pulse)
                }

                // Orbit ring: bright arc that circles slowly (fast while connecting).
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 3)
                    .frame(width: orbSize + 28, height: orbSize + 28)
                Circle()
                    .trim(from: 0, to: phase == .off ? 0.0 : (phase == .connected ? 1.0 : 0.28))
                    .stroke(LinearGradient(colors: [accent, Theme.cyan], startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: orbSize + 28, height: orbSize + 28)
                    .rotationEffect(.degrees(rotate ? 360 : 0))

                // Core.
                Circle()
                    .fill(LinearGradient(colors: orbColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: orbSize, height: orbSize)
                    .overlay(
                        Circle()
                            .fill(LinearGradient(colors: [Color.white.opacity(0.28), .clear],
                                                 startPoint: .top, endPoint: .center))
                            .padding(6))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1.5))
                    .shadow(color: accent.opacity(0.55), radius: phase == .off ? 10 : 28)

                // Flowing ribbon inside the orb when connected.
                WaveShape(amplitude: 0.09, yOffset: 0.2, phase: flow, cycles: 1.5)
                    .stroke(Color.white.opacity(phase == .connected ? 0.30 : 0),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: orbSize * 0.62, height: orbSize)

                Image(systemName: phase == .connected ? "checkmark.shield.fill" : "power")
                    .font(.system(size: 58, weight: .semibold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    .offset(y: -6)
            }
            .frame(width: orbSize + 40, height: orbSize + 64)
            .contentShape(Circle().scale(0.6))
            .animation(.easeInOut(duration: 0.5), value: phase)
        }
        .buttonStyle(OrbButtonStyle())
        .disabled(buttonDisabled)
        .opacity(buttonDisabled ? 0.55 : 1)
    }

    /// Acts on the user's intent, not the momentary status: while the VPN is
    /// on (connected, connecting or armed to reconnect) a tap always turns it
    /// off; it never re-starts it from a transient "disconnected" gap.
    private func toggle() {
        if vpn.stopping { return }
        if vpn.isOn {
            vpn.stop()
        } else if let p = selected {
            var o = VPNController.Options()
            o.tunnelUDP = tunnelUDP
            o.splitTunnelRU = splitTunnelRU
            o.bypassLAN = bypassLAN
            o.autoReconnect = autoReconnect
            o.disconnectOnSleep = disconnectOnSleep
            o.deadGrace = deadGrace
            o.batched = p.batched
            vpn.start(transport: p.transport, url: p.joinedURLs,
                      maxToken: p.maxToken, maxUid: p.maxUid, options: o)
        }
    }

    // MARK: status

    private var statusBlock: some View {
        VStack(spacing: 6) {
            Text(statusText)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundColor(.white)
            Group {
                if phase == .connected {
                    TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                        Label(elapsed(at: ctx.date), systemImage: "clock")
                            .font(.subheadline.monospacedDigit())
                    }
                } else {
                    Text(statusHint)
                }
            }
            .font(.subheadline)
            .foregroundColor(.white.opacity(0.6))
            .multilineTextAlignment(.center)
        }
        .animation(.easeInOut(duration: 0.3), value: phase)
    }

    private var statusText: String {
        switch phase {
        case .stopping: return "Отключение…"
        case .connected: return "Подключено"
        case .connecting: return "Подключение…"
        case .off: return "Отключено"
        }
    }

    private var statusHint: String {
        switch phase {
        case .stopping: return "Подождите секунду"
        case .connecting: return "Нажмите, чтобы отменить"
        case .connected: return ""
        case .off: return canConnect ? "Нажмите, чтобы подключиться" : "Добавьте профиль в настройках"
        }
    }

    private func elapsed(at now: Date) -> String {
        guard let since = vpn.connectedDate else { return "защищено" }
        let t = max(0, Int(now.timeIntervalSince(since)))
        let h = t / 3600, m = t / 60 % 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: profile card (tap to switch)

    private var profileCard: some View {
        Menu {
            if store.profiles.isEmpty {
                Text("Нет профилей")
            } else {
                ForEach(store.profiles) { p in
                    Button {
                        store.select(p.id)
                    } label: {
                        if p.id == store.selectedID {
                            Label(p.name, systemImage: "checkmark")
                        } else {
                            Text(p.name)
                        }
                    }
                }
            }
            Divider()
            Button {
                showSettings = true
            } label: {
                Label("Управление профилями", systemImage: "slider.horizontal.3")
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: transportIcon(selected?.transport))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(LinearGradient(colors: [Theme.violet, Theme.sky],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
                VStack(alignment: .leading, spacing: 6) {
                    Text(selected?.name ?? "Нет профилей")
                        .font(.headline)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if let p = selected {
                        HStack(spacing: 6) {
                            Chip(text: TransportKind(rawValue: p.transport)?.title ?? p.transport, color: Theme.cyan)
                            Chip(text: p.batched ? "Панель WPP" : "Свой узел", color: Theme.violet)
                            if p.cleanURLs.count > 1 {
                                Chip(text: "\(p.cleanURLs.count)×", color: Theme.teal)
                            }
                        }
                    } else {
                        Text("Добавьте профиль в настройках")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: vpn.isOn ? "lock.fill" : "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.45))
            }
            .padding(14)
            .glassCard()
        }
        .disabled(vpn.isOn)
    }

    private func transportIcon(_ t: String?) -> String {
        switch t {
        case "mailru": return "envelope.fill"
        case "oneme": return "bubble.left.and.bubble.right.fill"
        case "yandex": return "doc.text.fill"
        default: return "plus"
        }
    }

    // MARK: routing summary

    private var routingCard: some View {
        Button { showSettings = true } label: {
            HStack(spacing: 0) {
                routeItem("globe.europe.africa.fill", "RU напрямую", splitTunnelRU)
                divider
                routeItem("wifi.router.fill", "LAN напрямую", bypassLAN)
                divider
                routeItem("arrow.triangle.2.circlepath", "Автоподкл.", autoReconnect)
                divider
                routeItem("bolt.horizontal.fill", "UDP", tunnelUDP)
            }
            .padding(.vertical, 12)
            .glassCard()
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 30)
    }

    private func routeItem(_ icon: String, _ title: String, _ on: Bool) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(on ? Theme.teal : .white.opacity(0.3))
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundColor(.white.opacity(on ? 0.8 : 0.35))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: connectivity check

    private var checkCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                checkIcon
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(checkTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                    Text(checkDetail)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Button {
                    tunnel.testConnectivity()
                } label: {
                    Label("Проверить", systemImage: "waveform.path.ecg")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .foregroundColor(.white)
                        .background(
                            Capsule().fill(LinearGradient(colors: [Theme.violet, Theme.sky],
                                                          startPoint: .leading, endPoint: .trailing)))
                }
                .disabled(selected == nil || tunnel.check == .running)
                .opacity(selected == nil ? 0.5 : 1)

                Button {
                    showSettings = true
                } label: {
                    Label("Журнал", systemImage: "text.alignleft")
                        .font(.subheadline.weight(.semibold))
                        .padding(.vertical, 11).padding(.horizontal, 16)
                        .foregroundColor(.white.opacity(0.85))
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
            }
        }
        .padding(14)
        .glassCard()
        .animation(.easeInOut(duration: 0.25), value: tunnel.check)
    }

    @ViewBuilder private var checkIcon: some View {
        switch tunnel.check {
        case .idle:
            Image(systemName: "network")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Circle().fill(Color.white.opacity(0.08)))
        case .running:
            ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(Theme.teal)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 26))
                .foregroundColor(Theme.coral)
        }
    }

    private var checkTitle: String {
        switch tunnel.check {
        case .idle: return "Проверка доступности"
        case .running: return "Проверяем…"
        case .ok(_, let ms): return "Работает · \(ms) мс"
        case .failed: return "Не прошла"
        }
    }

    private var checkDetail: String {
        switch tunnel.check {
        case .idle: return isConnected ? "Запрос через VPN к ifconfig.me" : "Сначала подключитесь — запрос пойдёт через VPN"
        case .running: return "Запрос к ifconfig.me…"
        case .ok(let ip, _): return "Внешний IP: \(ip)"
        case .failed(let e): return e
        }
    }
}

/// Gentle press feedback for the orb.
private struct OrbButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

#Preview {
    ContentView()
}

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var store = ProfileStore()
    @StateObject private var tunnel = TunnelController()
    @StateObject private var vpn = VPNController()

    @State private var showSettings = false
    @State private var showInfo = false
    @State private var spin = false
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
    private var isBusy: Bool { isConnecting || vpn.stopping }
    private var buttonDisabled: Bool { vpn.stopping || (!vpn.isOn && !canConnect) }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Spacer()
                powerButton
                statusBlock
                    .padding(.top, 28)
                Spacer()
                VStack(spacing: 12) {
                    profileRow
                    checkRow
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("OpenFlux")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showInfo = true } label: { Image(systemName: "info.circle") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .onChange(of: vpn.isOn) { _ in tunnel.check = .idle }
            .sheet(isPresented: $showSettings) {
                SettingsView(store: store, tunnel: tunnel, vpn: vpn)
            }
            .sheet(isPresented: $showInfo) { InfoView() }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: power button

    private var powerButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(isConnected ? Color.green : Color(.secondarySystemGroupedBackground))
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                Circle()
                    .stroke(Color(.separator).opacity(isConnected ? 0 : 0.6), lineWidth: 1)
                if isBusy {
                    Circle()
                        .trim(from: 0, to: 0.22)
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .padding(2)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
                        .onAppear { spin = true }
                        .onDisappear { spin = false }
                }
                Image(systemName: "power")
                    .font(.system(size: 56, weight: .medium))
                    .foregroundColor(isConnected ? .white : (isBusy ? .orange : .accentColor))
            }
            .frame(width: 180, height: 180)
            .animation(.easeInOut(duration: 0.25), value: isConnected)
        }
        .buttonStyle(PressStyle())
        .disabled(buttonDisabled)
        .opacity(buttonDisabled ? 0.45 : 1)
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
                .font(.title3.weight(.semibold))
            Group {
                if isConnected {
                    TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                        Text(elapsed(at: ctx.date))
                            .font(.subheadline.monospacedDigit())
                    }
                } else {
                    Text(statusHint).font(.subheadline)
                }
            }
            .foregroundColor(.secondary)
        }
    }

    private var statusText: String {
        if vpn.stopping { return "Отключение…" }
        if isConnected { return "Подключено" }
        if isConnecting { return "Подключение…" }
        return "Отключено"
    }

    private var statusHint: String {
        if vpn.stopping { return " " }
        if isConnecting { return "Нажмите, чтобы отменить" }
        return canConnect ? "Нажмите, чтобы подключиться" : "Добавьте профиль в настройках"
    }

    private func elapsed(at now: Date) -> String {
        guard let since = vpn.connectedDate else { return " " }
        let t = max(0, Int(now.timeIntervalSince(since)))
        let h = t / 3600, m = t / 60 % 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: profile (tap to switch)

    private var profileRow: some View {
        Menu {
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
            Divider()
            Button {
                showSettings = true
            } label: {
                Label("Управление профилями", systemImage: "slider.horizontal.3")
            }
        } label: {
            row(icon: "doc.text",
                title: selected?.name ?? "Нет профиля",
                subtitle: profileSubtitle,
                trailing: vpn.isOn ? "lock.fill" : "chevron.up.chevron.down")
        }
        .disabled(vpn.isOn)
    }

    private var profileSubtitle: String {
        guard let p = selected else { return "Добавьте в настройках" }
        var parts = [TransportKind(rawValue: p.transport)?.title ?? p.transport,
                     p.batched ? "Панель WPP" : "Свой узел"]
        if p.cleanURLs.count > 1 { parts.append("\(p.cleanURLs.count) док.") }
        return parts.joined(separator: " · ")
    }

    // MARK: connectivity check

    private var checkRow: some View {
        Button {
            tunnel.testConnectivity()
        } label: {
            row(icon: checkIcon, iconColor: checkColor,
                title: checkTitle, subtitle: checkDetail,
                trailing: tunnel.check == .running ? nil : "arrow.clockwise")
        }
        .disabled(selected == nil || tunnel.check == .running)
    }

    private var checkIcon: String {
        switch tunnel.check {
        case .idle, .running: return "network"
        case .ok: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private var checkColor: Color {
        switch tunnel.check {
        case .ok: return .green
        case .failed: return .red
        default: return .accentColor
        }
    }

    private var checkTitle: String {
        switch tunnel.check {
        case .idle: return "Проверить соединение"
        case .running: return "Проверяем…"
        case .ok(_, let ms): return "Работает · \(ms) мс"
        case .failed: return "Нет соединения"
        }
    }

    private var checkDetail: String {
        switch tunnel.check {
        case .idle: return isConnected ? "Запрос через VPN" : "Сначала подключитесь"
        case .running: return "ifconfig.me"
        case .ok(let ip, _): return "IP \(ip)"
        case .failed(let e): return e
        }
    }

    // MARK: shared row

    private func row(icon: String, iconColor: Color = .accentColor,
                     title: String, subtitle: String, trailing: String?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(iconColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let t = trailing {
                Image(systemName: t)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Color(.tertiaryLabel))
            } else {
                ProgressView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

#Preview {
    ContentView()
}

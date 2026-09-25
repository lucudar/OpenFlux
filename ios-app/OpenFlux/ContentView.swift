import SwiftUI

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

    /// Accent colour reflects the tunnel state at a glance.
    private var accent: Color {
        if isConnected { return .green }
        if isConnecting { return .orange }
        return .gray
    }

    var body: some View {
        NavigationView {
            ZStack {
                backgroundGradient.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 28) {
                        Spacer(minLength: 12)
                        connectButton
                        statusPill
                        profileCard
                        checkButton
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("OpenFlux")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showInfo = true } label: {
                        Image(systemName: "info.circle")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(store: store, tunnel: tunnel, vpn: vpn)
            }
            .sheet(isPresented: $showInfo) { InfoView() }
        }
        .navigationViewStyle(.stack)
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [accent.opacity(0.12), Color(.systemBackground)],
            startPoint: .top, endPoint: .center)
        .animation(.easeInOut(duration: 0.6), value: accent)
    }

    // MARK: connect button

    private var connectButton: some View {
        Button {
            toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.12))
                    .frame(width: 230, height: 230)
                Circle()
                    .strokeBorder(accent.opacity(0.35), lineWidth: 2)
                    .frame(width: 230, height: 230)

                // Progress arc while connecting.
                if isConnecting {
                    Circle()
                        .trim(from: 0, to: 0.18)
                        .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 230, height: 230)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
                        .onAppear { spin = true }
                } else {
                    Circle()
                        .stroke(accent, lineWidth: 6)
                        .frame(width: 230, height: 230)
                        .onAppear { spin = false }
                }

                VStack(spacing: 10) {
                    Image(systemName: isConnected ? "lock.shield.fill" : "power")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundColor(accent)
                    Text(buttonText)
                        .multilineTextAlignment(.center)
                        .font(.headline)
                        .foregroundColor(.primary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(vpn.stopping || (!vpn.isOn && !canConnect))
        .opacity((vpn.stopping || (!vpn.isOn && !canConnect)) ? 0.5 : 1)
    }

    private var buttonText: String {
        if vpn.stopping { return "Отключение…" }
        if isConnected { return "Отключить" }
        if isConnecting { return "Подключение…\nнажмите, чтобы отменить" }
        return "Подключить"
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

    // MARK: status pill

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle().fill(accent).frame(width: 9, height: 9)
            Text(statusText).font(.subheadline).bold()
            if tunnelUDP {
                Text("UDP")
                    .font(.caption2).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.blue.opacity(0.15))
                    .foregroundColor(.blue)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .clipShape(Capsule())
    }

    private var statusText: String {
        if vpn.stopping { return "Отключение…" }
        if isConnected { return "Подключено" }
        if isConnecting { return "Подключение…" }
        return "Отключено"
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
            HStack(spacing: 12) {
                Image(systemName: "doc.on.doc.fill")
                    .foregroundColor(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(selected?.name ?? "Нет профилей")
                        .font(.subheadline).bold()
                        .foregroundColor(.primary)
                    Text(selected?.subtitle ?? "Добавьте профиль в настройках")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if let n = selected?.cleanURLs.count, n > 1 {
                    Text("\(n)×")
                        .font(.caption).bold()
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(accent.opacity(0.15))
                        .foregroundColor(accent)
                        .clipShape(Capsule())
                }
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .disabled(vpn.isOn)
    }

    // MARK: connectivity check

    private var checkButton: some View {
        VStack(spacing: 6) {
            Button {
                tunnel.testConnectivity()
                showSettings = true
            } label: {
                Label("Проверить доступность", systemImage: "waveform.path.ecg")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(selected == nil)

            Text("Проверка через VPN — результат в логе (Настройки).")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

#Preview {
    ContentView()
}

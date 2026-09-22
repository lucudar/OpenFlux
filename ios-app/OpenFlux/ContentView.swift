import SwiftUI

struct ContentView: View {
    @StateObject private var store = ProfileStore()
    @StateObject private var tunnel = TunnelController()
    @StateObject private var vpn = VPNController()

    @State private var showSettings = false
    @State private var showInfo = false
    @AppStorage("tunnelUDP") private var tunnelUDP: Bool = false

    private var selected: Profile? { store.selected }
    private var canConnect: Bool { selected?.isComplete ?? false }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    Text("Выберите профиль и нажмите кнопку подключения")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)

                    connectButton

                    Text(statusText)
                        .font(.title3).bold()

                    profilePicker

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
                .padding()
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

    private var statusText: String {
        if vpn.active { return vpn.status == "Connected" ? "Подключено" : vpn.status }
        return "Отключено"
    }

    private var connectButton: some View {
        Button {
            if vpn.active {
                vpn.stop()
            } else if let p = selected {
                vpn.start(transport: p.transport, url: p.url,
                          maxToken: p.maxToken, maxUid: p.maxUid,
                          tunnelUDP: tunnelUDP)
            }
        } label: {
            ZStack {
                Circle()
                    .fill((vpn.active ? Color.green : Color.gray).opacity(0.18))
                    .frame(width: 210, height: 210)
                Circle()
                    .strokeBorder(vpn.active ? Color.green : Color.gray.opacity(0.5), lineWidth: 5)
                    .frame(width: 210, height: 210)
                VStack(spacing: 10) {
                    Image(systemName: "bolt.horizontal.fill")
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundColor(vpn.active ? .green : .gray)
                    Text(vpn.active ? "Отключить" : "Подключить")
                        .font(.headline)
                        .foregroundColor(.primary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!vpn.active && !canConnect)
    }

    private var profilePicker: some View {
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
                Image(systemName: "doc.text")
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(selected?.name ?? "Нет профилей")
                        .font(.subheadline).bold()
                        .foregroundColor(.primary)
                    Text(subtitle(for: selected))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(vpn.active)
    }

    private func subtitle(for p: Profile?) -> String {
        guard let p = p else { return "Добавьте профиль в настройках" }
        switch p.transport {
        case "oneme": return "MAX • uid \(p.maxUid)"
        default:      return p.url.isEmpty ? "URL не задан" : p.url
        }
    }
}

#Preview {
    ContentView()
}

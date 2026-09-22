import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var vpn: VPNController

    @AppStorage("socksPort") private var socksPort: String = "10808"
    @AppStorage("debugLog") private var debugLog: Bool = false
    @AppStorage("tunnelUDP") private var tunnelUDP: Bool = false
    @AppStorage("splitTunnelRU") private var splitTunnelRU: Bool = true

    @Environment(\.dismiss) private var dismiss
    @State private var editing: Profile?
    @State private var showEditor = false

    var body: some View {
        NavigationView {
            Form {
                routingSection
                profilesSection
                vpnLogSection
                proxySection
                logSection
                aboutSection
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
            .onAppear { OpenFluxSetDebug(debugLog ? 1 : 0) }
            .sheet(isPresented: $showEditor) {
                ProfileEditor(profile: editing) { saved in
                    if store.profiles.contains(where: { $0.id == saved.id }) {
                        store.update(saved)
                    } else {
                        store.add(saved)
                    }
                }
            }
        }
    }

    private static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Версия")
                Spacer()
                Text(Self.appVersion).foregroundColor(.secondary)
            }
        }
    }

    private var routingSection: some View {
        Section {
            Toggle("Российские сайты — напрямую", isOn: $splitTunnelRU)
            Text("Вкл = трафик к российским IP идёт мимо VPN (быстрее, и меньше нагрузка на туннель — меньше реконнектов). Остальное — через VPN. Меняется при следующем подключении.")
                .font(.caption).foregroundColor(.secondary)
            Toggle("Туннелировать UDP / QUIC", isOn: $tunnelUDP)
            Text("Выкл = QUIC падает на TCP (работает на любом узле). Вкл = требуется UDP-совместимый узел. Меняется при следующем подключении.")
                .font(.caption).foregroundColor(.secondary)
        } header: {
            Text("Маршрутизация")
        }
    }

    private var profilesSection: some View {
        Section("Профили (документы)") {
            if store.profiles.isEmpty {
                Text("Пока нет профилей. Добавьте документ ниже.")
                    .font(.caption).foregroundColor(.secondary)
            }
            ForEach(store.profiles) { p in
                Button {
                    editing = p
                    showEditor = true
                } label: {
                    HStack {
                        Image(systemName: p.id == store.selectedID ? "checkmark.circle.fill" : "doc.text")
                            .foregroundColor(p.id == store.selectedID ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).foregroundColor(.primary)
                            Text(p.subtitle)
                                .font(.caption).foregroundColor(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Image(systemName: "pencil").foregroundColor(.secondary)
                    }
                }
            }
            .onDelete { store.delete(at: $0) }

            Button {
                editing = nil
                showEditor = true
            } label: {
                Label("Добавить профиль", systemImage: "plus.circle")
            }
        }
    }

    private var vpnLogSection: some View {
        Section {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(vpn.vpnLog.isEmpty ? "— (лог появляется, пока VPN подключён)" : vpn.vpnLog)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("vpntail")
                }
                .frame(height: 220)
                .onChange(of: vpn.vpnLog) { _ in
                    withAnimation { proxy.scrollTo("vpntail", anchor: .bottom) }
                }
            }
        } header: {
            Text("VPN журнал (расширение)")
        } footer: {
            Text("Статус подключения, переподключения и свободная память расширения. Память близко к 0 перед перезапуском = убито по памяти.")
        }
    }

    private var proxySection: some View {
        Section("Локальный прокси (SOCKS5)") {
            HStack {
                Text("Порт")
                Spacer()
                TextField("10808", text: $socksPort)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                    .disabled(tunnel.running)
            }
            if tunnel.running {
                Button(role: .destructive) { tunnel.stop() } label: {
                    Label("Остановить локальный прокси", systemImage: "stop.fill")
                }
                Text("SOCKS5: \(tunnel.socksAddr)")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Button {
                    guard let p = store.selected else { return }
                    let kind = TransportKind(rawValue: p.transport) ?? .yandex
                    tunnel.start(transport: kind, url: p.joinedURLs,
                                 maxToken: p.maxToken, maxUid: p.maxUid,
                                 port: Int(socksPort) ?? 10808)
                } label: {
                    Label("Запустить локальный прокси", systemImage: "play.fill")
                }
                .disabled(!(store.selected?.isComplete ?? false))
            }
        }
    }

    private var logSection: some View {
        Section("Журнал") {
            Toggle("Подробный лог", isOn: $debugLog)
                .onChange(of: debugLog) { on in OpenFluxSetDebug(on ? 1 : 0) }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(tunnel.log.isEmpty ? "—" : tunnel.log)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("logtail")
                }
                .frame(height: 200)
                .onChange(of: tunnel.log) { _ in
                    withAnimation { proxy.scrollTo("logtail", anchor: .bottom) }
                }
            }
        }
    }
}

/// Add or edit a single profile. A Yandex profile may hold several document
/// URLs — they are fanned out into one connection (more speed + resilience).
struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var transport: String
    @State private var urls: [String]
    @State private var maxToken: String
    @State private var maxUid: String
    private let id: UUID
    private let onSave: (Profile) -> Void

    init(profile: Profile?, onSave: @escaping (Profile) -> Void) {
        self.id = profile?.id ?? UUID()
        _name = State(initialValue: profile?.name ?? "")
        _transport = State(initialValue: profile?.transport ?? "yandex")
        // Always keep at least one editable row.
        let existing = profile?.urls.filter { !$0.isEmpty } ?? []
        _urls = State(initialValue: existing.isEmpty ? [""] : existing)
        _maxToken = State(initialValue: profile?.maxToken ?? "")
        _maxUid = State(initialValue: profile?.maxUid ?? "")
        self.onSave = onSave
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Название") {
                    TextField("Например: Документ 1", text: $name)
                }
                Section("Транспорт") {
                    Picker("Транспорт", selection: $transport) {
                        Text("Yandex Docs").tag("yandex")
                        Text("MAX").tag("oneme")
                    }
                    .pickerStyle(.segmented)
                }
                if transport == "oneme" {
                    Section("MAX") {
                        TextField("token", text: $maxToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                        TextField("user id", text: $maxUid)
                            .keyboardType(.numberPad)
                    }
                } else {
                    yandexDocsSection
                }
            }
            .navigationTitle("Профиль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Сохранить") { save() }.disabled(!canSave)
                }
            }
        }
    }

    private var yandexDocsSection: some View {
        Section {
            ForEach(urls.indices, id: \.self) { i in
                HStack {
                    Image(systemName: "doc.text")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    TextField("https://disk.yandex.ru/i/...", text: $urls[i])
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                }
            }
            .onDelete { idx in
                urls.remove(atOffsets: idx)
                if urls.isEmpty { urls = [""] }
            }
            Button {
                urls.append("")
            } label: {
                Label("Добавить документ", systemImage: "plus.circle")
            }
        } header: {
            Text("Yandex Docs — документы")
        } footer: {
            Text("Несколько документов работают параллельно — быстрее и стабильнее. На выходном узле должен быть настроен ТОТ ЖЕ набор документов в том же порядке.")
        }
    }

    private func save() {
        let finalName = name.trimmingCharacters(in: .whitespaces)
        let cleanURLs = urls
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        onSave(Profile(
            id: id,
            name: finalName.isEmpty ? "Профиль" : finalName,
            transport: transport,
            urls: cleanURLs,
            maxToken: maxToken.trimmingCharacters(in: .whitespaces),
            maxUid: maxUid.trimmingCharacters(in: .whitespaces)))
        dismiss()
    }
}

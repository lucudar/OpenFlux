import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var tunnel: TunnelController

    @AppStorage("socksPort") private var socksPort: String = "10808"
    @AppStorage("debugLog") private var debugLog: Bool = false
    @AppStorage("tunnelUDP") private var tunnelUDP: Bool = false

    @Environment(\.dismiss) private var dismiss
    @State private var editing: Profile?
    @State private var showEditor = false

    var body: some View {
        NavigationView {
            Form {
                routingSection
                profilesSection
                proxySection
                logSection
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

    private var routingSection: some View {
        Section {
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
                            Text(p.transport == "oneme" ? "MAX • uid \(p.maxUid)" : p.url)
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
                    tunnel.start(transport: kind, url: p.url,
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

/// Add or edit a single profile.
struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var transport: String
    @State private var url: String
    @State private var maxToken: String
    @State private var maxUid: String
    private let id: UUID
    private let onSave: (Profile) -> Void

    init(profile: Profile?, onSave: @escaping (Profile) -> Void) {
        self.id = profile?.id ?? UUID()
        _name = State(initialValue: profile?.name ?? "")
        _transport = State(initialValue: profile?.transport ?? "yandex")
        _url = State(initialValue: profile?.url ?? "")
        _maxToken = State(initialValue: profile?.maxToken ?? "")
        _maxUid = State(initialValue: profile?.maxUid ?? "")
        self.onSave = onSave
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
                    Section("Yandex Docs URL") {
                        TextField("https://disk.yandex.ru/i/...", text: $url)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                    }
                }
            }
            .navigationTitle("Профиль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Сохранить") {
                        let finalName = name.trimmingCharacters(in: .whitespaces)
                        onSave(Profile(
                            id: id,
                            name: finalName.isEmpty ? "Профиль" : finalName,
                            transport: transport,
                            url: url.trimmingCharacters(in: .whitespaces),
                            maxToken: maxToken.trimmingCharacters(in: .whitespaces),
                            maxUid: maxUid.trimmingCharacters(in: .whitespaces)))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

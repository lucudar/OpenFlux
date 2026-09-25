import SwiftUI
import UIKit

/// About screen with donation addresses (tap a row to copy).
struct InfoView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?

    private let sol = "7yXWW2iAkKadyVvMjZLPYo1PqizvKqseG2ZQ1sZk9X1k"
    private let eth = "0xd043E852158C13C8064a73b9cDd920DaAa80f0c1"

    var body: some View {
        NavigationView {
            ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(spacing: 10) {
                        LogoMark().frame(width: 84, height: 84)
                            .shadow(color: Theme.cyan.opacity(0.4), radius: 18)
                        Text("OpenFlux")
                            .font(.system(.title, design: .rounded).weight(.bold))
                        Text("TCP-туннель через скрытый транспорт. Клиент поднимает локальный SOCKS5 и системный VPN, трафик идёт через exit-node.")
                            .font(.footnote).foregroundColor(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Поддержать разработку ♥")
                            .font(.headline)
                        Text("Нажми на адрес, чтобы скопировать.")
                            .font(.caption).foregroundColor(.secondary)

                        donationRow(title: "Solana (SOL)", address: sol)
                        donationRow(title: "Ethereum (ETH)", address: eth)

                        if let c = copied {
                            Label("\(c) скопирован", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundColor(Theme.teal)
                        }
                    }
                    .padding()
                    .glassCard()

                    Spacer(minLength: 0)
                }
                .padding()
            }
            }
            .navigationTitle("О приложении")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func donationRow(title: String, address: String) -> some View {
        Button {
            UIPasteboard.general.string = address
            copied = title
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.subheadline).bold()
                    Spacer()
                    Image(systemName: "doc.on.doc").font(.caption)
                }
                Text(address)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

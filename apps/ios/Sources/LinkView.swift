import SwiftUI

/// First-run: join your Artist OS account from another device. Mirrors the
/// web app's device-link flow — open Settings → Sync on your Mac or in the
/// web app, tap "Link another device", type the 6-character code here.
struct LinkView: View {
    @EnvironmentObject var store: CompanionStore
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            AOS.ink.ignoresSafeArea()
            VStack(alignment: .leading, spacing: AOS.Space.lg) {
                Spacer().frame(height: 24)
                Text("ARTIST OS").font(.system(size: 15, weight: .black)).tracking(1.5)
                    .foregroundStyle(AOS.text) +
                Text("  COMPANION").font(.system(size: 15, weight: .black)).tracking(1.5)
                    .foregroundStyle(AOS.gold)

                Text("Your catalog,\nin your pocket.")
                    .font(.system(size: 34, weight: .black)).tracking(-0.8)
                    .foregroundStyle(AOS.text)
                Text("Link this phone to your Artist OS account. On your other device, open Settings → Sync → “Link another device”, then enter the code here.")
                    .font(.system(size: 14)).foregroundStyle(AOS.muted)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: AOS.Space.sm) {
                    TextField("6-character code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(size: 24, weight: .heavy, design: .monospaced))
                        .kerning(6)
                        .multilineTextAlignment(.center)
                        .focused($focused)
                        .padding(.vertical, 16)
                        .background(AOS.panel, in: RoundedRectangle(cornerRadius: AOS.Radius.card, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: AOS.Radius.card, style: .continuous)
                            .strokeBorder(focused ? AOS.gold.opacity(0.5) : AOS.line, lineWidth: 1))
                        .foregroundStyle(AOS.text)
                        .onChange(of: code) { _, v in if v.count > 6 { code = String(v.prefix(6)) } }

                    if case .failed(let msg) = store.linkState {
                        Text(msg).font(.system(size: 12.5)).foregroundStyle(Color(hex: 0xE8788A))
                    }

                    Button {
                        Task { await store.link(code: code) }
                    } label: {
                        HStack {
                            Spacer()
                            if store.linkState == .linking { ProgressView().tint(Color(hex: 0x14100A)) }
                            Text(store.linkState == .linking ? "Linking…" : "Link this phone")
                                .font(.system(size: 16, weight: .heavy))
                            Spacer()
                        }
                        .padding(.vertical, 15)
                        .background(code.count == 6 ? AOS.gold : AOS.gold.opacity(0.35),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(Color(hex: 0x14100A))
                    }
                    .disabled(code.count != 6 || store.linkState == .linking)
                }

                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(AOS.gold)
                    Text("Local-first. Your audio stays on your devices unless you choose otherwise.")
                        .font(.system(size: 11.5)).foregroundStyle(AOS.muted)
                }
                Spacer()
            }
            .padding(.horizontal, AOS.Space.lg)
        }
        .onAppear { focused = true }
    }
}

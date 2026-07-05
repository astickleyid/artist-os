import SwiftUI

/// Capture in the moment — the companion's core job. Two paths, both core:
/// record a quick idea, or pull in a bounce a collaborator sent. Wiring to real
/// recording (AVAudioRecorder) + file import (Files/Share Sheet) + "attach to
/// song" lands with the sync/catalog integration; this establishes the flow.
struct CaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack {
            AOS.ink.ignoresSafeArea()
            VStack(alignment: .leading, spacing: AOS.Space.lg) {
                Capsule().fill(AOS.line).frame(width: 40, height: 5).frame(maxWidth: .infinity).padding(.top, 8)

                Text("Capture an idea")
                    .font(.system(size: 22, weight: .black)).tracking(-0.4).foregroundStyle(AOS.text)
                Text("Grab it now — Artist OS files it into the right song so it never becomes an orphan.")
                    .font(.system(size: 13)).foregroundStyle(AOS.muted)

                CaptureOption(icon: "mic.fill", tint: AOS.gold,
                              title: "Record a voice memo",
                              subtitle: "Hum a hook, capture a lyric — straight into a song")
                CaptureOption(icon: "square.and.arrow.down.fill", tint: AOS.blue,
                              title: "Import a file",
                              subtitle: "A bounce from Files, or shared to Artist OS")

                Spacer()
            }
            .padding(.horizontal, AOS.Space.lg)
        }
    }
}

struct CaptureOption: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    var body: some View {
        Button {} label: {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.14))
                    Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(tint)
                }.frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15.5, weight: .bold)).foregroundStyle(AOS.text)
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(AOS.muted).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(AOS.muted)
            }
            .padding(AOS.Space.md)
            .background(AOS.panel, in: RoundedRectangle(cornerRadius: AOS.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AOS.Radius.card, style: .continuous).strokeBorder(AOS.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

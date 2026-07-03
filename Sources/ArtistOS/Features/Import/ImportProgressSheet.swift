import SwiftUI

struct ImportProgressSheet: View {
    @EnvironmentObject private var state: AppState

    private var progress: ImportProgress {
        state.importProgress ?? ImportProgress(phase: "Preparing…")
    }

    private var fraction: Double {
        guard progress.total > 0 else { return 0 }
        return Double(progress.processed) / Double(progress.total)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Folder")
                .font(.title3.weight(.black))

            if let summary = progress.finishedSummary {
                if let error = progress.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                }
                Text(summary)
                    .font(.subheadline)
                HStack {
                    Spacer()
                    Button("Done") { state.importProgress = nil }
                        .buttonStyle(.borderedProminent)
                        .tint(AOSTheme.gold)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Text(progress.phase)
                    .font(.subheadline)
                    .foregroundStyle(AOSTheme.muted)
                if progress.total > 0 {
                    ProgressView(value: fraction) {
                        Text("\(progress.processed) of \(progress.total) files")
                            .font(.caption)
                            .foregroundStyle(AOSTheme.muted)
                    }
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .interactiveDismissDisabled(progress.finishedSummary == nil)
    }
}

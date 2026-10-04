import SwiftUI
import TranscriberCore

/// The empty main window: one obvious thing to do.
struct DropZoneView: View {
    @ObservedObject var store: TranscriptionStore

    var body: some View {
        VStack(spacing: Space.group) {
            Image(systemName: store.dropIsTargeted ? "arrow.down.circle.fill" : "waveform")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(store.dropIsTargeted ? Palette.active : Palette.textTertiary)
                .accessibilityHidden(true)

            Text(store.dropIsTargeted ? "Release to add" : "Add audio or video")
                .font(Typography.pageTitle)

            Text("Drop files or folders here, or choose them from your Mac.\nMP3, WAV, M4A, MP4, MOV, MKV and more.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                store.presentFilePicker()
            } label: {
                Label("Add Files…", systemImage: "plus")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.top, Space.close)
        }
        .padding(Space.page * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(store.dropIsTargeted ? Palette.accentFill : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card)
                .strokeBorder(Palette.active, lineWidth: store.dropIsTargeted ? 2 : 0)
                .padding(Space.close)
        )
    }
}

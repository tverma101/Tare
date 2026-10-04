import AppKit
import SwiftUI
import TranscriberCore

/// Earlier Tare results, found in the output folders: the place to come back
/// to a transcript from last week.
struct LibraryView: View {
    @ObservedObject var store: TranscriptionStore
    @State private var query = ""
    @State private var selection: PastTranscript.ID?

    private var matches: [PastTranscript] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return store.pastTranscripts }
        return store.pastTranscripts.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.location.localizedCaseInsensitiveContains(needle)
                || ($0.modelName?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    var body: some View {
        Group {
            if let id = store.openPastTranscriptID,
               let entry = store.pastTranscripts.first(where: { $0.id == id }) {
                PastTranscriptPage(store: store, entry: entry)
            } else if store.pastTranscripts.isEmpty {
                empty
            } else {
                table
                    .searchable(text: $query, placement: .toolbar, prompt: "Search transcripts")
            }
        }
        .task { store.refreshPastTranscripts() }
    }

    private var empty: some View {
        VStack(spacing: Space.group) {
            if store.isScanningPast {
                ProgressView()
                Text("Looking for earlier transcripts…")
                    .foregroundStyle(Palette.textSecondary)
            } else {
                Image(systemName: "books.vertical")
                    .font(.system(size: 44, weight: .ultraLight))
                    .foregroundStyle(Palette.textTertiary)
                    .accessibilityHidden(true)
                Text("No earlier transcripts yet")
                    .font(Typography.pageTitle)
                Text("Transcripts Tare saves in \(store.outputPathForDisplay) show up here.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Space.page * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var table: some View {
        Table(of: PastTranscript.self, selection: $selection) {
            TableColumn("Name") { entry in
                VStack(alignment: .leading, spacing: Space.optical) {
                    Text(entry.title)
                        .font(Typography.rowTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(entry.location.isEmpty ? "Tare Transcripts" : entry.location)
                        .font(Typography.metadata)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .help(entry.folder.path)
            }
            .width(min: 160, ideal: 240)

            TableColumn("Date") { entry in
                Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                    .font(Typography.metadata)
                    .foregroundStyle(Palette.textSecondary)
            }
            .width(min: 110, ideal: 130, max: 170)

            TableColumn("Model") { entry in
                Text(entry.modelName ?? "—")
                    .font(Typography.metadata)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            .width(min: 70, ideal: 110, max: 160)

            TableColumn("") { entry in
                HStack(spacing: Space.close) {
                    Button("View") { store.openPastTranscriptID = entry.id }
                    Button("Show") { reveal(entry) }
                }
                .buttonStyle(.link)
                .font(Typography.metadata)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(Metric.actionsColumnWidth)
        } rows: {
            ForEach(matches) { entry in
                TableRow(entry)
                    .itemProvider { entry.primary.flatMap { NSItemProvider(contentsOf: $0) } }
            }
        }
        .tableStyle(.inset)
        .accessibilityLabel("Earlier transcripts")
        .contextMenu(forSelectionType: PastTranscript.ID.self) { ids in
            if let id = ids.first, let entry = store.pastTranscripts.first(where: { $0.id == id }) {
                Button("View Transcript") { store.openPastTranscriptID = id }
                if let primary = entry.primary {
                    Button("Open in Default App") { store.open(primary) }
                }
                Button("Show in Finder") { reveal(entry) }
            }
        } primaryAction: { ids in
            if let id = ids.first { store.openPastTranscriptID = id }
        }
        .overlay(alignment: .bottom) {
            if matches.isEmpty && !query.isEmpty {
                Text("No transcripts match “\(query)”.")
                    .foregroundStyle(Palette.textSecondary)
                    .padding(Space.page)
            }
        }
    }

    private func reveal(_ entry: PastTranscript) {
        if let primary = entry.primary {
            store.reveal(primary)
        } else {
            store.reveal(entry.folder)
        }
    }
}

/// One earlier transcript, read in the window.
struct PastTranscriptPage: View {
    @ObservedObject var store: TranscriptionStore
    let entry: PastTranscript
    @State private var text: String?
    @State private var loadFailed = false

    var body: some View {
        VStack(spacing: 0) {
            if let text {
                TranscriptReader(text: text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loadFailed {
                Text("Tare could not read this transcript. It may have been moved or deleted.")
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            filesBar
        }
        .task(id: entry.id) { await load() }
        .onChange(of: text) { _, newValue in
            store.openPastTranscriptText = newValue
        }
        .onDisappear { store.openPastTranscriptText = nil }
    }

    private var filesBar: some View {
        let others = entry.files.filter { $0 != entry.primary && !OutputFileKind.isInternal($0) }

        return HStack(spacing: Space.close) {
            Text("\(entry.date.formatted(date: .abbreviated, time: .shortened))\(entry.modelName.map { " · \($0)" } ?? "")")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)

            Spacer()

            if let primary = entry.primary {
                Button("Show in Finder") { store.reveal(primary) }
                Button("Open Transcript") { store.open(primary) }
            }

            if !others.isEmpty {
                Menu("More") {
                    ForEach(others, id: \.self) { url in
                        Button(OutputFileKind.title(for: url, source: url)) { store.reveal(url) }
                            .help(url.lastPathComponent)
                    }
                }
                .menuStyle(.button)
                .fixedSize()
            }
        }
        .padding(.horizontal, Space.page)
        .padding(.vertical, Space.close)
    }

    private func load() async {
        text = nil
        loadFailed = false
        guard let url = entry.primary else {
            loadFailed = true
            return
        }
        let loaded = await Task.detached(priority: .userInitiated) {
            try? String(contentsOf: url, encoding: .utf8)
        }.value
        if let loaded, !loaded.isEmpty {
            text = loaded
        } else {
            loadFailed = true
        }
    }
}

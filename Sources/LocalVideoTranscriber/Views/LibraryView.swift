import AppKit
import SwiftUI
import TranscriberCore

/// One folder in the Library sidebar: a folder of your Tare output that holds
/// transcripts somewhere inside it.
struct LibraryFolder: Identifiable, Hashable {
    /// The folder names from the output root, joined; stable across rescans.
    let id: String
    let name: String
    let path: [String]
    let count: Int
    var children: [LibraryFolder]?

    static let allID = "·all"
    static let looseID = "·loose"

    /// Builds the folder tree from where each result sits on disk.
    static func tree(from entries: [PastTranscript]) -> [LibraryFolder] {
        final class Node {
            var children: [String: Node] = [:]
            var count = 0
        }
        let root = Node()
        var loose = 0
        for entry in entries {
            guard !entry.folderPath.isEmpty else { loose += 1; continue }
            var node = root
            for name in entry.folderPath {
                if let existing = node.children[name] {
                    node = existing
                } else {
                    let created = Node()
                    node.children[name] = created
                    node = created
                }
                node.count += 1
            }
        }

        func build(_ node: Node, path: [String]) -> [LibraryFolder] {
            node.children
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map { name, child in
                    let childPath = path + [name]
                    let kids = build(child, path: childPath)
                    return LibraryFolder(
                        id: childPath.joined(separator: "/"),
                        name: PastTranscriptScanner.folderDisplayName(name),
                        path: childPath,
                        count: child.count,
                        children: kids.isEmpty ? nil : kids
                    )
                }
        }

        var folders = build(root, path: [])
        if loose > 0 {
            folders.append(LibraryFolder(id: looseID, name: "Other", path: [], count: loose, children: nil))
        }
        return folders
    }

    func contains(_ entry: PastTranscript) -> Bool {
        if id == Self.looseID { return entry.folderPath.isEmpty }
        return entry.folderPath.starts(with: path)
    }
}

/// Earlier Tare results: your folders on the left, the transcripts in the
/// selected folder on the right, and the transcript itself in place when opened.
struct LibraryView: View {
    @ObservedObject var store: TranscriptionStore
    @State private var folderID: String? = LibraryFolder.allID
    @State private var selection: PastTranscript.ID?
    @State private var query = ""
    @State private var sortOrder = [KeyPathComparator(\PastTranscript.date, order: .reverse)]

    private var folders: [LibraryFolder] { LibraryFolder.tree(from: store.pastTranscripts) }

    private var selectedFolder: LibraryFolder? {
        guard let folderID, folderID != LibraryFolder.allID else { return nil }
        return Self.find(folderID, in: folders)
    }

    private static func find(_ id: String, in folders: [LibraryFolder]) -> LibraryFolder? {
        for folder in folders {
            if folder.id == id { return folder }
            if let kids = folder.children, let hit = find(id, in: kids) { return hit }
        }
        return nil
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the table shows: a search looks through everything, otherwise the
    /// selected folder and everything inside it.
    private var visibleEntries: [PastTranscript] {
        var entries = store.pastTranscripts
        if isSearching {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            entries = entries.filter { entry in
                entry.title.localizedCaseInsensitiveContains(needle)
                    || entry.folderPath.contains { $0.localizedCaseInsensitiveContains(needle) }
            }
        } else if let folder = selectedFolder {
            entries = entries.filter(folder.contains)
        }
        return entries.sorted(using: sortOrder)
    }

    private var openEntry: PastTranscript? {
        store.openPastTranscriptID.flatMap { id in store.pastTranscripts.first { $0.id == id } }
    }

    private var selectedEntry: PastTranscript? {
        selection.flatMap { id in store.pastTranscripts.first { $0.id == id } }
    }

    private var heading: String {
        if isSearching { return "Search Results" }
        return selectedFolder?.name ?? "All Transcripts"
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
        }
        .task { store.refreshPastTranscripts() }
        .onChange(of: folderID) { _, newValue in
            store.openPastTranscriptID = nil
            selection = nil
            sortOrder = newValue == LibraryFolder.allID
                ? [KeyPathComparator(\PastTranscript.date, order: .reverse)]
                : [KeyPathComparator(\PastTranscript.title, comparator: .localizedStandard)]
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $folderID) {
            Label("All Transcripts", systemImage: "tray.full")
                .badge(store.pastTranscripts.count)
                .tag(LibraryFolder.allID)

            Section("Folders") {
                OutlineGroup(folders, children: \.children) { folder in
                    Label(folder.name, systemImage: folder.id == LibraryFolder.looseID ? "doc.text" : "folder")
                        .badge(folder.count)
                        .lineLimit(1)
                        .tag(folder.id)
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        Group {
            if let entry = openEntry {
                PastTranscriptPage(store: store, entry: entry)
                    .navigationTitle(entry.title)
                    .navigationSubtitle("")
            } else if store.pastTranscripts.isEmpty {
                empty
                    .navigationTitle("Library")
                    .navigationSubtitle("")
            } else {
                table
                    .navigationTitle(heading)
                    .navigationSubtitle("\(visibleEntries.count) transcript\(visibleEntries.count == 1 ? "" : "s")")
                    .searchable(text: $query, placement: .toolbar, prompt: "Search all transcripts")
            }
        }
        .toolbar { libraryToolbar }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        if openEntry != nil {
            ToolbarItem(placement: .navigation) {
                Button {
                    store.openPastTranscriptID = nil
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .keyboardShortcut(.cancelAction)
                .help("Back to the list (Esc)")
            }

            if let text = store.openPastTranscriptText, !text.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Label("Copy Transcript", systemImage: "doc.on.doc")
                    }
                    .help("Copy the whole transcript")
                }
            }
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if let entry = selectedEntry { reveal(entry) }
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .disabled(selectedEntry == nil)
                .help("Show the selected transcript in Finder")

                Button {
                    store.refreshPastTranscripts()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isScanningPast)
                .help("Look for transcripts again")
            }
        }
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
                Text("Transcripts you make with Tare show up here.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Space.page * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var table: some View {
        Table(of: PastTranscript.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.title) { entry in
                VStack(alignment: .leading, spacing: Space.optical) {
                    Text(entry.title)
                        .font(Typography.rowTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Where it lives, only when the selected folder does not
                    // already say so.
                    if isSearching || selectedFolder == nil {
                        Text(breadcrumb(for: entry))
                            .font(Typography.metadata)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .help(entry.folder.path)
            }
            .width(min: 180, ideal: 300)

            TableColumn("Date", value: \.date) { entry in
                Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                    .foregroundStyle(Palette.textSecondary)
            }
            .width(min: 100, ideal: 130, max: 160)
        } rows: {
            ForEach(visibleEntries) { entry in
                TableRow(entry)
                    .itemProvider { entry.primary.flatMap { NSItemProvider(contentsOf: $0) } }
            }
        }
        .tableStyle(.inset)
        .accessibilityLabel("Earlier transcripts")
        .contextMenu(forSelectionType: PastTranscript.ID.self) { ids in
            if let id = ids.first, let entry = store.pastTranscripts.first(where: { $0.id == id }) {
                Button("Read Transcript") { store.openPastTranscriptID = id }
                if let primary = entry.primary {
                    Button("Open in Default App") { store.open(primary) }
                }
                Button("Show in Finder") { reveal(entry) }
            }
        } primaryAction: { ids in
            if let id = ids.first { store.openPastTranscriptID = id }
        }
        .onKeyPress(.return) {
            guard let selection else { return .ignored }
            store.openPastTranscriptID = selection
            return .handled
        }
        .overlay {
            if visibleEntries.isEmpty {
                Text(isSearching ? "No transcripts match “\(query)”." : "Nothing in this folder yet.")
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    /// The folder a transcript was filed in, by name.
    private func breadcrumb(for entry: PastTranscript) -> String {
        entry.folderPath.last ?? "Other"
    }

    private func reveal(_ entry: PastTranscript) {
        if let primary = entry.primary {
            store.reveal(primary)
        } else {
            store.reveal(entry.folder)
        }
    }
}

/// One earlier transcript, read in place.
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

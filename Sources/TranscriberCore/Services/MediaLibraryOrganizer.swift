import Foundation

public enum MediaLibraryOrganizerError: Error, LocalizedError {
    case sourceMissing(URL)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let url):
            return "Missing source file: \(url.path)"
        }
    }
}

public struct MediaOrganizationResult: Hashable, Sendable {
    public var originalURL: URL
    public var destinationURL: URL
    public var folderURL: URL
    public var moved: Bool
    public var tableOfContentsURL: URL?

    public init(
        originalURL: URL,
        destinationURL: URL,
        folderURL: URL,
        moved: Bool,
        tableOfContentsURL: URL? = nil
    ) {
        self.originalURL = originalURL
        self.destinationURL = destinationURL
        self.folderURL = folderURL
        self.moved = moved
        self.tableOfContentsURL = tableOfContentsURL
    }
}

public final class MediaLibraryOrganizer {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func organize(sourceURL: URL, libraryRoot: URL) async throws -> MediaOrganizationResult {
        try await Task.detached(priority: .utility) { [fileManager] in
            try organizeSynchronously(
                sourceURL: sourceURL.standardizedFileURL,
                libraryRoot: libraryRoot.standardizedFileURL,
                fileManager: fileManager
            )
        }.value
    }
}

private func organizeSynchronously(
    sourceURL: URL,
    libraryRoot: URL,
    fileManager: FileManager
) throws -> MediaOrganizationResult {
    guard fileManager.fileExists(atPath: sourceURL.path) else {
        throw MediaLibraryOrganizerError.sourceMissing(sourceURL)
    }

    let plan = organizationPlan(for: sourceURL, libraryRoot: libraryRoot)
    let folderURL = plan.folderURL
    let preferredDestination = folderURL.appendingPathComponent(sourceURL.lastPathComponent)

    if sourceURL.standardizedFileURL.path == preferredDestination.standardizedFileURL.path {
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let tableOfContentsURL = try writeTableOfContentsIfNeeded(in: plan.tableRootURL, fileManager: fileManager)
        return MediaOrganizationResult(
            originalURL: sourceURL,
            destinationURL: sourceURL,
            folderURL: folderURL,
            moved: false,
            tableOfContentsURL: tableOfContentsURL
        )
    }

    try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
    let destinationURL = uniqueDestinationURL(
        for: preferredDestination,
        sourceURL: sourceURL,
        fileManager: fileManager
    )

    if sameFile(sourceURL, destinationURL, fileManager: fileManager) {
        let tableOfContentsURL = try writeTableOfContentsIfNeeded(in: plan.tableRootURL, fileManager: fileManager)
        return MediaOrganizationResult(
            originalURL: sourceURL,
            destinationURL: destinationURL,
            folderURL: folderURL,
            moved: false,
            tableOfContentsURL: tableOfContentsURL
        )
    }

    try fileManager.moveItem(at: sourceURL, to: destinationURL)
    let tableOfContentsURL = try writeTableOfContentsIfNeeded(in: plan.tableRootURL, fileManager: fileManager)
    return MediaOrganizationResult(
        originalURL: sourceURL,
        destinationURL: destinationURL,
        folderURL: folderURL,
        moved: true,
        tableOfContentsURL: tableOfContentsURL
    )
}

private struct OrganizationPlan {
    var folderURL: URL
    var tableRootURL: URL?
}

private func organizationPlan(for sourceURL: URL, libraryRoot: URL) -> OrganizationPlan {
    if let episode = tvEpisodeEntry(for: sourceURL.lastPathComponent) {
        let showFolder = libraryRoot.appendingPathComponent(folderSafe(episode.show), isDirectory: true)
        let seasonFolder = showFolder.appendingPathComponent("Season \(episode.seasonNumber)", isDirectory: true)
        return OrganizationPlan(folderURL: seasonFolder, tableRootURL: showFolder)
    }

    let folderName = OutputFolderPlanner.cleanSourceTitle(
        sourceURL.deletingPathExtension().lastPathComponent
    )
    return OrganizationPlan(
        folderURL: libraryRoot.appendingPathComponent(folderName, isDirectory: true),
        tableRootURL: nil
    )
}

private func uniqueDestinationURL(
    for preferredURL: URL,
    sourceURL: URL,
    fileManager: FileManager
) -> URL {
    if !fileManager.fileExists(atPath: preferredURL.path) || sameFile(sourceURL, preferredURL, fileManager: fileManager) {
        return preferredURL
    }

    let baseURL = preferredURL.deletingPathExtension()
    let pathExtension = preferredURL.pathExtension

    for index in 2...999 {
        let candidate = baseURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(baseURL.lastPathComponent) \(index)")
            .appendingPathExtension(pathExtension)
        if !fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }
    }

    return baseURL
        .deletingLastPathComponent()
        .appendingPathComponent("\(baseURL.lastPathComponent) \(UUID().uuidString)")
        .appendingPathExtension(pathExtension)
}

private func sameFile(_ lhs: URL, _ rhs: URL, fileManager: FileManager) -> Bool {
    fileManager.contentsEqual(atPath: lhs.path, andPath: rhs.path)
        && lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
}

private struct TVEpisodeEntry {
    var show: String
    var episode: String
    var seasonNumber: String
    var title: String
    var filename: String
}

private func writeTableOfContentsIfNeeded(in folderURL: URL?, fileManager: FileManager) throws -> URL? {
    guard let folderURL else {
        return nil
    }

    let contents = tvMKVFiles(in: folderURL, fileManager: fileManager)
    let entries = contents.compactMap { url -> TVEpisodeEntry? in
        guard url.pathExtension.caseInsensitiveCompare("mkv") == .orderedSame else {
            return nil
        }
        return tvEpisodeEntry(for: url.lastPathComponent)
    }

    guard !entries.isEmpty else {
        return nil
    }

    let grouped = Dictionary(grouping: entries, by: \.show)
    var lines = ["# Table of Contents", ""]

    for show in grouped.keys.sorted(by: localizedAscending) {
        lines.append("## \(show)")
        lines.append("")
        lines.append("| Episode | Title | File |")
        lines.append("| --- | --- | --- |")

        for entry in (grouped[show] ?? []).sorted(by: { $0.episode.localizedStandardCompare($1.episode) == .orderedAscending }) {
            let title = entry.title.isEmpty ? entry.episode : entry.title
            lines.append("| \(entry.episode) | \(markdownCell(title)) | \(markdownCell(entry.filename)) |")
        }

        lines.append("")
    }

    let tableURL = folderURL.appendingPathComponent("Table of Contents.md")
    try lines.joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .appending("\n")
        .write(to: tableURL, atomically: true, encoding: .utf8)
    return tableURL
}

private func tvMKVFiles(in folderURL: URL, fileManager: FileManager) -> [URL] {
    guard let enumerator = fileManager.enumerator(
        at: folderURL,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
        return []
    }

    var urls: [URL] = []
    for case let url as URL in enumerator {
        if url.lastPathComponent == "Original Video Backups" {
            enumerator.skipDescendants()
            continue
        }

        guard url.pathExtension.caseInsensitiveCompare("mkv") == .orderedSame else {
            continue
        }

        urls.append(url)
    }

    return urls.sorted {
        $0.path.localizedStandardCompare($1.path) == .orderedAscending
    }
}

private func tvEpisodeEntry(for filename: String) -> TVEpisodeEntry? {
    let pattern = #"^(.+?) - (S\d{2}E\d{2,3})(?: - (.+?))?\.mkv$"#
    guard let range = filename.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
        return nil
    }

    let matched = String(filename[range])
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return nil
    }

    let nsRange = NSRange(matched.startIndex..<matched.endIndex, in: matched)
    guard let match = regex.firstMatch(in: matched, range: nsRange), match.numberOfRanges >= 4 else {
        return nil
    }

    func group(_ index: Int) -> String {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: matched) else {
            return ""
        }
        return String(matched[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let episode = group(2).uppercased()
    let season = String(episode.dropFirst().prefix(2))

    return TVEpisodeEntry(
        show: group(1),
        episode: episode,
        seasonNumber: season,
        title: group(3),
        filename: matched
    )
}

private func markdownCell(_ value: String) -> String {
    value.replacingOccurrences(of: "|", with: "\\|")
}

private func localizedAscending(_ lhs: String, _ rhs: String) -> Bool {
    lhs.localizedStandardCompare(rhs) == .orderedAscending
}

private func folderSafe(_ value: String) -> String {
    let disallowed = CharacterSet(charactersIn: "/:")
        .union(.newlines)
        .union(.controlCharacters)
    let cleaned = String(value.unicodeScalars.map { scalar in
        disallowed.contains(scalar) ? Character("-") : Character(scalar)
    })
    let collapsed = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return collapsed.isEmpty ? "TV Show" : String(collapsed.prefix(120))
}

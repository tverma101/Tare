import Foundation
import TranscriberCore

/// One earlier Tare result found on disk: a folder holding a transcript and
/// whatever else was written beside it.
struct PastTranscript: Identifiable, Hashable {
    /// The folder path; one folder is one result.
    let id: String
    let title: String
    let date: Date
    let modelName: String?
    /// The folders between the Tare output root and this result, outermost first.
    let folderPath: [String]
    let files: [URL]

    var modelSortKey: String { modelName ?? "" }

    var primary: URL? { OutputFileKind.primary(in: files) }
    var folder: URL { URL(fileURLWithPath: id, isDirectory: true) }
}

/// Finds earlier results by walking the Tare output folders. Reads the small
/// `.tare-link.json` Tare writes beside each result when it is there, and
/// falls back to the folder name and file dates for older results.
enum PastTranscriptScanner {
    private static let resultExtensions: Set<String> = ["txt", "srt", "vtt", "json", "ttml", "lrc"]
    private static let readableExtensions: Set<String> = ["txt", "srt", "vtt"]

    private struct Manifest: Decodable {
        let displayName: String?
        let createdAt: Date?
        let modelIdentifier: String?
    }

    static func scan(roots: [URL]) -> [PastTranscript] {
        let fileManager = FileManager.default
        var filesByFolder: [String: [URL]] = [:]
        var manifestByFolder: [String: URL] = [:]
        var rootForFolder: [String: URL] = [:]

        for root in roots {
            guard let walker = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let folder = url.deletingLastPathComponent().standardizedFileURL.path
                if url.lastPathComponent.hasSuffix(".tare-link.json") {
                    manifestByFolder[folder] = url
                    rootForFolder[folder] = rootForFolder[folder] ?? root
                } else if resultExtensions.contains(url.pathExtension.lowercased()),
                          !url.lastPathComponent.hasPrefix(".") {
                    filesByFolder[folder, default: []].append(url)
                    rootForFolder[folder] = rootForFolder[folder] ?? root
                }
            }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var results: [PastTranscript] = []
        for (folder, files) in filesByFolder {
            // A folder is a result only if it holds something readable.
            guard files.contains(where: { readableExtensions.contains($0.pathExtension.lowercased()) }) else { continue }

            let manifest = manifestByFolder[folder]
                .flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? decoder.decode(Manifest.self, from: $0) }
            let folderURL = URL(fileURLWithPath: folder, isDirectory: true)
            let primary = OutputFileKind.primary(in: files)
            let modified = primary
                .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                ?? .distantPast

            let root = rootForFolder[folder]?.standardizedFileURL.path ?? ""
            var parent = folderURL.deletingLastPathComponent().path
            if parent.hasPrefix(root) { parent = String(parent.dropFirst(root.count)) }
            // Tare's dated "Transcription Batch" wrapper folders are bookkeeping,
            // not somewhere anyone filed anything, so a result belongs to the
            // folder the batch sits in.
            let folderPath = parent.split(separator: "/").map(String.init)
                .filter { folderDisplayName($0) == $0 }

            results.append(
                PastTranscript(
                    id: folder,
                    title: cleanedTitle(manifest?.displayName ?? folderURL.lastPathComponent),
                    date: manifest?.createdAt ?? modified,
                    modelName: manifest?.modelIdentifier.map {
                        (WhisperModelPreset.preset(for: $0)?.displayName
                            ?? ($0.split(separator: "/").last.map(String.init) ?? $0))
                            .components(separatedBy: " · ").first ?? $0
                    },
                    folderPath: folderPath,
                    files: files.sorted { $0.lastPathComponent < $1.lastPathComponent }
                )
            )
        }
        return results.sorted { $0.date > $1.date }
    }

    /// "Southern Wake Campus 11 Original 20260825 111157 Transcript 2" reads as
    /// "Southern Wake Campus 11": the suffixes are Tare's and the recorder's
    /// bookkeeping, not part of the name anyone uses.
    static func cleanedTitle(_ raw: String) -> String {
        var title = raw
        title = title.replacingOccurrences(of: #"\s+Transcript(\s+\d+)?$"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"\s+Original\s+\d{8}\s+\d{6}$"#, with: "", options: .regularExpression)
        title = title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? raw : title
    }

    /// "Transcription Batch 2026-09-27 16-18-20 (5 Files)" reads as "Batch of
    /// Sep 27, 4:18 PM (5 files)"; any other folder keeps its own name.
    static func folderDisplayName(_ raw: String) -> String {
        let pattern = #"^Transcription Batch (\d{4})-(\d{2})-(\d{2}) (\d{2})-(\d{2})-(\d{2}) \((\d+) Files?\)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) else { return raw }
        func part(_ i: Int) -> Int {
            Range(match.range(at: i), in: raw).flatMap { Int(raw[$0]) } ?? 0
        }
        var components = DateComponents()
        components.year = part(1); components.month = part(2); components.day = part(3)
        components.hour = part(4); components.minute = part(5)
        guard let date = Calendar.current.date(from: components) else { return raw }
        let count = part(7)
        return "Batch of \(date.formatted(date: .abbreviated, time: .shortened)) (\(count) file\(count == 1 ? "" : "s"))"
    }

    /// The Tare output root, and the chosen output folder when it lives elsewhere.
    static func roots(outputDirectory: URL) -> [URL] {
        let root = OutputFolderPlanner.defaultRootDirectory().standardizedFileURL
        var roots = [root]
        let chosen = outputDirectory.standardizedFileURL
        if !chosen.path.hasPrefix(root.path) { roots.append(chosen) }
        return roots.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

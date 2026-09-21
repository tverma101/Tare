import Foundation
import UniformTypeIdentifiers

public enum SupportedMedia {
    public static let audioExtensions: Set<String> = [
        "aac", "aif", "aiff", "caf", "flac", "m4a", "mp3", "ogg", "opus", "wav", "wma"
    ]

    public static let videoExtensions: Set<String> = [
        "3g2", "3gp", "avi", "flv", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "mts", "ts", "webm", "wmv"
    ]

    public static let allExtensions: Set<String> = audioExtensions.union(videoExtensions)

    public static let defaultPlayerCompatibleExtensions: Set<String> = [
        "aac", "aif", "aiff", "caf", "m4a", "m4v", "mov", "mp3", "mp4", "mpeg", "mpg", "wav"
    ]

    private static let defaultPlayerPreference: [String] = [
        "mov", "mp4", "m4v", "m4a", "mp3", "wav", "aiff", "aif", "aac", "caf", "mpeg", "mpg"
    ]

    public static let contentTypes: [UTType] = [
        .movie,
        .video,
        .audio,
        .mpeg4Movie,
        .quickTimeMovie,
        .mp3,
        .wav,
        .mpeg4Audio
    ] + customContentTypes

    public static func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return false }

        return allExtensions.contains(ext)
    }

    public static func isDefaultPlayerCompatible(_ url: URL) -> Bool {
        defaultPlayerCompatibleExtensions.contains(url.pathExtension.lowercased())
    }

    public static func preferredMacCompatibleURLs(from urls: [URL]) -> [URL] {
        let supported = urls
            .map { $0.standardizedFileURL }
            .filter(isSupported)

        let grouped = Dictionary(grouping: supported) { url in
            url.deletingPathExtension().path.lowercased()
        }

        return grouped.values
            .compactMap(preferredURL)
            .sorted { lhs, rhs in
                lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
    }

    private static func preferredURL(from candidates: [URL]) -> URL? {
        candidates.min { lhs, rhs in
            let lhsRank = rank(for: lhs.pathExtension)
            let rhsRank = rank(for: rhs.pathExtension)

            if lhsRank == rhsRank {
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }

            return lhsRank < rhsRank
        }
    }

    private static func rank(for pathExtension: String) -> Int {
        defaultPlayerPreference.firstIndex(of: pathExtension.lowercased()) ?? Int.max
    }

    private static let customContentTypes: [UTType] = [
        "3g2", "3gp", "avi", "flac", "flv", "m2ts", "mkv", "mts", "ogg", "opus", "ts", "webm", "wma", "wmv"
    ].compactMap { UTType(filenameExtension: $0) }
}

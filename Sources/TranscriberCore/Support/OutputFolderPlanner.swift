import Foundation

public enum OutputFolderPlanner {
    public static let defaultRootFolderName = "Tare Transcripts"
    public static let defaultLibraryFolderName = ""

    public static func defaultRootDirectory(fileManager: FileManager = .default) -> URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return documents.appendingPathComponent(defaultRootFolderName, isDirectory: true)
    }

    public static func defaultLibraryDirectory(fileManager: FileManager = .default) -> URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return documents
    }

    public static func sourceOutputRootDirectory(
        for sourceURLs: [URL],
        fallback: URL = defaultRootDirectory()
    ) -> URL {
        let parentDirectories = sourceURLs
            .map { $0.standardizedFileURL.deletingLastPathComponent() }

        guard let firstParent = parentDirectories.first else {
            return fallback
        }

        let allSourcesShareParent = parentDirectories.allSatisfy {
            $0.standardizedFileURL.path == firstParent.standardizedFileURL.path
        }

        return allSourcesShareParent ? firstParent : fallback
    }

    public static func createBatchDirectory(
        rootDirectory: URL,
        sourceURLs: [URL],
        date: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL {
        let preferred = rootDirectory.appendingPathComponent(
            folderName(for: sourceURLs, date: date),
            isDirectory: true
        )
        let unique = uniqueDirectory(for: preferred, fileManager: fileManager)
        try fileManager.createDirectory(at: unique, withIntermediateDirectories: true)
        return unique
    }

    public static func folderName(for sourceURLs: [URL], date: Date = Date()) -> String {
        if sourceURLs.count == 1, let sourceURL = sourceURLs.first {
            return "\(cleanSourceTitle(sourceURL.deletingPathExtension().lastPathComponent)) Transcript"
        }

        let stamp = batchDateFormatter.string(from: date)
        let count = sourceURLs.count
        if count > 1 {
            return "Transcription Batch \(stamp) (\(count) Files)"
        }
        return "Transcription Batch \(stamp)"
    }

    public static func transcriptBaseName(for sourceURL: URL) -> String {
        sanitizedBaseName(cleanSourceTitle(sourceURL.deletingPathExtension().lastPathComponent))
    }

    public static func sanitizedBaseName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let scalars = name.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let cleaned = String(scalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        let collapsed = cleaned
            .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))

        return collapsed.isEmpty ? "transcript" : collapsed
    }

    private static func uniqueDirectory(for preferred: URL, fileManager: FileManager) -> URL {
        guard fileManager.fileExists(atPath: preferred.path) else {
            return preferred
        }

        for index in 2...999 {
            let candidate = preferred
                .deletingLastPathComponent()
                .appendingPathComponent("\(preferred.lastPathComponent) \(index)", isDirectory: true)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return preferred
            .deletingLastPathComponent()
            .appendingPathComponent("\(preferred.lastPathComponent) \(UUID().uuidString)", isDirectory: true)
    }

    public static func cleanSourceTitle(_ rawName: String) -> String {
        var name = rawName.replacingOccurrences(of: "&", with: " and ")
        name = name.replacingOccurrences(of: #"[\[\]\{\}\(\)]"#, with: " ", options: .regularExpression)
        name = name.replacingOccurrences(of: #"['`]"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"[._+]+"#, with: " ", options: .regularExpression)
        name = name.replacingOccurrences(of: #"[-–—]+"#, with: " ", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let yearRange = name.range(
            of: #"(?<!\d)((?:19|20)\d{2})(?!\d)"#,
            options: .regularExpression
        ) {
            let title = name[..<yearRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let year = String(name[yearRange])
            if !title.isEmpty {
                return folderSafe("\(titleCase(title)) (\(year))")
            }
        }

        if let mediaRange = name.range(of: mediaTagPattern, options: [.regularExpression, .caseInsensitive]) {
            let title = name[..<mediaRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return folderSafe(titleCase(String(title)))
            }
        }

        return folderSafe(titleCase(name.isEmpty ? "Transcript" : name))
    }

    private static func titleCase(_ value: String) -> String {
        let minorWords: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "for", "from", "in", "into", "nor", "of", "on", "or", "the", "to", "vs", "with"]
        let acronyms: Set<String> = [
            "aac", "ai", "api", "dvd", "hd", "ios", "mkv", "ml", "mov", "mp3", "mp4", "tv", "ui", "url", "vtt"
        ]
        let words = value.split(separator: " ").map(String.init)

        return words.enumerated().map { index, word in
            let lower = word.lowercased()
            if acronyms.contains(lower) {
                return lower.uppercased()
            }
            if lower.range(of: #"^s\d{2}e\d{2,3}$"#, options: .regularExpression) != nil {
                return lower.uppercased()
            }
            if lower.range(of: #"^[ivxlcdm]+$"#, options: .regularExpression) != nil {
                return lower.uppercased()
            }
            if minorWords.contains(lower), index != 0, index != words.count - 1 {
                return lower
            }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }

    private static func folderSafe(_ value: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/:")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = String(value.unicodeScalars.map { scalar in
            disallowed.contains(scalar) ? Character("-") : Character(scalar)
        })
        let collapsed = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "Transcript" : String(collapsed.prefix(120))
    }

    private static let mediaTagPattern = #"(?<![A-Za-z0-9])(?:2160p|1440p|1080p|720p|480p|4k|8k|x26[45]|h\.?26[45]|hevc|av1|blu[-_. ]?ray|bluray|brrip|bdrip|webrip|web[-_. ]?dl|web|dvdrip|hdrip|hdtv|remux|uhd|hdr10?|dovi|ddp|eac3|aac|ac3|dts|truehd|atmos|proper|repack|rarbg|yify)(?![A-Za-z0-9])"#

    private static let batchDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter
    }()
}

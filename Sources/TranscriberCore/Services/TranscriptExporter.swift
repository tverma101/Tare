import Foundation

public enum TranscriptExporterError: Error, LocalizedError {
    case noFormatsSelected

    public var errorDescription: String? {
        switch self {
        case .noFormatsSelected:
            return "Select at least one export format."
        }
    }
}

public final class TranscriptExporter {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let dateFormatter: ISO8601DateFormatter
    private let captionedVideoExporter: CaptionedVideoExporter

    private struct LyricLine {
        var text: String
        var startTime: TimeInterval?
        var endTime: TimeInterval?
        var stanzaBreakBefore: Bool
        var words: [TranscriptWord]
    }

    public init(
        fileManager: FileManager = .default,
        captionedVideoExporter: CaptionedVideoExporter = CaptionedVideoExporter()
    ) {
        self.fileManager = fileManager
        self.captionedVideoExporter = captionedVideoExporter
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        dateFormatter = ISO8601DateFormatter()
    }

    public func export(
        _ transcript: Transcript,
        sourceURL: URL,
        to outputDirectory: URL,
        formats: Set<ExportFormat>,
        baseName: String? = nil
    ) async throws -> [URL] {
        guard !formats.isEmpty else {
            throw TranscriptExporterError.noFormatsSelected
        }

        try fileManager.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        var writtenURLs: [URL] = []
        do {
        let resolvedBaseName = baseName.map(OutputFolderPlanner.sanitizedBaseName)
            ?? OutputFolderPlanner.transcriptBaseName(for: sourceURL)

        for format in ExportFormat.allCases where formats.contains(format) {
            if format == .captionedVideo {
                if let captionedVideoURL = try await exportCaptionedVideo(
                    transcript,
                    sourceURL: sourceURL,
                    outputDirectory: outputDirectory,
                    baseName: resolvedBaseName
                ) {
                    writtenURLs.append(captionedVideoURL)
                }
                continue
            }

            let preferredURL = outputDirectory
                .appendingPathComponent("\(resolvedBaseName).\(filenameSuffix(for: format))")
                .appendingPathExtension(format.fileExtension)
            let destinationURL = uniqueURL(for: preferredURL)
            let data = try data(for: transcript, format: format)
            writtenURLs.append(destinationURL)
            try data.write(to: destinationURL, options: [.atomic])
        }

        } catch {
            // A failed export must not leave a misleading partial transcript
            // set in the batch folder. Only remove files created by this call.
            for url in writtenURLs {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }

        return writtenURLs
    }

    private func exportCaptionedVideo(
        _ transcript: Transcript,
        sourceURL: URL,
        outputDirectory: URL,
        baseName: String
    ) async throws -> URL? {
        guard SupportedMedia.videoExtensions.contains(sourceURL.pathExtension.lowercased()) else {
            return nil
        }

        guard !transcript.segments.isEmpty else {
            return nil
        }

        let preferredExtension = CaptionedVideoExporter.preferredOutputExtension(for: sourceURL)
        let preferredURL = outputDirectory
            .appendingPathComponent("\(baseName).captioned")
            .appendingPathExtension(preferredExtension)
        let destinationURL = uniqueURL(for: preferredURL)
        let captions = srtDocument(for: transcript)

        do {
            return try await captionedVideoExporter.export(
                sourceURL: sourceURL,
                captions: captions,
                localeIdentifier: transcript.localeIdentifier,
                to: destinationURL
            )
        } catch CaptionedVideoExporterError.muxFailed where preferredExtension != "mkv" {
            let fallbackURL = uniqueURL(
                for: preferredURL
                    .deletingPathExtension()
                    .appendingPathExtension("mkv")
            )
            return try await captionedVideoExporter.export(
                sourceURL: sourceURL,
                captions: captions,
                localeIdentifier: transcript.localeIdentifier,
                to: fallbackURL
            )
        }
    }

    private func data(for transcript: Transcript, format: ExportFormat) throws -> Data {
        switch format {
        case .text:
            return plainTextDocument(for: transcript).data(using: .utf8) ?? Data()
        case .timestampedText:
            return timestampedTextDocument(for: transcript).data(using: .utf8) ?? Data()
        case .srt:
            return srtDocument(for: transcript).data(using: .utf8) ?? Data()
        case .vtt:
            return vttDocument(for: transcript).data(using: .utf8) ?? Data()
        case .json:
            return try encoder.encode(transcript)
        case .wordTimings:
            return wordTimingsCSVDocument(for: transcript).data(using: .utf8) ?? Data()
        case .appleMusicLyrics:
            return appleMusicLyricsDocument(for: transcript).data(using: .utf8) ?? Data()
        case .appleMusicTTML:
            return appleMusicTTMLDocument(for: transcript).data(using: .utf8) ?? Data()
        case .captionedVideo:
            return Data()
        }
    }

    private func plainTextDocument(for transcript: Transcript) -> String {
        let text = transcript.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "" : text + "\n"
    }

    private func timestampedTextDocument(for transcript: Transcript) -> String {
        var sections: [String] = [
            "Source: \(transcript.sourceName)",
            "Locale: \(transcript.localeIdentifier)",
            "Created: \(dateFormatter.string(from: transcript.createdAt))",
            "",
            transcript.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        ]

        if !transcript.segments.isEmpty {
            sections.append("")
            sections.append("Segments")
            sections.append(contentsOf: transcript.segments.map { segment in
                let start = TimecodeFormatter.compact(segment.startTime)
                let end = TimecodeFormatter.compact(segment.endTime)
                return "[\(start) - \(end)] \(renderedText(for: segment))"
            })
        }

        return sections.joined(separator: "\n") + "\n"
    }

    public func srtDocument(for transcript: Transcript) -> String {
        guard !transcript.segments.isEmpty else {
            return ""
        }

        return cues(for: transcript).map { segment in
            [
                "\(segment.index)",
                "\(TimecodeFormatter.srt(segment.startTime)) --> \(TimecodeFormatter.srt(segment.endTime))",
                subtitleText(for: renderedText(for: segment))
            ].joined(separator: "\n")
        }
        .joined(separator: "\n\n") + "\n"
    }

    private func vttDocument(for transcript: Transcript) -> String {
        guard !transcript.segments.isEmpty else {
            return "WEBVTT\n\n"
        }

        let body = cues(for: transcript).map { segment in
            [
                "\(TimecodeFormatter.vtt(segment.startTime)) --> \(TimecodeFormatter.vtt(segment.endTime))",
                subtitleText(for: renderedText(for: segment))
            ].joined(separator: "\n")
        }
        .joined(separator: "\n\n")

        return "WEBVTT\n\n\(body)\n"
    }

    public func appleMusicLyricsDocument(for transcript: Transcript) -> String {
        let lines = lyricLines(for: transcript)
        guard !lines.isEmpty else {
            return ""
        }

        var outputLines: [String] = []
        for line in lines {
            if line.stanzaBreakBefore, !outputLines.isEmpty, outputLines.last != "" {
                outputLines.append("")
            }
            outputLines.append(line.text)
        }

        return outputLines.joined(separator: "\n") + "\n"
    }

    private func appleMusicTTMLDocument(for transcript: Transcript) -> String {
        let lines = lyricLines(for: transcript)
        let title = xmlEscaped(cleanedSourceTitle(for: transcript))
        let localeIdentifier = transcript.localeIdentifier
            .replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let language = localeIdentifier.isEmpty ? "und" : localeIdentifier

        var document: [String] = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<tt xmlns="http://www.w3.org/ns/ttml""#,
            #"    xmlns:tts="http://www.w3.org/ns/ttml#styling""#,
            #"    xmlns:itunes="http://itunes.apple.com/lyric-ttml-extensions""#,
            #"    xmlns:ttm="http://www.w3.org/ns/ttml#metadata""#,
            #"    xml:lang="\#(xmlEscaped(language))">"#,
            "  <head>",
            "    <metadata>",
            "      <ttm:title>\(title)</ttm:title>",
            "    </metadata>",
            "  </head>"
        ]

        let duration = lines.compactMap(\.endTime).max()
        if let duration {
            document.append("  <body dur=\"\(TimecodeFormatter.appleMusicTTML(duration))\">")
        } else {
            document.append("  <body>")
        }

        let groupedLines = lyricLineGroups(from: lines)
        if groupedLines.isEmpty {
            document.append(#"    <div itunes:song-part="Verse"/>"#)
        } else {
            for group in groupedLines {
                let timedLines = group.filter { $0.startTime != nil && $0.endTime != nil }
                if let begin = timedLines.compactMap(\.startTime).min(),
                   let end = timedLines.compactMap(\.endTime).max() {
                    document.append("    <div begin=\"\(TimecodeFormatter.appleMusicTTML(begin))\" end=\"\(TimecodeFormatter.appleMusicTTML(end))\" itunes:song-part=\"Verse\">")
                } else {
                    document.append(#"    <div itunes:song-part="Verse">"#)
                }

                for line in group {
                    let text = xmlEscaped(line.text)
                if let begin = line.startTime, let end = line.endTime {
                    let timedWords = line.words.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    if timedWords.isEmpty {
                        document.append("      <p begin=\"\(TimecodeFormatter.appleMusicTTML(begin))\" end=\"\(TimecodeFormatter.appleMusicTTML(end))\">\(text)</p>")
                    } else {
                        let spans = timedWords
                            .map { word -> String in
                                let escapedWord = xmlEscaped(word.text)
                                return "<span begin=\"\(TimecodeFormatter.appleMusicTTML(word.startTime))\" end=\"\(TimecodeFormatter.appleMusicTTML(word.endTime))\">\(escapedWord)</span>"
                            }
                            .joined(separator: " ")
                        document.append("      <p begin=\"\(TimecodeFormatter.appleMusicTTML(begin))\" end=\"\(TimecodeFormatter.appleMusicTTML(end))\">\(spans)</p>")
                    }
                } else {
                    document.append("      <p>\(text)</p>")
                }
                }

                document.append("    </div>")
            }
        }

        document.append("  </body>")
        document.append("</tt>")

        return document.joined(separator: "\n") + "\n"
    }

    private func wordTimingsCSVDocument(for transcript: Transcript) -> String {
        var rows = ["segment_index,word_index,start_seconds,end_seconds,word,probability"]

        for segment in cues(for: transcript) {
            let words = timedWords(for: segment)
            for word in words {
                let probability = word.probability.map { String(format: "%.4f", $0) } ?? ""
                rows.append(
                    [
                        "\(segment.index)",
                        "\(word.index)",
                        String(format: "%.3f", word.startTime),
                        String(format: "%.3f", word.endTime),
                        csvEscaped(word.text),
                        probability
                    ].joined(separator: ",")
                )
            }
        }

        return rows.joined(separator: "\n") + "\n"
    }

    private func cues(for transcript: Transcript) -> [TranscriptSegment] {
        let cleanedSegments = transcript.segments.compactMap { segment -> TranscriptSegment? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }

            return TranscriptSegment(
                id: segment.id,
                index: segment.index,
                startTime: segment.startTime,
                duration: segment.duration,
                text: text,
                speaker: segment.speaker,
                words: segment.words
            )
        }

        return cleanedSegments.enumerated().map { offset, segment in
            TranscriptSegment(
                id: segment.id,
                index: offset + 1,
                startTime: segment.startTime,
                duration: segment.duration,
                text: segment.text,
                speaker: segment.speaker,
                words: segment.words
            )
        }
    }

    private func subtitleText(for text: String) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return wrappedSubtitleText(collapsed, maxLineLength: 42)
    }

    private func wrappedSubtitleText(_ text: String, maxLineLength: Int) -> String {
        guard text.count > maxLineLength else {
            return text
        }

        var lines: [String] = []
        var currentLine = ""

        for word in text.split(separator: " ").map(String.init) {
            if currentLine.isEmpty {
                currentLine = word
            } else if currentLine.count + 1 + word.count <= maxLineLength {
                currentLine += " \(word)"
            } else {
                lines.append(currentLine)
                currentLine = word
            }
        }

        if !currentLine.isEmpty {
            lines.append(currentLine)
        }

        return lines.joined(separator: "\n")
    }

    private func lyricLines(for transcript: Transcript) -> [LyricLine] {
        let cueSegments = cues(for: transcript)
        if !cueSegments.isEmpty {
            var previousEndTime: TimeInterval?
            return cueSegments.compactMap { segment in
                let text = singleLineLyricText(for: renderedText(for: segment))
                guard !text.isEmpty else {
                    return nil
                }

                let hasStanzaBreak = previousEndTime.map { segment.startTime - $0 >= 2.0 } ?? false
                previousEndTime = segment.endTime
                return LyricLine(
                    text: text,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    stanzaBreakBefore: hasStanzaBreak,
                    words: timedWords(for: segment)
                )
            }
        }

        return plainLyricLines(from: transcript.fullText)
    }

    private func lyricLineGroups(from lines: [LyricLine]) -> [[LyricLine]] {
        var groups: [[LyricLine]] = []
        var currentGroup: [LyricLine] = []

        for line in lines {
            if line.stanzaBreakBefore, !currentGroup.isEmpty {
                groups.append(currentGroup)
                currentGroup = []
            }
            currentGroup.append(line)
        }

        if !currentGroup.isEmpty {
            groups.append(currentGroup)
        }

        return groups
    }

    private func plainLyricLines(from text: String) -> [LyricLine] {
        text
            .components(separatedBy: .newlines)
            .map { singleLineLyricText(for: $0) }
            .filter { !$0.isEmpty }
            .map {
                LyricLine(
                    text: $0,
                    startTime: nil,
                    endTime: nil,
                    stanzaBreakBefore: false,
                    words: []
                )
            }
    }

    private func timedWords(for segment: TranscriptSegment) -> [TranscriptWord] {
        let words = segment.words
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                if lhs.startTime == rhs.startTime {
                    return lhs.index < rhs.index
                }
                return lhs.startTime < rhs.startTime
            }

        guard !words.isEmpty else {
            return []
        }

        return words.enumerated().map { offset, word in
            TranscriptWord(
                id: word.id,
                index: offset + 1,
                startTime: word.startTime,
                duration: max(word.duration, 0.05),
                text: word.text.trimmingCharacters(in: .whitespacesAndNewlines),
                probability: word.probability
            )
        }
    }

    private func singleLineLyricText(for text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func renderedText(for segment: TranscriptSegment) -> String {
        guard let speaker = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
              !speaker.isEmpty else {
            return segment.text
        }

        return "\(speaker): \(segment.text)"
    }

    private func cleanedSourceTitle(for transcript: Transcript) -> String {
        let sourceTitle = (transcript.sourceName as NSString).deletingPathExtension
        return OutputFolderPlanner.cleanSourceTitle(sourceTitle)
    }

    private func filenameSuffix(for format: ExportFormat) -> String {
        switch format {
        case .text:
            return "plain-transcript"
        case .appleMusicLyrics:
            return "apple-music-lyrics"
        case .appleMusicTTML:
            return "apple-music"
        case .wordTimings:
            return "word-timings"
        case .timestampedText, .srt, .vtt, .json, .captionedVideo:
            return "transcript"
        }
    }

    private func csvEscaped(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private func xmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func uniqueURL(for preferredURL: URL) -> URL {
        guard fileManager.fileExists(atPath: preferredURL.path) else {
            return preferredURL
        }

        let baseURL = preferredURL.deletingPathExtension()
        let pathExtension = preferredURL.pathExtension

        for index in 2...999 {
            let candidate = baseURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(baseURL.lastPathComponent)-\(index)")
                .appendingPathExtension(pathExtension)

            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return baseURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(baseURL.lastPathComponent)-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
    }
}

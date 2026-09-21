import Foundation

public enum FFmpegAudioExtractorError: Error, LocalizedError {
    case ffmpegMissing
    case ffprobeMissing
    case durationUnavailable
    case extractionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .ffmpegMissing:
            return "ffmpeg was not found. Install it with Homebrew or add it to /opt/homebrew/bin/ffmpeg."
        case .ffprobeMissing:
            return "ffprobe was not found. Install the ffmpeg Homebrew package so Tare can measure long recordings before cloud upload."
        case .durationUnavailable:
            return "Tare could not determine the audio duration, so it cannot safely size a cloud transcription request."
        case .extractionFailed(let reason):
            return "Audio extraction failed: \(reason)"
        }
    }
}

public final class FFmpegAudioExtractor {
    private let fileManager: FileManager
    private let runner: ProcessRunner
    private let ffmpegURL: URL
    private let ffprobeURL: URL?

    public init(
        fileManager: FileManager = .default,
        runner: ProcessRunner = ProcessRunner(),
        ffmpegURL: URL? = nil
    ) throws {
        self.fileManager = fileManager
        self.runner = runner

        guard let resolvedURL = ffmpegURL ?? Self.resolveExecutable(named: "ffmpeg") else {
            throw FFmpegAudioExtractorError.ffmpegMissing
        }

        self.ffmpegURL = resolvedURL
        self.ffprobeURL = Self.resolveExecutable(named: "ffprobe")
    }

    public func extractAudio(from sourceURL: URL, preserveSourceQuality: Bool = false) async throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("Tare", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let outputURL = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(preserveSourceQuality ? "flac" : "wav")

        var arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-nostdin",
            "-y",
            "-i", sourceURL.path,
            "-vn",
            "-map", "0:a:0"
        ]
        if preserveSourceQuality {
            arguments += ["-c:a", "flac"]
        } else {
            arguments += ["-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le"]
        }
        arguments.append(outputURL.path)

        do {
            _ = try await runner.run(
                executableURL: ffmpegURL,
                arguments: arguments
            )
            try validateOutputFile(outputURL)
        } catch let error as FFmpegAudioExtractorError {
            try? fileManager.removeItem(at: outputURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: outputURL)
            throw FFmpegAudioExtractorError.extractionFailed(error.localizedDescription)
        }

        return outputURL
    }

    public func extractAudioChunk(
        from audioURL: URL,
        startTime: TimeInterval,
        duration: TimeInterval,
        preserveSourceQuality: Bool = false
    ) async throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("Tare", isDirectory: true)
            .appendingPathComponent("GeminiChunks", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let outputURL = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(preserveSourceQuality ? "flac" : "wav")
        let boundedStart = max(0, startTime)
        let boundedDuration = max(0.2, duration)

        var arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-nostdin",
            "-y",
            "-i", audioURL.path,
            "-ss", String(format: "%.3f", boundedStart),
            "-t", String(format: "%.3f", boundedDuration),
            "-vn",
            "-map", "0:a:0"
        ]
        if preserveSourceQuality {
            arguments += ["-c:a", "flac"]
        } else {
            arguments += ["-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le"]
        }
        arguments.append(outputURL.path)

        do {
            _ = try await runner.run(
                executableURL: ffmpegURL,
                arguments: arguments
            )
            try validateOutputFile(outputURL)
        } catch let error as FFmpegAudioExtractorError {
            try? fileManager.removeItem(at: outputURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: outputURL)
            throw FFmpegAudioExtractorError.extractionFailed(error.localizedDescription)
        }

        return outputURL
    }

    public func duration(of audioURL: URL) async throws -> TimeInterval {
        guard let ffprobeURL else {
            throw FFmpegAudioExtractorError.ffprobeMissing
        }

        do {
            let result = try await runner.run(
                executableURL: ffprobeURL,
                arguments: [
                    "-v", "error",
                    "-show_entries", "format=duration",
                    "-of", "default=noprint_wrappers=1:nokey=1",
                    audioURL.path
                ]
            )
            guard let duration = Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
                  duration.isFinite,
                  duration > 0 else {
                throw FFmpegAudioExtractorError.durationUnavailable
            }
            return duration
        } catch let error as FFmpegAudioExtractorError {
            throw error
        } catch {
            throw FFmpegAudioExtractorError.extractionFailed(error.localizedDescription)
        }
    }

    public func silenceBoundaries(of audioURL: URL) async throws -> [TimeInterval] {
        let result: ProcessResult
        do {
            result = try await runner.run(
                executableURL: ffmpegURL,
                arguments: [
                    "-hide_banner",
                    "-nostats",
                    "-nostdin",
                    "-i", audioURL.path,
                    "-map", "0:a:0",
                    "-af", "silencedetect=noise=-35dB:d=0.35",
                    "-f", "null",
                    "-"
                ]
            )
        } catch {
            throw FFmpegAudioExtractorError.extractionFailed(error.localizedDescription)
        }

        return Self.parseSilenceBoundaries(from: result.stderr)
    }

    public func measureAudioLevel(of sourceURL: URL) async throws -> AudioLevelReport {
        do {
            let result = try await runner.run(
                executableURL: ffmpegURL,
                arguments: [
                    "-hide_banner",
                    "-nostats",
                    "-nostdin",
                    "-i", sourceURL.path,
                    "-map", "0:a:0",
                    "-af", "volumedetect",
                    "-f", "null",
                    "-"
                ]
            )

            return AudioLevelReport(stderr: result.stderr)
        } catch {
            throw FFmpegAudioExtractorError.extractionFailed(error.localizedDescription)
        }
    }

    public static func resolveExecutable(named executableName: String) -> URL? {
        let candidatePaths = [
            "/opt/homebrew/bin/\(executableName)",
            "/usr/local/bin/\(executableName)",
            "/usr/bin/\(executableName)",
            "/bin/\(executableName)"
        ]

        return candidatePaths
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func validateOutputFile(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0 else {
            throw FFmpegAudioExtractorError.extractionFailed("ffmpeg produced an empty audio file")
        }
    }

    static func parseSilenceBoundaries(from text: String) -> [TimeInterval] {
        let startPattern = try? NSRegularExpression(pattern: #"silence_start:\s*([0-9]+(?:\.[0-9]+)?)"#)
        let endPattern = try? NSRegularExpression(pattern: #"silence_end:\s*([0-9]+(?:\.[0-9]+)?)"#)
        var currentStart: TimeInterval?
        var boundaries: [TimeInterval] = []

        for line in text.components(separatedBy: .newlines) {
            if let startPattern,
               let match = startPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line),
               let start = Double(line[range]) {
                currentStart = start
            }

            if let endPattern,
               let match = endPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line),
               let end = Double(line[range]),
               let start = currentStart,
               end > start {
                boundaries.append((start + end) / 2)
                currentStart = nil
            }
        }

        return boundaries
    }
}

public struct AudioLevelReport: Hashable, Sendable {
    public var meanVolumeDB: Double?
    public var maxVolumeDB: Double?

    public init(meanVolumeDB: Double? = nil, maxVolumeDB: Double? = nil) {
        self.meanVolumeDB = meanVolumeDB
        self.maxVolumeDB = maxVolumeDB
    }

    init(stderr: String) {
        meanVolumeDB = Self.parseVolume(named: "mean_volume", in: stderr)
        maxVolumeDB = Self.parseVolume(named: "max_volume", in: stderr)
    }

    public var isEffectivelySilent: Bool {
        guard let maxVolumeDB else { return false }
        return maxVolumeDB <= -70
    }

    private static func parseVolume(named name: String, in text: String) -> Double? {
        for line in text.components(separatedBy: .newlines) where line.contains(name) {
            let pieces = line.components(separatedBy: "\(name):")
            guard pieces.count > 1 else { continue }
            let valueText = pieces[1]
                .replacingOccurrences(of: "dB", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Double(valueText) {
                return value
            }
        }

        return nil
    }
}

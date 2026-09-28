import Foundation
import TranscriberCore

enum SmokeTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

@main
enum TranscriberCoreSmokeTests {
    static func main() async throws {
        if CommandLine.arguments.contains("--freellm-live") {
            try await testFreeLLMLiveNaming()
            return
        }

        if CommandLine.arguments.contains("--exports-only") {
            try await testExportsTextSRTVTTAndJSON()
            try await testExportsTimestampedTranscriptWhenRequested()
            try await testExportsAppleMusicLyricsAndTTML()
            try await testExportsWordTimingsCSV()
            try await testAudioLyricsEmbedderReplacesSourceWithBackup()
            try testTranscriptLinkerWritesAndReadsManifest()
            try testTranscriptNamingFallbackAndParsing()
            try testOutputFolderPlannerCreatesSemanticFolder()
            try testAudioLyricsEmbedderOnlyTargetsContainersThatPersistLyrics()
            try await testExporterUsesUniquePathInsteadOfOverwriting()
            try await testExporterCollapsesPunctuationInOutputBasename()
            try await testExporterRemovesReleaseTagsFromOutputBasename()
            try await testExporterFormatsSubtitleTextForPlayers()
            try await testExporterWritesEmptyCaptionCuesForNoSpeech()
            print("TranscriberCoreSmokeTests exports passed")
            return
        }

        try await testExportsTextSRTVTTAndJSON()
        try await testExportsTimestampedTranscriptWhenRequested()
        try await testExportsAppleMusicLyricsAndTTML()
        try await testExportsWordTimingsCSV()
        try await testAudioLyricsEmbedderReplacesSourceWithBackup()
        try testTranscriptLinkerWritesAndReadsManifest()
        try testTranscriptNamingFallbackAndParsing()
        try testOutputFolderPlannerCreatesSemanticFolder()
        try testAudioLyricsEmbedderOnlyTargetsContainersThatPersistLyrics()
        try await testExporterUsesUniquePathInsteadOfOverwriting()
        try await testExporterCollapsesPunctuationInOutputBasename()
        try await testExporterRemovesReleaseTagsFromOutputBasename()
        try await testExporterFormatsSubtitleTextForPlayers()
        try await testExporterWritesEmptyCaptionCuesForNoSpeech()
        try await testCaptionedVideoExportEmbedsSubtitleTrack()
        try await testAttachToSourceReplacesMKVWithEmbeddedSubtitleTrack()
        try await testAttachToSourcePackagesMP4AsSelectableMKV()
        try testOutputFolderPlannerUsesDocumentsDefault()
        try testOutputFolderPlannerNamesSingleFileFolder()
        try testOutputFolderPlannerUsesSourceParentWhenPossible()
        try testOutputFolderPlannerCreatesUniqueBatchFolder()
        try await testMKVDiscoveryFindsMKVFiles()
        try await testMediaLibraryOrganizerMovesTVEpisodeAndWritesTableOfContents()
        try testFilenameCleanerDecodesResults()
        try testWhisperEnvironmentIncludesHomebrewPath()
        try testWhisperLanguageSelection()
        try testWhisperModelPresets()
        try testGeminiModelDetectionAndOptions()
        try testGeminiAPIKeyStorePersistence()
        try testGeminiChunkPlanner()
        try await testGeminiModelAccessVerification()
        try await testCloudAudioExtractionPreservesSourceQuality()
        try await testGeminiTranscriptionServiceWithMockAPI()
        try testTranscriptionConfigurationRequestsWordTimestampsByDefault()
        try testExportFormatVisibleOptions()
        try testChunkProgressLineParsing()
        try testProviderTextIsRedacted()
        try testSupportedMediaRecognizesDefaultPlayerFormats()
        try testPreferredMacCompatibleURLsChooseQuickTimeFriendlyVariant()
        print("TranscriberCoreSmokeTests passed")
    }

    private static func testExportsTextSRTVTTAndJSON() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let transcript = makeTranscript()
        let exporter = TranscriptExporter()
        let sourceURL = URL(fileURLWithPath: "/tmp/Interview.mov")

        let urls = try await exporter.export(
            transcript,
            sourceURL: sourceURL,
            to: temporaryDirectory,
            formats: [.text, .srt, .vtt, .json]
        )

        try expect(urls.count == 4, "Expected four exported transcript files.")
        try expect(FileManager.default.fileExists(atPath: temporaryDirectory.appendingPathComponent("Interview.plain-transcript.txt").path), "Missing plain text export.")
        try expect(FileManager.default.fileExists(atPath: temporaryDirectory.appendingPathComponent("Interview.transcript.srt").path), "Missing SRT export.")
        try expect(FileManager.default.fileExists(atPath: temporaryDirectory.appendingPathComponent("Interview.transcript.vtt").path), "Missing VTT export.")
        try expect(FileManager.default.fileExists(atPath: temporaryDirectory.appendingPathComponent("Interview.transcript.json").path), "Missing JSON export.")

        let plainText = try String(contentsOf: temporaryDirectory.appendingPathComponent("Interview.plain-transcript.txt"))
        try expect(plainText == "First sentence. Second sentence.\n", "Plain text export should contain only transcript text.")
        try expect(!plainText.contains("Source:"), "Plain text export should not include metadata.")
        try expect(!plainText.contains("[00:"), "Plain text export should not include segment timestamps.")

        let srt = try String(contentsOf: temporaryDirectory.appendingPathComponent("Interview.transcript.srt"))
        try expect(srt.contains("00:00:01,250 --> 00:00:03,750"), "SRT timecode formatting is wrong.")
        try expect(srt.contains("First sentence."), "SRT text is missing.")

        let vtt = try String(contentsOf: temporaryDirectory.appendingPathComponent("Interview.transcript.vtt"))
        try expect(vtt.hasPrefix("WEBVTT"), "VTT header is missing.")
        try expect(vtt.contains("00:00:04.000 --> 00:00:05.200"), "VTT timecode formatting is wrong.")
    }

    private static func testExportsTimestampedTranscriptWhenRequested() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let urls = try await TranscriptExporter().export(
            makeTranscript(),
            sourceURL: URL(fileURLWithPath: "/tmp/Interview.mov"),
            to: temporaryDirectory,
            formats: [.timestampedText]
        )

        try expect(urls.map(\.lastPathComponent) == ["Interview.transcript.txt"], "Timestamped transcript filename is wrong.")
        let timestampedText = try String(contentsOf: temporaryDirectory.appendingPathComponent("Interview.transcript.txt"))
        try expect(timestampedText.contains("Source: Interview.mov"), "Timestamped text export should include source metadata.")
        try expect(timestampedText.contains("[0:01 - 0:03] First sentence."), "Timestamped text export should include segment timestamps.")
    }

    private static func testExportsAppleMusicLyricsAndTTML() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let transcript = makeTranscript()
        let exporter = TranscriptExporter()
        let sourceURL = URL(fileURLWithPath: "/tmp/Interview.mov")

        let urls = try await exporter.export(
            transcript,
            sourceURL: sourceURL,
            to: temporaryDirectory,
            formats: [.appleMusicLyrics, .appleMusicTTML]
        )

        try expect(urls.map(\.lastPathComponent) == ["Interview.apple-music-lyrics.txt", "Interview.apple-music.ttml"], "Apple Music exports used unexpected filenames.")

        let lyrics = try String(contentsOf: temporaryDirectory.appendingPathComponent("Interview.apple-music-lyrics.txt"))
        try expect(lyrics == "First sentence.\nSecond sentence.\n", "Apple Music lyrics export should be clean paste-ready lyric text.")
        try expect(!lyrics.contains("Source:"), "Apple Music lyrics export should not include transcript metadata.")
        try expect(!lyrics.contains("00:00"), "Apple Music lyrics export should not include timestamps.")

        let ttml = try String(contentsOf: temporaryDirectory.appendingPathComponent("Interview.apple-music.ttml"))
        try expect(ttml.contains(#"xmlns="http://www.w3.org/ns/ttml""#), "Apple Music TTML namespace is missing.")
        try expect(ttml.contains(#"xmlns:tts="http://www.w3.org/ns/ttml#styling""#), "Apple Music TTML styling namespace is missing.")
        try expect(ttml.contains(#"xmlns:itunes="http://itunes.apple.com/lyric-ttml-extensions""#), "Apple Music TTML extension namespace is missing.")
        try expect(ttml.contains(#"xml:lang="en-US""#), "Apple Music TTML should normalize the transcript locale.")
        try expect(ttml.contains(#"<body dur="00:05.200">"#), "Apple Music TTML duration formatting is wrong.")
        try expect(ttml.contains(#"<div begin="00:01.250" end="00:05.200" itunes:song-part="Verse">"#), "Apple Music TTML timed lyric group is wrong.")
        try expect(ttml.contains(#"<p begin="00:01.250" end="00:03.750"><span begin="00:01.250" end="00:01.900">First</span> <span begin="00:01.900" end="00:03.750">sentence.</span></p>"#), "Apple Music TTML first timed lyric line should include word-level spans.")
        try expect(ttml.contains(#"<p begin="00:04.000" end="00:05.200"><span begin="00:04.000" end="00:04.500">Second</span> <span begin="00:04.500" end="00:05.200">sentence.</span></p>"#), "Apple Music TTML second timed lyric line should include word-level spans.")
    }

    private static func testExportsWordTimingsCSV() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let urls = try await TranscriptExporter().export(
            makeTranscript(),
            sourceURL: URL(fileURLWithPath: "/tmp/Interview.mov"),
            to: temporaryDirectory,
            formats: [.wordTimings]
        )

        try expect(urls.map(\.lastPathComponent) == ["Interview.word-timings.csv"], "Word timings export used an unexpected filename.")
        let csv = try String(contentsOf: temporaryDirectory.appendingPathComponent("Interview.word-timings.csv"))
        try expect(csv.contains("segment_index,word_index,start_seconds,end_seconds,word,probability"), "Word timings CSV header is wrong.")
        try expect(csv.contains("1,1,1.250,1.900,\"First\",0.9800"), "Word timings CSV first word row is wrong.")
        try expect(csv.contains("2,2,4.500,5.200,\"sentence.\",0.9600"), "Word timings CSV second segment row is wrong.")
    }

    private static func testAudioLyricsEmbedderReplacesSourceWithBackup() async throws {
        guard let ffmpegURL = FFmpegAudioExtractor.resolveExecutable(named: "ffmpeg"),
              let ffprobeURL = FFmpegAudioExtractor.resolveExecutable(named: "ffprobe") else {
            print("Skipping audio lyrics embedder test because ffmpeg or ffprobe is missing")
            return
        }

        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("Song.m4a")
        let runner = ProcessRunner()
        _ = try await runner.run(
            executableURL: ffmpegURL,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-nostdin",
                "-y",
                "-f", "lavfi",
                "-i", "sine=frequency=440",
                "-t", "0.25",
                "-c:a", "aac",
                sourceURL.path
            ]
        )

        let lyrics = TranscriptExporter().appleMusicLyricsDocument(for: makeTranscript())
        let linker = TranscriptLinker()
        let metadata = linker.metadata(
            for: makeTranscript(),
            sourceURL: sourceURL,
            transcriptURLs: [],
            manifestURL: temporaryDirectory.appendingPathComponent("Interview.tare-link.json"),
            modelIdentifier: "gemini-3.5-transcribe"
        )
        let result = try await AudioLyricsEmbedder().attachToSource(
            sourceURL: sourceURL,
            lyrics: lyrics,
            linkMetadata: metadata
        )

        try expect(result.replacedSource, "Audio lyrics embedding should replace the source file with a tagged copy.")
        try expect(result.outputURL.path == sourceURL.path, "Audio lyrics embedding should keep the original source path.")
        try expect(FileManager.default.fileExists(atPath: sourceURL.path), "Tagged source audio file was not written.")
        try expect(FileManager.default.fileExists(atPath: result.backupURL.path), "Original audio backup was not written.")
        try expect(result.backupURL.deletingLastPathComponent().lastPathComponent == "Original Audio Backups", "Original audio backup folder is wrong.")

        let probe = try await runner.run(
            executableURL: ffprobeURL,
            arguments: [
                "-v", "error",
                "-show_entries", "format_tags=lyrics",
                "-of", "default=noprint_wrappers=1:nokey=1",
                sourceURL.path
            ]
        )

        try expect(probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "First sentence.\nSecond sentence.", "Embedded audio lyrics tag is wrong.")

        let metadataProbe = try await runner.run(
            executableURL: ffprobeURL,
            arguments: [
                "-v", "error",
                "-show_entries", "format_tags=description",
                "-of", "default=noprint_wrappers=1:nokey=1",
                sourceURL.path
            ]
        )
        let decodedMetadata = TranscriptLinker.decodeEmbeddedMetadata(from: metadataProbe.stdout)
        try expect(decodedMetadata?.linkID == metadata.linkID, "Embedded audio link metadata did not round-trip.")
        try expect(metadataProbe.stdout.contains("gemini-3.5-transcribe"), "Embedded audio link metadata omitted the model identifier.")
    }

    private static func testTranscriptLinkerWritesAndReadsManifest() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("Source.m4a")
        let transcriptURL = temporaryDirectory.appendingPathComponent("Source.plain-transcript.txt")
        try Data("source".utf8).write(to: sourceURL)
        try Data("transcript".utf8).write(to: transcriptURL)

        let outputDirectory = temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        let linker = TranscriptLinker()
        let manifestURL = linker.manifestURL(for: sourceURL, outputDirectory: outputDirectory)
        let metadata = linker.metadata(
            for: makeTranscript(),
            sourceURL: sourceURL,
            transcriptURLs: [transcriptURL],
            manifestURL: manifestURL,
            modelIdentifier: "gemini-3.5-transcribe"
        )

        let writtenURL = try linker.write(metadata)
        try expect(writtenURL.path == manifestURL.path, "Transcript link manifest path was not preserved.")
        try expect(FileManager.default.fileExists(atPath: manifestURL.path), "Transcript link manifest was not written.")
        try expect(FileManager.default.fileExists(atPath: linker.sourceSidecarURL(for: sourceURL).path), "Source-side transcript link pointer was not written.")

        let manifestData = try Data(contentsOf: manifestURL)
        let manifestDecoder = JSONDecoder()
        manifestDecoder.dateDecodingStrategy = .iso8601
        let decodedManifest = try manifestDecoder.decode(TranscriptLinkMetadata.self, from: manifestData)
        try expect(decodedManifest.linkID == metadata.linkID, "Transcript link manifest did not preserve its link ID.")
        try expect(decodedManifest.primaryTranscriptPath == transcriptURL.standardizedFileURL.path, "Transcript link manifest did not preserve the transcript path.")

        let discovered = linker.existingLink(for: sourceURL)
        try expect(discovered?.linkID == metadata.linkID, "Tare did not rediscover the source-side transcript link.")
        try expect(discovered?.primaryTranscriptURL?.path == transcriptURL.standardizedFileURL.path, "Rediscovered transcript link points to the wrong transcript.")

        let sidecarData = try Data(contentsOf: linker.sourceSidecarURL(for: sourceURL))
        let sidecarText = String(data: sidecarData, encoding: .utf8) ?? ""
        try expect(!sidecarText.contains("\n"), "Source-side transcript pointer should stay compact.")
        try expect(manifestData != sidecarData, "Visible manifest and compact source pointer should use different formatting.")
    }

    private static func testTranscriptNamingFallbackAndParsing() throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/BIO-111_Scientific_Method_Recording.m4a")
        let fallback = TranscriptNamingService.deterministicSuggestion(for: sourceURL)
        try expect(fallback.title == "Bio 111 Scientific Method", "Filename fallback should remove recording noise and preserve course words.")
        try expect(fallback.folderName == fallback.title, "Filename fallback should use one compact folder name.")
        try expect(fallback.provider == "local", "Filename fallback should be explicitly local.")

        let response = """
        {"model":"gpt-oss-120b","choices":[{"message":{"content":"{\\"title\\":\\"BIO 111: Cell Membranes\\",\\"folder\\":\\"BIO 111 - Cell Membranes\\"}"}}]}
        """
        let parsed = TranscriptNamingService.parseSuggestion(
            from: Data(response.utf8),
            sourceURL: sourceURL,
            modelIdentifier: "gpt-oss-120b"
        )
        try expect(parsed?.title == "BIO 111 - Cell Membranes", "LLM title parsing should sanitize filesystem punctuation.")
        try expect(parsed?.folderName == "BIO 111 - Cell Membranes", "LLM folder parsing should preserve the compact subject name.")
        try expect(parsed?.modelIdentifier == "gpt-oss-120b", "LLM parsing should retain the selected model identifier.")
    }

    private static func testFreeLLMLiveNaming() async throws {
        guard let key = ProcessInfo.processInfo.environment["TARE_FREELLM_API_KEY"], !key.isEmpty else {
            throw SmokeTestFailure.failed("Set TARE_FREELLM_API_KEY for the explicit live smoke test; it never reads Keychain.")
        }

        let transcript = Transcript(
            sourceName: "BIO-111_lecture.m4a",
            createdAt: Date(timeIntervalSince1970: 0),
            localeIdentifier: "en_US",
            fullText: "Today we compare phospholipid bilayers, membrane proteins, and the role of cholesterol in cell membrane fluidity.",
            segments: []
        )
        let sourceURL = URL(fileURLWithPath: "/tmp/BIO-111_lecture.m4a")
        let service = TranscriptNamingService(configuration: .discovered())
        guard let suggestion = await service.suggestName(
            for: transcript,
            sourceURL: sourceURL,
            apiKey: key
        ) else {
            throw SmokeTestFailure.failed("FreeLLMAPI did not return a usable naming suggestion.")
        }

        print("FreeLLMAPI live naming passed: \(suggestion.title) [\(suggestion.modelIdentifier)]")
    }

    private static func testOutputFolderPlannerCreatesSemanticFolder() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let folder = try OutputFolderPlanner.createTranscriptDirectory(
            rootDirectory: temporaryDirectory,
            title: "BIO 111 / Cell Membranes"
        )
        try expect(folder.lastPathComponent == "BIO 111 - Cell Membranes", "Semantic transcript folder should be filesystem-safe and readable.")
        try expect(FileManager.default.fileExists(atPath: folder.path), "Semantic transcript folder was not created.")

        let secondFolder = try OutputFolderPlanner.createTranscriptDirectory(
            rootDirectory: temporaryDirectory,
            title: "BIO 111 / Cell Membranes"
        )
        try expect(secondFolder.lastPathComponent == "BIO 111 - Cell Membranes 2", "Repeated exports should not overwrite a semantic transcript folder.")
    }

    private static func testAudioLyricsEmbedderOnlyTargetsContainersThatPersistLyrics() throws {
        try expect(AudioLyricsEmbedder.canAttachLyrics(to: URL(fileURLWithPath: "/tmp/song.m4a")), "M4A should support embedded lyrics.")
        try expect(AudioLyricsEmbedder.canAttachLyrics(to: URL(fileURLWithPath: "/tmp/song.mp3")), "MP3 should support embedded lyrics.")
        try expect(AudioLyricsEmbedder.canAttachLyrics(to: URL(fileURLWithPath: "/tmp/song.caf")), "CAF should support embedded lyrics.")
        try expect(!AudioLyricsEmbedder.canAttachLyrics(to: URL(fileURLWithPath: "/tmp/song.wav")), "WAV should not claim embedded lyrics support because ffmpeg drops the tag.")
        try expect(!AudioLyricsEmbedder.canAttachLyrics(to: URL(fileURLWithPath: "/tmp/song.aiff")), "AIFF should not claim embedded lyrics support because ffmpeg drops the tag.")
        try expect(!AudioLyricsEmbedder.canAttachLyrics(to: URL(fileURLWithPath: "/tmp/song.aac")), "AAC should not claim embedded lyrics support because ffmpeg drops the tag.")
    }

    private static func testExporterUsesUniquePathInsteadOfOverwriting() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let transcript = makeTranscript()
        let exporter = TranscriptExporter()
        let sourceURL = URL(fileURLWithPath: "/tmp/Interview.mov")
        let existingURL = temporaryDirectory.appendingPathComponent("Interview.plain-transcript.txt")
        try "existing".write(to: existingURL, atomically: true, encoding: .utf8)

        let urls = try await exporter.export(
            transcript,
            sourceURL: sourceURL,
            to: temporaryDirectory,
            formats: [.text]
        )

        try expect(urls.map(\.lastPathComponent) == ["Interview.plain-transcript-2.txt"], "Exporter did not choose the expected unique filename.")
        let originalContents = try String(contentsOf: existingURL)
        try expect(originalContents == "existing", "Exporter overwrote an existing file.")
    }

    private static func testExporterCollapsesPunctuationInOutputBasename() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let exporter = TranscriptExporter()
        let urls = try await exporter.export(
            makeTranscript(),
            sourceURL: URL(fileURLWithPath: "/tmp/Quick Action Audio (2026).aiff"),
            to: temporaryDirectory,
            formats: [.text]
        )

        try expect(urls.map(\.lastPathComponent) == ["Quick-Action-Audio-2026.plain-transcript.txt"], "Exporter did not collapse punctuation in output basename.")
    }

    private static func testExporterRemovesReleaseTagsFromOutputBasename() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let exporter = TranscriptExporter()
        let urls = try await exporter.export(
            makeTranscript(),
            sourceURL: URL(fileURLWithPath: "/tmp/Movie.Title.2020.1080p.WEB-DL.x264.m4a"),
            to: temporaryDirectory,
            formats: [.text]
        )

        try expect(urls.map(\.lastPathComponent) == ["Movie-Title-2020.plain-transcript.txt"], "Exporter did not remove release tags from output basename.")
    }

    private static func testExporterFormatsSubtitleTextForPlayers() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let transcript = Transcript(
            sourceName: "Wrapped.mov",
            createdAt: Date(timeIntervalSince1970: 0),
            localeIdentifier: "en",
            fullText: "This subtitle has awkward spacing.",
            segments: [
                TranscriptSegment(
                    index: 1,
                    startTime: 0,
                    duration: 2,
                    text: "This subtitle has awkward\n\nspacing and should wrap into player-friendly lines without blank cue rows."
                )
            ]
        )

        _ = try await TranscriptExporter().export(
            transcript,
            sourceURL: URL(fileURLWithPath: "/tmp/Wrapped.mov"),
            to: temporaryDirectory,
            formats: [.srt, .vtt]
        )

        let srt = try String(contentsOf: temporaryDirectory.appendingPathComponent("Wrapped.transcript.srt"))
        let vtt = try String(contentsOf: temporaryDirectory.appendingPathComponent("Wrapped.transcript.vtt"))

        try expect(!srt.contains("awkward\n\nspacing"), "SRT cue text should not contain blank lines inside a cue.")
        try expect(srt.contains("player-friendly"), "SRT cue text should preserve words while wrapping.")
        try expect(srt.contains("blank cue rows."), "SRT cue text should preserve the end of the cue while wrapping.")
        try expect(!vtt.contains("awkward\n\nspacing"), "VTT cue text should not contain blank lines inside a cue.")
    }

    private static func testExporterWritesEmptyCaptionCuesForNoSpeech() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let transcript = Transcript(
            sourceName: "Silent.mov",
            createdAt: Date(timeIntervalSince1970: 0),
            localeIdentifier: "en_US",
            fullText: "No audible speech detected. Maximum audio level: -91.0 dB.",
            segments: []
        )

        let urls = try await TranscriptExporter().export(
            transcript,
            sourceURL: URL(fileURLWithPath: "/tmp/Silent.mov"),
            to: temporaryDirectory,
            formats: [.text, .srt, .vtt, .captionedVideo]
        )

        try expect(!urls.contains(where: { $0.lastPathComponent == "Silent.captioned.mov" }), "No-speech video should not duplicate the source with empty subtitles.")

        let srt = try String(contentsOf: temporaryDirectory.appendingPathComponent("Silent.transcript.srt"))
        let vtt = try String(contentsOf: temporaryDirectory.appendingPathComponent("Silent.transcript.vtt"))
        let text = try String(contentsOf: temporaryDirectory.appendingPathComponent("Silent.plain-transcript.txt"))

        try expect(srt.isEmpty, "No-speech SRT should not create a false subtitle cue.")
        try expect(vtt == "WEBVTT\n\n", "No-speech VTT should only contain the VTT header.")
        try expect(text.contains("No audible speech detected"), "No-speech text export should keep the diagnostic note.")
    }

    private static func testCaptionedVideoExportEmbedsSubtitleTrack() async throws {
        guard let ffmpegURL = FFmpegAudioExtractor.resolveExecutable(named: "ffmpeg"),
              let ffprobeURL = FFmpegAudioExtractor.resolveExecutable(named: "ffprobe") else {
            print("Skipping captioned video export test because ffmpeg or ffprobe is missing")
            return
        }

        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("Caption Source.mp4")
        let runner = ProcessRunner()
        _ = try await runner.run(
            executableURL: ffmpegURL,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-nostdin",
                "-y",
                "-f", "lavfi",
                "-i", "color=c=black:s=320x180:d=2",
                "-f", "lavfi",
                "-i", "sine=frequency=1000:duration=2",
                "-t", "2",
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                "-c:a", "aac",
                "-shortest",
                sourceURL.path
            ]
        )

        let transcript = Transcript(
            sourceName: sourceURL.lastPathComponent,
            createdAt: Date(timeIntervalSince1970: 0),
            localeIdentifier: "en",
            fullText: "Caption test.",
            segments: [
                TranscriptSegment(index: 1, startTime: 0.2, duration: 1.2, text: "Caption test.")
            ]
        )

        let urls = try await TranscriptExporter().export(
            transcript,
            sourceURL: sourceURL,
            to: temporaryDirectory,
            formats: [.captionedVideo]
        )

        try expect(urls.map(\.lastPathComponent) == ["Caption-Source.captioned.mkv"], "Captioned video output name is wrong.")
        try expect(FileManager.default.fileExists(atPath: urls[0].path), "Captioned video file was not written.")

        let probe = try await runner.run(
            executableURL: ffprobeURL,
            arguments: [
                "-v", "error",
                "-select_streams", "s",
                "-show_streams",
                "-of", "json",
                urls[0].path
            ]
        )

        try expect(probe.stdout.contains("\"codec_name\": \"subrip\""), "Captioned video should contain a SubRip subtitle track.")
        try expect(probe.stdout.contains("\"default\": 1"), "Captioned video subtitle track should be marked default for IINA/mpv.")
        try expect(probe.stdout.contains("\"title\": \"Transcript\""), "Subtitle track should be titled Transcript.")
        try expect(CaptionedVideoExporter.preferredOutputExtension(for: URL(fileURLWithPath: "/tmp/Movie.mkv")) == "mkv", "MKV sources should export captioned MKV without forcing a slow video transcode.")
        try expect(CaptionedVideoExporter.preferredOutputExtension(for: URL(fileURLWithPath: "/tmp/Movie.mp4")) == "mkv", "MP4 sources should export captioned MKV so default subtitle selection works in IINA/mpv.")

        let mkvSourceURL = temporaryDirectory.appendingPathComponent("Movie MKV Source.mkv")
        _ = try await runner.run(
            executableURL: ffmpegURL,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-nostdin",
                "-y",
                "-f", "lavfi",
                "-i", "color=c=blue:s=320x180:d=2",
                "-f", "lavfi",
                "-i", "sine=frequency=440:duration=2",
                "-t", "2",
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                "-c:a", "aac",
                "-shortest",
                mkvSourceURL.path
            ]
        )

        let mkvURLs = try await TranscriptExporter().export(
            transcript,
            sourceURL: mkvSourceURL,
            to: temporaryDirectory,
            formats: [.captionedVideo]
        )

        try expect(mkvURLs.map(\.lastPathComponent) == ["Movie-MKV-Source.captioned.mkv"], "MKV captioned video output name is wrong.")

        let mkvProbe = try await runner.run(
            executableURL: ffprobeURL,
            arguments: [
                "-v", "error",
                "-select_streams", "s",
                "-show_streams",
                "-of", "json",
                mkvURLs[0].path
            ]
        )

        try expect(mkvProbe.stdout.contains("\"codec_name\": \"subrip\""), "Captioned MKV should contain a SubRip subtitle track.")
        try expect(mkvProbe.stdout.contains("\"default\": 1"), "Captioned MKV subtitle track should be marked default for IINA/mpv.")
        try expect(mkvProbe.stdout.contains("\"title\": \"Transcript\""), "Captioned MKV subtitle track should be titled Transcript.")
    }

    private static func testAttachToSourceReplacesMKVWithEmbeddedSubtitleTrack() async throws {
        guard let ffmpegURL = FFmpegAudioExtractor.resolveExecutable(named: "ffmpeg"),
              let ffprobeURL = FFmpegAudioExtractor.resolveExecutable(named: "ffprobe") else {
            print("Skipping source attachment test because ffmpeg or ffprobe is missing")
            return
        }

        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("Source To Attach.mkv")
        let runner = ProcessRunner()
        _ = try await runner.run(
            executableURL: ffmpegURL,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-nostdin",
                "-y",
                "-f", "lavfi",
                "-i", "color=c=green:s=320x180:d=2",
                "-f", "lavfi",
                "-i", "sine=frequency=330:duration=2",
                "-t", "2",
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                "-c:a", "aac",
                "-shortest",
                sourceURL.path
            ]
        )

        let captions = """
        1
        00:00:00,200 --> 00:00:01,400
        Attached caption.

        """
        let result = try await CaptionedVideoExporter().attachToSource(
            sourceURL: sourceURL,
            captions: captions,
            localeIdentifier: "en_US"
        )

        try expect(result.replacedSource, "MKV source should be replaced in place.")
        try expect(result.outputURL.path == sourceURL.path, "Attached output should keep the original source path.")
        try expect(FileManager.default.fileExists(atPath: sourceURL.path), "Source path should still exist after attachment.")
        try expect(result.backupURL != nil, "Source replacement should keep a backup.")
        try expect(FileManager.default.fileExists(atPath: result.backupURL?.path ?? ""), "Original video backup was not written.")

        let probe = try await runner.run(
            executableURL: ffprobeURL,
            arguments: [
                "-v", "error",
                "-select_streams", "s",
                "-show_streams",
                "-of", "json",
                sourceURL.path
            ]
        )

        try expect(probe.stdout.contains("\"codec_name\": \"subrip\""), "Attached source should contain a SubRip subtitle track.")
        try expect(probe.stdout.contains("\"default\": 1"), "Attached source subtitle track should be marked default for IINA/mpv.")
        try expect(probe.stdout.contains("\"title\": \"Transcript\""), "Attached source subtitle track should be titled Transcript.")
    }

    private static func testAttachToSourcePackagesMP4AsSelectableMKV() async throws {
        guard let ffmpegURL = FFmpegAudioExtractor.resolveExecutable(named: "ffmpeg"),
              let ffprobeURL = FFmpegAudioExtractor.resolveExecutable(named: "ffprobe") else {
            print("Skipping MP4 source attachment test because ffmpeg or ffprobe is missing")
            return
        }

        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("Source To Attach.mp4")
        let runner = ProcessRunner()
        _ = try await runner.run(
            executableURL: ffmpegURL,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-nostdin",
                "-y",
                "-f", "lavfi",
                "-i", "color=c=purple:s=320x180:d=2",
                "-f", "lavfi",
                "-i", "sine=frequency=550:duration=2",
                "-t", "2",
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                "-c:a", "aac",
                "-shortest",
                sourceURL.path
            ]
        )

        let captions = """
        1
        00:00:00,200 --> 00:00:01,400
        Selectable caption.

        """
        let result = try await CaptionedVideoExporter().attachToSource(
            sourceURL: sourceURL,
            captions: captions,
            localeIdentifier: "en_US"
        )

        try expect(!result.replacedSource, "MP4 source should not be replaced with a mov_text subtitle track.")
        try expect(result.outputURL.lastPathComponent == "Source To Attach.captioned.mkv", "MP4 attachment should create an IINA-friendly captioned MKV.")
        try expect(FileManager.default.fileExists(atPath: sourceURL.path), "Original MP4 should remain in place.")
        try expect(result.backupURL == nil, "MP4 packaging should not create an in-place replacement backup.")

        let probe = try await runner.run(
            executableURL: ffprobeURL,
            arguments: [
                "-v", "error",
                "-select_streams", "s",
                "-show_streams",
                "-of", "json",
                result.outputURL.path
            ]
        )

        try expect(probe.stdout.contains("\"codec_name\": \"subrip\""), "Packaged MP4 output should contain a SubRip subtitle track.")
        try expect(probe.stdout.contains("\"default\": 1"), "Packaged MP4 subtitle track should be marked default for IINA/mpv.")
        try expect(probe.stdout.contains("\"title\": \"Transcript\""), "Packaged MP4 subtitle track should be titled Transcript.")
    }

    private static func testOutputFolderPlannerUsesDocumentsDefault() throws {
        let defaultRoot = OutputFolderPlanner.defaultRootDirectory()
        try expect(defaultRoot.lastPathComponent == "Tare Transcripts", "Default output folder name is not stable.")

        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try expect(
                defaultRoot.deletingLastPathComponent().standardizedFileURL.path == documents.standardizedFileURL.path,
                "Default output folder should live directly inside Documents."
            )
        }
    }

    private static func testOutputFolderPlannerNamesSingleFileFolder() throws {
        let date = fixedLocalDate()
        let folderName = OutputFolderPlanner.folderName(
            for: [URL(fileURLWithPath: "/tmp/Movie.Title.2020.1080p.WEB-DL.x264.mkv")],
            date: date
        )

        try expect(folderName == "Movie Title (2020) Transcript", "Single-file transcript folder name is not readable.")

        let acronymFolderName = OutputFolderPlanner.folderName(
            for: [URL(fileURLWithPath: "/tmp/Finder.MKV.Test.2026.1080p.WEB-DL.x264.mkv")],
            date: date
        )

        try expect(acronymFolderName == "Finder MKV Test (2026) Transcript", "Media acronym casing is not preserved.")
    }

    private static func testOutputFolderPlannerUsesSourceParentWhenPossible() throws {
        let fallback = URL(fileURLWithPath: "/tmp/Fallback", isDirectory: true)
        let sharedParent = URL(fileURLWithPath: "/tmp/Movies", isDirectory: true)
        let first = sharedParent.appendingPathComponent("First.mov")
        let second = sharedParent.appendingPathComponent("Second.mkv")

        let sourceRoot = OutputFolderPlanner.sourceOutputRootDirectory(
            for: [first, second],
            fallback: fallback
        )

        try expect(sourceRoot.path == sharedParent.path, "Sources in the same folder should save outputs next to the media.")

        let mixedRoot = OutputFolderPlanner.sourceOutputRootDirectory(
            for: [
                URL(fileURLWithPath: "/tmp/Movies/First.mov"),
                URL(fileURLWithPath: "/tmp/Other/Second.mov")
            ],
            fallback: fallback
        )

        try expect(mixedRoot.path == fallback.path, "Mixed source folders should fall back to the configured root.")
    }

    private static func testOutputFolderPlannerCreatesUniqueBatchFolder() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let date = fixedLocalDate()
        let sources = [
            URL(fileURLWithPath: "/tmp/First.mov"),
            URL(fileURLWithPath: "/tmp/Second.mov")
        ]

        let first = try OutputFolderPlanner.createBatchDirectory(
            rootDirectory: temporaryDirectory,
            sourceURLs: sources,
            date: date
        )
        let second = try OutputFolderPlanner.createBatchDirectory(
            rootDirectory: temporaryDirectory,
            sourceURLs: sources,
            date: date
        )

        try expect(first.lastPathComponent == "Transcription Batch 2026-05-18 12-00-00 (2 Files)", "Batch folder name is not readable.")
        try expect(second.lastPathComponent == "Transcription Batch 2026-05-18 12-00-00 (2 Files) 2", "Duplicate batch folder did not get a unique suffix.")
    }

    private static func testMKVDiscoveryFindsMKVFiles() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let nested = temporaryDirectory.appendingPathComponent("Nested", isDirectory: true)
        let backups = temporaryDirectory.appendingPathComponent("Original Video Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("Episode.mkv"))
        try Data().write(to: nested.appendingPathComponent("Clip.mp4"))
        try Data().write(to: backups.appendingPathComponent("Backup.mkv"))

        let discovered = await MKVDiscoveryService().discover(in: [temporaryDirectory])

        try expect(discovered.map(\.lastPathComponent) == ["Episode.mkv"], "MKV discovery should find MKVs and skip backup folders.")
    }

    private static func testMediaLibraryOrganizerMovesTVEpisodeAndWritesTableOfContents() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let source = temporaryDirectory.appendingPathComponent("Game of Thrones - S01E03 - Lord Snow.mkv")
        try Data("episode".utf8).write(to: source)

        let library = temporaryDirectory.appendingPathComponent("Library", isDirectory: true)
        let result = try await MediaLibraryOrganizer().organize(
            sourceURL: source,
            libraryRoot: library
        )

        try expect(result.moved, "Organizer should move the MKV into the library.")
        try expect(result.destinationURL.lastPathComponent == "Game of Thrones - S01E03 - Lord Snow.mkv", "Organizer should keep the cleaned episode filename.")
        try expect(result.destinationURL.deletingLastPathComponent().lastPathComponent == "Season 01", "Organizer should place TV files in the matching season folder.")
        try expect(result.destinationURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Game of Thrones", "Organizer should place TV files under the show folder.")
        guard let tableURL = result.tableOfContentsURL else {
            throw SmokeTestFailure.failed("Organizer did not write a table of contents for a TV MKV.")
        }
        try expect(tableURL.deletingLastPathComponent().lastPathComponent == "Game of Thrones", "Table of contents should be written at the show folder.")
        let contents = try String(contentsOf: tableURL)
        try expect(contents.contains("## Game of Thrones"), "Table of contents should group by show name.")
        try expect(contents.contains("| S01E03 | Lord Snow | Game of Thrones - S01E03 - Lord Snow.mkv |"), "Table of contents should include the TV episode row.")
    }

    private static func testFilenameCleanerDecodesResults() throws {
        let json = """
        [
          {
            "path": "/tmp/Show.S01E01.mkv",
            "old_name": "Show.S01E01.mkv",
            "new_name": "Show - S01E01.mkv",
            "target_path": "/tmp/Show - S01E01.mkv",
            "changed": true,
            "renamed": true,
            "reason": "TV episode pattern",
            "category": "tv",
            "confidence": 0.95,
            "elapsed_seconds": 0.01
          }
        ]
        """

        let results = try FilenameCleanerService.decodeResults(from: json)
        try expect(results.first?.targetURL.lastPathComponent == "Show - S01E01.mkv", "Cleaner JSON decoder should expose the cleaned target URL.")
        try expect(results.first?.category == "tv", "Cleaner JSON decoder should preserve TV categories.")
    }

    private static func fixedLocalDate() -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone.current
        components.year = 2026
        components.month = 5
        components.day = 18
        components.hour = 12
        components.minute = 0
        components.second = 0
        return components.date!
    }

    private static func testWhisperEnvironmentIncludesHomebrewPath() throws {
        let environment = WhisperTranscriptionService.transcriptionEnvironment(processEnvironment: ["PATH": "/usr/bin:/bin"])
        try expect(environment["PYTHONUNBUFFERED"] == "1", "Whisper environment should run Python unbuffered.")
        try expect(environment["PATH"]?.contains("/opt/homebrew/bin") == true, "Whisper environment should include Homebrew ffmpeg path.")
        try expect(environment["PATH"]?.contains("/usr/bin:/bin") == true, "Whisper environment should preserve the existing PATH.")
    }

    private static func testWhisperLanguageSelection() throws {
        try expect(WhisperTranscriptionService.languageCode(from: "auto") == nil, "Auto language should omit the language argument.")
        try expect(WhisperTranscriptionService.languageCode(from: "en_US") == "en", "Locale should resolve to a language code.")
        try expect(WhisperTranscriptionService.languageCode(from: "es") == "es", "Language code should pass through.")
    }

    private static func testWhisperModelPresets() throws {
        try expect(WhisperModelPreset.qwen3ASR6Bit.id == "mlx-community/Qwen3-ASR-1.7B-6bit", "Qwen3-ASR 6-bit should use the MLX community checkpoint.")
        try expect(WhisperModelPreset.canaryQwen.id == "speechllms/canary-speechlm-mlx", "Canary-Qwen should use the local MLX port.")
        try expect(WhisperModelPreset.canaryQwen.backend == .canary, "Canary-Qwen should use its dedicated backend route.")
        try expect(WhisperModelPreset.voxtralSmall.id == "VincentGOURBIN/voxtral-small-4bit-mixed", "Voxtral Small should use the mixed 4-bit local checkpoint.")
        try expect(WhisperModelPreset.voxtralMini8BitDense.id == "MarkusKaemmerer/Voxtral-Mini-3B-2507-8bit-dense-encoder", "Voxtral Mini 8-bit should use the dense-encoder MLX checkpoint.")
        try expect(WhisperModelPreset.cohereTranscribe.id == "aufklarer/Cohere-Transcribe-2B-MLX-FP16", "Cohere Transcribe should use the MLX BF16 checkpoint.")
        try expect(WhisperModelPreset.qwen3ASRBF16.id == "mlx-community/Qwen3-ASR-1.7B-bf16", "Qwen3-ASR BF16 should use the MLX community checkpoint.")
        try expect(WhisperModelPreset.qwen3ASR8Bit.id == "mlx-community/Qwen3-ASR-1.7B-8bit", "Qwen3-ASR 8-bit should use the MLX community checkpoint.")
        try expect(WhisperModelPreset.voxtralMini.id == "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit", "Voxtral Mini should use the MLX realtime checkpoint.")
        try expect(WhisperModelPreset.usesMLXAudio(WhisperModelPreset.qwen3ASR8Bit.id), "Qwen3-ASR should use the MLX-Audio backend.")
        try expect(WhisperModelPreset.qwen3ASR6Bit.backend == .mlxAudio, "Qwen3-ASR 6-bit should use the MLX-Audio backend.")
        try expect(WhisperModelPreset.voxtralMini8BitDense.backend == .mlxVoxtral, "Voxtral Mini 8-bit should use the dedicated Voxtral backend.")
        try expect(WhisperModelPreset.isVoxtral(WhisperModelPreset.voxtralMini8BitDense.id), "Voxtral Mini 8-bit should be recognized by the dedicated backend.")
        try expect(WhisperModelPreset.usesLongFormInference(WhisperModelPreset.voxtralMini.id), "MLX-Audio models should bypass Whisper chunking.")
        try expect(WhisperModelPreset.usesLongFormInference(WhisperModelPreset.voxtralMini8BitDense.id), "Voxtral models should bypass Whisper chunking.")
        try expect(WhisperModelPreset.usesLongFormInference(WhisperModelPreset.canaryQwen.id), "Canary-Qwen should bypass Whisper chunking.")
        try expect(WhisperModelPreset.fastestMultilingual.id == "mlx-community/whisper-tiny", "Fastest multilingual model should use the tiny local MLX preset.")
        try expect(WhisperModelPreset.fastestMultilingual.isMultilingual, "Fastest multilingual preset should support language detection.")
        try expect(WhisperModelPreset.fastMultilingual.id == "mlx-community/whisper-base-mlx", "Fast multilingual model should use the base local MLX preset.")
        try expect(WhisperModelPreset.fastMultilingual.isMultilingual, "Fast multilingual preset should support language detection.")
        try expect(WhisperModelPreset.fastTurboMultilingual.id == "mlx-community/whisper-large-v3-turbo", "Fast turbo multilingual model should use the mlx-whisper compatible local turbo preset.")
        try expect(WhisperModelPreset.fastTurboMultilingual.isMultilingual, "Fast turbo multilingual preset should support language detection.")
        try expect(WhisperModelPreset.parakeetV3.id == "mlx-community/parakeet-tdt-0.6b-v3", "Parakeet v3 should use the MLX-compatible local repository.")
        try expect(WhisperModelPreset.isParakeetV3(WhisperModelPreset.parakeetV3.id), "Parakeet v3 should be recognized by the dedicated backend.")
        try expect(WhisperModelPreset.distilledLargeMultilingual.id == "mlx-community/distil-whisper-large-v3", "Distilled large multilingual model should use the local Distil Whisper Large v3 preset.")
        try expect(WhisperModelPreset.distilledLargeMultilingual.isMultilingual, "Distilled large multilingual preset should support language detection.")
        try expect(WhisperModelPreset.highestAccuracyMultilingual.id == "mlx-community/whisper-large-v3-mlx", "Highest accuracy model should use the local Large v3 MLX preset.")
        try expect(WhisperModelPreset.highestAccuracyMultilingual.isMultilingual, "Highest accuracy preset should support language detection.")
        try expect(WhisperModelPreset.accurateMultilingual.id == "mlx-community/whisper-medium-mlx-4bit", "Accurate multilingual model should use the medium 4-bit preset.")
        try expect(WhisperModelPreset.accurateMultilingual.isMultilingual, "Accurate multilingual preset should support language detection.")
        try expect(WhisperModelPreset.balancedMultilingual.isMultilingual, "Balanced multilingual preset should support language detection.")
        try expect(WhisperModelPreset.fastEnglish.id == "mlx-community/whisper-base.en-mlx", "Fast English model should use the base English local MLX preset.")
        try expect(!WhisperModelPreset.balancedEnglish.isMultilingual, "English-only preset should be marked as English-only.")
        try expect(WhisperModelPreset.all.prefix(3) == [.parakeetV3, .qwen3ASR6Bit, .voxtralMini8BitDense], "The recommended 16 GB model presets should be first in the catalog.")
        try expect(WhisperModelPreset.normalizedIdentifier("") == WhisperModelPreset.fastMultilingual.id, "Empty model preference should resolve to the faster base preset.")
        try expect(WhisperModelPreset.normalizedIdentifier("mlx-community/whisper-large-v3-turbo-4bit") == WhisperModelPreset.fastTurboMultilingual.id, "Old turbo 4-bit preference should resolve to the mlx-whisper compatible turbo preset.")
        try expect(WhisperModelPreset.normalizedIdentifier("mlx-community/whisper-small.en-mlx") == WhisperModelPreset.balancedEnglish.id, "Existing English preset should not be downgraded to the default model.")
        try expect(WhisperModelPreset.optimizedIdentifier(WhisperModelPreset.fastMultilingual.id, languageCode: "en") == WhisperModelPreset.fastEnglish.id, "English speed jobs should use the measured fast English preset.")
        try expect(WhisperModelPreset.optimizedIdentifier(WhisperModelPreset.fastMultilingual.id, languageCode: nil) == WhisperModelPreset.fastMultilingual.id, "Auto-detect jobs should keep a multilingual preset.")
        try expect(WhisperModelPreset.optimizedIdentifier(WhisperModelPreset.highestAccuracyMultilingual.id, languageCode: "en") == WhisperModelPreset.highestAccuracyMultilingual.id, "Accuracy-focused models should not be downgraded for English.")
        try expect(WhisperModelPreset.usesLongFormInference(WhisperModelPreset.mossDiarize.id), "MOSS should bypass Whisper chunking.")
        try expect(WhisperModelPreset.usesLongFormInference(WhisperModelPreset.parakeetV3.id), "Parakeet should use its dedicated chunking implementation.")
    }

    private static func testGeminiModelDetectionAndOptions() throws {
        let cloudPreset = WhisperModelPreset.gemini35Transcribe
        try expect(cloudPreset.id == "gemini-3.5-transcribe", "Gemini 3.5 Transcribe should use Google's exact model identifier.")
        try expect(cloudPreset.backend == .geminiTranscribe, "Gemini 3.5 Transcribe should use the cloud backend route.")
        try expect(cloudPreset.isCloud && !cloudPreset.isLocal, "Cloud and local model classifications should be mutually exclusive.")
        try expect(WhisperModelPreset.cloud == [cloudPreset], "The cloud catalog should contain the Gemini transcriber only.")
        try expect(WhisperModelPreset.local.allSatisfy(\.isLocal), "The local catalog should exclude cloud models.")
        try expect(
            WhisperModelPreset.preset(for: "GOOGLE/GEMINI-3.5-TRANSCRIBE") == cloudPreset,
            "Gemini aliases should resolve case-insensitively to the canonical preset."
        )
        try expect(
            WhisperModelPreset.isGeminiTranscribe(" models/gemini-3.5-transcribe "),
            "Gemini model detection should accept the documented resource-style alias."
        )

        let vocabulary = GeminiTranscriptionOptions.vocabularyTerms(from: "Gemini, gemini\nKubernetes; ")
        try expect(vocabulary == ["Gemini", "Kubernetes"], "Gemini vocabulary parsing should trim and de-duplicate terms.")

        let documentedDefault = GeminiTranscriptionOptions()
        try expect(documentedDefault.mode == .verbatim, "Gemini options should follow Google's documented verbatim default.")
        try expect(documentedDefault.safeChunkSeconds == GeminiTranscriptionLimits.safePlainChunkSeconds, "Unannotated requests should use the 55-minute safety limit.")
        let validatedDefault = try documentedDefault.validated()
        try expect(validatedDefault == documentedDefault, "Default Gemini options should validate.")
        try expect(GeminiTranscriptionService.bcp47LanguageCode(from: "auto") == nil, "Auto detection should omit a language hint value.")
        try expect(GeminiTranscriptionService.bcp47LanguageCode(from: "en") == "en-US", "Compact English selection should expand to Google's supported BCP-47 hint.")
        try expect(GeminiTranscriptionService.bcp47LanguageCode(from: "en_GB") == "en-GB", "Supported BCP-47 locale hints should be normalized without losing their region.")
        try expect(GeminiTranscriptionService.bcp47LanguageCode(from: "en-AU") == nil, "Unsupported BCP-47 hints should fall back to automatic detection.")
        try expect(GeminiTranscriptionService.bcp47LanguageCode(from: "zh") == "cmn-Hans-CN", "Compact Chinese selection should use Google's supported Mandarin hint.")

        let annotated = GeminiTranscriptionOptions(mode: .verbatim, wordTimestamps: true, speakerDiarization: true)
        try expect(annotated.safeChunkSeconds == GeminiTranscriptionLimits.safeAnnotatedChunkSeconds, "Annotated mode should use the 28-minute safety limit.")
        try expect(throws: GeminiTranscriptionOptionsError.smartModeDoesNotSupportAnnotations) {
            _ = try GeminiTranscriptionOptions(mode: .smart, wordTimestamps: true).validated()
        }
        try expect(throws: GeminiTranscriptionOptionsError.vocabularyDoesNotSupportAnnotations) {
            _ = try GeminiTranscriptionOptions(mode: .verbatim, speakerDiarization: true, customVocabulary: ["Tare"]).validated()
        }
        try expect(throws: GeminiTranscriptionOptionsError.vocabularyLimitExceeded(1_001)) {
            _ = try GeminiTranscriptionOptions(customVocabulary: (0..<1_001).map { "term\($0)" }).validated()
        }
    }

    private static func testGeminiAPIKeyStorePersistence() throws {
        let suiteName = "com.tejas.Tare.smoke.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw SmokeTestFailure.failed("Could not create isolated defaults for Gemini key persistence.")
        }
        let metadataKey = "geminiAPIKeys.\(UUID().uuidString)"
        let keychainService = "com.tejas.Tare.smoke.\(UUID().uuidString)"
        let store = GeminiAPIKeyStore(
            defaults: defaults,
            metadataKey: metadataKey,
            keychainService: keychainService
        )
        defer {
            let records = (try? store.loadRecords()) ?? []
            for record in records {
                try? store.delete(record)
            }
            defaults.removePersistentDomain(forName: suiteName)
        }

        let first = try store.add(label: "  Primary lecture  ", apiKey: "test-gemini-primary-123")
        let second = try store.add(label: "", apiKey: "test-gemini-secondary-456")
        let reopened = GeminiAPIKeyStore(
            defaults: defaults,
            metadataKey: metadataKey,
            keychainService: keychainService
        )
        let reopenedRecords = try reopened.loadRecords()
        try expect(reopenedRecords.map(\.id) == [first.id, second.id], "Gemini key metadata should survive reopening the store.")
        try expect(reopenedRecords[0].label == "Primary lecture", "Gemini key labels should be trimmed before saving.")
        let reopenedCredentials = try reopened.activeCredentials()
        try expect(reopenedCredentials.count == 2, "Reopened Gemini key metadata should resolve both Keychain secrets.")

        try reopened.setEnabled(false, for: first)
        let disabledCredentials = try reopened.activeCredentials()
        try expect(disabledCredentials.map(\.id) == [second.id], "Disabling a key should persist across the active credential read.")
        try reopened.setEnabled(true, for: first)
        try reopened.delete(second)
        let remainingRecords = try reopened.loadRecords()
        try expect(remainingRecords.map(\.id) == [first.id], "Deleting a Gemini key should persist metadata and remove its secret.")
        try reopened.delete(first)

        defaults.set(Data("not-json".utf8), forKey: metadataKey)
        try expect(throws: GeminiAPIKeyStoreError.metadataFailure) {
            _ = try reopened.loadRecords()
        }
    }

    private static func testGeminiChunkPlanner() throws {
        let plain = GeminiTranscriptionOptions()
        let lectureDuration = 71 * 60 + 52
        let lecturePlan = GeminiAudioChunkPlanner.plan(
            duration: TimeInterval(lectureDuration),
            options: plain,
            safeBoundaries: [2_100, 2_200]
        )

        try expect(lecturePlan.isChunked, "A 71-minute lecture should be automatically chunked for Gemini.")
        try expect(lecturePlan.chunks.count == 2, "A 71:52 plain lecture should use two safe chunks.")
        try expect(lecturePlan.chunks.first?.startTime == 0, "Gemini chunk planning should start at the beginning of the recording.")
        try expect(abs((lecturePlan.chunks.last?.endTime ?? 0) - Double(lectureDuration)) < 0.001, "Gemini chunk planning should cover the complete recording.")
        try expect(lecturePlan.chunks.allSatisfy { $0.duration <= Double(plain.safeChunkSeconds) + 0.001 }, "Plain Gemini chunks must stay below the safe request size.")
        try expect(lecturePlan.chunks[1].startTime < lecturePlan.chunks[0].endTime, "Gemini chunks should overlap at interior boundaries for context continuity.")
        try expect(lecturePlan.estimatedInputTokens == Int64(lectureDuration) * Int64(GeminiTranscriptionLimits.audioTokensPerSecond), "Gemini input token estimates should follow the dedicated transcribe pricing token rate.")
        try expect(GeminiTranscriptionLimits.audioTokensPerSecond == 25, "Gemini 3.5 Transcribe pricing docs currently estimate 25 audio tokens per second.")

        let annotated = GeminiTranscriptionOptions(mode: .verbatim, wordTimestamps: true)
        let multiHourPlan = GeminiAudioChunkPlanner.plan(duration: 2 * 60 * 60, options: annotated)
        try expect(multiHourPlan.chunks.count == 5, "A two-hour annotated recording should use five 28-minute-safe chunks.")
        try expect(multiHourPlan.chunks.allSatisfy { $0.duration <= Double(annotated.safeChunkSeconds) + 0.001 }, "Annotated Gemini chunks must stay below the 30-minute documented limit.")
        try expect(multiHourPlan.chunks.first?.startTime == 0, "Multi-hour chunk planning should start at zero.")
        try expect(abs((multiHourPlan.chunks.last?.endTime ?? 0) - 7_200) < 0.001, "Multi-hour chunk planning should cover the complete recording.")

        let exactLimit = GeminiAudioChunkPlanner.plan(duration: TimeInterval(plain.safeChunkSeconds), options: plain)
        try expect(!exactLimit.isChunked && exactLimit.chunks.count == 1, "A recording exactly at the safe limit should not be split.")

        let justOverLimit = GeminiAudioChunkPlanner.plan(
            duration: TimeInterval(plain.safeChunkSeconds) + 0.01,
            options: plain
        )
        try expect(justOverLimit.chunks.count == 2, "A recording just over the safe plain limit should split into two chunks.")
        try expect(justOverLimit.chunks.allSatisfy { $0.duration <= Double(plain.safeChunkSeconds) + 0.001 }, "Near-limit plain chunks must stay within the safe duration.")

        let lectureTwoAndHalfHours: TimeInterval = 2.5 * 60 * 60
        let plainTwoHalf = GeminiAudioChunkPlanner.plan(
            duration: lectureTwoAndHalfHours,
            options: plain,
            safeBoundaries: [3_000, 6_000, 8_900]
        )
        try expect(plainTwoHalf.chunks.count == 3, "A 2h30m plain lecture should use three safe chunks.")
        try expect(plainTwoHalf.chunks.allSatisfy { $0.duration <= Double(plain.safeChunkSeconds) + 0.001 }, "2h30m plain chunks must stay under the 55-minute safe limit.")
        try expect(plainTwoHalf.chunks.first?.startTime == 0, "2h30m plain planning should start at zero.")
        try expect(abs((plainTwoHalf.chunks.last?.endTime ?? 0) - lectureTwoAndHalfHours) < 0.001, "2h30m plain planning should cover the full recording.")
        for index in 1..<plainTwoHalf.chunks.count {
            try expect(
                plainTwoHalf.chunks[index].startTime < plainTwoHalf.chunks[index - 1].endTime,
                "2h30m plain interior boundaries should overlap for context continuity."
            )
        }
        try expect(
            abs(plainTwoHalf.chunks[0].endTime - (3_000 + GeminiTranscriptionLimits.boundaryContextOverlapSeconds)) < 0.001,
            "2h30m plain planning should cut near the first silence boundary with overlap context."
        )
        try expect(
            abs(plainTwoHalf.chunks[1].startTime - (3_000 - GeminiTranscriptionLimits.boundaryContextOverlapSeconds)) < 0.001,
            "2h30m plain second chunk should begin with overlap before the first silence boundary."
        )
        try expect(
            plainTwoHalf.estimatedInputTokens == Int64(lectureTwoAndHalfHours) * Int64(GeminiTranscriptionLimits.audioTokensPerSecond),
            "2h30m plain token estimates should be duration * tokens/sec."
        )

        let annotatedTwoHalf = GeminiAudioChunkPlanner.plan(
            duration: lectureTwoAndHalfHours,
            options: annotated
        )
        try expect(annotatedTwoHalf.chunks.count == 6, "A 2h30m annotated lecture should use six 28-minute-safe chunks.")
        try expect(annotatedTwoHalf.chunks.allSatisfy { $0.duration <= Double(annotated.safeChunkSeconds) + 0.001 }, "2h30m annotated chunks must stay under the safe annotated limit.")
        try expect(abs((annotatedTwoHalf.chunks.last?.endTime ?? 0) - lectureTwoAndHalfHours) < 0.001, "2h30m annotated planning should cover the full recording.")
        for index in 1..<annotatedTwoHalf.chunks.count {
            try expect(
                annotatedTwoHalf.chunks[index].startTime < annotatedTwoHalf.chunks[index - 1].endTime,
                "2h30m annotated interior boundaries should overlap."
            )
        }

        let invalidDuration = GeminiAudioChunkPlanner.plan(duration: .nan, options: plain)
        try expect(invalidDuration.duration > 0 && invalidDuration.chunks.count == 1, "Invalid duration input should produce a bounded plan instead of an unsafe upload.")
    }

    private static func testGeminiTranscriptionServiceWithMockAPI() async throws {
        guard FFmpegAudioExtractor.resolveExecutable(named: "ffmpeg") != nil,
              FFmpegAudioExtractor.resolveExecutable(named: "ffprobe") != nil else {
            print("Skipping Gemini transcription service test because ffmpeg or ffprobe is missing")
            return
        }

        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let audioURL = temporaryDirectory.appendingPathComponent("Gemini Mock.wav")
        let ffmpegURL = FFmpegAudioExtractor.resolveExecutable(named: "ffmpeg")!
        _ = try await ProcessRunner().run(
            executableURL: ffmpegURL,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-nostdin",
                "-y",
                "-f", "lavfi",
                "-i", "sine=frequency=440:duration=1",
                "-ac", "1",
                "-ar", "16000",
                "-c:a", "pcm_s16le",
                audioURL.path
            ]
        )

        GeminiMockURLProtocol.reset()
        defer { GeminiMockURLProtocol.reset() }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [GeminiMockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let service = GeminiTranscriptionService(
            session: session,
            baseURL: URL(string: "https://gemini.test")!
        )
        let transcript = try await service.transcribe(
            audioURL: audioURL,
            sourceName: audioURL.lastPathComponent,
            localeIdentifier: "auto",
            credentials: [GeminiAPIKeyCredential(id: UUID(), apiKey: "test-key-123456")],
            options: GeminiTranscriptionOptions(mode: .verbatim, wordTimestamps: true),
            audioExtractor: try FFmpegAudioExtractor()
        )

        try expect(transcript.fullText == "Hello world", "Gemini response parsing should return the provider transcript text.")
        try expect(transcript.segments.count == 1, "Gemini word annotations should assemble into a transcript segment.")
        try expect(transcript.segments[0].words.count == 2, "Gemini word annotations should preserve both words.")
        try expect(abs(transcript.segments[0].words[0].startTime - 0.1) < 0.001, "Gemini word start offsets should be preserved.")
        try expect(GeminiMockURLProtocol.interactionRequestCount == 1, "Gemini should create one interaction for a one-second audio file.")
        try expect(
            GeminiMockURLProtocol.recordedAPIKeys.filter { !$0.isEmpty }.allSatisfy { $0 == "test-key-123456" },
            "Gemini credentials should be sent only as the API header."
        )
        try expect(
            GeminiMockURLProtocol.uploadAPIKeys.allSatisfy(\.isEmpty),
            "Gemini credentials should not be copied to the signed resumable upload URL."
        )
        try expect(
            GeminiMockURLProtocol.uploadContentTypes.allSatisfy { value in
                value.isEmpty || value == "application/octet-stream"
            },
            "Gemini resumable upload finalization should use the documented binary upload contract: \(GeminiMockURLProtocol.uploadContentTypes)"
        )
        try expect(GeminiMockURLProtocol.recordedURLs.allSatisfy { $0.query == nil }, "Gemini API keys must never be placed in request URLs.")

        guard let body = GeminiMockURLProtocol.interactionBodies.first,
              let root = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw SmokeTestFailure.failed("Gemini interaction request body was not valid JSON.")
        }
        try expect(root["model"] as? String == WhisperModelPreset.gemini35Transcribe.id, "Gemini interaction should use the exact transcribe model ID.")
        guard let generationConfig = root["generation_config"] as? [String: Any],
              let transcriptionConfig = generationConfig["transcription_config"] as? [String: Any],
              let mode = transcriptionConfig["mode"] as? [String: Any],
              let input = root["input"] as? [[String: Any]],
              let audioInput = input.first else {
            throw SmokeTestFailure.failed("Gemini interaction request omitted transcription configuration.")
        }
        try expect(root["store"] as? Bool == false, "Gemini cloud interactions should be stateless and avoid server-side transcript retention.")
        try expect(audioInput["type"] as? String == "audio", "Gemini interaction should send an audio input item.")
        try expect(audioInput["mime_type"] as? String == "audio/flac", "Gemini interaction should preserve the lossless FLAC MIME type.")
        try expect(mode["type"] as? String == "verbatim", "Annotated Gemini requests should use verbatim mode.")
        try expect((mode["timestamp_granularities"] as? [String]) == ["word"], "Annotated Gemini requests should request word timestamps.")
        try expect((transcriptionConfig["language_codes"] as? [String]) == [], "Auto detection should be sent explicitly as an empty language hint list.")

        GeminiMockURLProtocol.reset()
        GeminiMockURLProtocol.includeWordAnnotations = false
        do {
            _ = try await service.transcribe(
                audioURL: audioURL,
                sourceName: audioURL.lastPathComponent,
                localeIdentifier: "auto",
                credentials: [GeminiAPIKeyCredential(id: UUID(), apiKey: "test-key-123456")],
                options: GeminiTranscriptionOptions(mode: .verbatim, wordTimestamps: true),
                audioExtractor: try FFmpegAudioExtractor()
            )
            throw SmokeTestFailure.failed("Gemini should reject an annotated response that contains no word annotations.")
        } catch let error as GeminiTranscriptionError {
            try expect(error == .incompleteResponse, "Gemini should reject an annotated response that contains no word annotations.")
        } catch let error as SmokeTestFailure {
            throw error
        } catch {
            throw SmokeTestFailure.failed("Gemini returned an unexpected error for a missing annotation response.")
        }

        GeminiMockURLProtocol.reset()
        GeminiMockURLProtocol.rejectAPIKey = "bad-key-123456"
        let failoverTranscript = try await service.transcribe(
            audioURL: audioURL,
            sourceName: audioURL.lastPathComponent,
            localeIdentifier: "auto",
            credentials: [
                GeminiAPIKeyCredential(id: UUID(), apiKey: "bad-key-123456"),
                GeminiAPIKeyCredential(id: UUID(), apiKey: "good-key-123456")
            ],
            options: GeminiTranscriptionOptions(),
            audioExtractor: try FFmpegAudioExtractor()
        )
        GeminiMockURLProtocol.rejectAPIKey = nil

        try expect(failoverTranscript.fullText == "Hello world", "Gemini should fail over to the next enabled API key after authentication failure.")
        try expect(GeminiMockURLProtocol.recordedAPIKeys.contains("bad-key-123456"), "Gemini failover should try the first configured key.")
        try expect(GeminiMockURLProtocol.recordedAPIKeys.contains("good-key-123456"), "Gemini failover should try the next configured key.")
    }

    private static func testGeminiModelAccessVerification() async throws {
        GeminiMockURLProtocol.reset()
        defer { GeminiMockURLProtocol.reset() }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [GeminiMockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let service = GeminiTranscriptionService(
            session: session,
            baseURL: URL(string: "https://gemini.test")!
        )

        GeminiMockURLProtocol.modelLookupMode = .available
        let ok = try await service.verifyTranscribeModelAccess(apiKey: "verify-key-123456")
        try expect(ok.isAvailable, "Model verification should succeed when Google returns the transcribe model.")
        try expect(ok.modelIdentifier == WhisperModelPreset.gemini35Transcribe.id, "Verification should target the exact Gemini transcribe model ID.")
        try expect(
            GeminiMockURLProtocol.recordedURLs.contains(where: { $0.path.hasSuffix("/v1beta/models/gemini-3.5-transcribe") }),
            "Verification should GET the exact model resource."
        )
        try expect(
            GeminiMockURLProtocol.recordedAPIKeys.contains("verify-key-123456"),
            "Verification should authenticate with the x-goog-api-key header."
        )
        try expect(
            GeminiMockURLProtocol.recordedURLs.allSatisfy { $0.query == nil },
            "Verification must not place the API key in the URL query."
        )

        GeminiMockURLProtocol.reset()
        GeminiMockURLProtocol.modelLookupMode = .missing
        do {
            _ = try await service.verifyTranscribeModelAccess(apiKey: "verify-key-123456")
            throw SmokeTestFailure.failed("Missing model lookup should throw.")
        } catch let error as GeminiTranscriptionError {
            try expect(error == .modelUnavailable, "A missing gemini-3.5-transcribe model should map to modelUnavailable.")
        }

        GeminiMockURLProtocol.reset()
        GeminiMockURLProtocol.modelLookupMode = .unauthorized
        do {
            _ = try await service.verifyTranscribeModelAccess(apiKey: "bad-verify-key")
            throw SmokeTestFailure.failed("Unauthorized model lookup should throw.")
        } catch let error as GeminiTranscriptionError {
            try expect(error == .authenticationFailed, "Unauthorized model verification should map to authenticationFailed.")
        }

        GeminiMockURLProtocol.reset()
        GeminiMockURLProtocol.modelLookupMode = .available
        GeminiMockURLProtocol.rejectAPIKey = "bad-verify-key"
        let failover = await service.verifyTranscribeModelAccess(
            credentials: [
                GeminiAPIKeyCredential(id: UUID(), apiKey: "bad-verify-key"),
                GeminiAPIKeyCredential(id: UUID(), apiKey: "good-verify-key")
            ]
        )
        try expect(failover.isAvailable, "Credential failover verification should accept the next usable key.")
        try expect(failover.verifiedCredentialID != nil, "Successful failover verification should report which credential worked.")
    }

    private static func testCloudAudioExtractionPreservesSourceQuality() async throws {
        guard let ffmpegURL = FFmpegAudioExtractor.resolveExecutable(named: "ffmpeg"),
              let ffprobeURL = FFmpegAudioExtractor.resolveExecutable(named: "ffprobe") else {
            print("Skipping cloud audio extraction test because ffmpeg or ffprobe is missing")
            return
        }

        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("Source Audio.wav")
        let runner = ProcessRunner()
        _ = try await runner.run(
            executableURL: ffmpegURL,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-nostdin",
                "-y",
                "-f", "lavfi",
                "-i", "sine=frequency=440:duration=1",
                "-ac", "2",
                "-ar", "48000",
                "-c:a", "pcm_s24le",
                sourceURL.path
            ]
        )

        let extractor = try FFmpegAudioExtractor()
        let losslessURL = try await extractor.extractAudio(from: sourceURL, preserveSourceQuality: true)
        defer { try? FileManager.default.removeItem(at: losslessURL) }
        try expect(losslessURL.pathExtension == "flac", "Cloud extraction should use a lossless FLAC intermediate.")

        let probe = try await runner.run(
            executableURL: ffprobeURL,
            arguments: [
                "-v", "error",
                "-select_streams", "a:0",
                "-show_entries", "stream=codec_name,sample_rate,channels",
                "-of", "default=noprint_wrappers=1",
                losslessURL.path
            ]
        )
        try expect(probe.stdout.contains("codec_name=flac"), "Cloud extraction should not use a lossy audio codec.")
        try expect(probe.stdout.contains("sample_rate=48000"), "Cloud extraction should preserve the source sample rate.")
        try expect(probe.stdout.contains("channels=2"), "Cloud extraction should preserve the source channel layout.")

        let chunkURL = try await extractor.extractAudioChunk(
            from: losslessURL,
            startTime: 0.2,
            duration: 0.5,
            preserveSourceQuality: true
        )
        defer { try? FileManager.default.removeItem(at: chunkURL) }
        try expect(chunkURL.pathExtension == "flac", "Cloud chunk extraction should remain lossless.")
        let chunkDuration = try await extractor.duration(of: chunkURL)
        try expect(chunkDuration > 0.4 && chunkDuration <= 0.55, "Cloud chunk extraction should retain the requested time window.")
    }

    private static func testTranscriptionConfigurationRequestsWordTimestampsByDefault() throws {
        let defaultConfiguration = TranscriptionConfiguration(
            outputDirectory: URL(fileURLWithPath: "/tmp"),
            localeIdentifier: "en"
        )
        try expect(defaultConfiguration.formats == [.text], "Default app-side export formats should only include text.")
        try expect(defaultConfiguration.requiresWordTimestamps, "Default app-side transcription should keep word timing data for embedded outputs.")
        try expect(defaultConfiguration.smartNamingEnabled, "Smart transcript naming should be enabled by default.")

        let fastPlain = TranscriptionConfiguration(
            outputDirectory: URL(fileURLWithPath: "/tmp"),
            localeIdentifier: "en",
            formats: [.text, .srt, .json]
        )
        try expect(fastPlain.requiresWordTimestamps, "Plain transcript exports should still preserve word timing data.")

        let timed = TranscriptionConfiguration(
            outputDirectory: URL(fileURLWithPath: "/tmp"),
            localeIdentifier: "en",
            formats: [.text, .wordTimings]
        )
        try expect(timed.requiresWordTimestamps, "Word timing exports should request word timestamp alignment.")
    }

    /// The bridge reports progress as `Finished chunk i/N (P%)`. Reading those
    /// as loose digits turned `12/12 (100%)` into 1 of 2, which pinned the
    /// progress bar and showed a nonsense counter.
    private static func testChunkProgressLineParsing() throws {
        let cases: [(String, Int, Int)] = [
            ("Finished chunk 3/7 (42%)", 3, 7),
            ("Finished chunk 1/10 (10%)", 1, 10),
            ("Finished chunk 12/12 (100%)", 12, 12),
            ("Finished chunk 20/25 (80%)", 20, 25),
            ("Finished chunk 100/120 (83%)", 100, 120)
        ]

        for (line, expectedCompleted, expectedTotal) in cases {
            let parsed = WhisperTranscriptionService.parseChunkProgressLine(line)
            guard let parsed else {
                try expect(false, "Chunk progress line should parse: \(line)")
                return
            }
            try expect(
                parsed.completed == expectedCompleted && parsed.total == expectedTotal,
                "Chunk progress line \(line) should parse as \(expectedCompleted)/\(expectedTotal), got \(parsed.completed)/\(parsed.total)"
            )
        }

        try expect(
            WhisperTranscriptionService.parseChunkProgressLine("Chunked transcription: 7 chunks, 1 worker(s), 600s chunks") == nil,
            "The plan banner is not a per-chunk progress line."
        )
        try expect(
            WhisperTranscriptionService.parseChunkProgressLine("Finished chunk 0/0 (0%)") == nil,
            "A zero total cannot be used to compute a fraction."
        )
    }

    /// Provider error text is echoed into the UI, so credential-shaped content
    /// must never survive into a user-visible string.
    private static func testProviderTextIsRedacted() throws {
        let cases: [(String, Bool)] = [
            ("Unknown name \"key\": \"AIzaSySECRET-KEY-ONE-000000000000\"", true),
            ("Invalid key sk-abcdefghijklmnopqrstuvwx provided", true),
            ("Authorization: Bearer abcdefghijklmnopqrstuvwxyz", true),
            ("api_key=ABCDEFGHIJKLMNOPQRST was refused", true),
            ("The Generative Language API is not enabled for this project.", false),
            ("Resource not found: files/abc123", false)
        ]

        for (input, shouldRedact) in cases {
            let output = GeminiTranscriptionService.redactCredentialsForTesting(input)
            try expect(
                output.contains("[redacted]") == shouldRedact,
                "Redaction of \"\(input)\" should be \(shouldRedact), got \(output)"
            )
        }
    }

    private static func testExportFormatVisibleOptions() throws {
        let visible = ExportFormat.visibleManualFormats
        try expect(!visible.isEmpty, "There should be manual output choices.")
        try expect(
            !visible.contains(.captionedVideo),
            "Captioned video replaces media rather than writing a sidecar, so it must not be a manual format choice."
        )
        try expect(
            Set(visible) == ExportFormat.sidecarFormats,
            "Every visible manual format should be one the store will actually export."
        )
        try expect(
            ExportFormat.allCases.count > visible.count,
            "captionedVideo is the only format that is not a sidecar choice."
        )
        try expect(ExportFormat.text.displayName == "Plain Transcript", "Plain text format should use the product-facing label.")
        try expect(ExportFormat.timestampedText.displayName == "Timestamped Transcript", "Timestamped text format should use the product-facing label.")
        try expect(ExportFormat.srt.needsWordTimestamps == false, "SRT is built from segment timings, not word alignment.")
        try expect(ExportFormat.wordTimings.needsWordTimestamps, "Word timing exports should be gated on word-level alignment.")
        try expect(ExportFormat.appleMusicTTML.needsWordTimestamps, "TTML timing should be gated on word-level alignment.")
    }

    private static func testSupportedMediaRecognizesDefaultPlayerFormats() throws {
        try expect(SupportedMedia.isSupported(URL(fileURLWithPath: "/tmp/a.mov")), "MOV should be supported.")
        try expect(SupportedMedia.isSupported(URL(fileURLWithPath: "/tmp/a.mp4")), "MP4 should be supported.")
        try expect(SupportedMedia.isSupported(URL(fileURLWithPath: "/tmp/a.mkv")), "MKV should be supported for transcription.")
        try expect(SupportedMedia.isSupported(URL(fileURLWithPath: "/tmp/a.webm")), "WebM should be supported for transcription.")
        try expect(SupportedMedia.isSupported(URL(fileURLWithPath: "/tmp/a.m4a")), "M4A should be supported.")
        try expect(SupportedMedia.isSupported(URL(fileURLWithPath: "/tmp/a.wav")), "WAV should be supported.")
        try expect(!SupportedMedia.isDefaultPlayerCompatible(URL(fileURLWithPath: "/tmp/a.mkv")), "MKV should not be marked default-player-compatible.")
        try expect(!SupportedMedia.isSupported(URL(fileURLWithPath: "/tmp/a.pdf")), "PDF should not be supported.")
    }

    private static func testPreferredMacCompatibleURLsChooseQuickTimeFriendlyVariant() throws {
        let urls = [
            URL(fileURLWithPath: "/tmp/Clip.wav"),
            URL(fileURLWithPath: "/tmp/Clip.mkv"),
            URL(fileURLWithPath: "/tmp/Clip.mp4"),
            URL(fileURLWithPath: "/tmp/OnlyMKV.mkv"),
            URL(fileURLWithPath: "/tmp/Other.m4a"),
            URL(fileURLWithPath: "/tmp/Other.mp3")
        ]

        let preferred = SupportedMedia.preferredMacCompatibleURLs(from: urls)
        try expect(preferred.map(\.lastPathComponent) == ["Clip.mp4", "OnlyMKV.mkv", "Other.m4a"], "Mac-compatible preference ordering is wrong.")
    }

    private static func makeTranscript() -> Transcript {
        Transcript(
            sourceName: "Interview.mov",
            createdAt: Date(timeIntervalSince1970: 0),
            localeIdentifier: "en_US",
            fullText: "First sentence. Second sentence.",
            segments: [
                TranscriptSegment(
                    index: 1,
                    startTime: 1.25,
                    duration: 2.5,
                    text: "First sentence.",
                    words: [
                        TranscriptWord(index: 1, startTime: 1.25, duration: 0.65, text: "First", probability: 0.98),
                        TranscriptWord(index: 2, startTime: 1.90, duration: 1.85, text: "sentence.", probability: 0.97)
                    ]
                ),
                TranscriptSegment(
                    index: 2,
                    startTime: 4.0,
                    duration: 1.2,
                    text: "Second sentence.",
                    words: [
                        TranscriptWord(index: 1, startTime: 4.0, duration: 0.5, text: "Second", probability: 0.99),
                        TranscriptWord(index: 2, startTime: 4.5, duration: 0.7, text: "sentence.", probability: 0.96)
                    ]
                )
            ]
        )
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriberCoreSmokeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        return temporaryDirectory
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw SmokeTestFailure.failed(message)
        }
    }

    private static func expect<E: Error & Equatable>(
        throws expected: E,
        _ operation: () throws -> Void
    ) throws {
        do {
            try operation()
            throw SmokeTestFailure.failed("Expected error \(expected), but the operation succeeded.")
        } catch let error as E {
            try expect(error == expected, "Expected error \(expected), received \(error).")
        } catch {
            throw SmokeTestFailure.failed("Expected error \(expected), received an unexpected error.")
        }
    }
}

private final class GeminiMockURLProtocol: URLProtocol {
    enum ModelLookupMode {
        case available
        case missing
        case unauthorized
    }

    static private(set) var interactionBodies: [Data] = []
    static private(set) var interactionRequestCount = 0
    static private(set) var recordedAPIKeys: [String] = []
    static private(set) var uploadAPIKeys: [String] = []
    static private(set) var uploadContentTypes: [String] = []
    static private(set) var recordedURLs: [URL] = []
    static var rejectAPIKey: String?
    static var includeWordAnnotations = true
    static var modelLookupMode: ModelLookupMode = .available

    static func reset() {
        interactionBodies = []
        interactionRequestCount = 0
        recordedAPIKeys = []
        uploadAPIKeys = []
        uploadContentTypes = []
        recordedURLs = []
        rejectAPIKey = nil
        includeWordAnnotations = true
        modelLookupMode = .available
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "gemini.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestURL = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.recordedURLs.append(requestURL)
        Self.recordedAPIKeys.append(request.value(forHTTPHeaderField: "x-goog-api-key") ?? "")

        let statusCode: Int
        let headers: [String: String]
        let body: Data

        switch (request.httpMethod ?? "GET", requestURL.path) {
        case ("GET", "/v1beta/models/gemini-3.5-transcribe"):
            if request.value(forHTTPHeaderField: "x-goog-api-key") == Self.rejectAPIKey
                || Self.modelLookupMode == .unauthorized {
                statusCode = 403
                headers = ["Content-Type": "application/json"]
                body = Data(#"{"error":{"message":"mock authentication failure","code":403}}"#.utf8)
            } else if Self.modelLookupMode == .missing {
                statusCode = 404
                headers = ["Content-Type": "application/json"]
                body = Data(#"{"error":{"message":"model not found","code":404}}"#.utf8)
            } else {
                statusCode = 200
                headers = ["Content-Type": "application/json"]
                body = Data(#"{"name":"models/gemini-3.5-transcribe","displayName":"Gemini 3.5 Transcribe"}"#.utf8)
            }
        case ("POST", "/upload/v1beta/files"):
            if request.value(forHTTPHeaderField: "x-goog-api-key") == Self.rejectAPIKey {
                statusCode = 403
                headers = ["Content-Type": "application/json"]
                body = Data(#"{"error":{"message":"mock authentication failure"}}"#.utf8)
            } else {
                statusCode = 200
                headers = ["X-Goog-Upload-URL": "https://gemini.test/upload-session"]
                body = Data()
            }
        case ("POST", "/upload-session"):
            Self.uploadAPIKeys.append(request.value(forHTTPHeaderField: "x-goog-api-key") ?? "")
            Self.uploadContentTypes.append(request.value(forHTTPHeaderField: "Content-Type") ?? "")
            statusCode = 200
            headers = [:]
            body = Data(#"{"file":{"name":"files/mock-audio","uri":"https://gemini.test/files/mock-audio","mimeType":"audio/flac","state":"ACTIVE"}}"#.utf8)
        case ("POST", "/v1beta/interactions"):
            statusCode = 200
            headers = [:]
            Self.interactionRequestCount += 1
            if let requestBody = Self.requestBody(from: request) {
                Self.interactionBodies.append(requestBody)
            }
            body = Self.interactionResponse()
        case ("DELETE", "/v1beta/files/mock-audio"):
            statusCode = 204
            headers = [:]
            body = Data()
        default:
            statusCode = 404
            headers = ["Content-Type": "application/json"]
            body = Data(#"{"error":{"message":"mock endpoint not found"}}"#.utf8)
        }

        guard let response = HTTPURLResponse(
            url: requestURL,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func interactionResponse() -> Data {
        if includeWordAnnotations {
            return Data(#"{"status":"completed","output_text":"Hello world","steps":[{"content":[{"type":"word_info","text":"Hello","start_offset":{"seconds":"0","nanos":100000000},"end_offset":"0.45s"},{"type":"word_info","text":"world","start_offset":"0.50s","end_offset":"0.90s"}]}]}"#.utf8)
        }
        return Data(#"{"status":"completed","output_text":"Hello world","steps":[{"content":[{"type":"text","text":"Hello world"}]}]}"#.utf8)
    }

    private static func requestBody(from request: URLRequest) -> Data? {
        if let httpBody = request.httpBody {
            return httpBody
        }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body.isEmpty ? nil : body
    }
}

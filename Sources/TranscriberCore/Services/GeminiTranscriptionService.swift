import Foundation

public struct GeminiTranscriptionProgress: Sendable {
    public let phase: String
    public let completedChunks: Int
    public let totalChunks: Int
    public let estimatedInputTokens: Int64
    /// Set when one saved key was rejected or failed and Tare moved on to the
    /// next one, so a failover job is not indistinguishable from a job where the
    /// first key served everything. It names the record's label, never the key.
    public let credentialFailure: CredentialFailure?

    public struct CredentialFailure: Hashable, Sendable {
        public let credentialID: UUID
        public let label: String
        public let reason: String

        public init(credentialID: UUID, label: String, reason: String) {
            self.credentialID = credentialID
            self.label = label
            self.reason = reason
        }
    }

    public init(
        phase: String,
        completedChunks: Int,
        totalChunks: Int,
        estimatedInputTokens: Int64 = 0,
        credentialFailure: CredentialFailure? = nil
    ) {
        self.phase = phase
        self.completedChunks = completedChunks
        self.totalChunks = totalChunks
        self.estimatedInputTokens = estimatedInputTokens
        self.credentialFailure = credentialFailure
    }
}

public struct GeminiModelAccessVerification: Hashable, Sendable {
    public let modelIdentifier: String
    public let isAvailable: Bool
    public let message: String
    public let verifiedCredentialID: UUID?

    public init(
        modelIdentifier: String,
        isAvailable: Bool,
        message: String,
        verifiedCredentialID: UUID? = nil
    ) {
        self.modelIdentifier = modelIdentifier
        self.isAvailable = isAvailable
        self.message = message
        self.verifiedCredentialID = verifiedCredentialID
    }
}

public enum GeminiTranscriptionError: Error, LocalizedError, Hashable, Sendable {
    case apiKeysMissing
    case invalidOptions(String)
    case audioFileMissing
    case audioFileTooLarge
    case durationUnavailable
    case uploadFailed
    case fileProcessingFailed(String)
    case authenticationFailed
    case rateLimited
    case modelUnavailable
    case requestRejected(String)
    case serviceUnavailable
    case networkUnavailable
    case emptyResponse
    case incompleteResponse
    case providerFailure(String)

    public var errorDescription: String? {
        switch self {
        case .apiKeysMissing:
            return "Add at least one enabled Google Gemini API key in Transcribe via Cloud before starting."
        case .invalidOptions(let message):
            return message
        case .audioFileMissing:
            return "The audio file for cloud transcription is no longer available. Choose Retry to extract it again."
        case .audioFileTooLarge:
            return "This audio chunk is larger than Google's 2 GB Files API limit. Tare could not upload it."
        case .durationUnavailable:
            return "Tare could not measure this recording, so it stopped before uploading an incorrectly sized Gemini request."
        case .uploadFailed:
            return "Google Gemini could not upload the audio chunk. Check the network, API key, and Google API access, then choose Retry."
        case .fileProcessingFailed(let message):
            return "Google Gemini could not prepare the uploaded audio. \(message)"
        case .authenticationFailed:
            return "None of the enabled Google Gemini API keys was accepted. Check the keys in Transcribe via Cloud."
        case .rateLimited:
            return "Google Gemini rate-limited this transcription (often free-tier RPD/TPM). Quotas are per Google Cloud project — extra API keys in the same project do not multiply quota. Tare already honors Retry-After with bounded backoff; wait and retry, switch to a paid project, or use a local model."
        case .modelUnavailable:
            return "Google Gemini could not use \(GeminiTranscriptionService.modelIdentifier) with the enabled keys. This usually means the Generative Language API is not enabled for the key's Google Cloud project, or the project is not permitted to use the transcribe model. Check the API is enabled for the project in the Google Cloud console, then choose Retry."
        case .requestRejected(let message):
            return "Google Gemini rejected this transcription request. \(message)"
        case .serviceUnavailable:
            return "Google Gemini is temporarily unavailable. Tare retried transient failures; choose Retry later."
        case .networkUnavailable:
            return "Tare could not reach Google Gemini. Check your internet connection, then choose Retry."
        case .emptyResponse:
            return "Google Gemini finished without returning transcript text. Choose Retry or use another model. The raw reply was saved in ~/Library/Logs/Tare."
        case .incompleteResponse:
            return "Google Gemini returned an incomplete transcript. Tare did not export partial text; choose Retry. The raw reply was saved in ~/Library/Logs/Tare."
        case .providerFailure(let message):
            return "Google Gemini could not transcribe this file. \(message)"
        }
    }
}

public final class GeminiTranscriptionService: @unchecked Sendable {
    public static let modelIdentifier = WhisperModelPreset.gemini35Transcribe.id

    private let session: URLSession
    private let baseURL: URL
    private let decoder = JSONDecoder()

    public init(
        session: URLSession? = nil,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com")!
    ) {
        self.session = session ?? URLSession(configuration: .ephemeral)
        self.baseURL = baseURL
    }

    /// Lightweight authenticated check that the key/project can see the
    /// dedicated Gemini 3.5 Transcribe model before a long upload starts.
    public func verifyTranscribeModelAccess(apiKey: String) async throws -> GeminiModelAccessVerification {
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty,
              !normalizedKey.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw GeminiTranscriptionError.apiKeysMissing
        }

        var request = URLRequest(
            url: baseURL
                .appendingPathComponent("v1beta/models")
                .appendingPathComponent(Self.modelIdentifier)
        )
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(normalizedKey, forHTTPHeaderField: "x-goog-api-key")

        let (data, response) = try await requestWithRetry {
            try await self.session.data(for: request)
        }

        do {
            try checkHTTP(data, response: response)
        } catch let error as GeminiHTTPError {
            throw map(error)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiTranscriptionError.providerFailure("Google returned an unreadable models response.")
        }

        let name = (root["name"] as? String) ?? ""
        let normalizedName = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "models/", with: "")
        let displayName = (root["displayName"] as? String)
            ?? (root["display_name"] as? String)
            ?? Self.modelIdentifier

        if normalizedName == Self.modelIdentifier || name.hasSuffix(Self.modelIdentifier) {
            return GeminiModelAccessVerification(
                modelIdentifier: Self.modelIdentifier,
                isAvailable: true,
                message: "Verified: \(displayName) (\(Self.modelIdentifier)) is available for this API key."
            )
        }

        // Some responses omit a trailing-compatible name field; treat a 200 for
        // the exact model resource as success when the body is otherwise valid.
        if response.statusCode == 200, !root.isEmpty {
            return GeminiModelAccessVerification(
                modelIdentifier: Self.modelIdentifier,
                isAvailable: true,
                message: "Verified: \(Self.modelIdentifier) is available for this API key."
            )
        }

        return GeminiModelAccessVerification(
            modelIdentifier: Self.modelIdentifier,
            isAvailable: false,
            message: "This API key authenticated, but Google did not confirm \(Self.modelIdentifier)."
        )
    }

    public func verifyTranscribeModelAccess(
        credentials: [GeminiAPIKeyCredential]
    ) async -> GeminiModelAccessVerification {
        var failures: [GeminiCredentialFailure] = []
        for credential in credentials {
            do {
                let result = try await verifyTranscribeModelAccess(apiKey: credential.apiKey)
                if result.isAvailable {
                    return GeminiModelAccessVerification(
                        modelIdentifier: result.modelIdentifier,
                        isAvailable: true,
                        message: result.message,
                        verifiedCredentialID: credential.id
                    )
                }
                failures.append(
                    GeminiCredentialFailure(
                        label: credential.label,
                        summary: Self.truncated(result.message, limit: 300),
                        reason: Self.truncated(result.message, limit: 160)
                    )
                )
            } catch {
                // Every credential here is worth reporting: replacing the
                // previous failure meant the user saw one arbitrary message
                // from an arbitrary key, and no count of what was rejected.
                failures.append(
                    GeminiCredentialFailure(
                        label: credential.label,
                        summary: Self.truncated(error.localizedDescription, limit: 300),
                        reason: Self.credentialFailureReason(for: error)
                    )
                )
            }
        }

        return GeminiModelAccessVerification(
            modelIdentifier: Self.modelIdentifier,
            isAvailable: false,
            message: Self.verificationFailureMessage(failures: failures, attemptedCount: credentials.count)
        )
    }

    private static func verificationFailureMessage(
        failures: [GeminiCredentialFailure],
        attemptedCount: Int
    ) -> String {
        guard let first = failures.first else {
            return "None of the enabled Gemini API keys could access \(Self.modelIdentifier)."
        }
        // One failed key keeps its full guidance; several get the count plus a
        // short per-label reason, because the full texts repeat themselves.
        guard failures.count > 1 else { return first.summary }
        let details = failures
            .map { "\($0.label): \($0.reason)" }
            .joined(separator: " ")
        return "\(failures.count) of \(attemptedCount) enabled Gemini API keys failed to reach \(Self.modelIdentifier). \(details)"
    }

    /// A short, key-free reason for a status line or an aggregated message.
    private static func credentialFailureReason(for error: Error) -> String {
        guard let transcriptionError = error as? GeminiTranscriptionError else {
            return truncated(error.localizedDescription, limit: 160)
        }
        switch transcriptionError {
        case .authenticationFailed:
            return "Google rejected the key"
        case .modelUnavailable:
            return "the project cannot use \(Self.modelIdentifier) (is the Generative Language API enabled?)"
        case .rateLimited:
            return "the project hit a quota limit"
        case .serviceUnavailable:
            return "Google reported a temporary service failure"
        case .networkUnavailable:
            return "Tare could not reach Google"
        default:
            return truncated(transcriptionError.localizedDescription, limit: 160)
        }
    }

    /// Strips credential-shaped content from provider-controlled text.
    ///
    /// Tare never places a key in a request body, so this is defence in depth:
    /// a provider error message is echoed into the UI, and nothing should be able
    /// to make that echo a secret.
    ///
    /// Public so the store can apply it as a final guarantee before an error
    /// reaches the screen, independent of which error type produced it.
    public static func redactingCredentialsInProviderText(_ text: String) -> String {
        let patterns = [
            "AIza[0-9A-Za-z_-]{10,}",          // Google API key
            "sk-[A-Za-z0-9_-]{16,}",            // provider-style secret
            "(?i)bearer\\s+[A-Za-z0-9._-]{16,}",
            "(?i)(api[_-]?key|token|secret)\\s*[:=]\\s*\"?[A-Za-z0-9._-]{12,}"
        ]

        var result = text
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "[redacted]"
            )
        }
        return result
    }

    private static func truncated(_ message: String, limit: Int) -> String {
        let normalized = redactingCredentialsInProviderText(
            message
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "…"
    }

    public func transcribe(
        audioURL: URL,
        sourceName: String,
        localeIdentifier: String,
        credentials: [GeminiAPIKeyCredential],
        options: GeminiTranscriptionOptions,
        audioExtractor: FFmpegAudioExtractor,
        progress: @escaping @Sendable (GeminiTranscriptionProgress) -> Void = { _ in },
        onCredentialUsed: @escaping @Sendable (UUID) -> Void = { _ in }
    ) async throws -> Transcript {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw GeminiTranscriptionError.audioFileMissing
        }
        var seenKeys = Set<String>()
        let usableCredentials = credentials.compactMap { credential -> GeminiAPIKeyCredential? in
            let key = credential.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty,
                  !key.contains(where: { $0.isWhitespace || $0.isNewline }),
                  seenKeys.insert(key).inserted else {
                return nil
            }
            return GeminiAPIKeyCredential(id: credential.id, apiKey: key, label: credential.label)
        }
        guard !usableCredentials.isEmpty else {
            throw GeminiTranscriptionError.apiKeysMissing
        }

        let validatedOptions: GeminiTranscriptionOptions
        do {
            validatedOptions = try options.validated()
        } catch {
            throw GeminiTranscriptionError.invalidOptions(error.localizedDescription)
        }

        let duration: TimeInterval
        do {
            duration = try await audioExtractor.duration(of: audioURL)
        } catch {
            throw GeminiTranscriptionError.durationUnavailable
        }
        guard duration.isFinite, duration > 0 else {
            throw GeminiTranscriptionError.durationUnavailable
        }

        let boundaries: [TimeInterval]
        if duration > TimeInterval(validatedOptions.safeChunkSeconds) {
            boundaries = (try? await audioExtractor.silenceBoundaries(of: audioURL)) ?? []
        } else {
            boundaries = []
        }

        let plan = GeminiAudioChunkPlanner.plan(
            duration: duration,
            options: validatedOptions,
            safeBoundaries: boundaries
        )

        progress(
            GeminiTranscriptionProgress(
                phase: plan.isChunked
                    ? "Plan ready: \(plan.summaryDescription). Free-tier quotas are per Google project."
                    : "Plan ready: \(plan.summaryDescription)",
                completedChunks: 0,
                totalChunks: plan.chunks.count,
                estimatedInputTokens: plan.estimatedInputTokens
            )
        )

        var chunkResults: [(GeminiAudioChunk, GeminiChunkTranscript)] = []
        var nextCredentialIndex = 0

        for chunk in plan.chunks {
            try Task.checkCancellation()

            let chunkURL: URL
            let shouldRemoveChunk: Bool
            if plan.isChunked {
                chunkURL = try await audioExtractor.extractAudioChunk(
                    from: audioURL,
                    startTime: chunk.startTime,
                    duration: chunk.duration,
                    preserveSourceQuality: true
                )
                shouldRemoveChunk = true
            } else {
                chunkURL = audioURL
                shouldRemoveChunk = false
            }

            do {
                progress(
                    GeminiTranscriptionProgress(
                        phase: plan.isChunked
                            ? "Transcribing chunk \(chunk.index) of \(plan.chunks.count) · ~\(GeminiTranscriptionPlan.formattedTokenCount(plan.estimatedInputTokens)) audio tokens"
                            : "Transcribing with Gemini 3.5 Transcribe · ~\(GeminiTranscriptionPlan.formattedTokenCount(plan.estimatedInputTokens)) audio tokens",
                        completedChunks: chunk.index - 1,
                        totalChunks: plan.chunks.count,
                        estimatedInputTokens: plan.estimatedInputTokens
                    )
                )

                let result = try await transcribeChunk(
                    audioURL: chunkURL,
                    sourceName: sourceName,
                    localeIdentifier: localeIdentifier,
                    credentials: usableCredentials,
                    options: validatedOptions,
                    startingCredentialIndex: nextCredentialIndex,
                    chunkProgress: GeminiChunkProgress(
                        completedChunks: chunk.index - 1,
                        totalChunks: plan.chunks.count,
                        estimatedInputTokens: plan.estimatedInputTokens
                    ),
                    progress: progress,
                    onCredentialUsed: onCredentialUsed
                )
                nextCredentialIndex = (result.credentialIndex + 1) % usableCredentials.count
                chunkResults.append((chunk, result.transcript))
            } catch {
                if shouldRemoveChunk {
                    try? FileManager.default.removeItem(at: chunkURL)
                }
                throw error
            }

            if shouldRemoveChunk {
                try? FileManager.default.removeItem(at: chunkURL)
            }

            progress(
                GeminiTranscriptionProgress(
                    phase: plan.isChunked
                        ? "Finished chunk \(chunk.index) of \(plan.chunks.count)"
                        : "Finished transcription",
                    completedChunks: chunk.index,
                    totalChunks: plan.chunks.count,
                    estimatedInputTokens: plan.estimatedInputTokens
                )
            )
        }

        return Self.assembleTranscript(
            sourceName: sourceName,
            localeIdentifier: localeIdentifier,
            chunks: chunkResults
        )
    }

    private func transcribeChunk(
        audioURL: URL,
        sourceName: String,
        localeIdentifier: String,
        credentials: [GeminiAPIKeyCredential],
        options: GeminiTranscriptionOptions,
        startingCredentialIndex: Int,
        chunkProgress: GeminiChunkProgress,
        progress: @escaping @Sendable (GeminiTranscriptionProgress) -> Void,
        onCredentialUsed: @escaping @Sendable (UUID) -> Void
    ) async throws -> (credentialIndex: Int, transcript: GeminiChunkTranscript) {
        var lastError: Error?

        for offset in 0..<credentials.count {
            try Task.checkCancellation()

            let credentialIndex = (startingCredentialIndex + offset) % credentials.count
            let credential = credentials[credentialIndex]
            let hasAnotherKey = offset + 1 < credentials.count

            do {
                let transcript = try await transcribeChunkWithCredential(
                    audioURL: audioURL,
                    sourceName: sourceName,
                    localeIdentifier: localeIdentifier,
                    credential: credential,
                    options: options
                )
                onCredentialUsed(credential.id)
                return (credentialIndex, transcript)
            } catch let error as GeminiHTTPError {
                lastError = error
                let mapped = map(error)
                reportCredentialFailure(
                    credential,
                    reason: Self.credentialFailureReason(for: mapped),
                    triesAnotherKey: hasAnotherKey && error.shouldTryAnotherCredential,
                    chunkProgress: chunkProgress,
                    progress: progress
                )
                guard error.shouldTryAnotherCredential else {
                    throw mapped
                }
            } catch let error as URLError {
                guard error.code != .cancelled else { throw CancellationError() }
                lastError = error
                reportCredentialFailure(
                    credential,
                    reason: "Tare could not reach Google with this key",
                    triesAnotherKey: hasAnotherKey,
                    chunkProgress: chunkProgress,
                    progress: progress
                )
            } catch {
                throw error
            }
        }

        if let httpError = lastError as? GeminiHTTPError {
            throw map(httpError)
        }
        if lastError is URLError {
            throw GeminiTranscriptionError.networkUnavailable
        }
        throw GeminiTranscriptionError.providerFailure("All enabled API keys failed for this chunk.")
    }

    /// Surfaces a rejected key in the job status line so the failover is visible.
    /// Only the saved label and a short reason are ever reported.
    private func reportCredentialFailure(
        _ credential: GeminiAPIKeyCredential,
        reason: String,
        triesAnotherKey: Bool,
        chunkProgress: GeminiChunkProgress,
        progress: @Sendable (GeminiTranscriptionProgress) -> Void
    ) {
        let phase = triesAnotherKey
            ? "\(credential.label) failed: \(reason). Trying the next saved key…"
            : "\(credential.label) failed: \(reason)."
        progress(
            GeminiTranscriptionProgress(
                phase: phase,
                completedChunks: chunkProgress.completedChunks,
                totalChunks: chunkProgress.totalChunks,
                estimatedInputTokens: chunkProgress.estimatedInputTokens,
                credentialFailure: GeminiTranscriptionProgress.CredentialFailure(
                    credentialID: credential.id,
                    label: credential.label,
                    reason: reason
                )
            )
        )
    }

    private func transcribeChunkWithCredential(
        audioURL: URL,
        sourceName: String,
        localeIdentifier: String,
        credential: GeminiAPIKeyCredential,
        options: GeminiTranscriptionOptions
    ) async throws -> GeminiChunkTranscript {
        let file = try await upload(audioURL: audioURL, sourceName: sourceName, credential: credential)

        do {
            let transcript = try await createInteraction(
                file: file,
                localeIdentifier: localeIdentifier,
                credential: credential,
                options: options
            )
            await deleteFile(named: file.name, credential: credential)
            return transcript
        } catch {
            await deleteFile(named: file.name, credential: credential)
            throw error
        }
    }

    private func upload(
        audioURL: URL,
        sourceName: String,
        credential: GeminiAPIKeyCredential
    ) async throws -> GeminiFile {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw GeminiTranscriptionError.audioFileMissing
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: audioURL.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else { throw GeminiTranscriptionError.audioFileMissing }
        guard fileSize <= GeminiTranscriptionLimits.maximumFileBytes else {
            throw GeminiTranscriptionError.audioFileTooLarge
        }

        let mimeType = Self.mimeType(for: audioURL)
        let displayName = String(
            "Tare \(sourceName) (\(audioURL.deletingPathExtension().lastPathComponent))"
                .unicodeScalars
                .filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }
                .prefix(160)
        )
        let metadata: [String: Any] = [
            "file": ["display_name": displayName]
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)

        var startRequest = URLRequest(url: baseURL.appendingPathComponent("upload/v1beta/files"))
        startRequest.httpMethod = "POST"
        startRequest.timeoutInterval = 120
        startRequest.setValue(credential.apiKey, forHTTPHeaderField: "x-goog-api-key")
        startRequest.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        startRequest.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        startRequest.setValue(String(fileSize), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        startRequest.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        startRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        startRequest.httpBody = metadataData

        let (startData, startResponse) = try await requestWithRetry {
            try await self.session.data(for: startRequest)
        }
        try checkHTTP(startData, response: startResponse)
        guard let uploadURLString = headerValue("x-goog-upload-url", from: startResponse),
              let uploadURL = URL(string: uploadURLString),
              uploadURL.scheme?.lowercased() == "https",
              uploadURL.host != nil else {
            throw GeminiTranscriptionError.uploadFailed
        }

        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.timeoutInterval = 1_800
        uploadRequest.setValue(String(fileSize), forHTTPHeaderField: "Content-Length")
        uploadRequest.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        uploadRequest.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")

        let (fileData, fileResponse) = try await requestWithRetry {
            try await self.session.upload(for: uploadRequest, fromFile: audioURL)
        }
        try checkHTTP(fileData, response: fileResponse)
        // The object exists in Google's Files store from here on, so every throw
        // below must try to delete it. A body that does not decode as the
        // expected file resource can still expose the name, so recover it from
        // the raw payload instead of leaving the audio behind for its
        // retention window.
        var uploadedFileName = Self.recoverableFileName(from: fileData)
        do {
            let decodedFile = try decodeFile(from: fileData)
            let file = GeminiFile(
                name: decodedFile.name,
                uri: decodedFile.uri,
                mimeType: decodedFile.mimeType ?? mimeType,
                state: decodedFile.state
            )
            guard !file.name.isEmpty, !file.uri.isEmpty else {
                throw GeminiTranscriptionError.uploadFailed
            }
            uploadedFileName = file.name

            switch file.state?.uppercased() {
            case "PROCESSING":
                return try await waitForActiveFile(
                    file,
                    expectedMimeType: mimeType,
                    credential: credential
                )
            case "FAILED":
                throw GeminiTranscriptionError.fileProcessingFailed("Google marked the uploaded file as failed.")
            default:
                return file
            }
        } catch {
            await deleteFile(named: uploadedFileName ?? "", credential: credential)
            throw error
        }
    }

    /// Best-effort recovery of a `files/…` name from a finalize body that failed
    /// to decode, so the uploaded object can still be deleted.
    private static func recoverableFileName(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let candidates = [(root["file"] as? [String: Any])?["name"], root["name"]]
        return candidates
            .compactMap { $0 as? String }
            .first { $0.hasPrefix("files/") && $0.count > "files/".count }
    }

    private func waitForActiveFile(
        _ file: GeminiFile,
        expectedMimeType: String,
        credential: GeminiAPIKeyCredential
    ) async throws -> GeminiFile {
        // Long FLAC uploads can take more than a few polling cycles to become
        // ACTIVE. Keep polling bounded, but do not fail a valid long lecture
        // merely because file preparation is slower than a short clip.
        for _ in 0..<150 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 2_000_000_000)

            guard let fileURL = fileResourceURL(named: file.name) else {
                throw GeminiTranscriptionError.fileProcessingFailed("Google returned an invalid file identifier.")
            }
            var request = URLRequest(url: fileURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 120
            request.setValue(credential.apiKey, forHTTPHeaderField: "x-goog-api-key")
            let (data, response) = try await requestWithRetry {
                try await self.session.data(for: request)
            }
            try checkHTTP(data, response: response)
            let refreshed = try decodeFile(from: data)
            if refreshed.state?.uppercased() == "ACTIVE" || refreshed.state == nil {
                return GeminiFile(
                    name: refreshed.name,
                    uri: refreshed.uri,
                    mimeType: refreshed.mimeType ?? expectedMimeType,
                    state: refreshed.state
                )
            }
            if refreshed.state?.uppercased() == "FAILED" {
                throw GeminiTranscriptionError.fileProcessingFailed("Google marked the uploaded file as failed.")
            }
        }

        throw GeminiTranscriptionError.fileProcessingFailed("Google did not finish processing the upload in time.")
    }

    private func createInteraction(
        file: GeminiFile,
        localeIdentifier: String,
        credential: GeminiAPIKeyCredential,
        options: GeminiTranscriptionOptions
    ) async throws -> GeminiChunkTranscript {
        let requestBody = GeminiInteractionRequest(
            model: Self.modelIdentifier,
            input: [
                GeminiAudioInput(
                    type: "audio",
                    uri: file.uri,
                    mimeType: file.mimeType ?? "audio/wav"
                )
            ],
            store: false,
            generationConfig: GeminiGenerationConfig(
                transcriptionConfig: GeminiTranscriptionConfig(
                    languageCodes: Self.bcp47LanguageCode(from: localeIdentifier).map { [$0] } ?? [],
                    customVocabulary: options.customVocabulary.isEmpty ? nil : options.customVocabulary,
                    mode: GeminiModePayload(options: options)
                )
            )
        )

        var request = URLRequest(url: baseURL.appendingPathComponent("v1beta/interactions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 1_800
        request.setValue(credential.apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await requestWithRetry {
            try await self.session.data(for: request)
        }
        try checkHTTP(data, response: response)
        do {
            return try parseInteraction(data, requireAnnotations: options.usesAnnotatedOutput)
        } catch let error as GeminiTranscriptionError {
            switch error {
            case .emptyResponse, .incompleteResponse:
                Self.saveDiagnostic(data, response: response, failure: error)
            default:
                break
            }
            throw error
        }
    }

    /// Keeps the raw reply when Google answers 2xx but Tare finds no usable
    /// transcript, so the next failure shows what actually came back. The API
    /// key travels in a request header and is never part of this body.
    private static func saveDiagnostic(
        _ data: Data,
        response: HTTPURLResponse,
        failure: GeminiTranscriptionError
    ) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Tare", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("gemini-reply-\(stamp).txt")
        let limit = 256 * 1024
        let body = String(decoding: data.prefix(limit), as: UTF8.self)
        let header = """
        Failure: \(failure.errorDescription ?? "unknown")
        HTTP status: \(response.statusCode)
        Content-Type: \(response.value(forHTTPHeaderField: "Content-Type") ?? "none")
        Body bytes: \(data.count)\(data.count > limit ? " (truncated to \(limit))" : "")

        """
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try (header + body).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Diagnostics must never turn a recoverable failure into a different one.
        }
    }

    private func deleteFile(named name: String, credential: GeminiAPIKeyCredential) async {
        guard let fileURL = fileResourceURL(named: name) else { return }
        var request = URLRequest(url: fileURL)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        request.setValue(credential.apiKey, forHTTPHeaderField: "x-goog-api-key")
        _ = try? await session.data(for: request)
    }

    private func requestWithRetry(
        _ operation: () async throws -> (Data, URLResponse)
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await operation()
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw GeminiTranscriptionError.providerFailure("Google returned an invalid HTTP response.")
                }
                if httpResponse.statusCode == 408 || httpResponse.statusCode == 429 || httpResponse.statusCode >= 500 {
                    let message = Self.providerMessage(from: data)
                    if attempt < 3 {
                        try await retrySleep(attempt: attempt, response: httpResponse)
                        attempt += 1
                        continue
                    }
                    throw GeminiHTTPError(
                        statusCode: httpResponse.statusCode,
                        code: Self.providerCode(from: data),
                        message: message
                    )
                }
                return (data, httpResponse)
            } catch let error as GeminiHTTPError {
                if error.isRetryable, attempt < 3 {
                    try await retrySleep(attempt: attempt)
                    attempt += 1
                    continue
                }
                throw error
            } catch let error as URLError {
                guard error.code != .cancelled else { throw error }
                if attempt < 3 {
                    try await retrySleep(attempt: attempt)
                    attempt += 1
                    continue
                }
                throw error
            }
        }
    }

    private func retrySleep(attempt: Int, response: HTTPURLResponse? = nil) async throws {
        let exponentialSeconds = TimeInterval(1 << min(attempt, 4))
        let requestedSeconds = response.flatMap(Self.retryAfterSeconds) ?? exponentialSeconds
        // Honor Google's backoff hint without allowing a malformed server
        // header to make a desktop transcription wait indefinitely.
        let boundedSeconds = min(max(requestedSeconds, 0), 60)
        try await Task.sleep(nanoseconds: UInt64(boundedSeconds * 1_000_000_000))
    }

    private static func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    private func checkHTTP(_ data: Data, response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw GeminiHTTPError(
                statusCode: response.statusCode,
                code: Self.providerCode(from: data),
                message: Self.providerMessage(from: data)
            )
        }
    }

    private func map(_ error: GeminiHTTPError) -> GeminiTranscriptionError {
        switch error.statusCode {
        case 401, 403:
            // Google answers 403 both for a rejected key and for a project that
            // has not enabled the Generative Language API or cannot use the
            // transcribe model. Reporting the latter as a bad key sends the user
            // to fix keys that are fine, so trust the provider code first.
            return error.isPermissionDenied ? .modelUnavailable : .authenticationFailed
        case 404:
            return .modelUnavailable
        case 408, 429:
            return .rateLimited
        case 400, 416:
            return .requestRejected(error.safeMessage)
        case 500...599:
            return .serviceUnavailable
        default:
            return .providerFailure(error.safeMessage)
        }
    }

    private func fileResourceURL(named name: String) -> URL? {
        let prefix = "files/"
        guard name.hasPrefix(prefix) else { return nil }
        let identifier = String(name.dropFirst(prefix.count))
        guard !identifier.isEmpty,
              !identifier.contains("/"),
              !identifier.contains("..") else {
            return nil
        }
        return baseURL.appendingPathComponent("v1beta/files").appendingPathComponent(identifier)
    }

    private func decodeFile(from data: Data) throws -> GeminiFile {
        if let envelope = try? decoder.decode(GeminiFileEnvelope.self, from: data),
           let file = envelope.file {
            return file
        }
        if let file = try? decoder.decode(GeminiFile.self, from: data) {
            return file
        }
        throw GeminiTranscriptionError.uploadFailed
    }

    private func parseInteraction(
        _ data: Data,
        requireAnnotations: Bool
    ) throws -> GeminiChunkTranscript {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiTranscriptionError.emptyResponse
        }

        if let status = root["status"] as? String {
            switch status.lowercased() {
            case "incomplete", "in_progress", "processing", "pending":
                throw GeminiTranscriptionError.incompleteResponse
            case "failed", "cancelled":
                let message = Self.providerMessage(from: data)
                throw GeminiTranscriptionError.providerFailure(message)
            default:
                break
            }
        }

        var textCandidates: [String] = []
        if let outputText = root["output_text"] as? String {
            textCandidates.append(outputText)
        }
        var words: [GeminiWord] = []
        visitResponseNode(root, textCandidates: &textCandidates, words: &words)

        let text = textCandidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .first ?? ""
        let fallbackText = words.map(\.text).joined(separator: " ")
        let finalText = text.isEmpty ? fallbackText : text
        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiTranscriptionError.emptyResponse
        }

        let uniqueWords = Self.uniqueWords(words)
        if requireAnnotations, uniqueWords.isEmpty {
            throw GeminiTranscriptionError.incompleteResponse
        }

        return GeminiChunkTranscript(
            text: finalText.trimmingCharacters(in: .whitespacesAndNewlines),
            words: uniqueWords
        )
    }

    private func visitResponseNode(
        _ node: Any,
        textCandidates: inout [String],
        words: inout [GeminiWord]
    ) {
        if let dictionary = node as? [String: Any] {
            if dictionary["type"] as? String == "text",
               let text = dictionary["text"] as? String {
                textCandidates.append(text)
            }
            if dictionary["type"] as? String == "word_info",
               let text = dictionary["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let start = Self.parseOffset(dictionary["start_offset"]),
               let end = Self.parseOffset(dictionary["end_offset"]),
               end >= start {
                words.append(
                    GeminiWord(
                        text: text,
                        start: start,
                        end: max(end, start + 0.05),
                        speaker: dictionary["speaker"] as? String
                    )
                )
            }
            for value in dictionary.values {
                visitResponseNode(value, textCandidates: &textCandidates, words: &words)
            }
        } else if let array = node as? [Any] {
            for value in array {
                visitResponseNode(value, textCandidates: &textCandidates, words: &words)
            }
        }
    }

    private static func assembleTranscript(
        sourceName: String,
        localeIdentifier: String,
        chunks: [(GeminiAudioChunk, GeminiChunkTranscript)]
    ) -> Transcript {
        let orderedChunks = chunks.sorted { $0.0.index < $1.0.index }
        let fullText = mergeChunkTexts(orderedChunks.map { $0.1.text })
        let allWords = uniqueWords(
            orderedChunks.flatMap { chunk, result in
                result.words.map {
                    GeminiWord(
                        text: $0.text,
                        start: $0.start + chunk.startTime,
                        end: $0.end + chunk.startTime,
                        speaker: $0.speaker
                    )
                }
            }
        ).sorted { lhs, rhs in
            if lhs.start == rhs.start { return lhs.end < rhs.end }
            return lhs.start < rhs.start
        }

        let transcriptSegments: [TranscriptSegment]
        if allWords.isEmpty {
            transcriptSegments = orderedChunks.enumerated().compactMap { offset, pair in
                let text = pair.1.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(
                    index: offset + 1,
                    startTime: pair.0.startTime,
                    duration: max(pair.0.duration, 0.2),
                    text: text
                )
            }
        } else {
            transcriptSegments = Self.segments(from: allWords)
        }

        return Transcript(
            sourceName: sourceName,
            localeIdentifier: localeIdentifier,
            fullText: fullText,
            segments: transcriptSegments
        )
    }

    private static func segments(from words: [GeminiWord]) -> [TranscriptSegment] {
        var groups: [[GeminiWord]] = []
        for word in words {
            guard let last = groups.last, let previous = last.last else {
                groups.append([word])
                continue
            }
            let speakerChanged = previous.speaker != nil && word.speaker != nil && previous.speaker != word.speaker
            let longPause = word.start - previous.end > 1.25
            if speakerChanged || longPause || last.count >= 80 {
                groups.append([word])
            } else {
                groups[groups.count - 1].append(word)
            }
        }

        return groups.enumerated().map { offset, group in
            let start = group.first?.start ?? 0
            let end = group.last?.end ?? start + 0.2
            let speaker = group.compactMap(\.speaker).first
            let transcriptWords = group.enumerated().map { wordOffset, word in
                TranscriptWord(
                    index: wordOffset + 1,
                    startTime: word.start,
                    duration: max(word.end - word.start, 0.05),
                    text: word.text,
                    probability: nil
                )
            }
            return TranscriptSegment(
                index: offset + 1,
                startTime: start,
                duration: max(end - start, 0.2),
                text: joinWords(group.map(\.text)),
                speaker: speaker,
                words: transcriptWords
            )
        }
    }

    private static func mergeChunkTexts(_ texts: [String]) -> String {
        var merged = ""
        for rawText in texts {
            let nextText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !nextText.isEmpty else { continue }
            guard !merged.isEmpty else {
                merged = nextText
                continue
            }

            let previousWords = merged.split(whereSeparator: { $0.isWhitespace })
            var nextWords = nextText.split(whereSeparator: { $0.isWhitespace })
            let maximumOverlap = min(32, min(previousWords.count, nextWords.count))
            var overlap = 0
            if maximumOverlap >= 1 {
                for count in stride(from: maximumOverlap, through: 1, by: -1) {
                    let previousTail = previousWords.suffix(count).map { normalizeToken(String($0)) }
                    let nextHead = nextWords.prefix(count).map { normalizeToken(String($0)) }
                    if previousTail == nextHead {
                        overlap = count
                        break
                    }
                }
            }
            if overlap > 0 {
                nextWords.removeFirst(overlap)
            }
            let remainder = nextWords.map(String.init).joined(separator: " ")
            if !remainder.isEmpty {
                merged += "\n\n" + remainder
            }
        }
        return merged.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func joinWords(_ words: [String]) -> String {
        var result = ""
        let punctuation = CharacterSet(charactersIn: ".,!?;:%)]}»”’")
        for word in words {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if result.isEmpty {
                result = trimmed
            } else if let firstScalar = trimmed.unicodeScalars.first, punctuation.contains(firstScalar) {
                result += trimmed
            } else {
                result += " " + trimmed
            }
        }
        return result
    }

    private static func uniqueWords(_ words: [GeminiWord]) -> [GeminiWord] {
        var unique: [GeminiWord] = []
        var latestByToken: [String: GeminiWord] = [:]
        for word in words.sorted(by: { lhs, rhs in
            if lhs.start == rhs.start { return lhs.end < rhs.end }
            return lhs.start < rhs.start
        }) {
            let normalizedText = normalizeToken(word.text)
            if normalizedText.isEmpty {
                unique.append(word)
                continue
            }
            let tokenKey = "\(normalizedText)|\(word.speaker ?? "")"
            let isBoundaryDuplicate = latestByToken[tokenKey].map { existing in
                abs(existing.start - word.start) <= 0.25
                    && abs(existing.end - word.end) <= 0.5
            } ?? false
            if !isBoundaryDuplicate {
                unique.append(word)
                latestByToken[tokenKey] = word
            }
        }
        return unique
    }

    private static func normalizeToken(_ value: String) -> String {
        String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
    }

    private static func parseOffset(_ value: Any?) -> TimeInterval? {
        if let value = value as? NSNumber {
            return validOffset(value.doubleValue)
        }
        if let dictionary = value as? [String: Any] {
            let seconds: Double
            if let rawSeconds = dictionary["seconds"] {
                guard let parsedSeconds = numericValue(rawSeconds) else { return nil }
                seconds = parsedSeconds
            } else {
                seconds = 0
            }
            let nanos: Double
            if let rawNanos = dictionary["nanos"] {
                guard let parsedNanos = numericValue(rawNanos) else { return nil }
                nanos = parsedNanos
            } else {
                nanos = 0
            }
            guard nanos.isFinite, nanos >= 0, nanos < 1_000_000_000 else { return nil }
            return validOffset(seconds + nanos / 1_000_000_000)
        }
        guard let rawValue = value as? String else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasSuffix("ms"), let number = Double(trimmed.dropLast(2)) {
            return validOffset(number / 1_000)
        }
        if trimmed.hasSuffix("us"), let number = Double(trimmed.dropLast(2)) {
            return validOffset(number / 1_000_000)
        }
        if trimmed.hasSuffix("ns"), let number = Double(trimmed.dropLast(2)) {
            return validOffset(number / 1_000_000_000)
        }
        if trimmed.hasSuffix("s"), let number = Double(trimmed.dropLast()) {
            return validOffset(number)
        }
        return Double(trimmed).flatMap(validOffset)
    }

    private static func validOffset(_ value: TimeInterval) -> TimeInterval? {
        guard value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    public static func bcp47LanguageCode(from identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        guard !["auto", "detect", "auto-detect", "automatic"].contains(lowered) else { return nil }
        let normalized = trimmed.replacingOccurrences(of: "_", with: "-")
        let lowercased = normalized.lowercased()

        // Tare's compact language picker uses language-only IDs. Gemini's
        // documented list uses supported BCP-47 locale tags, so expand those
        // IDs to an unambiguous supported hint and reject unsupported custom
        // tags so the provider can safely fall back to automatic detection.
        let documentedLanguageHints: [String: String] = [
            "en": "en-US",
            "es": "es-419",
            "fr": "fr-FR",
            "de": "de-DE",
            "hi": "hi-IN",
            "zh": "cmn-Hans-CN",
            "ja": "ja-JP",
            "ko": "ko-KR",
            "pt": "pt-BR",
            "ru": "ru-RU",
            "ar": "ar-EG"
        ]
        if let documentedHint = documentedLanguageHints[lowercased] {
            return documentedHint
        }

        let parts = normalized.split(separator: "-").map(String.init)
        guard let language = parts.first, language.count >= 2 else { return nil }
        let normalizedCode = parts.enumerated().map { index, part in
            if index == 0 { return part.lowercased() }
            if part.count == 4 { return part.prefix(1).uppercased() + part.dropFirst().lowercased() }
            if part.count == 2 || (part.count == 3 && part.allSatisfy(\.isNumber)) {
                return part.uppercased()
            }
            return part
        }
        .joined(separator: "-")
        return Self.supportedLanguageHints.contains(normalizedCode) ? normalizedCode : nil
    }

    private static let supportedLanguageHints: Set<String> = [
        "af-ZA", "am-ET", "ar-EG", "as-IN", "az-AZ", "be-BY", "bg-BG", "bn-BD", "bn-IN",
        "bs-BA", "ca-ES", "ceb", "cmn-Hans-CN", "cs-CZ", "da-DK", "de-DE", "el-GR", "en-GB",
        "en-IN", "en-US", "es-419", "es-US", "et-EE", "fa-IR", "fi-FI", "fil-PH", "fr-FR",
        "gl-ES", "gu-IN", "ha-NG", "he-IL", "hi-IN", "hr-HR", "hu-HU", "hy-AM", "id-ID",
        "is-IS", "it-IT", "ja-JP", "jv-ID", "ka-GE", "kea-CV", "kk-KZ", "km-KH", "kn-IN",
        "ko-KR", "ky-KG", "ln-CD", "lt-LT", "lv-LV", "mk-MK", "ml-IN", "mn-MN", "mr-IN",
        "ms-MY", "mt-MT", "my-MM", "nb-NO", "ne-NP", "nl-NL", "or-IN", "pa-Guru-IN", "pa-IN",
        "pl-PL", "pt-BR", "pt-PT", "ro-RO", "rup-BG", "ru-RU", "sd-Arab-IN", "sk-SK", "sl-SI",
        "sr-RS", "sv-KE", "sw-KE", "tg-TJ", "te-IN", "th-TH", "tr-TR", "uk-UA", "uz-UZ",
        "vi-VN", "yue-Hant-HK"
    ]

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mp3"
        case "m4a": return "audio/m4a"
        case "aif", "aiff": return "audio/aiff"
        case "aac": return "audio/aac"
        case "ogg": return "audio/ogg"
        case "opus": return "audio/opus"
        case "flac": return "audio/flac"
        case "webm": return "audio/webm"
        default: return "audio/wav"
        }
    }

    private static func providerCode(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = root["error"] as? [String: Any] {
            return providerName(error["status"]) ?? providerName(error["code"])
        }
        if let errors = root["errors"] as? [[String: Any]], let first = errors.first {
            return providerName(first["status"]) ?? providerName(first["code"])
        }
        return nil
    }

    /// Keeps only the string form: Google repeats the HTTP status numerically in
    /// `code` and names the condition (`PERMISSION_DENIED`) in `status`.
    private static func providerName(_ value: Any?) -> String? {
        guard let name = value as? String else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func providerMessage(from data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "The provider returned an unreadable response."
        }
        if let error = root["error"] as? [String: Any], let message = error["message"] as? String {
            return safeProviderMessage(message)
        }
        if let errors = root["errors"] as? [[String: Any]],
           let message = errors.first?["message"] as? String {
            return safeProviderMessage(message)
        }
        return "The provider returned an error response."
    }

    /// Every provider-controlled string passes through here on its way to a
    /// `GeminiHTTPError`, which is what surfaces in a job's error message. It
    /// must redact, or a provider that echoes a credential in its error body
    /// would put it on screen.
    private static func safeProviderMessage(_ message: String) -> String {
        let normalized = redactingCredentialsInProviderText(
            message
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return String(normalized.prefix(300))
    }

    private static func headerValue(_ name: String, from response: HTTPURLResponse) -> String? {
        response.allHeaderFields.first { key, _ in
            String(describing: key).caseInsensitiveCompare(name) == .orderedSame
        }.map { String(describing: $0.value).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func headerValue(_ name: String, from response: HTTPURLResponse) -> String? {
        Self.headerValue(name, from: response)
    }
}

private struct GeminiInteractionRequest: Encodable {
    let model: String
    let input: [GeminiAudioInput]
    let store: Bool
    let generationConfig: GeminiGenerationConfig

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case store
        case generationConfig = "generation_config"
    }
}

private struct GeminiAudioInput: Encodable {
    let type: String
    let uri: String
    let mimeType: String

    enum CodingKeys: String, CodingKey {
        case type
        case uri
        case mimeType = "mime_type"
    }
}

private struct GeminiGenerationConfig: Encodable {
    let transcriptionConfig: GeminiTranscriptionConfig

    enum CodingKeys: String, CodingKey {
        case transcriptionConfig = "transcription_config"
    }
}

private struct GeminiTranscriptionConfig: Encodable {
    let languageCodes: [String]
    let customVocabulary: [String]?
    let mode: GeminiModePayload

    enum CodingKeys: String, CodingKey {
        case languageCodes = "language_codes"
        case customVocabulary = "custom_vocabulary"
        case mode
    }
}

private enum GeminiModePayload: Encodable {
    case smart
    case verbatim(wordTimestamps: Bool, speakerDiarization: Bool)

    init(options: GeminiTranscriptionOptions) {
        switch options.mode {
        case .smart:
            self = .smart
        case .verbatim:
            self = .verbatim(
                wordTimestamps: options.wordTimestamps,
                speakerDiarization: options.speakerDiarization
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .smart:
            var container = encoder.singleValueContainer()
            try container.encode("smart")
        case let .verbatim(wordTimestamps, speakerDiarization):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("verbatim", forKey: .type)
            if wordTimestamps {
                try container.encode(["word"], forKey: .timestampGranularities)
            }
            if speakerDiarization {
                try container.encode("speaker", forKey: .diarizationMode)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case timestampGranularities = "timestamp_granularities"
        case diarizationMode = "diarization_mode"
    }
}

private struct GeminiFileEnvelope: Decodable {
    let file: GeminiFile?
}

private struct GeminiFile: Decodable {
    let name: String
    let uri: String
    let mimeType: String?
    let state: String?

    enum CodingKeys: String, CodingKey {
        case name
        case uri
        case mimeType
        case mimeTypeSnake = "mime_type"
        case state
    }

    init(
        name: String,
        uri: String,
        mimeType: String?,
        state: String?
    ) {
        self.name = name
        self.uri = uri
        self.mimeType = mimeType
        self.state = state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        uri = try container.decode(String.self, forKey: .uri)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
            ?? container.decodeIfPresent(String.self, forKey: .mimeTypeSnake)

        if let stringState = try container.decodeIfPresent(String.self, forKey: .state) {
            state = stringState
        } else if let objectState = try? container.decode(GeminiFileStateObject.self, forKey: .state) {
            state = objectState.name
        } else {
            state = nil
        }
    }
}

private struct GeminiFileStateObject: Decodable {
    let name: String
}

private struct GeminiChunkTranscript {
    let text: String
    let words: [GeminiWord]
}

/// The chunk counters a status event must carry so a credential-failure notice
/// does not move the job's chunk progress.
private struct GeminiChunkProgress {
    let completedChunks: Int
    let totalChunks: Int
    let estimatedInputTokens: Int64
}

/// A per-key failure captured while walking the saved keys. Carries the record's
/// label only, so no message can leak the key itself.
private struct GeminiCredentialFailure {
    let label: String
    /// The full provider/case guidance, used when it is the only failure.
    let summary: String
    /// A short form for an aggregate with other keys or a status line.
    let reason: String
}

private struct GeminiWord: Hashable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let speaker: String?
}

private struct GeminiHTTPError: Error, LocalizedError {
    let statusCode: Int
    let code: String?
    let message: String

    /// Without this, a raw HTTP failure that escapes `checkHTTP` — for example a
    /// 5xx raised by the retry wrapper — reaches the user as Foundation's
    /// default "error 1" description.
    var errorDescription: String? {
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty {
            return "Google Gemini returned HTTP \(statusCode)."
        }
        return "Google Gemini returned HTTP \(statusCode): \(detail)"
    }

    var isRetryable: Bool {
        statusCode == 408 || statusCode == 429 || statusCode >= 500
    }

    /// Google's `PERMISSION_DENIED` covers both a key Google will not accept
    /// and a project that has not enabled the Generative Language API.
    var isPermissionDenied: Bool {
        code?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "PERMISSION_DENIED"
    }

    var shouldTryAnotherCredential: Bool {
        statusCode == 401 || statusCode == 403 || statusCode == 404 || isRetryable
    }

    var safeMessage: String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "The provider returned HTTP status \(statusCode)." : trimmed
    }
}

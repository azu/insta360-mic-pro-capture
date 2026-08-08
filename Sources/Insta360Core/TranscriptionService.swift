import AVFoundation
import FluidAudio
import Foundation

public struct TranscriptionSummary: Sendable {
    public let segments: [TimedTranscriptSegment]
    public let processingTimeSeconds: Double
    public let audioDurationSeconds: Double

    public init(
        segments: [TimedTranscriptSegment],
        processingTimeSeconds: Double,
        audioDurationSeconds: Double
    ) {
        self.segments = segments
        self.processingTimeSeconds = processingTimeSeconds
        self.audioDurationSeconds = audioDurationSeconds
    }
}

public actor TranscriptionService {
    private let modelDirectory: URL
    private var manager: AsrManager?

    public init(paths: ApplicationPaths) {
        self.modelDirectory = paths.modelsDirectory.appendingPathComponent(
            "parakeet-0.6b-ja-coreml",
            isDirectory: true
        )
    }

    public func transcribe(_ audioURL: URL) async throws -> TranscriptionSummary {
        let manager = try await loadManager()
        let audioFile = try AVAudioFile(forReading: audioURL)
        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        var decoderState = try TdtDecoderState(decoderLayers: 2)
        let result = try await manager.transcribe(audioURL, decoderState: &decoderState)
        let timings = (result.tokenTimings ?? []).sorted {
            if $0.startTime == $1.startTime {
                return $0.endTime < $1.endTime
            }
            return $0.startTime < $1.startTime
        }
        guard !timings.isEmpty else {
            throw Insta360Error.noTimedTokens
        }
        return TranscriptionSummary(
            segments: Self.makeSegments(from: timings),
            processingTimeSeconds: result.processingTime,
            audioDurationSeconds: duration
        )
    }

    public static func makeSegments(from timings: [TokenTiming]) -> [TimedTranscriptSegment] {
        var output: [TimedTranscriptSegment] = []
        var tokens: [String] = []
        var start = 0.0
        var end = 0.0

        func appendCurrent() {
            let text = tokens.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            let punctuation = CharacterSet(charactersIn: "。、，．！？!?「」『』（）()[]【】・…〜ー—–")
            let meaningful = text.trimmingCharacters(in: punctuation)
            guard !meaningful.isEmpty, end > start else {
                tokens.removeAll(keepingCapacity: true)
                return
            }
            output.append(TimedTranscriptSegment(
                startMs: Int64((start * 1_000).rounded()),
                endMs: Int64((end * 1_000).rounded()),
                text: text
            ))
            tokens.removeAll(keepingCapacity: true)
        }

        for timing in timings {
            let token = normalizedToken(timing.token)
            guard !token.isEmpty else { continue }
            if !tokens.isEmpty {
                let gap = timing.startTime - end
                if gap >= 0.8 || timing.endTime - start >= 12.0 {
                    appendCurrent()
                }
            }
            if tokens.isEmpty {
                start = max(0, timing.startTime)
            }
            tokens.append(token)
            end = max(end, timing.endTime)
            if token.contains(where: { "。！？!?".contains($0) }) {
                appendCurrent()
            }
        }
        appendCurrent()
        return output
    }

    public static func normalizedToken(_ token: String) -> String {
        let normalized = token
            .replacingOccurrences(of: "▁", with: "")
            .replacingOccurrences(of: "<space>", with: " ")
        if normalized.hasPrefix("<"), normalized.hasSuffix(">") {
            return ""
        }
        return normalized
    }

    private func loadManager() async throws -> AsrManager {
        if let manager { return manager }
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        let models = try await AsrModels.downloadAndLoad(to: modelDirectory, version: .tdtJa)
        let manager = AsrManager(models: models)
        self.manager = manager
        return manager
    }
}

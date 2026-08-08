import Foundation
import AVFoundation
import FluidAudio

struct TranscriptSegment: Codable {
    let startMs: Int
    let endMs: Int
    let startedAt: String
    let endedAt: String
    let text: String
}

struct TranscriptionMetadata: Codable {
    let engine: String
    let model: String
    let processingTimeSeconds: Double
    let audioDurationSeconds: Double
    let realTimeFactor: Float
    let confidence: Float
    let tokenCount: Int
}

struct TranscriptOutput: Codable {
    let sourceAudio: String
    let recordingStartedAt: String
    let recordingStartSource: String
    let timeZone: String
    let transcription: TranscriptionMetadata
    let fullText: String
    let segments: [TranscriptSegment]
}

enum TranscribeError: Error, CustomStringConvertible {
    case invalidArguments
    case invalidFilename(String)
    case noTimedTokens

    var description: String {
        switch self {
        case .invalidArguments:
            return "usage: insta360-ja-transcribe <audio.wav> [output-base]"
        case .invalidFilename(let filename):
            return "recording start time not found in filename: \(filename)"
        case .noTimedTokens:
            return "transcription returned no timed tokens"
        }
    }
}

@main
struct Insta360JaTranscribe {
    static let timeZoneIdentifier = "Asia/Tokyo"

    static func main() async {
        do {
            try await run()
        } catch {
            fputs("error: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    static func run() async throws {
        guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else {
            throw TranscribeError.invalidArguments
        }

        let audioURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let outputBaseURL: URL
        if CommandLine.arguments.count == 3 {
            outputBaseURL = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        } else {
            outputBaseURL = audioURL.deletingPathExtension().appendingPathExtension("transcript")
        }

        let recordingStart = try recordingStartDate(from: audioURL.lastPathComponent)
        let audioFile = try AVAudioFile(forReading: audioURL)
        let audioDuration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestampFormatter.timeZone = TimeZone(identifier: timeZoneIdentifier)

        let modelDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".models/fluidaudio/parakeet-0.6b-ja-coreml", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )

        print("model-directory=\(modelDirectory.path)")
        let models = try await AsrModels.downloadAndLoad(
            to: modelDirectory,
            version: .tdtJa
        )

        let manager = AsrManager(models: models)
        let progressStream = await manager.transcriptionProgressStream
        let progressTask = Task {
            do {
                for try await progress in progressStream {
                    let percent = Int((progress * 100).rounded())
                    print("transcription-progress=\(percent)%")
                }
            } catch {
                fputs("transcription-progress-error: \(error)\n", stderr)
            }
        }

        print("transcription-started=\(audioURL.lastPathComponent)")
        var decoderState = try TdtDecoderState(decoderLayers: 2)
        let result = try await manager.transcribe(audioURL, decoderState: &decoderState)
        await progressTask.value

        let timings = (result.tokenTimings ?? []).sorted {
            if $0.startTime == $1.startTime {
                return $0.endTime < $1.endTime
            }
            return $0.startTime < $1.startTime
        }
        guard !timings.isEmpty else {
            throw TranscribeError.noTimedTokens
        }

        let segments = makeSegments(
            from: timings,
            recordingStart: recordingStart,
            timestampFormatter: timestampFormatter
        )
        let output = TranscriptOutput(
            sourceAudio: audioURL.lastPathComponent,
            recordingStartedAt: timestampFormatter.string(from: recordingStart),
            recordingStartSource: "filename-inferred",
            timeZone: timeZoneIdentifier,
            transcription: TranscriptionMetadata(
                engine: "FluidAudio",
                model: "Parakeet TDT Japanese",
                processingTimeSeconds: result.processingTime,
                audioDurationSeconds: audioDuration,
                realTimeFactor: Float(audioDuration / result.processingTime),
                confidence: result.confidence,
                tokenCount: timings.count
            ),
            fullText: result.text,
            segments: segments
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(output).write(
            to: outputBaseURL.appendingPathExtension("json"),
            options: .atomic
        )
        try makeMarkdown(from: output).write(
            to: outputBaseURL.appendingPathExtension("md"),
            atomically: true,
            encoding: .utf8
        )

        print("transcript-characters=\(result.text.count)")
        print("transcript-segments=\(segments.count)")
        print("processing-seconds=\(String(format: "%.2f", result.processingTime))")
        print("rtfx=\(String(format: "%.2f", audioDuration / result.processingTime))")
        print("output-json=\(outputBaseURL.appendingPathExtension("json").path)")
        print("output-markdown=\(outputBaseURL.appendingPathExtension("md").path)")
    }

    static func recordingStartDate(from filename: String) throws -> Date {
        let parts = filename.split(separator: "_")
        guard parts.count >= 3, parts[1].count == 6, parts[2].count == 6 else {
            throw TranscribeError.invalidFilename(filename)
        }

        let dateDigits = Array(parts[1])
        let timeDigits = Array(parts[2])
        func number(_ digits: [Character], _ range: Range<Int>) -> Int? {
            Int(String(digits[range]))
        }

        guard
            let year = number(dateDigits, 0..<2),
            let month = number(dateDigits, 2..<4),
            let day = number(dateDigits, 4..<6),
            let hour = number(timeDigits, 0..<2),
            let minute = number(timeDigits, 2..<4),
            let second = number(timeDigits, 4..<6),
            let zone = TimeZone(identifier: timeZoneIdentifier)
        else {
            throw TranscribeError.invalidFilename(filename)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(
            calendar: calendar,
            timeZone: zone,
            year: 2000 + year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
        guard let date = calendar.date(from: components) else {
            throw TranscribeError.invalidFilename(filename)
        }
        return date
    }

    static func makeSegments(
        from timings: [TokenTiming],
        recordingStart: Date,
        timestampFormatter: ISO8601DateFormatter
    ) -> [TranscriptSegment] {
        var output: [TranscriptSegment] = []
        var segmentTokens: [String] = []
        var segmentStart = 0.0
        var segmentEnd = 0.0

        func appendCurrentSegment() {
            let text = segmentTokens.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            let punctuation = CharacterSet(charactersIn: "。、，．！？!?「」『』（）()[]【】・…〜ー—–")
            let meaningfulText = text.trimmingCharacters(in: punctuation)
            guard !meaningfulText.isEmpty, segmentEnd > segmentStart else {
                segmentTokens.removeAll(keepingCapacity: true)
                return
            }
            let startMs = Int((segmentStart * 1_000).rounded())
            let endMs = Int((segmentEnd * 1_000).rounded())
            output.append(
                TranscriptSegment(
                    startMs: startMs,
                    endMs: endMs,
                    startedAt: timestampFormatter.string(
                        from: recordingStart.addingTimeInterval(segmentStart)
                    ),
                    endedAt: timestampFormatter.string(
                        from: recordingStart.addingTimeInterval(segmentEnd)
                    ),
                    text: text
                )
            )
            segmentTokens.removeAll(keepingCapacity: true)
        }

        for timing in timings {
            let token = normalizedToken(timing.token)
            guard !token.isEmpty else { continue }

            if !segmentTokens.isEmpty {
                let gap = timing.startTime - segmentEnd
                if gap >= 0.8 || timing.endTime - segmentStart >= 12.0 {
                    appendCurrentSegment()
                }
            }

            if segmentTokens.isEmpty {
                segmentStart = max(0, timing.startTime)
            }
            segmentTokens.append(token)
            segmentEnd = max(segmentEnd, timing.endTime)

            if token.contains(where: { "。！？!?".contains($0) }) {
                appendCurrentSegment()
            }
        }
        appendCurrentSegment()
        return output
    }

    static func normalizedToken(_ token: String) -> String {
        let normalized = token
            .replacingOccurrences(of: "▁", with: "")
            .replacingOccurrences(of: "<space>", with: " ")
        if normalized.hasPrefix("<") && normalized.hasSuffix(">") {
            return ""
        }
        return normalized
    }

    static func makeMarkdown(from output: TranscriptOutput) -> String {
        var markdown = """
        # 文字起こし

        - 音声: `\(output.sourceAudio)`
        - 録音開始: \(output.recordingStartedAt)（\(output.recordingStartSource)）
        - タイムゾーン: `\(output.timeZone)`
        - 文字起こし: `\(output.transcription.engine) / \(output.transcription.model)`
        - 処理時間: \(String(format: "%.2f秒", output.transcription.processingTimeSeconds))
        - 実時間比: \(String(format: "%.2fx", output.transcription.realTimeFactor))

        ## 文字起こし

        """
        for segment in output.segments {
            markdown += "- **\(segment.startedAt) – \(segment.endedAt)** \(segment.text)\n"
        }
        return markdown
    }
}

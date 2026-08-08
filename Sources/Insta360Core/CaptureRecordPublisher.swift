import CryptoKit
import Foundation

public struct ChronixdTranscriptionRecord: Codable, Sendable, Equatable {
    public let type: String
    public let unixTimeMs: Int64
    public let endUnixTimeMs: Int64
    public let sessionId: String
    public let text: String
    public let device: String
    public let rms: Double?

    public init(
        unixTimeMs: Int64,
        endUnixTimeMs: Int64,
        sessionId: String,
        text: String,
        device: String = "Insta360 Mic Pro",
        rms: Double? = nil
    ) {
        self.type = "transcription"
        self.unixTimeMs = unixTimeMs
        self.endUnixTimeMs = endUnixTimeMs
        self.sessionId = sessionId
        self.text = text
        self.device = device
        self.rms = rms
    }
}

public struct PublicationResult: Sendable {
    public let relativePaths: [String]
    public let recordCount: Int
    public let lineSHA256: [String]

    public init(relativePaths: [String], recordCount: Int, lineSHA256: [String]) {
        self.relativePaths = relativePaths
        self.recordCount = recordCount
        self.lineSHA256 = lineSHA256
    }
}

public actor CaptureRecordPublisher {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let calendar: Calendar

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: RecordingClock.timeZoneIdentifier)!
        self.calendar = calendar
    }

    public func publish(
        segments: [TimedTranscriptSegment],
        recordingStart: Date,
        recordingSHA256: String,
        dataDirectory: URL,
        deviceIdentity: CaptureDeviceIdentity = .generic
    ) throws -> PublicationResult {
        let sessionID = String(recordingSHA256.prefix(8))
        let startEpochMs = Int64((recordingStart.timeIntervalSince1970 * 1_000).rounded())
        let records = segments.map { segment in
            ChronixdTranscriptionRecord(
                unixTimeMs: startEpochMs + segment.startMs,
                endUnixTimeMs: startEpochMs + segment.endMs,
                sessionId: sessionID,
                text: segment.text,
                device: deviceIdentity.recordDeviceName
            )
        }
        let grouped = Dictionary(grouping: records) { record in
            captureDateString(for: record.unixTimeMs)
        }
        let capturesDirectory = dataDirectory
            .appendingPathComponent("captures", isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: capturesDirectory, withIntermediateDirectories: true)

        var paths: [String] = []
        var allHashes: [String] = []
        for date in grouped.keys.sorted() {
            guard let recordsForDay = grouped[date] else { continue }
            let target = capturesDirectory.appendingPathComponent(
                "\(date)_\(deviceIdentity.captureFileDeviceName).ndjson",
                isDirectory: false
            )
            let newLines = try recordsForDay.map(encodeLine)
            let existingLines = try validatedLines(at: target)
            var seen = Set(existingLines)
            var merged = existingLines
            for line in newLines where seen.insert(line).inserted {
                merged.append(line)
            }
            let body = merged.isEmpty ? "" : merged.joined(separator: "\n") + "\n"
            try Data(body.utf8).write(to: target, options: .atomic)

            let verified = try validatedLines(at: target)
            let verifiedSet = Set(verified)
            guard newLines.allSatisfy(verifiedSet.contains) else {
                throw Insta360Error.verificationFailed(target.path)
            }
            paths.append(relativePath(of: target, from: dataDirectory))
            allHashes.append(contentsOf: newLines.map(Self.sha256))
        }
        return PublicationResult(
            relativePaths: paths,
            recordCount: records.count,
            lineSHA256: allHashes
        )
    }

    public func records(
        segments: [TimedTranscriptSegment],
        recordingStart: Date,
        recordingSHA256: String,
        deviceIdentity: CaptureDeviceIdentity = .generic
    ) -> [ChronixdTranscriptionRecord] {
        let startEpochMs = Int64((recordingStart.timeIntervalSince1970 * 1_000).rounded())
        let sessionID = String(recordingSHA256.prefix(8))
        return segments.map {
            ChronixdTranscriptionRecord(
                unixTimeMs: startEpochMs + $0.startMs,
                endUnixTimeMs: startEpochMs + $0.endMs,
                sessionId: sessionID,
                text: $0.text,
                device: deviceIdentity.recordDeviceName
            )
        }
    }

    private func encodeLine(_ record: ChronixdTranscriptionRecord) throws -> String {
        guard let line = String(data: try encoder.encode(record), encoding: .utf8) else {
            throw Insta360Error.verificationFailed("JSONをUTF-8へ変換できません")
        }
        return line
    }

    private func validatedLines(at url: URL) throws -> [String] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let body = try String(contentsOf: url, encoding: .utf8)
        let lines = body.split(whereSeparator: \.isNewline).map(String.init)
        for (index, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  (try? decoder.decode(ChronixdTranscriptionRecord.self, from: data)) != nil
            else {
                throw Insta360Error.invalidNDJSON(path: url.path, line: index + 1)
            }
        }
        return lines
    }

    private func captureDateString(for unixTimeMs: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(unixTimeMs) / 1_000)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func relativePath(of fileURL: URL, from directoryURL: URL) -> String {
        let base = directoryURL.standardizedFileURL.path
        let path = fileURL.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return fileURL.lastPathComponent }
        return String(path.dropFirst(base.count + 1))
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

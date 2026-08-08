import Foundation

public struct SourceFingerprint: Codable, Sendable, Hashable {
    public let relativePath: String
    public let size: Int64
    public let modificationTimeMs: Int64

    public init(relativePath: String, size: Int64, modificationTimeMs: Int64) {
        self.relativePath = relativePath
        self.size = size
        self.modificationTimeMs = modificationTimeMs
    }
}

public struct DiscoveredAudioFile: Sendable {
    public let url: URL
    public let relativePath: String
    public let recordingID: String
    public let variant: AudioVariant
    public let bitDepth: Int
    public let fingerprint: SourceFingerprint

    public init(
        url: URL,
        relativePath: String,
        recordingID: String,
        variant: AudioVariant,
        bitDepth: Int,
        fingerprint: SourceFingerprint
    ) {
        self.url = url
        self.relativePath = relativePath
        self.recordingID = recordingID
        self.variant = variant
        self.bitDepth = bitDepth
        self.fingerprint = fingerprint
    }
}

public struct DiscoveredRecording: Sendable {
    public let id: String
    public let files: [DiscoveredAudioFile]

    public init(id: String, files: [DiscoveredAudioFile]) {
        self.id = id
        self.files = files
    }

    public func selectedFile(preference: [AudioVariant]) -> DiscoveredAudioFile? {
        for variant in preference {
            if let file = files.first(where: { $0.variant == variant }) {
                return file
            }
        }
        return files.first
    }
}

public struct RecordingStart: Codable, Sendable, Equatable {
    public let date: Date
    public let source: String

    public init(date: Date, source: String) {
        self.date = date
        self.source = source
    }
}

public enum RecordingClock {
    public static let timeZoneIdentifier = "Asia/Tokyo"

    public static func resolve(
        filename: String,
        fallbackModificationDate: Date
    ) -> RecordingStart {
        if let date = dateFromFilename(filename) {
            return RecordingStart(date: date, source: "filename-inferred")
        }
        return RecordingStart(date: fallbackModificationDate, source: "filesystem-mtime-fallback")
    }

    public static func dateFromFilename(_ filename: String) -> Date? {
        let parts = filename.split(separator: "_")
        guard parts.count >= 3, parts[1].count == 6, parts[2].count == 6 else {
            return nil
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
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: zone,
            year: 2000 + year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        ))
    }
}

public struct RecordingDiscovery: Sendable {
    private static let filenamePattern = try! NSRegularExpression(
        pattern: #"^audio_(\d{6})_(\d{6})_(\d+)bit_(orig|processed)\.wav$"#,
        options: [.caseInsensitive]
    )

    public init() {}

    public func discover(
        in sourceDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> [DiscoveredRecording] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw Insta360Error.invalidSource(sourceDirectory.path)
        }

        guard let enumerator = fileManager.enumerator(
            at: sourceDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw Insta360Error.invalidSource(sourceDirectory.path)
        }

        var grouped: [String: [DiscoveredAudioFile]] = [:]
        for case let url as URL in enumerator {
            guard let parsed = parseFilename(url.lastPathComponent) else { continue }
            let values = try url.resourceValues(forKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
                .isRegularFileKey,
            ])
            guard values.isRegularFile == true,
                  let size = values.fileSize,
                  let modificationDate = values.contentModificationDate
            else {
                continue
            }
            let relativePath = relativePath(of: url, from: sourceDirectory)
            let fingerprint = SourceFingerprint(
                relativePath: relativePath,
                size: Int64(size),
                modificationTimeMs: Int64((modificationDate.timeIntervalSince1970 * 1_000).rounded())
            )
            grouped[parsed.recordingID, default: []].append(DiscoveredAudioFile(
                url: url,
                relativePath: relativePath,
                recordingID: parsed.recordingID,
                variant: parsed.variant,
                bitDepth: parsed.bitDepth,
                fingerprint: fingerprint
            ))
        }

        return grouped.map { id, files in
            DiscoveredRecording(
                id: id,
                files: files.sorted { $0.relativePath < $1.relativePath }
            )
        }.sorted { $0.id < $1.id }
    }

    public func containsSupportedWAV(
        in sourceDirectory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let enumerator = fileManager.enumerator(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        for case let url as URL in enumerator where parseFilename(url.lastPathComponent) != nil {
            return true
        }
        return false
    }

    public func discover(file url: URL) throws -> DiscoveredRecording {
        let standardizedURL = url.standardizedFileURL
        let values = try standardizedURL.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .isRegularFileKey,
        ])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              let modificationDate = values.contentModificationDate
        else {
            throw Insta360Error.invalidSource(standardizedURL.path)
        }
        let parsed = parseFilename(standardizedURL.lastPathComponent)
        let recordingID = parsed?.recordingID
            ?? standardizedURL.deletingPathExtension().lastPathComponent
        let fingerprint = SourceFingerprint(
            relativePath: standardizedURL.lastPathComponent,
            size: Int64(size),
            modificationTimeMs: Int64((modificationDate.timeIntervalSince1970 * 1_000).rounded())
        )
        return DiscoveredRecording(id: recordingID, files: [
            DiscoveredAudioFile(
                url: standardizedURL,
                relativePath: standardizedURL.lastPathComponent,
                recordingID: recordingID,
                variant: parsed?.variant ?? .orig,
                bitDepth: parsed?.bitDepth ?? 0,
                fingerprint: fingerprint
            ),
        ])
    }

    public func parseFilename(
        _ filename: String
    ) -> (recordingID: String, variant: AudioVariant, bitDepth: Int)? {
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        guard let match = Self.filenamePattern.firstMatch(in: filename, range: range),
              let dateRange = Range(match.range(at: 1), in: filename),
              let timeRange = Range(match.range(at: 2), in: filename),
              let depthRange = Range(match.range(at: 3), in: filename),
              let variantRange = Range(match.range(at: 4), in: filename),
              let bitDepth = Int(filename[depthRange]),
              let variant = AudioVariant(rawValue: filename[variantRange].lowercased())
        else {
            return nil
        }
        return (
            recordingID: "audio_\(filename[dateRange])_\(filename[timeRange])",
            variant: variant,
            bitDepth: bitDepth
        )
    }

    private func relativePath(of fileURL: URL, from directoryURL: URL) -> String {
        let base = directoryURL.standardizedFileURL.path
        let path = fileURL.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return fileURL.lastPathComponent }
        return String(path.dropFirst(base.count + 1))
    }
}

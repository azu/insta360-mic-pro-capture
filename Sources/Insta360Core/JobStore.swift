import Foundation

public enum JobState: String, Codable, Sendable, CaseIterable {
    case copied
    case transcribing
    case publishing
    case completed
    case failed
}

public enum LocalCleanupState: String, Codable, Sendable {
    case pending
    case deleted
    case moved
    case failed
}

public enum DeviceCleanupState: String, Codable, Sendable {
    case pending
    case kept
    case deleted
    case failed
}

public struct JobCleanup: Codable, Sendable {
    public var localWav: LocalCleanupState
    public var deviceWav: DeviceCleanupState
    public var lastError: String?

    public init(
        localWav: LocalCleanupState = .pending,
        deviceWav: DeviceCleanupState = .pending,
        lastError: String? = nil
    ) {
        self.localWav = localWav
        self.deviceWav = deviceWav
        self.lastError = lastError
    }
}

public struct JobPublication: Codable, Sendable {
    public let relativePaths: [String]
    public let recordCount: Int
    public let lineSHA256: [String]

    public init(relativePaths: [String], recordCount: Int, lineSHA256: [String]) {
        self.relativePaths = relativePaths
        self.recordCount = recordCount
        self.lineSHA256 = lineSHA256
    }
}

public struct JobFailure: Codable, Sendable {
    public let operation: String
    public let message: String
    public let occurredAt: Date

    public init(operation: String, message: String, occurredAt: Date = Date()) {
        self.operation = operation
        self.message = message
        self.occurredAt = occurredAt
    }
}

public struct TimedTranscriptSegment: Codable, Sendable, Equatable {
    public let startMs: Int64
    public let endMs: Int64
    public let text: String

    public init(startMs: Int64, endMs: Int64, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

public struct ProcessingJob: Codable, Sendable {
    public let id: String
    public var state: JobState
    public var resumeFrom: JobState?
    public let recording: ImportedRecording
    public let options: RuntimeOptions
    public var segments: [TimedTranscriptSegment]
    public var publication: JobPublication?
    public var cleanup: JobCleanup
    public var attempts: Int
    public var lastError: JobFailure?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        recording: ImportedRecording,
        options: RuntimeOptions,
        now: Date = Date()
    ) {
        self.id = recording.id
        self.state = .copied
        self.resumeFrom = nil
        self.recording = recording
        self.options = options
        self.segments = []
        self.publication = nil
        self.cleanup = JobCleanup()
        self.attempts = 0
        self.lastError = nil
        self.createdAt = now
        self.updatedAt = now
    }

    public var shortID: String {
        String(id.prefix(8))
    }
}

public actor JobStore {
    private let paths: ApplicationPaths
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: ApplicationPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    public func save(_ job: ProcessingJob) throws {
        try paths.createRuntimeDirectories(fileManager: fileManager)
        let data = try encoder.encode(job)
        try data.write(to: jobURL(id: job.id), options: .atomic)
    }

    public func load(id: String) throws -> ProcessingJob {
        let exactURL = jobURL(id: id)
        if fileManager.fileExists(atPath: exactURL.path) {
            return try decode(at: exactURL)
        }
        let matches = try all().filter { $0.id.hasPrefix(id) }
        guard matches.count == 1, let job = matches.first else {
            throw Insta360Error.jobNotFound(id)
        }
        return job
    }

    public func existing(id: String) throws -> ProcessingJob? {
        let url = jobURL(id: id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decode(at: url)
    }

    public func all() throws -> [ProcessingJob] {
        guard fileManager.fileExists(atPath: paths.jobsDirectory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: paths.jobsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return try urls
            .filter { $0.pathExtension == "json" }
            .map(decode(at:))
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func matchingJob(
        sourceRoot: URL,
        fingerprints: [SourceFingerprint]
    ) throws -> ProcessingJob? {
        let rootPath = sourceRoot.standardizedFileURL.path
        let currentVolumeUUID = try? sourceRoot.resourceValues(
            forKeys: [.volumeUUIDStringKey]
        ).volumeUUIDString
        let expected = Set(fingerprints)
        return try all().last(where: { job in
            job.recording.sourceRootPath == rootPath
                && (job.recording.sourceVolumeUUID == nil
                    || currentVolumeUUID == job.recording.sourceVolumeUUID)
                && Set(job.recording.files.map(\.sourceFingerprint)) == expected
        })
    }

    private func decode(at url: URL) throws -> ProcessingJob {
        try decoder.decode(ProcessingJob.self, from: Data(contentsOf: url))
    }

    private func jobURL(id: String) -> URL {
        paths.jobsDirectory.appendingPathComponent("\(id).json", isDirectory: false)
    }
}

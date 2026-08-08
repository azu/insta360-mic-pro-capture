import CryptoKit
import Foundation

public struct ImportedAudioFile: Codable, Sendable, Hashable {
    public let sourceFingerprint: SourceFingerprint
    public let localRelativePath: String
    public let variant: AudioVariant
    public let bitDepth: Int
    public let sha256: String

    public init(
        sourceFingerprint: SourceFingerprint,
        localRelativePath: String,
        variant: AudioVariant,
        bitDepth: Int,
        sha256: String
    ) {
        self.sourceFingerprint = sourceFingerprint
        self.localRelativePath = localRelativePath
        self.variant = variant
        self.bitDepth = bitDepth
        self.sha256 = sha256
    }
}

public struct ImportedRecording: Codable, Sendable {
    public let id: String
    public let recordingID: String
    public let recordingStart: RecordingStart
    public let sourceRootPath: String
    public let sourceVolumeName: String
    public let sourceVolumeUUID: String?
    public let files: [ImportedAudioFile]
    public let selectedSHA256: String

    public init(
        id: String,
        recordingID: String,
        recordingStart: RecordingStart,
        sourceRootPath: String,
        sourceVolumeName: String,
        sourceVolumeUUID: String?,
        files: [ImportedAudioFile],
        selectedSHA256: String
    ) {
        self.id = id
        self.recordingID = recordingID
        self.recordingStart = recordingStart
        self.sourceRootPath = sourceRootPath
        self.sourceVolumeName = sourceVolumeName
        self.sourceVolumeUUID = sourceVolumeUUID
        self.files = files
        self.selectedSHA256 = selectedSHA256
    }

    public func selectedFileURL(spoolDirectory: URL) -> URL? {
        guard let file = files.first(where: { $0.sha256 == selectedSHA256 }) else { return nil }
        return spoolDirectory
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(file.localRelativePath, isDirectory: false)
    }
}

public struct RecordingImporter: Sendable {
    public init() {}

    public func importRecording(
        _ recording: DiscoveredRecording,
        from sourceRoot: URL,
        options: RuntimeOptions,
        paths: ApplicationPaths,
        fileManager: FileManager = .default
    ) throws -> ImportedRecording {
        try paths.createRuntimeDirectories(fileManager: fileManager)
        guard let selected = recording.selectedFile(preference: options.transcriptionPreference) else {
            throw Insta360Error.noRecordings(sourceRoot.path)
        }

        let filesToCopy: [DiscoveredAudioFile]
        switch options.copyPolicy {
        case .all:
            filesToCopy = recording.files
        case .selected:
            filesToCopy = [selected]
        }

        let requiredBytes = filesToCopy.reduce(Int64(0)) { $0 + $1.fingerprint.size }
        try ensureFreeSpace(requiredBytes: requiredBytes, at: paths.spoolDirectory)

        let temporaryDirectory = paths.spoolDirectory.appendingPathComponent(
            ".import-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        do {
            var importedFiles: [ImportedAudioFile] = []
            for file in filesToCopy {
                let destinationURL = temporaryDirectory.appendingPathComponent(
                    file.url.lastPathComponent,
                    isDirectory: false
                )
                let hash = try copyAndHash(
                    source: file,
                    destination: destinationURL,
                    fileManager: fileManager
                )
                importedFiles.append(ImportedAudioFile(
                    sourceFingerprint: file.fingerprint,
                    localRelativePath: destinationURL.lastPathComponent,
                    variant: file.variant,
                    bitDepth: file.bitDepth,
                    sha256: hash
                ))
            }

            guard let selectedImported = importedFiles.first(where: {
                $0.sourceFingerprint.relativePath == selected.relativePath
            }) else {
                throw Insta360Error.verificationFailed("選択したWAVのコピーが見つかりません")
            }

            let jobID = selectedImported.sha256
            let finalDirectory = paths.spoolDirectory.appendingPathComponent(jobID, isDirectory: true)
            if fileManager.fileExists(atPath: finalDirectory.path) {
                try fileManager.removeItem(at: temporaryDirectory)
            } else {
                try fileManager.moveItem(at: temporaryDirectory, to: finalDirectory)
            }

            let selectedModificationDate = Date(
                timeIntervalSince1970: Double(selected.fingerprint.modificationTimeMs) / 1_000
            )
            let recordingStart = RecordingClock.resolve(
                filename: selected.url.lastPathComponent,
                fallbackModificationDate: selectedModificationDate
            )
            let volumeValues = try? sourceRoot.resourceValues(forKeys: [
                .volumeNameKey,
                .volumeUUIDStringKey,
            ])
            return ImportedRecording(
                id: jobID,
                recordingID: recording.id,
                recordingStart: recordingStart,
                sourceRootPath: sourceRoot.standardizedFileURL.path,
                sourceVolumeName: volumeValues?.volumeName ?? sourceRoot.lastPathComponent,
                sourceVolumeUUID: volumeValues?.volumeUUIDString,
                files: importedFiles,
                selectedSHA256: selectedImported.sha256
            )
        } catch {
            if fileManager.fileExists(atPath: temporaryDirectory.path) {
                try? fileManager.removeItem(at: temporaryDirectory)
            }
            throw error
        }
    }

    public func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return Self.hexDigest(hasher.finalize())
    }

    private func copyAndHash(
        source: DiscoveredAudioFile,
        destination: URL,
        fileManager: FileManager
    ) throws -> String {
        let partialURL = destination.appendingPathExtension("partial")
        fileManager.createFile(atPath: partialURL.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source.url)
        let output = try FileHandle(forWritingTo: partialURL)
        defer {
            try? input.close()
            try? output.close()
        }

        var hasher = SHA256()
        var copiedBytes: Int64 = 0
        while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
            try output.write(contentsOf: data)
            hasher.update(data: data)
            copiedBytes += Int64(data.count)
        }
        try output.synchronize()

        guard copiedBytes == source.fingerprint.size else {
            throw Insta360Error.sourceChanged(source.url.path)
        }
        let current = try currentFingerprint(
            for: source.url,
            relativePath: source.relativePath
        )
        guard current == source.fingerprint else {
            throw Insta360Error.sourceChanged(source.url.path)
        }

        try fileManager.moveItem(at: partialURL, to: destination)
        return Self.hexDigest(hasher.finalize())
    }

    private func currentFingerprint(for url: URL, relativePath: String) throws -> SourceFingerprint {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values.fileSize, let modificationDate = values.contentModificationDate else {
            throw Insta360Error.invalidSource(url.path)
        }
        return SourceFingerprint(
            relativePath: relativePath,
            size: Int64(size),
            modificationTimeMs: Int64((modificationDate.timeIntervalSince1970 * 1_000).rounded())
        )
    }

    private func ensureFreeSpace(requiredBytes: Int64, at directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        let importantUsage = values.volumeAvailableCapacityForImportantUsage
        let generalCapacity = values.volumeAvailableCapacity.map(Int64.init)
        guard let available = (importantUsage ?? 0) > 0 ? importantUsage : generalCapacity,
              available > 0
        else { return }
        let margin = max(Int64(64 * 1_024 * 1_024), requiredBytes / 20)
        guard available >= requiredBytes + margin else {
            throw Insta360Error.insufficientFreeSpace(required: requiredBytes + margin, available: available)
        }
    }

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

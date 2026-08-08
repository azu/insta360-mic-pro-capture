import Foundation

public struct ImportSummary: Sendable {
    public let discoveredCount: Int
    public let copiedCount: Int
    public let skippedCount: Int
    public let completedJobIDs: [String]
    public let failedJobIDs: [String]

    public init(
        discoveredCount: Int,
        copiedCount: Int,
        skippedCount: Int,
        completedJobIDs: [String],
        failedJobIDs: [String]
    ) {
        self.discoveredCount = discoveredCount
        self.copiedCount = copiedCount
        self.skippedCount = skippedCount
        self.completedJobIDs = completedJobIDs
        self.failedJobIDs = failedJobIDs
    }
}

public actor JobRunner {
    private let paths: ApplicationPaths
    private let store: JobStore
    private let transcription: TranscriptionService
    private let publisher: CaptureRecordPublisher
    private let notification: NotificationService
    private let discovery = RecordingDiscovery()
    private let importer = RecordingImporter()
    private let fileManager: FileManager

    public init(
        paths: ApplicationPaths = ApplicationPaths(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.store = JobStore(paths: paths)
        self.transcription = TranscriptionService(paths: paths)
        self.publisher = CaptureRecordPublisher()
        self.notification = NotificationService()
    }

    public func importDirectory(
        _ sourceDirectory: URL,
        options: RuntimeOptions
    ) async throws -> ImportSummary {
        let discoveredRecordings = try discovery.discover(in: sourceDirectory)
        if discoveredRecordings.isEmpty {
            return ImportSummary(
                discoveredCount: 0,
                copiedCount: 0,
                skippedCount: 0,
                completedJobIDs: [],
                failedJobIDs: []
            )
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let refreshed = try discovery.discover(in: sourceDirectory)
        let refreshedByID = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.id, $0) })
        var unstableRecordingIDs: [String] = []
        let recordings = discoveredRecordings.compactMap { recording -> DiscoveredRecording? in
            guard let current = refreshedByID[recording.id],
                  Set(current.files.map(\.fingerprint)) == Set(recording.files.map(\.fingerprint))
            else {
                unstableRecordingIDs.append(recording.id)
                return nil
            }
            return current
        }

        var jobsToRun: [ProcessingJob] = []
        var copiedCount = 0
        var skippedCount = 0
        var importFailures = unstableRecordingIDs
        for recordingID in unstableRecordingIDs {
            notification.failed("\(recordingID): ファイルがまだ変更中のためコピーを保留しました")
        }
        for recording in recordings {
            do {
                let fingerprints = fingerprintsUsed(by: recording, options: options)
                if let existing = try await store.matchingJob(
                    sourceRoot: sourceDirectory,
                    fingerprints: fingerprints
                ) {
                    skippedCount += 1
                    if existing.state != .completed {
                        jobsToRun.append(existing)
                    } else {
                        var completed = existing
                        await cleanupDeviceWAVs(job: &completed)
                        try await store.save(completed)
                    }
                    continue
                }

                let imported = try importer.importRecording(
                    recording,
                    from: sourceDirectory,
                    options: options,
                    paths: paths,
                    fileManager: fileManager
                )
                if let existing = try await store.existing(id: imported.id) {
                    skippedCount += 1
                    if existing.state != .completed {
                        jobsToRun.append(existing)
                    } else {
                        try? removeSpoolDirectory(id: imported.id)
                    }
                    continue
                }
                let job = ProcessingJob(recording: imported, options: options)
                try await store.save(job)
                jobsToRun.append(job)
                copiedCount += 1
            } catch {
                importFailures.append(recording.id)
                notification.failed("\(recording.id): \(error)")
            }
        }

        if copiedCount > 0,
           importFailures.isEmpty,
           options.notifyWhenCopyCompletes {
            notification.copyCompleted(
                volumeName: sourceDirectory.lastPathComponent,
                count: copiedCount
            )
        }

        var completedIDs: [String] = []
        var failedIDs = importFailures
        for job in jobsToRun {
            do {
                let completed = try await run(job: job)
                completedIDs.append(completed.id)
            } catch {
                failedIDs.append(job.id)
            }
        }
        return ImportSummary(
            discoveredCount: discoveredRecordings.count,
            copiedCount: copiedCount,
            skippedCount: skippedCount,
            completedJobIDs: completedIDs,
            failedJobIDs: failedIDs
        )
    }

    public func processFile(
        _ audioURL: URL,
        options: RuntimeOptions
    ) async throws -> ProcessingJob {
        let recording = try discovery.discover(file: audioURL)
        let safeOptions = RuntimeOptions(
            dataDirectory: options.dataDirectory,
            acceptedVolumeNames: options.acceptedVolumeNames,
            copyPolicy: .selected,
            transcriptionPreference: options.transcriptionPreference,
            localWavPolicy: options.localWavPolicy,
            deviceWavPolicy: .keep,
            notifyWhenCopyCompletes: options.notifyWhenCopyCompletes,
            notifyWhenProcessingCompletes: options.notifyWhenProcessingCompletes
        )
        let imported = try importer.importRecording(
            recording,
            from: audioURL.deletingLastPathComponent(),
            options: safeOptions,
            paths: paths,
            fileManager: fileManager
        )
        if let existing = try await store.existing(id: imported.id) {
            if existing.state == .completed {
                try? removeSpoolDirectory(id: imported.id)
                return existing
            }
            return try await run(job: existing)
        }
        let job = ProcessingJob(recording: imported, options: safeOptions)
        try await store.save(job)
        return try await run(job: job)
    }

    public func retry(id: String) async throws -> ProcessingJob {
        let job = try await store.load(id: id)
        if job.state == .completed {
            var completed = job
            await cleanupLocalWAVs(job: &completed)
            await cleanupDeviceWAVs(job: &completed)
            try await store.save(completed)
            return completed
        }
        return try await run(job: job)
    }

    public func allJobs() async throws -> [ProcessingJob] {
        try await store.all()
    }

    private func run(job initialJob: ProcessingJob) async throws -> ProcessingJob {
        var job = initialJob
        job.attempts += 1
        job.lastError = nil

        do {
            let resume = job.state == .failed ? job.resumeFrom : job.state
            if resume == .copied || resume == .transcribing || job.segments.isEmpty {
                job.state = .transcribing
                job.resumeFrom = nil
                job.updatedAt = Date()
                try await store.save(job)
                guard let audioURL = job.recording.selectedFileURL(
                    spoolDirectory: paths.spoolDirectory
                ), fileManager.fileExists(atPath: audioURL.path) else {
                    throw Insta360Error.retryUnavailable("spool WAVがありません")
                }
                let result = try await transcription.transcribe(audioURL)
                job.segments = result.segments
                job.updatedAt = Date()
                try await store.save(job)
            }

            job.state = .publishing
            job.updatedAt = Date()
            try await store.save(job)
            let deviceIdentity = CaptureDeviceIdentity(
                sourceVolumeName: job.recording.sourceVolumeName,
                sourceVolumeUUID: job.recording.sourceVolumeUUID,
                acceptedVolumeNames: job.options.acceptedVolumeNames
            )
            let result = try await publisher.publish(
                segments: job.segments,
                recordingStart: job.recording.recordingStart.date,
                recordingSHA256: job.recording.id,
                dataDirectory: job.options.dataDirectory,
                deviceIdentity: deviceIdentity
            )
            job.publication = JobPublication(
                relativePaths: result.relativePaths,
                recordCount: result.recordCount,
                lineSHA256: result.lineSHA256
            )
            job.state = .completed
            job.resumeFrom = nil
            job.updatedAt = Date()
            try await store.save(job)

            await cleanupLocalWAVs(job: &job)
            await cleanupDeviceWAVs(job: &job)
            try await store.save(job)
            if job.options.notifyWhenProcessingCompletes {
                notification.processingCompleted(
                    recordCount: result.recordCount,
                    paths: result.relativePaths
                )
            }
            return job
        } catch {
            let failedAt = job.state
            job.state = .failed
            job.resumeFrom = failedAt
            job.lastError = JobFailure(
                operation: failedAt.rawValue,
                message: String(describing: error)
            )
            job.updatedAt = Date()
            try? await store.save(job)
            notification.failed(String(describing: error))
            throw error
        }
    }

    private func cleanupLocalWAVs(job: inout ProcessingJob) async {
        guard job.state == .completed,
              job.cleanup.localWav == .pending || job.cleanup.localWav == .failed
        else { return }
        let spool = paths.spoolDirectory.appendingPathComponent(job.id, isDirectory: true)
        guard fileManager.fileExists(atPath: spool.path) else {
            if job.options.localWavPolicy == .delete {
                job.cleanup.localWav = .deleted
            }
            return
        }
        do {
            switch job.options.localWavPolicy {
            case .delete:
                try fileManager.removeItem(at: spool)
                job.cleanup.localWav = .deleted
            case .move:
                let components = datePathComponents(job.recording.recordingStart.date)
                let deviceIdentity = CaptureDeviceIdentity(
                    sourceVolumeName: job.recording.sourceVolumeName,
                    sourceVolumeUUID: job.recording.sourceVolumeUUID,
                    acceptedVolumeNames: job.options.acceptedVolumeNames
                )
                let destination = job.options.dataDirectory
                    .appendingPathComponent(
                        "audio/\(deviceIdentity.audioDirectoryName)",
                        isDirectory: true
                    )
                    .appendingPathComponent(components, isDirectory: true)
                    .appendingPathComponent(job.recording.recordingID, isDirectory: true)
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                for file in job.recording.files {
                    let source = spool.appendingPathComponent(file.localRelativePath)
                    let target = destination.appendingPathComponent(file.localRelativePath)
                    if fileManager.fileExists(atPath: target.path) {
                        let existingHash = try importer.hashFile(at: target)
                        guard existingHash == file.sha256 else {
                            throw Insta360Error.verificationFailed("移動先に別内容のWAVがあります: \(target.path)")
                        }
                        try fileManager.removeItem(at: source)
                    } else {
                        try fileManager.moveItem(at: source, to: target)
                    }
                }
                try? fileManager.removeItem(at: spool)
                job.cleanup.localWav = .moved
            }
            job.cleanup.lastError = nil
        } catch {
            job.cleanup.localWav = .failed
            job.cleanup.lastError = String(describing: error)
        }
    }

    private func cleanupDeviceWAVs(job: inout ProcessingJob) async {
        guard job.state == .completed,
              job.cleanup.deviceWav == .pending || job.cleanup.deviceWav == .failed
        else { return }
        guard job.options.deviceWavPolicy == .deleteAfterPublish else {
            job.cleanup.deviceWav = .kept
            return
        }
        let root = URL(fileURLWithPath: job.recording.sourceRootPath, isDirectory: true)
            .standardizedFileURL
        guard fileManager.fileExists(atPath: root.path) else {
            job.cleanup.deviceWav = .pending
            job.cleanup.lastError = "Mic Proが接続されていません"
            return
        }
        if let expectedUUID = job.recording.sourceVolumeUUID {
            let currentUUID = try? root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
            guard currentUUID == expectedUUID else {
                job.cleanup.deviceWav = .failed
                job.cleanup.lastError = "取り込み時と異なるボリュームです"
                return
            }
        }
        do {
            for file in job.recording.files {
                let target = root.appendingPathComponent(file.sourceFingerprint.relativePath)
                    .standardizedFileURL
                guard target.path.hasPrefix(root.path + "/") else {
                    throw Insta360Error.verificationFailed("削除対象が取り込み元の外側です")
                }
                if !fileManager.fileExists(atPath: target.path) { continue }
                let values = try target.resourceValues(forKeys: [
                    .fileSizeKey,
                    .contentModificationDateKey,
                ])
                guard let size = values.fileSize,
                      let modificationDate = values.contentModificationDate
                else {
                    throw Insta360Error.invalidSource(target.path)
                }
                let current = SourceFingerprint(
                    relativePath: file.sourceFingerprint.relativePath,
                    size: Int64(size),
                    modificationTimeMs: Int64(
                        (modificationDate.timeIntervalSince1970 * 1_000).rounded()
                    )
                )
                guard current == file.sourceFingerprint else {
                    throw Insta360Error.sourceChanged(target.path)
                }
                try fileManager.removeItem(at: target)
            }
            job.cleanup.deviceWav = .deleted
            job.cleanup.lastError = nil
        } catch {
            job.cleanup.deviceWav = .failed
            job.cleanup.lastError = String(describing: error)
        }
    }

    private func fingerprintsUsed(
        by recording: DiscoveredRecording,
        options: RuntimeOptions
    ) -> [SourceFingerprint] {
        switch options.copyPolicy {
        case .all:
            return recording.files.map(\.fingerprint)
        case .selected:
            return recording.selectedFile(preference: options.transcriptionPreference)
                .map { [$0.fingerprint] } ?? []
        }
    }

    private func removeSpoolDirectory(id: String) throws {
        let directory = paths.spoolDirectory.appendingPathComponent(id, isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    private func datePathComponents(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: RecordingClock.timeZoneIdentifier)!
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d/%02d/%02d",
            values.year ?? 0,
            values.month ?? 0,
            values.day ?? 0
        )
    }
}

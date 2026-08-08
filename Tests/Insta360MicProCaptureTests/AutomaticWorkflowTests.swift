import Foundation
import FluidAudio
import XCTest
@testable import Insta360Core
@testable import Insta360MicProCapture

final class AutomaticWorkflowTests: XCTestCase {
    func testDiscoveryGroupsVariantsAndSelectsProcessed() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("original".utf8).write(
            to: root.appendingPathComponent("audio_260101_120000_32bit_orig.wav")
        )
        try Data("processed".utf8).write(
            to: root.appendingPathComponent("audio_260101_120000_24bit_processed.wav")
        )
        try Data("ignored".utf8).write(to: root.appendingPathComponent("unrelated.wav"))

        let recordings = try RecordingDiscovery().discover(in: root)

        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(recordings[0].id, "audio_260101_120000")
        XCTAssertEqual(recordings[0].files.count, 2)
        XCTAssertEqual(
            recordings[0].selectedFile(preference: [.processed, .orig])?.variant,
            .processed
        )
    }

    func testRecordingClockTreatsFilenameAsJapanTime() throws {
        let date = try XCTUnwrap(
            RecordingClock.dateFromFilename("audio_260101_120000_32bit_orig.wav")
        )
        XCTAssertEqual(Int64(date.timeIntervalSince1970), 1_767_236_400)
    }

    func testImporterCopiesWithoutChangingSourceAndHashesSelectedFile() throws {
        let root = try makeTemporaryDirectory()
        let support = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: support)
        }
        let source = root.appendingPathComponent("audio_260101_120000_32bit_orig.wav")
        let sourceData = Data("32-bit-float-fixture".utf8)
        try sourceData.write(to: source)
        let recording = try XCTUnwrap(RecordingDiscovery().discover(in: root).first)
        let paths = testPaths(support: support)
        let options = RuntimeOptions(dataDirectory: root.appendingPathComponent("data"))

        let imported = try RecordingImporter().importRecording(
            recording,
            from: root,
            options: options,
            paths: paths
        )

        XCTAssertEqual(try Data(contentsOf: source), sourceData)
        XCTAssertEqual(imported.id.count, 64)
        XCTAssertEqual(imported.id, imported.selectedSHA256)
        let copied = try XCTUnwrap(imported.selectedFileURL(spoolDirectory: paths.spoolDirectory))
        XCTAssertEqual(try Data(contentsOf: copied), sourceData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path + ".partial"))
    }

    func testPublisherCreatesChronixdCompatibleDeterministicNDJSON() async throws {
        let dataDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        let start = try XCTUnwrap(
            RecordingClock.dateFromFilename("audio_260101_235959_32bit_orig.wav")
        )
        let segments = [
            TimedTranscriptSegment(startMs: 0, endMs: 500, text: "日付の前"),
            TimedTranscriptSegment(startMs: 2_000, endMs: 2_500, text: "日付の後"),
        ]
        let hash = String(repeating: "a", count: 64)
        let publisher = CaptureRecordPublisher()
        let deviceIdentity = CaptureDeviceIdentity(
            sourceVolumeName: "MIC PRO",
            sourceVolumeUUID: "12345678-9ABC-4DEF-8123-456789ABCDEF",
            acceptedVolumeNames: ["MIC PRO"]
        )

        let first = try await publisher.publish(
            segments: segments,
            recordingStart: start,
            recordingSHA256: hash,
            dataDirectory: dataDirectory,
            deviceIdentity: deviceIdentity
        )
        let second = try await publisher.publish(
            segments: segments,
            recordingStart: start,
            recordingSHA256: hash,
            dataDirectory: dataDirectory,
            deviceIdentity: deviceIdentity
        )

        XCTAssertEqual(first.relativePaths, [
            "captures/2026-01-01_insta360-mic-pro-12345678.ndjson",
            "captures/2026-01-02_insta360-mic-pro-12345678.ndjson",
        ])
        XCTAssertEqual(first.lineSHA256, second.lineSHA256)
        XCTAssertEqual(first.recordCount, 2)
        for relativePath in first.relativePaths {
            let body = try String(
                contentsOf: dataDirectory.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertEqual(body.split(whereSeparator: \.isNewline).count, 1)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
            )
            XCTAssertEqual(object["type"] as? String, "transcription")
            XCTAssertEqual(object["device"] as? String, "Insta360 Mic Pro 12345678")
            XCTAssertEqual(object["sessionId"] as? String, "aaaaaaaa")
            XCTAssertNil(object["id"])
        }
    }

    func testCaptureDeviceIdentityUsesAcceptedVolumeUUID() {
        let identity = CaptureDeviceIdentity(
            sourceVolumeName: "mic pro",
            sourceVolumeUUID: "12345678-9ABC-4DEF-8123-456789ABCDEF",
            acceptedVolumeNames: ["MIC PRO"]
        )

        XCTAssertEqual(identity.shortID, "12345678")
        XCTAssertEqual(identity.recordDeviceName, "Insta360 Mic Pro 12345678")
        XCTAssertEqual(identity.captureFileDeviceName, "insta360-mic-pro-12345678")
        XCTAssertEqual(identity.audioDirectoryName, "insta360-mic-pro-12345678")
    }

    func testCaptureDeviceIdentityFallsBackForLocalOrMissingUUID() {
        XCTAssertEqual(
            CaptureDeviceIdentity(
                sourceVolumeName: "Macintosh HD",
                sourceVolumeUUID: "12345678-9ABC-4DEF-8123-456789ABCDEF",
                acceptedVolumeNames: ["MIC PRO"]
            ),
            .generic
        )
        XCTAssertEqual(
            CaptureDeviceIdentity(
                sourceVolumeName: "MIC PRO",
                sourceVolumeUUID: nil,
                acceptedVolumeNames: ["MIC PRO"]
            ),
            .generic
        )
    }

    func testPublisherDoesNotOverwriteInvalidNDJSON() async throws {
        let dataDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        let captures = dataDirectory.appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let target = captures.appendingPathComponent("2026-01-01_insta360-mic-pro.ndjson")
        let invalid = "{broken json}\n"
        try invalid.write(to: target, atomically: true, encoding: .utf8)
        let start = try XCTUnwrap(
            RecordingClock.dateFromFilename("audio_260101_120000_32bit_orig.wav")
        )

        do {
            _ = try await CaptureRecordPublisher().publish(
                segments: [TimedTranscriptSegment(startMs: 0, endMs: 1_000, text: "test")],
                recordingStart: start,
                recordingSHA256: String(repeating: "b", count: 64),
                dataDirectory: dataDirectory
            )
            XCTFail("invalid NDJSON must fail")
        } catch let error as Insta360Error {
            XCTAssertEqual(error.description, "NDJSONに壊れた行があります: \(target.path):1")
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), invalid)
    }

    func testJobStorePersistsAndFindsFingerprint() async throws {
        let support = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let source = support.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let paths = testPaths(support: support.appendingPathComponent("app"))
        let fingerprint = SourceFingerprint(
            relativePath: "audio_260101_120000_32bit_orig.wav",
            size: 123,
            modificationTimeMs: 456
        )
        let recording = ImportedRecording(
            id: String(repeating: "c", count: 64),
            recordingID: "audio_260101_120000",
            recordingStart: RecordingStart(date: Date(timeIntervalSince1970: 100), source: "test"),
            sourceRootPath: source.path,
            sourceVolumeName: "MIC PRO",
            sourceVolumeUUID: nil,
            files: [ImportedAudioFile(
                sourceFingerprint: fingerprint,
                localRelativePath: fingerprint.relativePath,
                variant: .orig,
                bitDepth: 32,
                sha256: String(repeating: "c", count: 64)
            )],
            selectedSHA256: String(repeating: "c", count: 64)
        )
        var job = ProcessingJob(
            recording: recording,
            options: RuntimeOptions(dataDirectory: support.appendingPathComponent("data"))
        )
        job.state = .publishing
        let store = JobStore(paths: paths)

        try await store.save(job)
        let loaded = try await store.load(id: "cccccccc")
        let matched = try await store.matchingJob(
            sourceRoot: source,
            fingerprints: [fingerprint]
        )

        XCTAssertEqual(loaded.state, .publishing)
        XCTAssertEqual(matched?.id, job.id)
    }

    func testJobStoreReportsCorruptExistingJob() async throws {
        let support = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let paths = testPaths(support: support)
        try paths.createRuntimeDirectories()
        let id = String(repeating: "d", count: 64)
        try "{broken".write(
            to: paths.jobsDirectory.appendingPathComponent("\(id).json"),
            atomically: true,
            encoding: .utf8
        )

        do {
            _ = try await JobStore(paths: paths).existing(id: id)
            XCTFail("corrupt job must not be treated as missing")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testAutomaticCLIRequiresDataDirectoryAndParsesOptions() throws {
        XCTAssertThrowsError(try AutomaticCLIArguments(arguments: [
            "insta360-mic-pro-capture", "watch",
        ]))

        let parsed = try AutomaticCLIArguments(arguments: [
            "insta360-mic-pro-capture",
            "watch",
            "--data-dir", "/tmp/activity",
            "--accepted-volume-name", "MIC PRO A",
            "--accepted-volume-name", "MIC PRO B",
            "--copy-policy", "selected",
            "--transcription-preference", "orig,processed",
            "--local-wav-policy", "move",
            "--device-wav-policy", "delete-after-publish",
            "--no-notify-copy-complete",
        ])
        guard case .watch(let options) = parsed.invocation else {
            return XCTFail("watch expected")
        }
        XCTAssertEqual(options.dataDirectory.path, "/tmp/activity")
        XCTAssertEqual(options.acceptedVolumeNames, ["MIC PRO A", "MIC PRO B"])
        XCTAssertEqual(options.copyPolicy, .selected)
        XCTAssertEqual(options.transcriptionPreference, [.orig, .processed])
        XCTAssertEqual(options.localWavPolicy, .move)
        XCTAssertEqual(options.deviceWavPolicy, .deleteAfterPublish)
        XCTAssertFalse(options.notifyWhenCopyCompletes)
    }

    func testLaunchAgentPlistStoresArgumentsWithoutShellExpansion() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(
            supportDirectory: root.appendingPathComponent("Application Support"),
            logsDirectory: root.appendingPathComponent("Logs"),
            launchAgentsDirectory: root.appendingPathComponent("LaunchAgents")
        )
        let options = RuntimeOptions(
            dataDirectory: root.appendingPathComponent("Activity Data"),
            acceptedVolumeNames: ["MIC PRO"],
            localWavPolicy: .move
        )
        let manager = LaunchAgentManager(paths: paths)
        let data = try manager.plistData(options: options)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let arguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])

        XCTAssertEqual(arguments[0], paths.installedExecutableURL.path)
        XCTAssertEqual(arguments[1], "watch")
        XCTAssertTrue(arguments.contains(options.dataDirectory.path))
        XCTAssertFalse(arguments.contains(where: { $0.contains("$HOME") || $0.contains("~") }))
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
    }

    func testTranscriptionSegmentationIsDeterministic() {
        let timings = [
            TokenTiming(token: "▁テスト", tokenId: 1, startTime: 0, endTime: 0.4, confidence: 1),
            TokenTiming(token: "です。", tokenId: 2, startTime: 0.4, endTime: 0.9, confidence: 1),
            TokenTiming(token: "<blank>", tokenId: 3, startTime: 1, endTime: 1.1, confidence: 1),
        ]
        XCTAssertEqual(
            TranscriptionService.makeSegments(from: timings),
            [TimedTranscriptSegment(startMs: 0, endMs: 900, text: "テストです。")]
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "insta360-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func testPaths(support: URL) -> ApplicationPaths {
        ApplicationPaths(
            supportDirectory: support,
            logsDirectory: support.appendingPathComponent("logs"),
            launchAgentsDirectory: support.appendingPathComponent("agents")
        )
    }
}

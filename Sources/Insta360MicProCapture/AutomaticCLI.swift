import Darwin
import Foundation
import Insta360Core

enum AutomaticInvocation: Equatable {
    case process(URL, RuntimeOptions)
    case importDirectory(URL, RuntimeOptions)
    case watch(RuntimeOptions)
    case status
    case retry(String)
    case agentInstall(RuntimeOptions)
    case agentStatus
    case agentUninstall
    case help
}

struct AutomaticCLIArguments {
    let invocation: AutomaticInvocation

    init(arguments: [String]) throws {
        guard arguments.count >= 2 else {
            invocation = .help
            return
        }
        let command = arguments[1]
        switch command {
        case "help", "--help", "-h":
            guard arguments.count == 2 else {
                throw Insta360Error.invalidArgument("helpに追加の引数は指定できません")
            }
            invocation = .help
        case "process":
            guard arguments.count >= 3 else {
                throw Insta360Error.invalidArgument("processにはWAVのパスが必要です")
            }
            let options = try Self.parseOptions(Array(arguments.dropFirst(3)))
            invocation = .process(Self.fileURL(arguments[2]), options)
        case "import":
            guard arguments.count >= 3 else {
                throw Insta360Error.invalidArgument("importにはディレクトリのパスが必要です")
            }
            let options = try Self.parseOptions(Array(arguments.dropFirst(3)))
            invocation = .importDirectory(Self.fileURL(arguments[2]), options)
        case "watch":
            invocation = .watch(try Self.parseOptions(Array(arguments.dropFirst(2))))
        case "status":
            guard arguments.count == 2 else {
                throw Insta360Error.invalidArgument("statusに追加の引数は指定できません")
            }
            invocation = .status
        case "retry":
            guard arguments.count == 3 else {
                throw Insta360Error.invalidArgument("usage: insta360-mic-pro-capture retry <job-id>")
            }
            invocation = .retry(arguments[2])
        case "agent":
            guard arguments.count >= 3 else {
                throw Insta360Error.invalidArgument("usage: insta360-mic-pro-capture agent <install|status|uninstall>")
            }
            switch arguments[2] {
            case "install":
                invocation = .agentInstall(
                    try Self.parseOptions(Array(arguments.dropFirst(3)))
                )
            case "status":
                guard arguments.count == 3 else {
                    throw Insta360Error.invalidArgument("agent statusに追加の引数は指定できません")
                }
                invocation = .agentStatus
            case "uninstall":
                guard arguments.count == 3 else {
                    throw Insta360Error.invalidArgument("agent uninstallに追加の引数は指定できません")
                }
                invocation = .agentUninstall
            default:
                throw Insta360Error.invalidArgument("不明なagent操作です: \(arguments[2])")
            }
        default:
            throw Insta360Error.invalidArgument("不明なコマンドです: \(command)")
        }
    }

    private static func parseOptions(_ arguments: [String]) throws -> RuntimeOptions {
        var dataDirectory: URL?
        var acceptedNames: [String] = []
        var copyPolicy: CopyPolicy = .all
        var preference: [AudioVariant] = [.processed, .orig]
        var localPolicy: LocalWavPolicy = .delete
        var devicePolicy: DeviceWavPolicy = .keep
        var notifyCopy = false
        var notifyProcessing = false
        var index = 0

        func value(after option: String) throws -> String {
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw Insta360Error.invalidArgument("\(option)には値が必要です")
            }
            return arguments[valueIndex]
        }

        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--data-dir":
                dataDirectory = fileURL(try value(after: option))
                index += 2
            case "--accepted-volume-name":
                let name = try value(after: option)
                guard !name.isEmpty else {
                    throw Insta360Error.invalidArgument("ボリューム名は空にできません")
                }
                acceptedNames.append(name)
                index += 2
            case "--copy-policy":
                let value = try value(after: option)
                guard let parsed = CopyPolicy(rawValue: value) else {
                    throw Insta360Error.invalidArgument("--copy-policyはallまたはselectedです: \(value)")
                }
                copyPolicy = parsed
                index += 2
            case "--transcription-preference":
                let value = try value(after: option)
                let parsed = value.split(separator: ",").compactMap {
                    AudioVariant(rawValue: String($0))
                }
                guard !parsed.isEmpty,
                      parsed.count == value.split(separator: ",").count,
                      Set(parsed).count == parsed.count
                else {
                    throw Insta360Error.invalidArgument(
                        "--transcription-preferenceはprocessed,origのように指定します: \(value)"
                    )
                }
                preference = parsed
                index += 2
            case "--local-wav-policy":
                let value = try value(after: option)
                guard let parsed = LocalWavPolicy(rawValue: value) else {
                    throw Insta360Error.invalidArgument("--local-wav-policyはdeleteまたはmoveです: \(value)")
                }
                localPolicy = parsed
                index += 2
            case "--device-wav-policy":
                let value = try value(after: option)
                guard let parsed = DeviceWavPolicy(rawValue: value) else {
                    throw Insta360Error.invalidArgument(
                        "--device-wav-policyはkeepまたはdelete-after-publishです: \(value)"
                    )
                }
                devicePolicy = parsed
                index += 2
            case "--notify":
                notifyCopy = true
                notifyProcessing = true
                index += 1
            default:
                throw Insta360Error.invalidArgument("不明なオプションです: \(option)")
            }
        }

        guard let dataDirectory else {
            throw Insta360Error.invalidArgument("--data-dirは必須です")
        }
        return RuntimeOptions(
            dataDirectory: dataDirectory,
            acceptedVolumeNames: acceptedNames.isEmpty ? ["MIC PRO"] : acceptedNames,
            copyPolicy: copyPolicy,
            transcriptionPreference: preference,
            localWavPolicy: localPolicy,
            deviceWavPolicy: devicePolicy,
            notifyWhenCopyCompletes: notifyCopy,
            notifyWhenProcessingCompletes: notifyProcessing
        )
    }

    private static func fileURL(_ path: String) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
}

enum AutomaticCLI {
    static func run(arguments: [String]) async throws {
        let parsed = try AutomaticCLIArguments(arguments: arguments)
        switch parsed.invocation {
        case .help:
            print(usage)
        case .process(let audioURL, let options):
            let job = try await JobRunner().processFile(audioURL, options: options)
            printJob(job)
        case .importDirectory(let sourceURL, let options):
            let runner = JobRunner(eventHandler: printEvent)
            let summary = try await runner.importDirectory(sourceURL, options: options)
            printSummary(summary)
        case .watch(let options):
            try await watch(options: options)
        case .status:
            let jobs = try await JobRunner().allJobs()
            if jobs.isEmpty {
                print("NO JOBS")
            } else {
                jobs.forEach(printJob)
            }
        case .retry(let id):
            let job = try await JobRunner().retry(id: id)
            printJob(job)
        case .agentInstall(let options):
            let manager = LaunchAgentManager()
            try manager.install(currentExecutable: executableURL(), options: options)
            print("INSTALLED \(LaunchAgentManager.label)")
            print("plist=\(ApplicationPaths().launchAgentPlistURL.path)")
        case .agentStatus:
            let status = LaunchAgentManager().status()
            print("\(status.installed ? "INSTALLED" : "NOT INSTALLED")  \(status.running ? "RUNNING" : "STOPPED")")
            if !status.programArguments.isEmpty {
                print("arguments=\(status.programArguments.joined(separator: " "))")
            }
        case .agentUninstall:
            try LaunchAgentManager().uninstall()
            print("UNINSTALLED \(LaunchAgentManager.label)")
        }
    }

    private static func watch(options: RuntimeOptions) async throws {
        let watcher = MountWatcher()
        let recognizer = VolumeRecognizer()
        let runner = JobRunner(eventHandler: printEvent)
        log("WATCHING  accepted=\(options.acceptedVolumeNames.joined(separator: ","))")
        for await volume in watcher.volumes() {
            guard recognizer.accepts(volume, acceptedNames: options.acceptedVolumeNames) else {
                continue
            }
            log("MOUNTED   \(volume.path)")
            do {
                let summary = try await runner.importDirectory(volume, options: options)
                printSummary(summary)
            } catch {
                fputs("FAILED    \(volume.path): \(error)\n", stderr)
                fflush(stderr)
            }
        }
    }

    private static func printEvent(_ event: JobRunnerEvent) {
        switch event {
        case .copyCompleted(let volumeName, let count):
            log("COPIED    count=\(count) volume=\(volumeName) safe-to-eject=true")
        case .jobCompleted(let job):
            printJob(job)
        case .failed(let id, let message):
            fputs("FAILED    \(id.prefix(8)) error=\(message)\n", stderr)
            fflush(stderr)
        }
    }

    private static func printSummary(_ summary: ImportSummary) {
        log(
            "IMPORT    discovered=\(summary.discoveredCount) copied=\(summary.copiedCount) "
                + "skipped=\(summary.skippedCount) completed=\(summary.completedJobIDs.count) "
                + "failed=\(summary.failedJobIDs.count)"
        )
    }

    private static func printJob(_ job: ProcessingJob) {
        let publication = job.publication.map {
            " -> \($0.relativePaths.joined(separator: ",")) (\($0.recordCount) records)"
        } ?? ""
        let error = job.lastError.map { " error=\($0.message)" } ?? ""
        log(
            "\(job.state.rawValue.uppercased())  \(job.shortID) \(job.recording.recordingID)"
                + publication + error
        )
        if job.state == .completed || job.cleanup.lastError != nil {
            let cleanupError = job.cleanup.lastError.map { " error=\($0)" } ?? ""
            log(
                "CLEANUP   local=\(job.cleanup.localWav.rawValue) "
                    + "device=\(job.cleanup.deviceWav.rawValue)\(cleanupError)"
            )
        }
    }

    private static func log(_ message: String) {
        print(message)
        fflush(stdout)
    }

    private static func executableURL() -> URL {
        let path = CommandLine.arguments[0]
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(path)
            .standardizedFileURL
    }

    static let usage = """
    usage:
      insta360-mic-pro-capture process <audio.wav> --data-dir <path> [options]
      insta360-mic-pro-capture import <directory> --data-dir <path> [options]
      insta360-mic-pro-capture watch --data-dir <path> [options]
      insta360-mic-pro-capture status
      insta360-mic-pro-capture retry <job-id>
      insta360-mic-pro-capture agent install --data-dir <path> [options]
      insta360-mic-pro-capture agent status
      insta360-mic-pro-capture agent uninstall

    options:
      --accepted-volume-name <name>       repeatable; default: MIC PRO
      --copy-policy <all|selected>        default: all
      --transcription-preference <list>   default: processed,orig
      --local-wav-policy <delete|move>    default: delete
      --device-wav-policy <keep|delete-after-publish>
      --notify                              enable macOS notifications; default: off
    """
}

@main
struct Insta360MicProCapture {
    static func main() async {
        do {
            try await AutomaticCLI.run(arguments: CommandLine.arguments)
        } catch {
            fputs("error: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }
}

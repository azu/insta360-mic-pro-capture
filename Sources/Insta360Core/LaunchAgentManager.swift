import Darwin
import Foundation

public struct LaunchAgentStatus: Sendable {
    public let installed: Bool
    public let running: Bool
    public let programArguments: [String]
    public let detail: String

    public init(installed: Bool, running: Bool, programArguments: [String], detail: String) {
        self.installed = installed
        self.running = running
        self.programArguments = programArguments
        self.detail = detail
    }
}

public struct LaunchAgentManager {
    public static let label = "com.github.azu.insta360-wav-to-text"

    private let paths: ApplicationPaths
    private let fileManager: FileManager

    public init(
        paths: ApplicationPaths = ApplicationPaths(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func install(currentExecutable: URL, options: RuntimeOptions) throws {
        try paths.createRuntimeDirectories(fileManager: fileManager)
        try fileManager.createDirectory(
            at: paths.binDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: paths.launchAgentsDirectory,
            withIntermediateDirectories: true
        )

        let source = currentExecutable.standardizedFileURL
        guard fileManager.isReadableFile(atPath: source.path) else {
            throw Insta360Error.launchAgent("実行ファイルを読み取れません: \(source.path)")
        }
        if source != paths.installedExecutableURL {
            let executableData = try Data(contentsOf: source)
            try executableData.write(to: paths.installedExecutableURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: paths.installedExecutableURL.path
            )
        }

        let data = try plistData(options: options)
        try data.write(to: paths.launchAgentPlistURL, options: .atomic)
        _ = try runLaunchctl([
            "bootout",
            domainTarget,
            paths.launchAgentPlistURL.path,
        ], allowFailure: true)
        _ = try runLaunchctl([
            "bootstrap",
            domainTarget,
            paths.launchAgentPlistURL.path,
        ])
        _ = try runLaunchctl([
            "kickstart",
            "-k",
            "\(domainTarget)/\(Self.label)",
        ])
    }

    public func uninstall() throws {
        _ = try runLaunchctl([
            "bootout",
            domainTarget,
            paths.launchAgentPlistURL.path,
        ], allowFailure: true)
        if fileManager.fileExists(atPath: paths.launchAgentPlistURL.path) {
            try fileManager.removeItem(at: paths.launchAgentPlistURL)
        }
        if fileManager.fileExists(atPath: paths.installedExecutableURL.path) {
            try fileManager.removeItem(at: paths.installedExecutableURL)
        }
    }

    public func status() -> LaunchAgentStatus {
        let installed = fileManager.fileExists(atPath: paths.launchAgentPlistURL.path)
        let dictionary = installed ? plistDictionary() : nil
        let arguments = dictionary?["ProgramArguments"] as? [String] ?? []
        let result = try? runLaunchctl([
            "print",
            "\(domainTarget)/\(Self.label)",
        ], allowFailure: true)
        let running = result?.status == 0
        return LaunchAgentStatus(
            installed: installed,
            running: running,
            programArguments: arguments,
            detail: result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    public func programArguments(options: RuntimeOptions) -> [String] {
        var arguments = [
            paths.installedExecutableURL.path,
            "watch",
            "--data-dir",
            options.dataDirectory.path,
        ]
        for name in options.acceptedVolumeNames {
            arguments += ["--accepted-volume-name", name]
        }
        arguments += [
            "--copy-policy", options.copyPolicy.rawValue,
            "--transcription-preference",
            options.transcriptionPreference.map(\.rawValue).joined(separator: ","),
            "--local-wav-policy", options.localWavPolicy.rawValue,
            "--device-wav-policy", options.deviceWavPolicy.rawValue,
        ]
        if !options.notifyWhenCopyCompletes {
            arguments.append("--no-notify-copy-complete")
        }
        if !options.notifyWhenProcessingCompletes {
            arguments.append("--no-notify-processing-complete")
        }
        return arguments
    }

    public func plistData(options: RuntimeOptions) throws -> Data {
        let dictionary: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": programArguments(options: options),
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardOutPath": paths.logFileURL.path,
            "StandardErrorPath": paths.logFileURL.path,
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .xml,
            options: 0
        )
    }

    private var domainTarget: String {
        "gui/\(getuid())"
    }

    private func plistDictionary() -> [String: Any]? {
        guard let data = try? Data(contentsOf: paths.launchAgentPlistURL),
              let value = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              )
        else { return nil }
        return value as? [String: Any]
    }

    private func runLaunchctl(
        _ arguments: [String],
        allowFailure: Bool = false
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let error = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        guard allowFailure || process.terminationStatus == 0 else {
            throw Insta360Error.launchAgent(
                ([output, error].joined(separator: " "))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return (process.terminationStatus, output + error)
    }
}

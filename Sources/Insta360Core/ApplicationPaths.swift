import Foundation

public struct ApplicationPaths: Sendable {
    public let supportDirectory: URL
    public let logsDirectory: URL
    public let launchAgentsDirectory: URL

    public init(
        supportDirectory: URL? = nil,
        logsDirectory: URL? = nil,
        launchAgentsDirectory: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.supportDirectory = (supportDirectory ?? homeDirectory
            .appendingPathComponent("Library/Application Support/Insta360MicProCapture", isDirectory: true))
            .standardizedFileURL
        self.logsDirectory = (logsDirectory ?? homeDirectory
            .appendingPathComponent("Library/Logs/Insta360MicProCapture", isDirectory: true))
            .standardizedFileURL
        self.launchAgentsDirectory = (launchAgentsDirectory ?? homeDirectory
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true))
            .standardizedFileURL
    }

    public var modelsDirectory: URL {
        supportDirectory.appendingPathComponent("models", isDirectory: true)
    }

    public var jobsDirectory: URL {
        supportDirectory.appendingPathComponent("jobs", isDirectory: true)
    }

    public var spoolDirectory: URL {
        supportDirectory.appendingPathComponent("spool", isDirectory: true)
    }

    public var binDirectory: URL {
        supportDirectory.appendingPathComponent("bin", isDirectory: true)
    }

    public var installedExecutableURL: URL {
        binDirectory.appendingPathComponent("insta360-mic-pro-capture", isDirectory: false)
    }

    public var logFileURL: URL {
        logsDirectory.appendingPathComponent("agent.log", isDirectory: false)
    }

    public var launchAgentPlistURL: URL {
        launchAgentsDirectory.appendingPathComponent(
            "com.github.azu.insta360-mic-pro-capture.plist",
            isDirectory: false
        )
    }

    public func createRuntimeDirectories(fileManager: FileManager = .default) throws {
        for directory in [supportDirectory, modelsDirectory, jobsDirectory, spoolDirectory, logsDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

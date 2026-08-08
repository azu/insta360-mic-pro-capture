import Foundation

public struct NotificationService: Sendable {
    public init() {}

    public func copyCompleted(volumeName: String, count: Int) {
        notify(
            title: "Insta360 Mic Pro",
            message: "\(count)件のコピー完了。\(volumeName)を取り外せます"
        )
    }

    public func processingCompleted(recordCount: Int, paths: [String]) {
        let destination = paths.first ?? "captures"
        notify(
            title: "Insta360 Mic Pro",
            message: "文字起こし完了: \(recordCount)件 → \(destination)"
        )
    }

    public func failed(_ message: String) {
        notify(
            title: "Insta360 Mic Pro: 処理失敗",
            message: "\(message)。statusで確認してください"
        )
    }

    private func notify(title: String, message: String) {
        let safeTitle = appleScriptEscaped(title)
        let safeMessage = appleScriptEscaped(message)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "display notification \"\(safeMessage)\" with title \"\(safeTitle)\"",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                fputs("notification-error: osascript status=\(process.terminationStatus)\n", stderr)
            }
        } catch {
            fputs("notification-error: \(error)\n", stderr)
        }
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

import AppKit
import Foundation

public struct VolumeRecognizer: Sendable {
    private let discovery = RecordingDiscovery()

    public init() {}

    public func accepts(_ volumeURL: URL, acceptedNames: [String]) -> Bool {
        guard acceptedNames.contains(where: {
            $0.compare(volumeURL.lastPathComponent, options: [.caseInsensitive]) == .orderedSame
        }) else {
            return false
        }
        let values = try? volumeURL.resourceValues(forKeys: [
            .volumeIsLocalKey,
            .volumeIsRemovableKey,
        ])
        if values?.volumeIsLocal == false || values?.volumeIsRemovable == false {
            return false
        }
        return discovery.containsSupportedWAV(in: volumeURL)
    }
}

private final class WorkspaceObserverToken: @unchecked Sendable {
    let value: NSObjectProtocol
    init(_ value: NSObjectProtocol) { self.value = value }
}

public struct MountWatcher: Sendable {
    public init() {}

    public func volumes() -> AsyncStream<URL> {
        AsyncStream { continuation in
            let center = NSWorkspace.shared.notificationCenter
            let token = WorkspaceObserverToken(center.addObserver(
                forName: NSWorkspace.didMountNotification,
                object: nil,
                queue: .main
            ) { notification in
                if let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                    continuation.yield(url.standardizedFileURL)
                }
            })

            let initial = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: [
                    .volumeNameKey,
                    .volumeIsLocalKey,
                    .volumeIsRemovableKey,
                ],
                options: [.skipHiddenVolumes]
            ) ?? []
            for volume in initial {
                continuation.yield(volume.standardizedFileURL)
            }
            continuation.onTermination = { _ in
                center.removeObserver(token.value)
            }
        }
    }
}

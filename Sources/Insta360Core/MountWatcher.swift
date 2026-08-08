import AppKit
import Foundation

public struct VolumeRecognizer: Sendable {
    private let discovery = RecordingDiscovery()

    public init() {}

    public func matchesName(_ volumeURL: URL, acceptedNames: [String]) -> Bool {
        acceptedNames.contains(where: {
            $0.compare(volumeURL.lastPathComponent, options: [.caseInsensitive]) == .orderedSame
        })
    }

    public func accepts(_ volumeURL: URL, acceptedNames: [String]) -> Bool {
        guard matchesName(volumeURL, acceptedNames: acceptedNames) else {
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

public enum MountWatcherEvent: Sendable {
    case mounted(URL)
    case unmounted(URL)
}

private final class WorkspaceObserverToken: @unchecked Sendable {
    let value: NSObjectProtocol
    init(_ value: NSObjectProtocol) { self.value = value }
}

public struct MountWatcher: Sendable {
    public init() {}

    public func volumes(
        eventHandler: @escaping @Sendable (MountWatcherEvent) -> Void = { _ in }
    ) -> AsyncStream<URL> {
        AsyncStream { continuation in
            let center = NSWorkspace.shared.notificationCenter
            let mountToken = WorkspaceObserverToken(center.addObserver(
                forName: NSWorkspace.didMountNotification,
                object: nil,
                queue: .main
            ) { notification in
                if let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                    let volume = url.standardizedFileURL
                    eventHandler(.mounted(volume))
                    continuation.yield(volume)
                }
            })
            let unmountToken = WorkspaceObserverToken(center.addObserver(
                forName: NSWorkspace.didUnmountNotification,
                object: nil,
                queue: .main
            ) { notification in
                if let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                    eventHandler(.unmounted(url.standardizedFileURL))
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
                let standardizedVolume = volume.standardizedFileURL
                eventHandler(.mounted(standardizedVolume))
                continuation.yield(standardizedVolume)
            }
            continuation.onTermination = { _ in
                center.removeObserver(mountToken.value)
                center.removeObserver(unmountToken.value)
            }
        }
    }
}

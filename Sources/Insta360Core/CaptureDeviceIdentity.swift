import Foundation

public struct CaptureDeviceIdentity: Sendable, Equatable {
    public static let generic = CaptureDeviceIdentity(
        shortID: nil,
        recordDeviceName: "Insta360 Mic Pro",
        captureFileDeviceName: "insta360-mic-pro"
    )

    public let shortID: String?
    public let recordDeviceName: String
    public let captureFileDeviceName: String

    public var audioDirectoryName: String {
        captureFileDeviceName
    }

    public init(
        sourceVolumeName: String,
        sourceVolumeUUID: String?,
        acceptedVolumeNames: [String]
    ) {
        let isAcceptedVolume = acceptedVolumeNames.contains {
            $0.compare(sourceVolumeName, options: [.caseInsensitive]) == .orderedSame
        }
        guard isAcceptedVolume,
              let sourceVolumeUUID,
              let uuid = UUID(uuidString: sourceVolumeUUID)
        else {
            self = .generic
            return
        }

        let shortID = String(uuid.uuidString.prefix(8)).lowercased()
        self.init(
            shortID: shortID,
            recordDeviceName: "Insta360 Mic Pro \(shortID)",
            captureFileDeviceName: "insta360-mic-pro-\(shortID)"
        )
    }

    private init(
        shortID: String?,
        recordDeviceName: String,
        captureFileDeviceName: String
    ) {
        self.shortID = shortID
        self.recordDeviceName = recordDeviceName
        self.captureFileDeviceName = captureFileDeviceName
    }
}

import Foundation

public enum CopyPolicy: String, Codable, Sendable, CaseIterable {
    case all
    case selected
}

public enum AudioVariant: String, Codable, Sendable, CaseIterable {
    case processed
    case orig
}

public enum LocalWavPolicy: String, Codable, Sendable, CaseIterable {
    case delete
    case move
}

public enum DeviceWavPolicy: String, Codable, Sendable, CaseIterable {
    case keep
    case deleteAfterPublish = "delete-after-publish"
}

public struct RuntimeOptions: Codable, Sendable, Equatable {
    public let dataDirectory: URL
    public let acceptedVolumeNames: [String]
    public let copyPolicy: CopyPolicy
    public let transcriptionPreference: [AudioVariant]
    public let localWavPolicy: LocalWavPolicy
    public let deviceWavPolicy: DeviceWavPolicy
    public let notifyWhenCopyCompletes: Bool
    public let notifyWhenProcessingCompletes: Bool

    public init(
        dataDirectory: URL,
        acceptedVolumeNames: [String] = ["MIC PRO"],
        copyPolicy: CopyPolicy = .all,
        transcriptionPreference: [AudioVariant] = [.processed, .orig],
        localWavPolicy: LocalWavPolicy = .delete,
        deviceWavPolicy: DeviceWavPolicy = .keep,
        notifyWhenCopyCompletes: Bool = true,
        notifyWhenProcessingCompletes: Bool = true
    ) {
        self.dataDirectory = dataDirectory.standardizedFileURL
        self.acceptedVolumeNames = acceptedVolumeNames
        self.copyPolicy = copyPolicy
        self.transcriptionPreference = transcriptionPreference
        self.localWavPolicy = localWavPolicy
        self.deviceWavPolicy = deviceWavPolicy
        self.notifyWhenCopyCompletes = notifyWhenCopyCompletes
        self.notifyWhenProcessingCompletes = notifyWhenProcessingCompletes
    }
}

public enum Insta360Error: Error, CustomStringConvertible, Sendable {
    case invalidArgument(String)
    case invalidFilename(String)
    case invalidSource(String)
    case noRecordings(String)
    case noTimedTokens
    case insufficientFreeSpace(required: Int64, available: Int64)
    case sourceChanged(String)
    case invalidNDJSON(path: String, line: Int)
    case verificationFailed(String)
    case jobNotFound(String)
    case retryUnavailable(String)
    case launchAgent(String)

    public var description: String {
        switch self {
        case .invalidArgument(let message):
            return message
        case .invalidFilename(let filename):
            return "録音開始時刻をファイル名から取得できません: \(filename)"
        case .invalidSource(let path):
            return "取り込み元を読み取れません: \(path)"
        case .noRecordings(let path):
            return "対象のWAVが見つかりません: \(path)"
        case .noTimedTokens:
            return "文字起こし結果にタイムスタンプ付きトークンがありません"
        case .insufficientFreeSpace(let required, let available):
            return "コピー先の空き容量が不足しています: required=\(required), available=\(available)"
        case .sourceChanged(let path):
            return "コピー中に元ファイルが変更されました: \(path)"
        case .invalidNDJSON(let path, let line):
            return "NDJSONに壊れた行があります: \(path):\(line)"
        case .verificationFailed(let message):
            return "保存結果を検証できません: \(message)"
        case .jobNotFound(let id):
            return "ジョブが見つかりません: \(id)"
        case .retryUnavailable(let message):
            return "ジョブを再開できません: \(message)"
        case .launchAgent(let message):
            return "LaunchAgentの操作に失敗しました: \(message)"
        }
    }
}

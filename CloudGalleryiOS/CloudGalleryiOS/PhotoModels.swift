import Foundation

enum PhotoType: String, Codable, CaseIterable, Identifiable {
    case manualBackup = "manual_backup"
    case cloudSync = "cloud_sync"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manualBackup: "Manual"
        case .cloudSync: "Sync"
        }
    }
}

struct LocalPhotoRecord: Codable, Identifiable, Hashable {
    var id: String { localId }

    let localId: String
    var remoteId: String?
    var photoType: PhotoType
    var fileName: String
    var createdAt: Date
}

struct RemotePhotoRecord: Codable, Identifiable, Hashable {
    var id: String { remoteId }

    let remoteId: String
    var photoType: PhotoType
    var fileName: String?
    var fileSize: Int64?
    var uploadedAt: Date
    var thumbnailCached: Bool
    var messageId: Int?
    var uploadType: String?
}

struct GalleryBackup: Codable {
    var photos: [LocalPhotoRecord]
    var remotePhotos: [RemotePhotoRecord]
}

struct TelegramCredentials: Equatable {
    var botToken: String
    var chatId: String

    var isComplete: Bool {
        !botToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !chatId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

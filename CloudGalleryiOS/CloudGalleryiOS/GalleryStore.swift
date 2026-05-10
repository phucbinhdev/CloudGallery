import CryptoKit
import Foundation
import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class GalleryStore: ObservableObject {
    @Published var credentials: TelegramCredentials
    @Published private(set) var localPhotos: [LocalPhotoRecord] = []
    @Published private(set) var remotePhotos: [RemotePhotoRecord] = []
    @Published private(set) var cachedRemoteImages: [String: UIImage] = [:]
    @Published var selectedItems: [PhotosPickerItem] = []
    @Published var isBusy = false
    @Published var statusMessage: String?

    private let backupURL: URL
    private let cacheDirectory: URL

    init() {
        credentials = TelegramCredentials(
            botToken: KeychainStore.string(for: "telegram_bot_token"),
            chatId: KeychainStore.string(for: "telegram_chat_id")
        )

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        backupURL = support.appendingPathComponent("CloudGalleryBackup.json")
        cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemotePhotos", isDirectory: true)

        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        loadBackup()
    }

    var telegramService: TelegramService {
        TelegramService(credentials: credentials)
    }

    func saveCredentials(botToken: String, chatId: String) async {
        do {
            let cleaned = TelegramCredentials(
                botToken: botToken.trimmingCharacters(in: .whitespacesAndNewlines),
                chatId: chatId.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            try KeychainStore.set(cleaned.botToken, for: "telegram_bot_token")
            try KeychainStore.set(cleaned.chatId, for: "telegram_chat_id")
            credentials = cleaned
            try await telegramService.validateChat()
            statusMessage = "Telegram chat validated."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func uploadSelectedPhotos() async {
        guard !selectedItems.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }

        var uploadedCount = 0
        var skippedDuplicateCount = 0
        for item in selectedItems {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    continue
                }

                let contentHash = data.sha256Hex
                if hasUploadedPhoto(hash: contentHash) {
                    skippedDuplicateCount += 1
                    continue
                }

                let fileName = "cloudgallery-\(UUID().uuidString).jpg"
                var remote = try await telegramService.uploadImage(
                    image,
                    fileName: fileName,
                    caption: "CloudGallery iOS backup"
                )
                remote.contentHash = contentHash

                let local = LocalPhotoRecord(
                    localId: UUID().uuidString,
                    remoteId: remote.remoteId,
                    photoType: .manualBackup,
                    fileName: fileName,
                    createdAt: Date(),
                    contentHash: contentHash
                )
                localPhotos.insert(local, at: 0)
                upsert(remote)
                cachedRemoteImages[remote.remoteId] = image
                try? writeCacheImage(image, remoteId: remote.remoteId)
                uploadedCount += 1
            } catch {
                statusMessage = error.localizedDescription
            }
        }

        selectedItems.removeAll()
        persistBackup()
        if uploadedCount > 0 || skippedDuplicateCount > 0 {
            statusMessage = uploadSummary(uploaded: uploadedCount, skipped: skippedDuplicateCount)
        }
    }

    func download(_ remote: RemotePhotoRecord) async {
        if cachedRemoteImages[remote.remoteId] != nil {
            return
        }

        if let image = readCacheImage(remoteId: remote.remoteId) {
            cachedRemoteImages[remote.remoteId] = image
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let data = try await telegramService.downloadFile(fileId: remote.remoteId)
            guard let image = UIImage(data: data) else {
                statusMessage = "Downloaded file is not a supported image."
                return
            }
            cachedRemoteImages[remote.remoteId] = image
            try? writeCacheImage(image, remoteId: remote.remoteId)
            markThumbnailCached(remote.remoteId)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func exportBackup() -> URL? {
        persistBackup()
        return FileManager.default.fileExists(atPath: backupURL.path) ? backupURL : nil
    }

    func importBackup(from url: URL) {
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer {
                if access { url.stopAccessingSecurityScopedResource() }
            }

            let data = try Data(contentsOf: url)
            let backup = try JSONDecoder.gallery.decode(GalleryBackup.self, from: data)
            localPhotos = backup.photos.sorted { $0.createdAt > $1.createdAt }
            remotePhotos = backup.remotePhotos.sorted { $0.uploadedAt > $1.uploadedAt }
            persistBackup()
            statusMessage = "Imported \(remotePhotos.count) remote records."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteMetadata(for remote: RemotePhotoRecord) {
        remotePhotos.removeAll { $0.remoteId == remote.remoteId }
        localPhotos.removeAll { $0.remoteId == remote.remoteId }
        cachedRemoteImages.removeValue(forKey: remote.remoteId)
        try? FileManager.default.removeItem(at: cacheURL(remote.remoteId))
        persistBackup()
    }

    private func upsert(_ remote: RemotePhotoRecord) {
        if let index = remotePhotos.firstIndex(where: { $0.remoteId == remote.remoteId }) {
            remotePhotos[index] = remote
        } else {
            remotePhotos.insert(remote, at: 0)
        }
    }

    private func hasUploadedPhoto(hash: String) -> Bool {
        localPhotos.contains { $0.contentHash == hash } ||
        remotePhotos.contains { $0.contentHash == hash }
    }

    private func uploadSummary(uploaded: Int, skipped: Int) -> String {
        var parts: [String] = []
        if uploaded > 0 {
            parts.append("Uploaded \(uploaded) photo\(uploaded == 1 ? "" : "s")")
        }
        if skipped > 0 {
            parts.append("Skipped \(skipped) duplicate\(skipped == 1 ? "" : "s")")
        }
        return parts.joined(separator: ". ") + "."
    }

    private func markThumbnailCached(_ remoteId: String) {
        guard let index = remotePhotos.firstIndex(where: { $0.remoteId == remoteId }) else {
            return
        }
        remotePhotos[index].thumbnailCached = true
        persistBackup()
    }

    private func loadBackup() {
        do {
            guard FileManager.default.fileExists(atPath: backupURL.path) else { return }
            let data = try Data(contentsOf: backupURL)
            let backup = try JSONDecoder.gallery.decode(GalleryBackup.self, from: data)
            localPhotos = backup.photos.sorted { $0.createdAt > $1.createdAt }
            remotePhotos = backup.remotePhotos.sorted { $0.uploadedAt > $1.uploadedAt }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func persistBackup() {
        do {
            let backup = GalleryBackup(photos: localPhotos, remotePhotos: remotePhotos)
            let data = try JSONEncoder.gallery.encode(backup)
            try data.write(to: backupURL, options: [.atomic])
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func cacheURL(_ remoteId: String) -> URL {
        cacheDirectory.appendingPathComponent(remoteId.safeFileName).appendingPathExtension("jpg")
    }

    private func readCacheImage(remoteId: String) -> UIImage? {
        UIImage(contentsOfFile: cacheURL(remoteId).path)
    }

    private func writeCacheImage(_ image: UIImage, remoteId: String) throws {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        try data.write(to: cacheURL(remoteId), options: [.atomic])
    }
}

private extension JSONEncoder {
    static var gallery: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var gallery: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension String {
    var safeFileName: String {
        components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}

private extension Data {
    var sha256Hex: String {
        SHA256.hash(data: self)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

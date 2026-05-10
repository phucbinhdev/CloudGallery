import CryptoKit
import Foundation
import Photos
import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class GalleryStore: ObservableObject {
    @Published var credentials: TelegramCredentials
    @Published private(set) var localPhotos: [LocalPhotoRecord] = []
    @Published private(set) var remotePhotos: [RemotePhotoRecord] = []
    @Published private(set) var devicePhotos: [DevicePhotoAsset] = []
    @Published private(set) var syncedDeviceAssetIDs: Set<String> = []
    @Published private(set) var cachedRemoteImages: [String: UIImage] = [:]
    @Published var selectedItems: [PhotosPickerItem] = []
    @Published var isBusy = false
    @Published var syncProgress: String?
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
                    contentHash: contentHash,
                    assetLocalIdentifier: nil
                )
                localPhotos.insert(local, at: 0)
                refreshSyncIndex()
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

    func loadDevicePhotos() async {
        let status = await requestPhotoLibraryAccess()
        guard status == .authorized || status == .limited else {
            statusMessage = "Allow Photos access to show device photos."
            return
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var loaded: [DevicePhotoAsset] = []
        loaded.reserveCapacity(assets.count)

        assets.enumerateObjects { asset, _, _ in
            loaded.append(
                    DevicePhotoAsset(
                        id: asset.localIdentifier,
                        creationDate: asset.creationDate,
                    mediaSubtypes: Int(asset.mediaSubtypes.rawValue)
                )
            )
        }

        devicePhotos = loaded
    }

    func isSynced(_ asset: DevicePhotoAsset) -> Bool {
        syncedDeviceAssetIDs.contains(asset.id)
    }

    func syncUnsyncedDevicePhotos() async {
        guard credentials.isComplete else {
            statusMessage = "Add your Telegram bot token and chat ID in Settings first."
            return
        }

        if devicePhotos.isEmpty {
            await loadDevicePhotos()
        }

        let unsynced = devicePhotos.filter { !isSynced($0) }
        guard !unsynced.isEmpty else {
            statusMessage = "All device photos are already synced."
            return
        }

        isBusy = true
        defer {
            isBusy = false
            syncProgress = nil
        }

        var uploadedCount = 0
        var skippedDuplicateCount = 0
        var failedCount = 0

        for (index, item) in unsynced.enumerated() {
            syncProgress = "\(index + 1)/\(unsynced.count)"

            do {
                guard let asset = fetchAsset(localIdentifier: item.id) else {
                    failedCount += 1
                    continue
                }

                let payload = try await imagePayload(for: asset)
                if hasUploadedPhoto(hash: payload.contentHash) {
                    recordLocalDuplicate(asset: asset, payload: payload)
                    skippedDuplicateCount += 1
                    continue
                }

                var remote = try await telegramService.uploadImageData(
                    payload.data,
                    fileName: payload.fileName,
                    mimeType: payload.mimeType,
                    caption: "CloudGallery iOS auto sync",
                    photoType: .cloudSync
                )
                remote.contentHash = payload.contentHash

                let local = LocalPhotoRecord(
                    localId: UUID().uuidString,
                    remoteId: remote.remoteId,
                    photoType: .cloudSync,
                    fileName: payload.fileName,
                    createdAt: asset.creationDate ?? Date(),
                    contentHash: payload.contentHash,
                    assetLocalIdentifier: asset.localIdentifier
                )

                localPhotos.insert(local, at: 0)
                refreshSyncIndex()
                upsert(remote)
                if let image = UIImage(data: payload.data) {
                    cachedRemoteImages[remote.remoteId] = image
                    try? writeCacheImage(image, remoteId: remote.remoteId)
                }
                uploadedCount += 1
                persistBackup()
            } catch {
                failedCount += 1
                statusMessage = error.localizedDescription
            }
        }

        await loadDevicePhotos()
        statusMessage = syncSummary(uploaded: uploadedCount, skipped: skippedDuplicateCount, failed: failedCount)
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
            refreshSyncIndex()
            persistBackup()
            statusMessage = "Imported \(remotePhotos.count) remote records."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteMetadata(for remote: RemotePhotoRecord) {
        remotePhotos.removeAll { $0.remoteId == remote.remoteId }
        localPhotos.removeAll { $0.remoteId == remote.remoteId }
        refreshSyncIndex()
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

    private func recordLocalDuplicate(asset: PHAsset, payload: PhotoAssetPayload) {
        guard !localPhotos.contains(where: { $0.assetLocalIdentifier == asset.localIdentifier }) else {
            return
        }

        let remoteId = remotePhotos.first { $0.contentHash == payload.contentHash }?.remoteId ??
        localPhotos.first { $0.contentHash == payload.contentHash }?.remoteId

        let local = LocalPhotoRecord(
            localId: UUID().uuidString,
            remoteId: remoteId,
            photoType: .cloudSync,
            fileName: payload.fileName,
            createdAt: asset.creationDate ?? Date(),
            contentHash: payload.contentHash,
            assetLocalIdentifier: asset.localIdentifier
        )
        localPhotos.insert(local, at: 0)
        refreshSyncIndex()
        persistBackup()
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

    private func syncSummary(uploaded: Int, skipped: Int, failed: Int) -> String {
        var parts: [String] = []
        if uploaded > 0 {
            parts.append("Uploaded \(uploaded)")
        }
        if skipped > 0 {
            parts.append("Skipped \(skipped) duplicate\(skipped == 1 ? "" : "s")")
        }
        if failed > 0 {
            parts.append("Failed \(failed)")
        }
        return parts.isEmpty ? "No photos synced." : parts.joined(separator: ". ") + "."
    }

    private func requestPhotoLibraryAccess() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .notDetermined {
            return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        return current
    }

    private func fetchAsset(localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    private func imagePayload(for asset: PHAsset) async throws -> PhotoAssetPayload {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false
            options.version = .current

            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, dataUTI, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data else {
                    continuation.resume(throwing: GalleryError.missingPhotoData)
                    return
                }

                let mimeType = dataUTI.flatMap(Self.mimeType(for:)) ?? "image/jpeg"
                let fileExtension = Self.fileExtension(for: mimeType)
                let fileName = "cloudgallery-\(asset.localIdentifier.safeFileName).\(fileExtension)"
                continuation.resume(
                    returning: PhotoAssetPayload(
                        data: data,
                        fileName: fileName,
                        mimeType: mimeType,
                        contentHash: data.sha256Hex
                    )
                )
            }
        }
    }

    private static func mimeType(for typeIdentifier: String) -> String? {
        switch typeIdentifier.lowercased() {
        case "public.heic", "public.heif":
            "image/heic"
        case "public.png":
            "image/png"
        case "public.jpeg", "public.jpg":
            "image/jpeg"
        default:
            nil
        }
    }

    private static func fileExtension(for mimeType: String) -> String {
        switch mimeType {
        case "image/heic":
            "heic"
        case "image/png":
            "png"
        default:
            "jpg"
        }
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
            refreshSyncIndex()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func refreshSyncIndex() {
        syncedDeviceAssetIDs = Set(localPhotos.compactMap(\.assetLocalIdentifier))
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

private struct PhotoAssetPayload {
    var data: Data
    var fileName: String
    var mimeType: String
    var contentHash: String
}

private enum GalleryError: LocalizedError {
    case missingPhotoData

    var errorDescription: String? {
        switch self {
        case .missingPhotoData:
            "Could not read the selected photo from the device library."
        }
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

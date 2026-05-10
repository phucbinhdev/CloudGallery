import Foundation
import UIKit

struct TelegramService {
    var credentials: TelegramCredentials

    func validateChat() async throws {
        guard credentials.isComplete else {
            throw TelegramError.missingCredentials
        }

        let url = try endpoint("getChat", queryItems: [
            URLQueryItem(name: "chat_id", value: credentials.chatId)
        ])

        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(TelegramEnvelope<TelegramChat>.self, from: data)
        guard response.ok, response.result?.id.description == credentials.chatId else {
            throw TelegramError.api(response.description ?? "Unable to validate chat.")
        }
    }

    func uploadImage(_ image: UIImage, fileName: String, caption: String?) async throws -> RemotePhotoRecord {
        guard credentials.isComplete else {
            throw TelegramError.missingCredentials
        }
        guard let imageData = image.jpegData(compressionQuality: 0.96) else {
            throw TelegramError.imageEncodingFailed
        }

        var request = URLRequest(url: try endpoint("sendDocument"))
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = MultipartFormData(boundary: boundary)
            .appendField(named: "chat_id", value: credentials.chatId)
            .appendField(named: "disable_content_type_detection", value: "false")
            .appendOptionalField(named: "caption", value: caption)
            .appendFile(named: "document", fileName: fileName, mimeType: "image/jpeg", data: imageData)
            .finalize()

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(TelegramEnvelope<TelegramMessage>.self, from: data)
        guard response.ok, let document = response.result?.document else {
            throw TelegramError.api(response.description ?? "Telegram upload failed.")
        }

        return RemotePhotoRecord(
            remoteId: document.fileID,
            photoType: .manualBackup,
            fileName: document.fileName ?? fileName,
            fileSize: document.fileSize,
            uploadedAt: Date(),
            thumbnailCached: false,
            messageId: response.result?.messageID,
            uploadType: PhotoType.manualBackup.rawValue
        )
    }

    func downloadFile(fileId: String) async throws -> Data {
        let fileURL = try endpoint("getFile", queryItems: [
            URLQueryItem(name: "file_id", value: fileId)
        ])
        let (metadata, _) = try await URLSession.shared.data(from: fileURL)
        let response = try JSONDecoder().decode(TelegramEnvelope<TelegramFile>.self, from: metadata)
        guard response.ok, let path = response.result?.filePath else {
            throw TelegramError.api(response.description ?? "Unable to resolve file path.")
        }

        let downloadURL = URL(string: "https://api.telegram.org/file/bot\(credentials.botToken)/\(path)")!
        let (data, _) = try await URLSession.shared.data(from: downloadURL)
        return data
    }

    private func endpoint(_ method: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard credentials.isComplete else {
            throw TelegramError.missingCredentials
        }

        var components = URLComponents(string: "https://api.telegram.org/bot\(credentials.botToken)/\(method)")!
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url!
    }
}

enum TelegramError: LocalizedError {
    case missingCredentials
    case imageEncodingFailed
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Add your Telegram bot token and chat ID in Settings first."
        case .imageEncodingFailed:
            "The selected image could not be encoded for upload."
        case .api(let message):
            message
        }
    }
}

private struct TelegramEnvelope<T: Decodable>: Decodable {
    var ok: Bool
    var result: T?
    var description: String?
}

private struct TelegramChat: Decodable {
    var id: Int64
}

private struct TelegramMessage: Decodable {
    var messageID: Int?
    var document: TelegramDocument?

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case document
    }
}

private struct TelegramDocument: Decodable {
    var fileID: String
    var fileName: String?
    var fileSize: Int64?

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileName = "file_name"
        case fileSize = "file_size"
    }
}

private struct TelegramFile: Decodable {
    var filePath: String?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
    }
}

private struct MultipartFormData {
    let boundary: String
    private var data = Data()

    init(boundary: String) {
        self.boundary = boundary
    }

    func appendField(named name: String, value: String) -> MultipartFormData {
        var copy = self
        copy.data.append("--\(boundary)\r\n")
        copy.data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        copy.data.append("\(value)\r\n")
        return copy
    }

    func appendOptionalField(named name: String, value: String?) -> MultipartFormData {
        guard let value, !value.isEmpty else { return self }
        return appendField(named: name, value: value)
    }

    func appendFile(named name: String, fileName: String, mimeType: String, data fileData: Data) -> MultipartFormData {
        var copy = self
        copy.data.append("--\(boundary)\r\n")
        copy.data.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n")
        copy.data.append("Content-Type: \(mimeType)\r\n\r\n")
        copy.data.append(fileData)
        copy.data.append("\r\n")
        return copy
    }

    func finalize() -> Data {
        var copy = data
        copy.append("--\(boundary)--\r\n")
        return copy
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}

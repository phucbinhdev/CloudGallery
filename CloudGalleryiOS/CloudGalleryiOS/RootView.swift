import Photos
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: GalleryStore
    @State private var tab: AppTab = .device

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                DeviceGalleryView()
            }
            .tabItem { Label("Device", systemImage: "iphone") }
            .tag(AppTab.device)

            NavigationStack {
                CloudGalleryView()
            }
            .tabItem { Label("Cloud", systemImage: "cloud") }
            .tag(AppTab.cloud)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(AppTab.settings)
        }
        .overlay(alignment: .bottom) {
            if store.isBusy {
                ProgressView()
                    .padding(14)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 58)
            }
        }
        .alert("CloudGallery", isPresented: Binding(
            get: { store.statusMessage != nil },
            set: { if !$0 { store.statusMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.statusMessage = nil }
        } message: {
            Text(store.statusMessage ?? "")
        }
    }
}

private enum AppTab {
    case device
    case cloud
    case settings
}

struct DeviceGalleryView: View {
    @EnvironmentObject private var store: GalleryStore

    private let columns = [
        GridItem(.adaptive(minimum: 110), spacing: 3)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(store.devicePhotos) { photo in
                        DevicePhotoTile(photo: photo, isSynced: store.syncedDeviceAssetIDs.contains(photo.id))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .navigationTitle("Device")
        .task {
            await store.loadDevicePhotos()
        }
        .toolbar {
            Button {
                Task { await store.loadDevicePhotos() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(store.isBusy)

            Button {
                Task { await store.syncUnsyncedDevicePhotos() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.icloud")
            }
            .disabled(store.devicePhotos.isEmpty || store.isBusy)
        }
    }

    @ViewBuilder
    private var header: some View {
        let syncedCount = store.devicePhotos.filter { store.syncedDeviceAssetIDs.contains($0.id) }.count
        let unsyncedCount = max(store.devicePhotos.count - syncedCount, 0)

        VStack(alignment: .leading, spacing: 10) {
            Text("\(store.devicePhotos.count) device photos")
                .font(.title2.bold())
            Text("\(syncedCount) synced. \(unsyncedCount) waiting.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let progress = store.syncProgress {
                Label("Syncing \(progress)", systemImage: "arrow.triangle.2.circlepath.icloud")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.blue)
            }
            if !store.credentials.isComplete {
                Label("Add Telegram credentials in Settings before uploading.", systemImage: "exclamationmark.triangle")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DevicePhotoTile: View {
    let photo: DevicePhotoAsset
    let isSynced: Bool
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()

            Image(systemName: isSynced ? "checkmark.icloud.fill" : "icloud.slash.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isSynced ? .green : .secondary)
                .padding(6)
                .background(.thinMaterial, in: Circle())
                .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: photo.id) {
            thumbnail = await loadThumbnail(localIdentifier: photo.id)
        }
    }

    private func loadThumbnail(localIdentifier: String) async -> UIImage? {
        await withCheckedContinuation { continuation in
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
                continuation.resume(returning: nil)
                return
            }

            var didResume = false
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 260, height: 260),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: image)
            }
        }
    }
}

struct CloudGalleryView: View {
    @EnvironmentObject private var store: GalleryStore

    private let columns = [
        GridItem(.adaptive(minimum: 116), spacing: 4)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(store.remotePhotos) { photo in
                    RemotePhotoTile(photo: photo)
                }
            }
            .padding(16)
        }
        .overlay {
            if store.remotePhotos.isEmpty {
                ContentUnavailableView(
                    "No cloud photos",
                    systemImage: "cloud",
                    description: Text("Uploaded photos and imported metadata appear here.")
                )
            }
        }
        .navigationTitle("Cloud")
    }
}

private struct RemotePhotoTile: View {
    @EnvironmentObject private var store: GalleryStore
    let photo: RemotePhotoRecord

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = store.cachedRemoteImages[photo.remoteId] {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "icloud.and.arrow.down")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()

            Menu {
                Button("Download Preview") {
                    Task { await store.download(photo) }
                }
                Button("Remove Metadata", role: .destructive) {
                    store.deleteMetadata(for: photo)
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.title2)
                    .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task {
            if photo.thumbnailCached {
                await store.download(photo)
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: GalleryStore
    @State private var botToken = ""
    @State private var chatId = ""
    @State private var importing = false
    @State private var exportedBackup: ExportedBackup?

    var body: some View {
        Form {
            Section("Telegram") {
                SecureField("Bot token", text: $botToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Chat ID", text: $chatId)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save and Validate") {
                    Task { await store.saveCredentials(botToken: botToken, chatId: chatId) }
                }
                .disabled(botToken.isEmpty || chatId.isEmpty || store.isBusy)
            }

            Section("Database") {
                LabeledContent("Device records", value: "\(store.localPhotos.count)")
                LabeledContent("Cloud records", value: "\(store.remotePhotos.count)")

                Button("Export JSON Backup") {
                    exportedBackup = store.exportBackup().map(ExportedBackup.init(url:))
                }
                Button("Import JSON Backup") {
                    importing = true
                }
            }

            Section("About") {
                Text("Native SwiftUI conversion of AKS-Labs CloudGallery. It keeps the original privacy model: credentials stay in Keychain, metadata stays local, and media goes directly to Telegram Bot API.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            botToken = store.credentials.botToken
            chatId = store.credentials.chatId
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result {
                store.importBackup(from: url)
            }
        }
        .sheet(item: $exportedBackup) { backup in
            ShareSheet(items: [backup.url])
                .presentationDetents([.medium])
        }
    }
}

struct ExportedBackup: Identifiable {
    let url: URL

    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

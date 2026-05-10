import PhotosUI
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
                    ForEach(store.localPhotos) { photo in
                        LocalPhotoTile(photo: photo)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .navigationTitle("Device")
        .toolbar {
            PhotosPicker(
                selection: $store.selectedItems,
                maxSelectionCount: 0,
                matching: .images
            ) {
                Image(systemName: "plus")
            }
            .disabled(store.isBusy)

            Button {
                Task { await store.uploadSelectedPhotos() }
            } label: {
                Image(systemName: "icloud.and.arrow.up")
            }
            .disabled(store.selectedItems.isEmpty || store.isBusy)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(store.localPhotos.count) backed up")
                .font(.title2.bold())
            Text("Pick images from Photos, then upload them as Telegram documents so Telegram does not compress them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !store.credentials.isComplete {
                Label("Add Telegram credentials in Settings before uploading.", systemImage: "exclamationmark.triangle")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LocalPhotoTile: View {
    let photo: LocalPhotoRecord

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: photo.remoteId == nil ? "photo" : "checkmark.icloud")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }

            Text(photo.fileName)
                .font(.caption2)
                .lineLimit(1)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
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

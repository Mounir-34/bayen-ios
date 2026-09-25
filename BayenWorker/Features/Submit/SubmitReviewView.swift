import SwiftData
import SwiftUI

@MainActor
@Observable
final class SubmitReviewViewModel {
    enum Phase: Equatable {
        case editing
        case sending
        /// Reached the server.
        case sent
        /// Saved on the phone; will be sent automatically.
        case queued
    }

    let taskId: String
    var note = ""
    private(set) var phase: Phase = .editing
    var errorMessage: String?
    var confirmIncomplete = false
    private(set) var remotePhotos: [RemotePhoto] = []

    init(taskId: String) { self.taskId = taskId }

    func loadRemotePhotos(api: APIClient) async {
        if let detail = try? await api.task(id: taskId) {
            remotePhotos = detail.photos.filter { $0.submissionId == nil }
        }
    }

    func submit(task: WorkerTask, localPhotos: [PendingPhoto], uploads: UploadManager, location: LocationService,
                network: NetworkMonitor) async {
        errorMessage = nil
        phase = .sending
        // Submission position: a fresh fix if possible, otherwise the last known one.
        guard let fix = await location.waitForFix(timeout: 10) else {
            phase = .editing
            errorMessage = L10n.tr("location.noFix")
            return
        }
        do {
            try uploads.queueSubmission(taskId: task.id, note: note, location: LocationPayload(fix),
                                        extraRemotePhotoIds: remotePhotos.map(\.id))
        } catch {
            phase = .editing
            errorMessage = L10n.tr("error.generic")
            return
        }
        guard network.isConnected else {
            phase = .queued
            return
        }
        // Online: wait a little for photos + submission to go through, else leave it to the queue.
        await uploads.processQueue()
        for _ in 0..<60 where uploads.pendingSubmissionTaskIds.contains(task.id) {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        phase = uploads.pendingSubmissionTaskIds.contains(task.id) ? .queued : .sent
    }
}

struct SubmitReviewView: View {
    let taskId: String

    @Environment(AppEnvironment.self) private var env
    @Environment(TaskStore.self) private var store
    @Environment(LocationService.self) private var location
    @Environment(UploadManager.self) private var uploads
    @Environment(NetworkMonitor.self) private var network
    @State private var model: SubmitReviewViewModel
    @Query private var localPhotos: [PendingPhoto]
    @FocusState private var noteFocused: Bool

    init(taskId: String) {
        self.taskId = taskId
        _model = State(initialValue: SubmitReviewViewModel(taskId: taskId))
        _localPhotos = Query(filter: #Predicate<PendingPhoto> { $0.taskId == taskId && !$0.markedForDeletion },
                             sort: \PendingPhoto.capturedAt)
    }

    var body: some View {
        Group {
            if let task = store.task(id: taskId) {
                switch model.phase {
                case .sent:
                    StateScreen(systemImage: "checkmark.seal.fill", color: .green,
                                title: L10n.tr("submit.sent.title"), message: L10n.tr("submit.sent.message")) {
                        BigButton(title: L10n.tr("submit.backToTasks"), systemImage: "list.bullet") { env.router.popToRoot() }
                    }
                case .queued:
                    StateScreen(systemImage: "icloud.and.arrow.up.fill", color: Color(uiColor: .systemBlue),
                                title: L10n.tr("submit.queued.title"), message: L10n.tr("submit.queued.message")) {
                        BigButton(title: L10n.tr("submit.backToTasks"), systemImage: "list.bullet") { env.router.popToRoot() }
                    }
                case .editing, .sending:
                    form(task)
                }
            } else {
                ProgressView()
            }
        }
        .background(Theme.background)
        .navigationTitle(L10n.tr("submit.title"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.phase != .editing)
        .task {
            location.start()
            await model.loadRemotePhotos(api: env.api)
        }
        .onDisappear { location.stop() }
    }

    private func form(_ task: WorkerTask) -> some View {
        let requirement = PhotoRequirement(task: task, localPhotos: localPhotos, remotePhotos: model.remotePhotos)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(task.title).font(.title2.weight(.bold))

                VStack(alignment: .leading, spacing: 8) {
                    RequirementRow(done: requirement.hasEnough,
                                   text: L10n.tr("requirement.minPhotos", requirement.total, requirement.minimum))
                    if task.requireBeforePhoto {
                        RequirementRow(done: requirement.hasBefore, text: L10n.tr("requirement.before"))
                    }
                    RequirementRow(done: requirement.hasAfter, text: L10n.tr("requirement.after"))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))

                Label(L10n.tr("submit.photos"), systemImage: "photo.on.rectangle").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                    ForEach(localPhotos) { photo in
                        PhotoThumbnail(photo: photo, size: 104)
                    }
                    ForEach(model.remotePhotos) { photo in
                        RemoteThumbnail(photo: photo, size: 104)
                    }
                }
                if uploads.pendingPhotoCount > 0 {
                    NoticeBanner(kind: .info, title: L10n.tr("upload.banner.photos", uploads.pendingPhotoCount),
                                 message: L10n.tr("submit.photosWillUpload"), systemImage: "arrow.up.circle")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.tr("submit.note"), systemImage: "text.bubble").font(.headline)
                    TextField(L10n.tr("submit.note.placeholder"), text: $model.note, axis: .vertical)
                        .lineLimit(3...8)
                        .font(.title3)
                        .focused($noteFocused)
                        .padding(12)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Label(L10n.tr("submit.note.dictationHint"), systemImage: "mic.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let error = model.errorMessage {
                    NoticeBanner(kind: .danger, title: error)
                }
            }
            .padding(16)
            .padding(.bottom, 100)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            BigButton(title: L10n.tr("submit.button"), systemImage: "checkmark.circle.fill", isLoading: model.phase == .sending) {
                noteFocused = false
                if requirement.isMet {
                    send(task)
                } else {
                    model.confirmIncomplete = true
                }
            }
            .disabled(requirement.total == 0 || location.isDenied)
            .padding(16)
            .background(.bar)
        }
        .alert(L10n.tr("submit.incomplete.title"), isPresented: $model.confirmIncomplete) {
            Button(L10n.tr("submit.incomplete.send"), role: .destructive) { send(task) }
            Button(L10n.tr("action.morePhotos"), role: .cancel) {}
        } message: {
            Text(L10n.tr("submit.incomplete.message"))
        }
    }

    private func send(_ task: WorkerTask) {
        Task {
            await model.submit(task: task, localPhotos: localPhotos, uploads: uploads, location: location, network: network)
        }
    }
}

struct RemoteThumbnail: View {
    let photo: RemotePhoto
    var size: CGFloat = 96

    var body: some View {
        AsyncImage(url: URL(string: photo.thumbnailUrl ?? photo.url)) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.gray.opacity(0.2)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            Text(photo.kind.label)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.6), in: Capsule())
                .foregroundStyle(.white)
                .padding(4)
        }
        .overlay(alignment: .bottomTrailing) {
            UploadStatusIcon(status: .uploaded).padding(4)
        }
    }
}

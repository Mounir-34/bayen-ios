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

    func loadRemotePhotos(api: APIClient, uploads: UploadManager) async {
        if let detail = try? await api.task(id: taskId) {
            remotePhotos = detail.photos.filter { $0.submissionId == nil }
                .notStored(locally: uploads.storedClientPhotoIds(for: taskId))
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
                    StateScreen(systemImage: "checkmark", color: Theme.success,
                                title: L10n.tr("submit.sent.title"), message: L10n.tr("submit.sent.message")) {
                        BigButton(title: L10n.tr("submit.backToTasks"), systemImage: "list.bullet") { env.router.popToRoot() }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                case .queued:
                    StateScreen(systemImage: "icloud.and.arrow.up.fill", color: Theme.info,
                                title: L10n.tr("submit.queued.title"), message: L10n.tr("submit.queued.message")) {
                        BigButton(title: L10n.tr("submit.backToTasks"), systemImage: "list.bullet") { env.router.popToRoot() }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                case .editing, .sending:
                    form(task)
                }
            } else {
                ProgressView().tint(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AmbientBackground(intensity: 0.45))
        .animation(Motion.spring, value: model.phase)
        .navigationTitle(L10n.tr("submit.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(model.phase != .editing)
        .sensoryFeedback(trigger: model.phase) { _, phase in
            switch phase {
            case .sent: return .success
            case .queued: return .warning
            default: return nil
            }
        }
        .task {
            location.start()
            await model.loadRemotePhotos(api: env.api, uploads: uploads)
        }
        .onDisappear { location.stop() }
    }

    private func form(_ task: WorkerTask) -> some View {
        let requirement = PhotoRequirement(task: task, localPhotos: localPhotos, remotePhotos: model.remotePhotos)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        CategoryIcon(category: task.category, size: 36)
                        Text(task.category.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Text(task.title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                }
                .appearAnimation(index: 0)

                RequirementsSummary(task: task, requirement: requirement)
                    .cardStyle(padding: 16)
                    .appearAnimation(index: 1)

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: L10n.tr("submit.photos"), count: localPhotos.count + model.remotePhotos.count,
                                  systemImage: "photo.on.rectangle")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                        ForEach(localPhotos) { photo in
                            PhotoThumbnail(photo: photo, size: 100)
                        }
                        ForEach(model.remotePhotos) { photo in
                            RemoteThumbnail(photo: photo, size: 100)
                        }
                    }
                    if uploads.pendingPhotoCount > 0 {
                        NoticeBanner(kind: .info, title: L10n.tr("upload.banner.photos", uploads.pendingPhotoCount),
                                     message: L10n.tr("submit.photosWillUpload"), systemImage: "arrow.up")
                    }
                }
                .cardStyle(padding: 16)
                .appearAnimation(index: 2)

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: L10n.tr("submit.note"), systemImage: "text.bubble")
                    TextField(L10n.tr("submit.note.placeholder"), text: $model.note, axis: .vertical)
                        .lineLimit(3...8)
                        .font(.body)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(Theme.textPrimary)
                        .focused($noteFocused)
                        .padding(14)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous)
                            .strokeBorder(noteFocused ? Theme.primary.opacity(0.5) : Theme.hairline, lineWidth: noteFocused ? 1.5 : 0.75))
                        .animation(Motion.snappy, value: noteFocused)
                    Label(L10n.tr("submit.note.dictationHint"), systemImage: "mic.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 4)
                }
                .cardStyle(padding: 16)
                .appearAnimation(index: 3)

                if let error = model.errorMessage {
                    NoticeBanner(kind: .danger, title: error)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .animation(Motion.spring, value: model.errorMessage)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BigButton(title: L10n.tr("submit.button"), systemImage: "paperplane.fill", isLoading: model.phase == .sending) {
                noteFocused = false
                if requirement.isMet {
                    send(task)
                } else {
                    model.confirmIncomplete = true
                }
            }
            .disabled(requirement.total == 0 || location.isDenied)
            .padding(.horizontal, Theme.screenPadding)
            .padding(.top, 20)
            .padding(.bottom, 10)
            .background { BottomFade() }
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
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        AsyncImage(url: URL(string: photo.thumbnailUrl ?? photo.url), transaction: Transaction(animation: Motion.gentle)) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Rectangle().fill(Theme.fill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.75))
        .overlay(alignment: .topLeading) {
            UploadStatusIcon(status: .uploaded).padding(5)
        }
        .overlay(alignment: .bottomLeading) {
            PhotoKindTag(kind: photo.kind).padding(5)
        }
    }
}

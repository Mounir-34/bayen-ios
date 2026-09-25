import MapKit
import SwiftData
import SwiftUI

struct TaskDetailView: View {
    let taskId: String

    @Environment(AppEnvironment.self) private var env
    @Environment(TaskStore.self) private var store
    @Environment(LocationService.self) private var location
    @Environment(UploadManager.self) private var uploads
    @Environment(NetworkMonitor.self) private var network
    @State private var model: TaskDetailViewModel
    @State private var showMapsChooser = false
    @Query private var localPhotos: [PendingPhoto]

    init(taskId: String) {
        self.taskId = taskId
        _model = State(initialValue: TaskDetailViewModel(taskId: taskId))
        _localPhotos = Query(filter: #Predicate<PendingPhoto> { $0.taskId == taskId && !$0.markedForDeletion },
                             sort: \PendingPhoto.capturedAt)
    }

    var body: some View {
        Group {
            if let task = store.task(id: taskId) ?? model.detail?.task {
                content(task)
            } else if let error = model.errorMessage {
                ContentUnavailableView(L10n.tr("tasks.error.title"), systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            location.start()
            if let task = store.task(id: taskId) { location.simulateArrival(at: task.coordinate) }
            await model.load(store: store, api: env.api)
        }
        .onDisappear { location.stop() }
        .fullScreenCover(item: Binding(get: { model.cameraKind.map(CameraRequest.init) },
                                       set: { model.cameraKind = $0?.kind })) { request in
            if let task = store.task(id: taskId) {
                CameraView(task: task, initialKind: request.kind)
            }
        }
    }

    @ViewBuilder
    private func content(_ task: WorkerTask) -> some View {
        let status = store.effectiveStatus(of: task)
        let hasQueuedSubmission = uploads.pendingSubmissionTaskIds.contains(task.id)
        let action = model.primaryAction(task: task, status: status, localPhotos: localPhotos, hasPendingSubmission: hasQueuedSubmission)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(task, status: status)

                if status == .rejected {
                    NoticeBanner(kind: .danger, title: L10n.tr("task.rejected.title"),
                                 message: store.rejectionNotes[task.id] ?? model.detail?.rejectionNote ?? L10n.tr("task.rejected.noReason"),
                                 systemImage: "exclamationmark.bubble.fill")
                }
                if let info = model.infoMessage {
                    NoticeBanner(kind: .info, title: info)
                }
                if let error = model.errorMessage {
                    NoticeBanner(kind: .danger, title: error)
                }
                if location.isDenied {
                    locationDeniedBanner
                }

                TaskLocationMap(task: task, userLocation: location.location, isSimulated: location.isSimulated)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))

                distanceRow(task)

                BigButton(title: L10n.tr("detail.openInMaps"), systemImage: "arrow.triangle.turn.up.right.diamond.fill",
                          style: .secondary) { showMapsChooser = true }
                    .confirmationDialog(L10n.tr("detail.openInMaps"), isPresented: $showMapsChooser, titleVisibility: .visible) {
                        Button(L10n.tr("maps.apple")) { MapsLauncher.open(.apple, task: task) }
                        Button(L10n.tr("maps.google")) { MapsLauncher.open(.google, task: task) }
                        Button(L10n.tr("maps.waze")) { MapsLauncher.open(.waze, task: task) }
                        Button(L10n.tr("common.cancel"), role: .cancel) {}
                    }

                if !task.description.isEmpty {
                    section(L10n.tr("detail.description"), systemImage: "text.alignleft") {
                        Text(task.description).font(.body)
                    }
                }

                requirementsSection(task)

                if !localPhotos.isEmpty {
                    section(L10n.tr("detail.myPhotos"), systemImage: "photo.stack") {
                        LocalPhotoStrip(photos: localPhotos, allowsDelete: status == .inProgress && !hasQueuedSubmission)
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 120)
        }
        .refreshable { await model.load(store: store, api: env.api) }
        .safeAreaInset(edge: .bottom) {
            actionBar(task, action: action)
        }
        .navigationTitle(task.category.label)
    }

    private func header(_ task: WorkerTask, status: TaskStatus) -> some View {
        HStack(alignment: .top, spacing: 14) {
            CategoryIcon(category: task.category, size: 60)
            VStack(alignment: .leading, spacing: 8) {
                Text(task.title).font(.title2.weight(.bold))
                StatusBadge(status: status)
                if let due = task.dueDate {
                    Label(L10n.tr("detail.due", due.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(L10n.locale))),
                          systemImage: "calendar")
                        .font(.subheadline)
                        .foregroundStyle(task.isOverdue ? Theme.danger : .secondary)
                }
                if let address = task.address {
                    Label(address, systemImage: "mappin.and.ellipse").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func distanceRow(_ task: WorkerTask) -> some View {
        if let here = location.location {
            let distance = Geo.distanceMeters(from: here.coordinate, to: task.coordinate)
            let inside = distance <= Double(task.radiusMeters)
            NoticeBanner(kind: inside ? .success : .info,
                         title: inside ? L10n.tr("detail.atLocation") : L10n.tr("detail.distance", Geo.formatDistance(distance)),
                         message: L10n.tr("detail.radius", Geo.formatDistance(Double(task.radiusMeters))),
                         systemImage: inside ? "checkmark.circle.fill" : "figure.walk")
        } else if location.isAuthorized {
            Label(L10n.tr("location.searching"), systemImage: "location.magnifyingglass").foregroundStyle(.secondary)
        }
    }

    private func requirementsSection(_ task: WorkerTask) -> some View {
        let requirement = PhotoRequirement(task: task, localPhotos: localPhotos, remotePhotos: model.unsubmittedRemotePhotos)
        return section(L10n.tr("detail.requirements"), systemImage: "checklist") {
            VStack(alignment: .leading, spacing: 8) {
                RequirementRow(done: requirement.hasEnough,
                               text: L10n.tr("requirement.minPhotos", requirement.total, requirement.minimum))
                if task.requireBeforePhoto {
                    RequirementRow(done: requirement.hasBefore, text: L10n.tr("requirement.before"))
                }
                RequirementRow(done: requirement.hasAfter, text: L10n.tr("requirement.after"))
            }
        }
    }

    @ViewBuilder
    private func actionBar(_ task: WorkerTask, action: TaskDetailViewModel.PrimaryAction) -> some View {
        VStack(spacing: 10) {
            switch action {
            case let .start(isRestart):
                BigButton(title: L10n.tr(isRestart ? "action.restart" : "action.start"), systemImage: "play.fill",
                          isLoading: model.isStarting) {
                    Task {
                        await model.start(task: task, store: store, api: env.api, uploads: uploads, location: location, network: network)
                    }
                }
                .disabled(location.isDenied)
            case .takePhotos:
                BigButton(title: L10n.tr("action.takePhotos"), systemImage: "camera.fill") { openCamera(task) }
                    .disabled(location.isDenied)
            case .markDone:
                NavigationLink(value: TaskRoute.submit(taskId: task.id)) {
                    Label(L10n.tr("action.markDone"), systemImage: "checkmark.circle.fill")
                        .font(.title3.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: Theme.bigButtonHeight)
                        .foregroundStyle(Theme.onPrimary)
                        .background(Theme.primary, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                BigButton(title: L10n.tr("action.morePhotos"), systemImage: "camera", style: .secondary) { openCamera(task) }
                    .disabled(location.isDenied)
            case let .waitingReview(queued):
                NoticeBanner(kind: queued ? .info : .warning,
                             title: L10n.tr(queued ? "submit.queued.title" : "status.SUBMITTED"),
                             message: L10n.tr(queued ? "submit.queued.message" : "detail.waitingReview"),
                             systemImage: queued ? "icloud.and.arrow.up" : "hourglass")
                if queued, (uploads.pendingSubmission(for: task.id)?.isPermanentFailure == true
                    || (uploads.blockedPhotoCount > 0 && uploads.hasBlockedPhotos(taskId: task.id))) {
                    BigButton(title: L10n.tr("common.retry"), systemImage: "arrow.clockwise", style: .secondary) {
                        uploads.retry(taskId: task.id)
                    }
                }
            case .approved:
                NoticeBanner(kind: .success, title: L10n.tr("status.APPROVED"), message: L10n.tr("detail.approved"))
            case .unavailable:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func openCamera(_ task: WorkerTask) {
        let hasBefore = localPhotos.contains { $0.kind == .before } || model.unsubmittedRemotePhotos.contains { $0.kind == .before }
        model.cameraKind = task.requireBeforePhoto && !hasBefore ? .before : .after
    }

    private var locationDeniedBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            NoticeBanner(kind: .danger, title: L10n.tr("location.denied.title"), message: L10n.tr("location.denied.message"),
                         systemImage: "location.slash.fill")
            BigButton(title: L10n.tr("common.openSettings"), systemImage: "gear", style: .secondary) { AppSettings.open() }
        }
    }

    private func section<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

private struct CameraRequest: Identifiable {
    let kind: PhotoKind
    var id: String { kind.rawValue }
}

struct RequirementRow: View {
    let done: Bool
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
        }
        .font(.body)
        .accessibilityValue(Text(L10n.tr(done ? "a11y.done" : "a11y.notDone")))
    }
}

struct TaskLocationMap: View {
    let task: WorkerTask
    let userLocation: CLLocation?
    let isSimulated: Bool

    var body: some View {
        let span = max(0.004, Double(task.radiusMeters) / 111_000 * 6)
        Map(initialPosition: .region(MKCoordinateRegion(center: task.coordinate,
                                                        span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)))) {
            MapCircle(center: task.coordinate, radius: CLLocationDistance(task.radiusMeters))
                .stroke(Theme.primary, lineWidth: 2)
                .foregroundStyle(Theme.primary.opacity(0.18))
            Marker(task.title, systemImage: task.category.symbol, coordinate: task.coordinate)
                .tint(Theme.primary)
            if isSimulated, let userLocation {
                Annotation(L10n.tr("map.you"), coordinate: userLocation.coordinate) { SimulatedUserDot() }
            } else {
                UserAnnotation()
            }
        }
        .mapControls { MapUserLocationButton() }
        .accessibilityLabel(Text(L10n.tr("detail.map.a11y")))
    }
}

enum MapsLauncher {
    enum App { case apple, google, waze }

    @MainActor
    static func open(_ app: App, task: WorkerTask) {
        let lat = task.latitude, lng = task.longitude
        switch app {
        case .apple:
            let item = MKMapItem(placemark: MKPlacemark(coordinate: task.coordinate))
            item.name = task.title
            item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
        case .google:
            openURL(app: "comgooglemaps://?daddr=\(lat),\(lng)&directionsmode=driving",
                    web: "https://www.google.com/maps/dir/?api=1&destination=\(lat),\(lng)")
        case .waze:
            openURL(app: "waze://?ll=\(lat),\(lng)&navigate=yes", web: "https://waze.com/ul?ll=\(lat),\(lng)&navigate=yes")
        }
    }

    @MainActor
    private static func openURL(app: String, web: String) {
        guard let appURL = URL(string: app), let webURL = URL(string: web) else { return }
        if UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL)
        } else {
            UIApplication.shared.open(webURL)
        }
    }
}

/// Horizontal list of this device's photos with upload status and delete.
struct LocalPhotoStrip: View {
    let photos: [PendingPhoto]
    var allowsDelete = true
    var thumbSize: CGFloat = 96
    @Environment(UploadManager.self) private var uploads
    @State private var toDelete: PendingPhoto?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(photos) { photo in
                    PhotoThumbnail(photo: photo, size: thumbSize, onDelete: allowsDelete ? { toDelete = photo } : nil)
                }
            }
            .padding(.vertical, 4)
        }
        .confirmationDialog(L10n.tr("photo.delete.title"), isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            titleVisibility: .visible) {
            Button(L10n.tr("photo.delete.confirm"), role: .destructive) {
                if let toDelete { uploads.delete(toDelete) }
                toDelete = nil
            }
            Button(L10n.tr("common.cancel"), role: .cancel) { toDelete = nil }
        }
    }
}

struct PhotoThumbnail: View {
    let photo: PendingPhoto
    var size: CGFloat = 96
    var onDelete: (() -> Void)?
    @Environment(UploadManager.self) private var uploads
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.gray.opacity(0.2)
                }
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
                UploadStatusIcon(status: photo.status, isUploading: uploads.uploadingIds.contains(photo.clientPhotoId),
                                 isBlocked: photo.isPermanentFailure)
                    .padding(4)
            }

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                        .frame(width: 44, height: 44)
                }
                .offset(x: 10, y: -10)
                .accessibilityLabel(L10n.tr("photo.delete.title"))
            }
        }
        .accessibilityElement(children: .contain)
        .task(id: photo.fileName) {
            let url = uploads.files.url(for: photo.fileName)
            image = await Task.detached(priority: .utility) { ImageThumbnail.load(url, maxPixelSize: 300) }.value
        }
    }
}

struct UploadStatusIcon: View {
    let status: PhotoUploadStatus
    var isUploading = false
    var isBlocked = false

    private struct Appearance {
        let symbol: String
        let color: Color
        let label: String
    }

    private var appearance: Appearance {
        if isUploading || status == .uploading {
            return Appearance(symbol: "arrow.up.circle.fill", color: .blue, label: L10n.tr("upload.status.uploading"))
        }
        switch status {
        case .uploaded:
            return Appearance(symbol: "checkmark.circle.fill", color: .green, label: L10n.tr("upload.status.uploaded"))
        case .failed:
            return isBlocked
                ? Appearance(symbol: "exclamationmark.circle.fill", color: .red, label: L10n.tr("upload.status.failed"))
                : Appearance(symbol: "arrow.clockwise.circle.fill", color: .orange, label: L10n.tr("upload.status.retrying"))
        case .waiting, .uploading:
            return Appearance(symbol: "clock.fill", color: .gray, label: L10n.tr("upload.status.waiting"))
        }
    }

    var body: some View {
        Image(systemName: appearance.symbol)
            .font(.title3)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, appearance.color)
            .background(Circle().fill(.white).padding(2))
            .accessibilityLabel(appearance.label)
    }
}

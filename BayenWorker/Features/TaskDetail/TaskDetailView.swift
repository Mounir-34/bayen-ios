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
                EmptyStateView(systemImage: "exclamationmark.triangle", tint: Theme.warning,
                               title: L10n.tr("tasks.error.title"), message: error) { EmptyView() }
            } else {
                ProgressView().controlSize(.large).tint(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AmbientBackground(intensity: 0.45))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
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
                    .appearAnimation(index: 0)

                VStack(spacing: 10) {
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
                }
                .animation(Motion.spring, value: model.errorMessage)
                .animation(Motion.spring, value: model.infoMessage)

                mapCard(task)
                    .appearAnimation(index: 1)

                infoCard(task)
                    .appearAnimation(index: 2)

                if !task.description.isEmpty {
                    card(L10n.tr("detail.description"), systemImage: "text.alignleft") {
                        Text(task.description)
                            .font(.body)
                            .foregroundStyle(Theme.textPrimary)
                            .lineSpacing(3)
                    }
                    .appearAnimation(index: 3)
                }

                requirementsSection(task)
                    .appearAnimation(index: 4)

                if !localPhotos.isEmpty {
                    card(L10n.tr("detail.myPhotos"), systemImage: "photo.stack") {
                        LocalPhotoStrip(photos: localPhotos, allowsDelete: status == .inProgress && !hasQueuedSubmission)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .animation(Motion.spring, value: localPhotos.count)
        }
        .scrollIndicators(.hidden)
        .refreshable { await model.load(store: store, api: env.api) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionBar(task, action: action)
        }
        .navigationTitle(task.category.label)
        .sensoryFeedback(.success, trigger: status) { _, new in new == .inProgress || new == .approved }
    }

    private func header(_ task: WorkerTask, status: TaskStatus) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                CategoryIcon(category: task.category, size: 58)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        StatusBadge(status: status)
                            .contentTransition(.interpolate)
                        if task.priority == .high {
                            Image(systemName: "flag.fill")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(Theme.danger)
                                .frame(width: 30, height: 30)
                                .background(Theme.danger.opacity(0.1), in: Circle())
                                .accessibilityLabel(L10n.tr("priority.HIGH"))
                        }
                    }
                }
            }
            Text(task.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(Motion.spring, value: status)
    }

    private func mapCard(_ task: WorkerTask) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TaskLocationMap(task: task, userLocation: location.location, isSimulated: location.isSimulated)
                .frame(height: 220)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: Theme.cornerRadius - 6,
                                                  bottomLeadingRadius: 8, bottomTrailingRadius: 8,
                                                  topTrailingRadius: Theme.cornerRadius - 6, style: .continuous))

            VStack(alignment: .leading, spacing: 14) {
                distanceRow(task)
                BigButton(title: L10n.tr("detail.openInMaps"), systemImage: "arrow.triangle.turn.up.right.diamond.fill",
                          style: .tinted) { showMapsChooser = true }
                    .confirmationDialog(L10n.tr("detail.openInMaps"), isPresented: $showMapsChooser, titleVisibility: .visible) {
                        Button(L10n.tr("maps.apple")) { MapsLauncher.open(.apple, task: task) }
                        Button(L10n.tr("maps.google")) { MapsLauncher.open(.google, task: task) }
                        Button(L10n.tr("maps.waze")) { MapsLauncher.open(.waze, task: task) }
                        Button(L10n.tr("common.cancel"), role: .cancel) {}
                    }
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 10)
        }
        .cardStyle(padding: 6)
    }

    @ViewBuilder
    private func distanceRow(_ task: WorkerTask) -> some View {
        let radius = L10n.tr("detail.radius", Geo.formatDistance(Double(task.radiusMeters)))
        if let here = location.location {
            let distance = Geo.distanceMeters(from: here.coordinate, to: task.coordinate)
            let inside = distance <= Double(task.radiusMeters)
            HStack(spacing: 12) {
                IconCircle(systemImage: inside ? "checkmark" : "figure.walk", color: inside ? Theme.success : Theme.info, size: 40)
                    .symbolEffect(.bounce, value: inside)
                VStack(alignment: .leading, spacing: 2) {
                    Text(inside ? L10n.tr("detail.atLocation") : L10n.tr("detail.distance", Geo.formatDistance(distance)))
                        .font(.headline)
                        .foregroundStyle(inside ? Theme.success : Theme.textPrimary)
                        .contentTransition(.numericText())
                    Text(radius)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .animation(Motion.spring, value: inside)
        } else if location.isAuthorized {
            HStack(spacing: 12) {
                ProgressView().frame(width: 40, height: 40)
                Text(L10n.tr("location.searching"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func infoCard(_ task: WorkerTask) -> some View {
        if task.dueDate != nil || task.address != nil {
            VStack(spacing: 4) {
                if let due = task.dueDate {
                    HStack(spacing: 12) {
                        IconCircle(systemImage: "calendar", color: task.isOverdue ? Theme.danger : Theme.primary, size: 32)
                        Text(L10n.tr("detail.due", due.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(L10n.locale))))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(task.isOverdue ? Theme.danger : Theme.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44)
                }
                if task.dueDate != nil, task.address != nil {
                    Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 44)
                }
                if let address = task.address {
                    HStack(spacing: 12) {
                        IconCircle(systemImage: "mappin.and.ellipse", color: Theme.primary, size: 32)
                        Text(address)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44)
                }
            }
            .cardStyle(padding: 12)
        }
    }

    private func requirementsSection(_ task: WorkerTask) -> some View {
        let requirement = PhotoRequirement(task: task, localPhotos: localPhotos, remotePhotos: model.unsubmittedRemotePhotos)
        return card(L10n.tr("detail.requirements"), systemImage: "checklist") {
            RequirementsSummary(task: task, requirement: requirement)
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
                    BigButtonLabel(title: L10n.tr("action.markDone"), systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(PressableStyle())
                BigButton(title: L10n.tr("action.morePhotos"), systemImage: "camera", style: .secondary) { openCamera(task) }
                    .disabled(location.isDenied)
            case let .waitingReview(queued):
                NoticeBanner(kind: queued ? .info : .warning,
                             title: L10n.tr(queued ? "submit.queued.title" : "status.SUBMITTED"),
                             message: L10n.tr(queued ? "submit.queued.message" : "detail.waitingReview"),
                             systemImage: queued ? "icloud.and.arrow.up" : "hourglass")
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous))
                if queued, (uploads.pendingSubmission(for: task.id)?.isPermanentFailure == true
                    || (uploads.blockedPhotoCount > 0 && uploads.hasBlockedPhotos(taskId: task.id))) {
                    BigButton(title: L10n.tr("common.retry"), systemImage: "arrow.clockwise", style: .secondary) {
                        uploads.retry(taskId: task.id)
                    }
                }
            case .approved:
                NoticeBanner(kind: .success, title: L10n.tr("status.APPROVED"), message: L10n.tr("detail.approved"),
                             systemImage: "checkmark.seal.fill")
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous))
            case .unavailable:
                EmptyView()
            }
        }
        .padding(.horizontal, Theme.screenPadding)
        .padding(.top, 20)
        .padding(.bottom, 10)
        .background { BottomFade() }
        .animation(Motion.spring, value: action)
    }

    private func openCamera(_ task: WorkerTask) {
        let hasBefore = localPhotos.contains { $0.kind == .before } || model.unsubmittedRemotePhotos.contains { $0.kind == .before }
        model.cameraKind = task.requireBeforePhoto && !hasBefore ? .before : .after
    }

    private var locationDeniedBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            NoticeBanner(kind: .danger, title: L10n.tr("location.denied.title"), message: L10n.tr("location.denied.message"),
                         systemImage: "location.slash.fill")
            BigButton(title: L10n.tr("common.openSettings"), systemImage: "gear", style: .tinted) { AppSettings.open() }
        }
    }

    private func card<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(Theme.primary)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            content()
        }
        .cardStyle(padding: 16)
    }
}

/// Soft fade from transparent to the screen colour behind floating bottom buttons.
struct BottomFade: View {
    var body: some View {
        LinearGradient(stops: [.init(color: Theme.background.opacity(0), location: 0),
                               .init(color: Theme.background.opacity(0.94), location: 0.3),
                               .init(color: Theme.background, location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

/// Progress ring plus the checklist of photo requirements.
struct RequirementsSummary: View {
    let task: WorkerTask
    let requirement: PhotoRequirement

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                ProgressRing(progress: Double(requirement.total) / Double(requirement.minimum),
                             color: requirement.isMet ? Theme.success : Theme.primary, lineWidth: 6, size: 64)
                VStack(spacing: 0) {
                    Text(verbatim: "\(requirement.total)")
                        .font(.system(.title3, design: .rounded, weight: .bold).monospacedDigit())
                        .contentTransition(.numericText())
                    Text(verbatim: "/ \(requirement.minimum)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
                .foregroundStyle(Theme.textPrimary)
                .environment(\.layoutDirection, .leftToRight)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                RequirementRow(done: requirement.hasEnough,
                               text: L10n.tr("requirement.minPhotos", requirement.total, requirement.minimum))
                if task.requireBeforePhoto {
                    RequirementRow(done: requirement.hasBefore, text: L10n.tr("requirement.before"))
                }
                RequirementRow(done: requirement.hasAfter, text: L10n.tr("requirement.after"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(Motion.spring, value: requirement.total)
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.body.weight(.semibold))
                .foregroundStyle(done ? Theme.success : Theme.textTertiary)
                .contentTransition(.symbolEffect(.replace))
            Text(text)
                .font(.subheadline.weight(done ? .medium : .regular))
                .foregroundStyle(done ? Theme.textPrimary : Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(Motion.snappy, value: done)
        .accessibilityElement(children: .combine)
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
                .stroke(task.category.tint, lineWidth: 2)
                .foregroundStyle(task.category.tint.opacity(0.15))
            Annotation(task.title, coordinate: task.coordinate, anchor: .bottom) {
                MapPin(symbol: task.category.symbol, color: task.category.tint, size: 40)
            }
            if isSimulated, let userLocation {
                Annotation(L10n.tr("map.you"), coordinate: userLocation.coordinate) { SimulatedUserDot() }
            } else {
                UserAnnotation()
            }
        }
        .mapStyle(.standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll))
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
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.vertical, 4)
            .animation(Motion.spring, value: photos.count)
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
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                } else {
                    Rectangle().fill(Theme.fill)
                }
            }
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.75))
            .overlay(alignment: .topLeading) {
                UploadStatusIcon(status: photo.status, isUploading: uploads.uploadingIds.contains(photo.clientPhotoId),
                                 isBlocked: photo.isPermanentFailure)
                    .padding(5)
            }
            .overlay(alignment: .bottomLeading) {
                PhotoKindTag(kind: photo.kind).padding(5)
            }

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(.black.opacity(0.55), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 0.85))
                .accessibilityLabel(L10n.tr("photo.delete.title"))
            }
        }
        .animation(Motion.gentle, value: image != nil)
        .accessibilityElement(children: .contain)
        .task(id: photo.fileName) {
            let url = uploads.files.url(for: photo.fileName)
            image = await Task.detached(priority: .utility) { ImageThumbnail.load(url, maxPixelSize: 300) }.value
        }
    }
}

/// "Before" / "After" tag shown on photo thumbnails.
struct PhotoKindTag: View {
    let kind: PhotoKind

    var body: some View {
        Text(kind.label)
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .minimumScaleFactor(0.8)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
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
            return Appearance(symbol: "arrow.up.circle.fill", color: Theme.info, label: L10n.tr("upload.status.uploading"))
        }
        switch status {
        case .uploaded:
            return Appearance(symbol: "checkmark.circle.fill", color: Theme.success, label: L10n.tr("upload.status.uploaded"))
        case .failed:
            return isBlocked
                ? Appearance(symbol: "exclamationmark.circle.fill", color: Theme.danger, label: L10n.tr("upload.status.failed"))
                : Appearance(symbol: "arrow.clockwise.circle.fill", color: Theme.warning, label: L10n.tr("upload.status.retrying"))
        case .waiting, .uploading:
            return Appearance(symbol: "clock.fill", color: Theme.neutral, label: L10n.tr("upload.status.waiting"))
        }
    }

    var body: some View {
        Image(systemName: appearance.symbol)
            .font(.system(size: 18, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, appearance.color)
            .background(Circle().fill(.white).padding(2))
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.pulse, options: .repeating, isActive: isUploading || status == .uploading)
            .accessibilityLabel(appearance.label)
    }
}

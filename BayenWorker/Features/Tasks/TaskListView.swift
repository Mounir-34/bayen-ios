import CoreLocation
import MapKit
import SwiftUI

enum TaskSection: String, CaseIterable, Identifiable {
    case toDo, inProgress, waitingReview, done
    var id: String { rawValue }

    var title: String { L10n.tr("section.\(rawValue)") }

    static func of(_ status: TaskStatus) -> TaskSection? {
        switch status {
        case .assigned, .rejected: return .toDo
        case .inProgress: return .inProgress
        case .submitted: return .waitingReview
        case .approved: return .done
        case .cancelled, .unknown: return nil
        }
    }
}

struct TaskListView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(TaskStore.self) private var store
    @Environment(LocationService.self) private var location
    @Environment(UploadManager.self) private var uploads
    @AppStorage("bayen.tasks.showMap") private var showMap = false

    var body: some View {
        @Bindable var router = env.router
        NavigationStack(path: $router.path) {
            VStack(spacing: 0) {
                UploadStatusBanner().padding(.horizontal).padding(.top, 8)
                if showMap {
                    TaskMapView(tasks: store.tasks.filter { TaskSection.of(store.effectiveStatus(of: $0)) != .done })
                } else {
                    list
                }
            }
            .background(Theme.background)
            .navigationTitle(L10n.tr("tasks.title"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BrandEmblem(size: 32)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Picker(selection: $showMap) {
                        Label(L10n.tr("tasks.view.list"), systemImage: "list.bullet").tag(false)
                        Label(L10n.tr("tasks.view.map"), systemImage: "map").tag(true)
                    } label: {
                        Text(L10n.tr("tasks.view"))
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
            }
            .navigationDestination(for: TaskRoute.self) { route in
                switch route {
                case let .detail(taskId): TaskDetailView(taskId: taskId)
                case let .submit(taskId): SubmitReviewView(taskId: taskId)
                }
            }
        }
        .task {
            location.start()
            if store.tasks.isEmpty || (store.lastUpdated.map { Date().timeIntervalSince($0) > 60 } ?? true) {
                await store.refresh()
            }
        }
        .onDisappear { location.stop() }
    }

    private struct SectionGroup: Identifiable {
        let section: TaskSection
        let tasks: [WorkerTask]
        var id: TaskSection { section }
    }

    private var grouped: [SectionGroup] {
        let bySection = Dictionary(grouping: store.tasks) { TaskSection.of(store.effectiveStatus(of: $0)) }
        return TaskSection.allCases.compactMap { section in
            guard let tasks = bySection[section], !tasks.isEmpty else { return nil }
            return SectionGroup(section: section,
                                tasks: tasks.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) })
        }
    }

    @ViewBuilder
    private var list: some View {
        List {
            if let error = store.lastError, !store.tasks.isEmpty {
                NoticeBanner(kind: .warning, title: error.localizedMessage, message: lastUpdatedText)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            ForEach(grouped) { group in
                let section = group.section
                let tasks = group.tasks
                Section {
                    ForEach(tasks) { task in
                        NavigationLink(value: TaskRoute.detail(taskId: task.id)) {
                            TaskCardView(task: task,
                                         status: store.effectiveStatus(of: task),
                                         rejectionNote: store.rejectionNotes[task.id],
                                         userLocation: location.location,
                                         pendingPhotos: uploads.photos(for: task.id).filter { $0.status != .uploaded }.count)
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                } header: {
                    Text(verbatim: "\(section.title) (\(tasks.count))")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if store.tasks.isEmpty {
                if store.isLoading {
                    ProgressView().controlSize(.large)
                } else if let error = store.lastError {
                    ContentUnavailableView {
                        Label(L10n.tr("tasks.error.title"), systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error.localizedMessage)
                    } actions: {
                        Button(L10n.tr("common.retry")) { Task { await store.refresh() } }.buttonStyle(.borderedProminent)
                    }
                } else {
                    ContentUnavailableView {
                        Label {
                            Text(L10n.tr("tasks.empty.title"))
                        } icon: {
                            BrandEmblem(size: 88)
                        }
                    } description: {
                        Text(L10n.tr("tasks.empty.message"))
                    }
                }
            }
        }
        .refreshable { await store.refresh() }
    }

    private var lastUpdatedText: String? {
        guard let date = store.lastUpdated else { return nil }
        return L10n.tr("tasks.lastUpdated", date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))
    }
}

struct TaskCardView: View {
    let task: WorkerTask
    let status: TaskStatus
    let rejectionNote: String?
    let userLocation: CLLocation?
    var pendingPhotos = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                CategoryIcon(category: task.category, size: 52)
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title)
                        .font(.headline)
                        .lineLimit(3)
                    StatusBadge(status: status)
                }
                Spacer(minLength: 0)
                if task.priority == .high {
                    Image(systemName: "flag.fill").foregroundStyle(Theme.danger)
                        .accessibilityLabel(L10n.tr("priority.HIGH"))
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { details }
                VStack(alignment: .leading, spacing: 6) { details }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if status == .rejected {
                NoticeBanner(kind: .danger, title: L10n.tr("task.rejected.title"),
                             message: rejectionNote ?? L10n.tr("task.rejected.noReason"), systemImage: "exclamationmark.bubble.fill")
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .leading) {
            // Status colour strip on the leading edge.
            RoundedRectangle(cornerRadius: 2).fill(status.color).frame(width: 4).offset(x: -10)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var details: some View {
        if let userLocation {
            Label(Geo.formatDistance(Geo.distanceMeters(from: userLocation.coordinate, to: task.coordinate)),
                  systemImage: "location.fill")
        }
        if let due = task.dueDate {
            Label(due.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.locale)), systemImage: "calendar")
                .foregroundStyle(task.isOverdue ? Theme.danger : .secondary)
        }
        if pendingPhotos > 0 {
            Label(L10n.tr("upload.banner.photos", pendingPhotos), systemImage: "arrow.up.circle")
                .foregroundStyle(Theme.warning)
        }
    }
}

struct TaskMapView: View {
    let tasks: [WorkerTask]
    @Environment(AppEnvironment.self) private var env
    @Environment(TaskStore.self) private var store
    @Environment(LocationService.self) private var location
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            ForEach(tasks) { task in
                let status = store.effectiveStatus(of: task)
                Annotation(task.title, coordinate: task.coordinate) {
                    Button {
                        env.router.path.append(.detail(taskId: task.id))
                    } label: {
                        Image(systemName: task.category.symbol)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(status.color, in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 3))
                            .shadow(radius: 3)
                    }
                    .accessibilityLabel(Text(verbatim: "\(task.title), \(status.label)"))
                }
            }
            if location.isSimulated, let loc = location.location {
                Annotation(L10n.tr("map.you"), coordinate: loc.coordinate) { SimulatedUserDot() }
            } else {
                UserAnnotation()
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
    }
}

struct SimulatedUserDot: View {
    var body: some View {
        Circle().fill(Color.blue).frame(width: 18, height: 18)
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(radius: 2)
    }
}

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

    var color: Color {
        switch self {
        case .toDo: return Theme.primary
        case .inProgress: return Theme.info
        case .waitingReview: return Theme.warning
        case .done: return Theme.success
        }
    }
}

struct TaskListView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(TaskStore.self) private var store
    @Environment(LocationService.self) private var location
    @Environment(UploadManager.self) private var uploads
    @AppStorage("bayen.tasks.showMap") private var showMap = false
    @Namespace private var zoom

    var body: some View {
        @Bindable var router = env.router
        NavigationStack(path: $router.path) {
            ZStack {
                if showMap {
                    TaskMapView(tasks: mapTasks)
                        .overlay(alignment: .top) {
                            VStack(spacing: 8) {
                                UploadStatusBanner()
                                if !store.sectionFilter.isEmpty {
                                    FilterActiveChip(sections: store.sectionFilter) { clearFilter() }
                                }
                            }
                            .padding(.horizontal, Theme.screenPadding)
                            .padding(.top, 8)
                        }
                        .transition(.opacity)
                } else {
                    list
                        .transition(.opacity)
                }
            }
            .animation(Motion.gentle, value: showMap)
            .animation(Motion.spring, value: uploads.pendingPhotoCount)
            // Fill the screen before the background goes on: a background only as wide as the content
            // shows up as a vertical stripe.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AmbientBackground(intensity: 0.55))
            .navigationTitle(L10n.tr("tasks.title"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // The emblem doubles as the way home: from the map it brings the list back.
                    Button { showMap = false } label: {
                        BrandEmblem(size: 30)
                    }
                    .buttonStyle(PressableStyle(scale: 0.9, haptic: showMap))
                    .accessibilityLabel(L10n.tr("tasks.view.list"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ViewModeSwitch(showMap: $showMap)
                }
                .hidingSharedGlass()
            }
            .navigationDestination(for: TaskRoute.self) { route in
                switch route {
                case let .detail(taskId): TaskDetailView(taskId: taskId).zoomTransition(id: taskId, in: zoom)
                case let .submit(taskId): SubmitReviewView(taskId: taskId)
                }
            }
        }
        // Decided here rather than on the pushed screens: a pushed screen's `.hidden` only lets go once the pop
        // animation has finished, which made the tab bar come back with a lag.
        .toolbar(router.path.isEmpty ? .visible : .hidden, for: .tabBar)
        .animation(Motion.snappy, value: router.path.isEmpty)
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

    private var filteredTasks: [WorkerTask] {
        TaskFilter.apply(store.tasks, selected: store.sectionFilter, status: store.effectiveStatus(of:))
    }

    /// The map leaves finished tasks out, unless the worker asked for them in the filter.
    private var mapTasks: [WorkerTask] {
        store.sectionFilter.isEmpty
            ? store.tasks.filter { TaskSection.of(store.effectiveStatus(of: $0)) != .done }
            : filteredTasks
    }

    private func toggle(_ section: TaskSection) {
        withAnimation(Motion.spring) { store.sectionFilter = TaskFilter.toggling(section, in: store.sectionFilter) }
    }

    private func clearFilter() {
        withAnimation(Motion.spring) { store.sectionFilter = [] }
    }

    private var grouped: [SectionGroup] {
        let bySection = Dictionary(grouping: filteredTasks) { TaskSection.of(store.effectiveStatus(of: $0)) }
        return TaskSection.allCases.compactMap { section in
            guard let tasks = bySection[section], !tasks.isEmpty else { return nil }
            return SectionGroup(section: section,
                                tasks: tasks.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) })
        }
    }

    @ViewBuilder
    private var list: some View {
        let groups = grouped
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                UploadStatusBanner()

                if let error = store.lastError, !store.tasks.isEmpty {
                    NoticeBanner(kind: .warning, title: error.localizedMessage, message: lastUpdatedText)
                }

                if !store.tasks.isEmpty {
                    SummaryCard(counts: TaskFilter.counts(store.tasks, status: store.effectiveStatus(of:)),
                                selected: store.sectionFilter, onToggle: toggle)
                        .appearAnimation(index: 0)
                        .padding(.bottom, 8)
                        .sensoryFeedback(.selection, trigger: store.sectionFilter)

                    if groups.isEmpty {
                        EmptyStateView(systemImage: "line.3.horizontal.decrease.circle", tint: Theme.neutral,
                                       title: L10n.tr("tasks.filter.empty.title"),
                                       message: L10n.tr("tasks.filter.empty.message")) {
                            BigButton(title: L10n.tr("tasks.filter.showAll"), systemImage: "list.bullet", style: .secondary) {
                                clearFilter()
                            }
                            .frame(maxWidth: 260)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                ForEach(groups) { group in
                    SectionHeader(title: group.section.title, count: group.tasks.count)
                        .padding(.top, 10)
                    ForEach(Array(group.tasks.enumerated()), id: \.element.id) { offset, task in
                        NavigationLink(value: TaskRoute.detail(taskId: task.id)) {
                            TaskCardView(task: task,
                                         status: store.effectiveStatus(of: task),
                                         rejectionNote: store.rejectionNotes[task.id],
                                         userLocation: location.location,
                                         pendingPhotos: uploads.photos(for: task.id).filter { $0.status != .uploaded }.count)
                                .zoomSource(id: task.id, in: zoom)
                        }
                        .buttonStyle(PressableStyle(scale: 0.98, haptic: false))
                        .appearAnimation(index: offset + 1)
                    }
                }
            }
            // A vertical ScrollView is only as wide as its content: with no tasks the content is empty, so
            // the whole list (and the empty state laid over it) collapsed to the width of the paddings.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.screenPadding)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .overlay {
            if store.tasks.isEmpty {
                emptyState
            }
        }
        .refreshable { await store.refresh() }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.isLoading {
            ProgressView().controlSize(.large).tint(Theme.textSecondary)
        } else if let error = store.lastError {
            EmptyStateView(systemImage: "wifi.exclamationmark", tint: Theme.warning,
                           title: L10n.tr("tasks.error.title"), message: error.localizedMessage) {
                BigButton(title: L10n.tr("common.retry"), systemImage: "arrow.clockwise") {
                    Task { await store.refresh() }
                }
                .frame(maxWidth: 260)
            }
        } else {
            EmptyStateView(systemImage: nil, tint: Theme.primary,
                           title: L10n.tr("tasks.empty.title"), message: L10n.tr("tasks.empty.message")) { EmptyView() }
        }
    }

    private var lastUpdatedText: String? {
        guard let date = store.lastUpdated else { return nil }
        return L10n.tr("tasks.lastUpdated", date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))
    }
}

// MARK: - View mode

/// List/map switch: one ivory capsule with a green pill sliding under the chosen mode.
private struct ViewModeSwitch: View {
    @Binding var showMap: Bool
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            segment(map: false, systemImage: "list.bullet", label: L10n.tr("tasks.view.list"))
            segment(map: true, systemImage: "map", label: L10n.tr("tasks.view.map"))
        }
        .padding(3)
        .background(Theme.cardElevated, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.75))
        .shadow(color: Theme.shadow, radius: 8, x: 0, y: 3)
        .sensoryFeedback(.selection, trigger: showMap)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("tasks.view"))
    }

    private func segment(map: Bool, systemImage: String, label: String) -> some View {
        let selected = showMap == map
        return Button {
            withAnimation(Motion.snappy) { showMap = map }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selected ? Theme.onPrimary : Theme.textSecondary)
                .frame(width: 46, height: 36)
                .background {
                    if selected {
                        Capsule().fill(Theme.primaryGradient).matchedGeometryEffect(id: "pill", in: pill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.92, haptic: false))
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension ToolbarContent {
    /// On iOS 26 toolbar items sit on a shared glass capsule; the switch draws its own, so it would be doubled.
    @ToolbarContentBuilder
    func hidingSharedGlass() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

// MARK: - Summary

/// Four-up overview of the worker's tasks. Tapping a state toggles it in the filter; the figures always
/// count every task in that state, whatever the filter.
private struct SummaryCard: View {
    let counts: [TaskSection: Int]
    let selected: Set<TaskSection>
    let onToggle: (TaskSection) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(TaskSection.allCases.enumerated()), id: \.element) { index, section in
                let count = counts[section] ?? 0
                let isSelected = selected.contains(section)
                let shape = RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous)
                if index > 0 {
                    Rectangle().fill(Theme.hairline).frame(width: 1, height: 56).padding(.top, 12)
                }
                Button { onToggle(section) } label: {
                    VStack(spacing: 6) {
                        Text(verbatim: "\(count)")
                            .font(.system(.title, design: .serif, weight: .bold).monospacedDigit())
                            .foregroundStyle(count > 0 ? section.color : Theme.textTertiary)
                            .contentTransition(.numericText())
                        Text(section.title)
                            .font(.caption.weight(isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .top)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
                    .background {
                        if isSelected {
                            shape.fill(section.color.opacity(0.16))
                                .overlay(shape.strokeBorder(section.color.opacity(0.75), lineWidth: 1.5))
                                .padding(.horizontal, 3)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 0.94, haptic: false))
                // An empty state can't be picked, but one that is already picked can always be released.
                .disabled(count == 0 && !isSelected)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityHint(L10n.tr("tasks.filter.hint"))
            }
        }
        .padding(6)
        .cardStyle(padding: 0)
    }
}

/// Reminder on the map that a filter chosen in the list is hiding tasks, with the way out.
private struct FilterActiveChip: View {
    let sections: Set<TaskSection>
    let onShowAll: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(Theme.primary)
                .accessibilityHidden(true)
            Text(TaskSection.allCases.filter(sections.contains).map(\.title).joined(separator: L10n.tr("list.separator")))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Button(L10n.tr("tasks.filter.showAll"), action: onShowAll)
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 14)
        .glass(in: RoundedRectangle(cornerRadius: Theme.innerRadius + 2, style: .continuous))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Card

struct TaskCardView: View {
    let task: WorkerTask
    let status: TaskStatus
    let rejectionNote: String?
    let userLocation: CLLocation?
    var pendingPhotos = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                CategoryIcon(category: task.category, size: 50)
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.category.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(task.title)
                        .font(.display(.headline))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 8) {
                StatusBadge(status: status, compact: true)
                if task.priority == .high {
                    HStack(spacing: 4) {
                        Image(systemName: "flag.fill").font(.system(size: 10, weight: .bold))
                        Text(L10n.tr("priority.HIGH")).font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(Theme.danger)
                    .background(Theme.danger.opacity(0.1), in: Capsule())
                }
            }

            if status == .rejected {
                NoticeBanner(kind: .danger, title: L10n.tr("task.rejected.title"),
                             message: rejectionNote ?? L10n.tr("task.rejected.noReason"), systemImage: "exclamationmark.bubble.fill")
            }

            if hasDetails {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { details }
                    VStack(alignment: .leading, spacing: 8) { details }
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .cardStyle(padding: 16)
        .accessibilityElement(children: .combine)
    }

    private var hasDetails: Bool { userLocation != nil || task.dueDate != nil || pendingPhotos > 0 }

    @ViewBuilder
    private var details: some View {
        if let userLocation {
            Label(Geo.formatDistance(Geo.distanceMeters(from: userLocation.coordinate, to: task.coordinate)),
                  systemImage: "location.fill")
                .labelStyle(MetaLabelStyle())
        }
        if let due = task.dueDate {
            Label(due.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.locale)), systemImage: "calendar")
                .labelStyle(MetaLabelStyle())
                .foregroundStyle(task.isOverdue ? Theme.danger : Theme.textSecondary)
        }
        if pendingPhotos > 0 {
            Label(L10n.tr("upload.banner.photos", pendingPhotos), systemImage: "arrow.up.circle.fill")
                .labelStyle(MetaLabelStyle())
                .foregroundStyle(Theme.warning)
        }
    }
}

/// Compact icon + text used for card metadata.
struct MetaLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.caption.weight(.semibold)).opacity(0.85)
            configuration.title.monospacedDigit()
        }
    }
}

// MARK: - Empty state

struct EmptyStateView<Actions: View>: View {
    /// `nil` shows the Bayen emblem.
    let systemImage: String?
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(tint.opacity(0.06)).frame(width: 150, height: 150)
                Circle().fill(tint.opacity(0.1)).frame(width: 110, height: 110)
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 40, weight: .semibold)).foregroundStyle(tint)
                } else {
                    BrandEmblem(size: 72)
                }
            }
            .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(title).font(.display(.title3, weight: .bold)).foregroundStyle(Theme.textPrimary)
                Text(message).font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            .multilineTextAlignment(.center)
            actions()
        }
        .padding(32)
        .appearAnimation()
    }
}

// MARK: - Map

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
                Annotation(task.title, coordinate: task.coordinate, anchor: .bottom) {
                    Button {
                        env.router.path.append(.detail(taskId: task.id))
                    } label: {
                        MapPin(symbol: task.category.symbol, color: status.color)
                    }
                    .buttonStyle(PressableStyle(scale: 0.9))
                    .accessibilityLabel(Text(verbatim: "\(task.title), \(status.label)"))
                }
            }
            if location.isSimulated, let loc = location.location {
                Annotation(L10n.tr("map.you"), coordinate: loc.coordinate) { SimulatedUserDot() }
            } else {
                UserAnnotation()
            }
        }
        .mapStyle(.standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
    }
}

/// Teardrop map marker: coloured disc with the category symbol and a small pointer.
struct MapPin: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 46

    var body: some View {
        VStack(spacing: -4) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(LinearGradient(colors: [color.opacity(0.9), color], startPoint: .top, endPoint: .bottom)))
                .overlay(Circle().strokeBorder(.white, lineWidth: 3))
            Triangle()
                .fill(.white)
                .frame(width: 14, height: 9)
        }
        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 4)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

struct SimulatedUserDot: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(Theme.info.opacity(0.25)).frame(width: 40, height: 40)
                .scaleEffect(pulse ? 1 : 0.5)
                .opacity(pulse ? 0 : 1)
            Circle().fill(Theme.info).frame(width: 18, height: 18)
                .overlay(Circle().stroke(.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.2), radius: 3)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

// MARK: - Zoom navigation (iOS 18+)

extension View {
    @ViewBuilder
    func zoomSource(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(id: id, in: namespace) { $0.clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)) }
        } else {
            self
        }
    }

    @ViewBuilder
    func zoomTransition(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}

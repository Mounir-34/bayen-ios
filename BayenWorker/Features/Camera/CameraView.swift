import SwiftData
import SwiftUI

/// Live-only camera with GPS/accuracy/distance overlay. No photo-library access exists in the app.
struct CameraView: View {
    let task: WorkerTask

    @Environment(\.dismiss) private var dismiss
    @Environment(LocationService.self) private var location
    @Environment(UploadManager.self) private var uploads
    @State private var model: CameraViewModel
    @Query private var photos: [PendingPhoto]

    init(task: WorkerTask, initialKind: PhotoKind) {
        self.task = task
        _model = State(initialValue: CameraViewModel(task: task, kind: initialKind))
        let taskId = task.id
        _photos = Query(filter: #Predicate<PendingPhoto> { $0.taskId == taskId && !$0.markedForDeletion },
                        sort: \PendingPhoto.capturedAt)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            preview
            // Short white flash on capture.
            Color.white.opacity(model.isCapturing ? 0.35 : 0).ignoresSafeArea().allowsHitTesting(false)
                .animation(.easeOut(duration: 0.2), value: model.isCapturing)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                hud(now: context.date)
            }
        }
        .statusBarHidden()
        .task { await model.appear(location: location) }
        .onDisappear { model.disappear(location: location) }
    }

    @ViewBuilder
    private var preview: some View {
        if model.cameraAuthorized == false {
            StateScreen(systemImage: "camera.fill", color: Theme.danger,
                        title: L10n.tr("camera.denied.title"), message: L10n.tr("camera.denied.message")) {
                BigButton(title: L10n.tr("common.openSettings"), systemImage: "gear") { AppSettings.open() }
                BigButton(title: L10n.tr("common.close"), systemImage: "xmark", style: .secondary) { dismiss() }
            }
        } else if model.camera.hasCamera {
            CameraPreview(session: model.camera.session).ignoresSafeArea()
        } else {
            // Simulator: no camera hardware.
            VStack(spacing: 12) {
                Image(systemName: "camera.metering.unknown").font(.system(size: 60))
                Text(L10n.tr("camera.simulator")).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white.opacity(0.8))
            .padding()
        }
    }

    @ViewBuilder
    private func hud(now: Date) -> some View {
        let gps = model.gpsState(location: location, now: now)
        VStack(spacing: 12) {
            topBar(gps: gps)
            warnings(gps: gps)
            Spacer()
            if let error = model.errorMessage {
                NoticeBanner(kind: .danger, title: error).padding(.horizontal)
            }
            bottomBar(now: now)
        }
        .environment(\.colorScheme, .dark)
    }

    private func topBar(gps: CameraViewModel.GPSState) -> some View {
        VStack(spacing: 12) {
            HStack {
                Button { dismiss() } label: {
                    Label(L10n.tr("common.close"), systemImage: "xmark")
                        .font(.headline)
                        .padding(.horizontal, 14).frame(minHeight: 44)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                GPSChip(state: gps)
            }
            // BEFORE / AFTER toggle
            HStack(spacing: 0) {
                ForEach(PhotoKind.allCases, id: \.self) { kind in
                    Button { model.kind = kind } label: {
                        Text(kind.label)
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(model.kind == kind ? Theme.onPrimary : .white)
                            .background(model.kind == kind ? Theme.primary : .clear, in: Capsule())
                    }
                    .accessibilityAddTraits(model.kind == kind ? .isSelected : [])
                }
            }
            .padding(4)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func warnings(gps: CameraViewModel.GPSState) -> some View {
        VStack(spacing: 8) {
            switch gps {
            case .denied:
                NoticeBanner(kind: .danger, title: L10n.tr("location.denied.title"), message: L10n.tr("camera.location.blocked"),
                             systemImage: "location.slash.fill")
                Button(L10n.tr("common.openSettings")) { AppSettings.open() }.buttonStyle(.borderedProminent)
            case let .searching(secondsLeft):
                NoticeBanner(kind: .info, title: L10n.tr("camera.gps.searching"),
                             message: L10n.tr("camera.gps.searching.detail", secondsLeft), systemImage: "location.magnifyingglass")
            case let .weak(accuracy):
                NoticeBanner(kind: .warning, title: L10n.tr("camera.gps.weak", Geo.formatDistance(accuracy)),
                             message: L10n.tr("camera.gps.weak.detail"), systemImage: "location.slash")
            case .good:
                EmptyView()
            }
            if gps != .denied, model.isOutsideRadius(location: location), let d = model.distanceToTask(location: location) {
                NoticeBanner(kind: .warning, title: L10n.tr("camera.outside", Geo.formatDistance(d)),
                             message: L10n.tr("camera.outside.detail", Geo.formatDistance(Double(task.radiusMeters))),
                             systemImage: "mappin.slash")
            }
        }
        .padding(.horizontal)
    }

    private func bottomBar(now: Date) -> some View {
        VStack(spacing: 14) {
            if !photos.isEmpty {
                LocalPhotoStrip(photos: photos, allowsDelete: true, thumbSize: 72)
                    .padding(.horizontal)
            }
            HStack {
                // Count of photos taken
                VStack {
                    Text(verbatim: "\(photos.count)").font(.title.weight(.bold))
                    Text(L10n.tr("camera.count")).font(.caption)
                }
                .frame(width: 90)
                .accessibilityElement(children: .combine)

                Spacer()
                ShutterButton(enabled: model.canCapture(location: location, now: now), isBusy: model.isCapturing) {
                    Task { await model.capture(location: location, uploads: uploads) }
                }
                Spacer()

                Button { dismiss() } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill").font(.title)
                        Text(L10n.tr("camera.done")).font(.caption.weight(.semibold))
                    }
                    .frame(width: 90, height: 64)
                }
                .accessibilityLabel(L10n.tr("camera.done"))
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .padding(.top, 12)
        .foregroundStyle(.white)
        .background(.black.opacity(0.55))
    }
}

private struct ShutterButton: View {
    let enabled: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white, lineWidth: 5).frame(width: 84, height: 84)
                Circle().fill(enabled ? Color.white : Color.gray).frame(width: 68, height: 68)
                if isBusy { ProgressView().tint(.black) }
            }
        }
        .disabled(!enabled || isBusy)
        .accessibilityLabel(L10n.tr("camera.shutter"))
        .accessibilityHint(enabled ? "" : L10n.tr("camera.shutter.disabledHint"))
    }
}

private struct GPSChip: View {
    let state: CameraViewModel.GPSState

    private var text: String {
        switch state {
        case .denied: return L10n.tr("camera.gps.off")
        case .searching: return L10n.tr("camera.gps.chip.searching")
        case let .good(accuracy), let .weak(accuracy): return L10n.tr("camera.gps.chip", Geo.formatDistance(accuracy))
        }
    }

    private var color: Color {
        switch state {
        case .denied: return .red
        case .searching, .weak: return .orange
        case .good: return .green
        }
    }

    var body: some View {
        Label {
            Text(text).font(.subheadline.weight(.bold))
        } icon: {
            Image(systemName: "location.fill").foregroundStyle(color)
        }
        .padding(.horizontal, 12).frame(minHeight: 44)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

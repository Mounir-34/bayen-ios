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
    /// Demo only: the scene in the "viewfinder", fixed for this camera session (the street doesn't change mid-visit).
    @State private var demoScene: UIImage?

    init(task: WorkerTask, initialKind: PhotoKind) {
        self.task = task
        _model = State(initialValue: CameraViewModel(task: task, kind: initialKind))
        _demoScene = State(initialValue: DemoMode.previewImage(for: initialKind))
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
        } else if let demoScene {
            // In an overlay so the filled image can't widen the HUD's layout.
            Color.black
                .overlay { Image(uiImage: demoScene).resizable().scaledToFill() }
                .clipped()
                .ignoresSafeArea()
        } else {
            // Simulator: no camera hardware.
            VStack(spacing: 14) {
                Image(systemName: "camera.aperture").font(.system(size: 56, weight: .light))
                Text(L10n.tr("camera.simulator")).font(.subheadline).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white.opacity(0.6))
            .padding(40)
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
                NoticeBanner(kind: .danger, title: error)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous))
                    .padding(.horizontal)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            bottomBar(now: now)
        }
        .animation(Motion.spring, value: gps)
        .animation(Motion.spring, value: model.errorMessage)
        .environment(\.colorScheme, .dark)
    }

    private func topBar(gps: CameraViewModel.GPSState) -> some View {
        VStack(spacing: 14) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 46, height: 46)
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle(scale: 0.9))
                .glass(in: Circle(), interactive: true)
                .accessibilityLabel(L10n.tr("common.close"))
                Spacer()
                GPSChip(state: gps)
            }
            KindSwitch(selection: $model.kind)
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
                HUDNotice(color: Theme.danger, systemImage: "location.slash.fill",
                          title: L10n.tr("location.denied.title"), message: L10n.tr("camera.location.blocked"))
                Button(L10n.tr("common.openSettings")) { AppSettings.open() }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18).frame(minHeight: 44)
                    .glass(in: Capsule(), interactive: true)
            case let .searching(secondsLeft):
                HUDNotice(color: Theme.info, systemImage: "location.magnifyingglass",
                          title: L10n.tr("camera.gps.searching"), message: L10n.tr("camera.gps.searching.detail", secondsLeft))
            case let .weak(accuracy):
                HUDNotice(color: Theme.warning, systemImage: "location.slash",
                          title: L10n.tr("camera.gps.weak", Geo.formatDistance(accuracy)), message: L10n.tr("camera.gps.weak.detail"))
            case .good:
                EmptyView()
            }
            if gps != .denied, model.isOutsideRadius(location: location), let d = model.distanceToTask(location: location) {
                HUDNotice(color: Theme.warning, systemImage: "mappin.slash",
                          title: L10n.tr("camera.outside", Geo.formatDistance(d)),
                          message: L10n.tr("camera.outside.detail", Geo.formatDistance(Double(task.radiusMeters))))
            }
        }
        .padding(.horizontal)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func bottomBar(now: Date) -> some View {
        VStack(spacing: 18) {
            if !photos.isEmpty {
                LocalPhotoStrip(photos: photos, allowsDelete: true, thumbSize: 68)
                    .padding(.horizontal)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack {
                // Count of photos taken
                VStack(spacing: 2) {
                    Text(verbatim: "\(photos.count)")
                        .font(.system(.title, design: .rounded, weight: .bold).monospacedDigit())
                        .contentTransition(.numericText())
                    Text(L10n.tr("camera.count"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(width: 90)
                .accessibilityElement(children: .combine)

                Spacer()
                ShutterButton(enabled: model.canCapture(location: location, now: now), isBusy: model.isCapturing) {
                    Task { await model.capture(location: location, uploads: uploads) }
                }
                Spacer()

                Button { dismiss() } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(photos.isEmpty ? .white : Theme.onPrimary)
                            .frame(width: 52, height: 52)
                            .background {
                                if !photos.isEmpty { Circle().fill(.white) }
                            }
                            .glass(in: Circle())
                        Text(L10n.tr("camera.done"))
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(width: 90)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 0.92))
                .accessibilityLabel(L10n.tr("camera.done"))
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .padding(.top, 18)
        .foregroundStyle(.white)
        .background {
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.55), .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .animation(Motion.spring, value: photos.count)
        .sensoryFeedback(.impact(weight: .medium), trigger: photos.count) { old, new in new > old }
    }
}

/// Glass "Before / After" switch with a sliding selection.
private struct KindSwitch: View {
    @Binding var selection: PhotoKind
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PhotoKind.allCases, id: \.self) { kind in
                let isSelected = selection == kind
                Button {
                    withAnimation(Motion.snappy) { selection = kind }
                } label: {
                    Text(kind.label)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(isSelected ? Color.black : .white)
                        .background {
                            if isSelected {
                                Capsule().fill(.white).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .glass(in: Capsule())
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Compact dark-glass notice for the camera HUD.
private struct HUDNotice: View {
    let color: Color
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.2), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.footnote).foregroundStyle(.white.opacity(0.75))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
        .padding(12)
        .glass(in: RoundedRectangle(cornerRadius: Theme.innerRadius + 2, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct ShutterButton: View {
    let enabled: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(.white.opacity(enabled ? 1 : 0.4), lineWidth: 4).frame(width: 84, height: 84)
                Circle().fill(enabled ? Color.white : Color.white.opacity(0.25)).frame(width: 68, height: 68)
                if isBusy { ProgressView().tint(.black) }
            }
            .contentShape(Circle())
        }
        .buttonStyle(ShutterStyle())
        .disabled(!enabled || isBusy)
        .animation(Motion.snappy, value: enabled)
        .accessibilityLabel(L10n.tr("camera.shutter"))
        .accessibilityHint(enabled ? "" : L10n.tr("camera.shutter.disabledHint"))
    }
}

private struct ShutterStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .heavy, intensity: 0.8), trigger: configuration.isPressed) { _, pressed in pressed }
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
        case .denied: return Theme.danger
        case .searching, .weak: return Theme.warning
        case .good: return Theme.success
        }
    }

    private var isGood: Bool { if case .good = state { return true } else { return false } }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(color.opacity(0.35)).frame(width: 16, height: 16)
                    .phaseAnimator([false, true]) { view, phase in
                        view.scaleEffect(phase ? 1.4 : 0.8).opacity(phase ? 0 : 1)
                    } animation: { _ in .easeOut(duration: 1.4) }
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(text)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 14).frame(minHeight: 46)
        .glass(in: Capsule())
        .animation(Motion.snappy, value: isGood)
        .accessibilityElement(children: .combine)
    }
}

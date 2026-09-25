import CoreLocation
import Foundation
import Observation

/// Location for the whole app: "When In Use" permission only.
///
/// * Real devices: `CLLocationUpdate.liveUpdates()` (iOS 17) while at least one screen needs it.
/// * Mock mode: a simulated GPS near the task, whose accuracy improves over a few seconds like a real fix.
@MainActor
@Observable
final class LocationService {
    /// Accuracy (m) considered good enough for a proof photo — same threshold as the server's LOW_GPS_ACCURACY flag.
    static let goodAccuracy: Double = 50
    /// How long we wait for a good fix before allowing capture with a warning.
    static let fixTimeout: TimeInterval = 20

    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var location: CLLocation?
    private(set) var isUpdating = false

    let isSimulated: Bool
    /// Mock only: when true, the simulated worker "walks" to each opened task.
    var simulateAtTask = true

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let delegate = AuthorizationDelegate()
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var consumers = 0
    @ObservationIgnored private var simulatedTarget = MockAPIClient.center

    init(simulated: Bool) {
        isSimulated = simulated
        authorization = simulated ? .authorizedWhenInUse : manager.authorizationStatus
        manager.delegate = delegate
        manager.desiredAccuracy = kCLLocationAccuracyBest
        delegate.onChange = { [weak self] status in
            Task { @MainActor in self?.authorization = status }
        }
    }

    var isAuthorized: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
    var isDenied: Bool { authorization == .denied || authorization == .restricted }
    var needsPermissionRequest: Bool { authorization == .notDetermined }

    func requestPermission() {
        guard !isSimulated, authorization == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    /// Reference-counted: every `start()` must be balanced by a `stop()`.
    func start() {
        consumers += 1
        guard updatesTask == nil else { return }
        requestPermission()
        isUpdating = true
        if isSimulated {
            updatesTask = Task { [weak self] in await self?.runSimulation() }
        } else {
            updatesTask = Task { [weak self] in
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if Task.isCancelled { break }
                        if let loc = update.location, loc.horizontalAccuracy >= 0 {
                            self?.location = loc
                        }
                    }
                } catch {
                    // Updates end on cancellation or when authorisation is revoked.
                }
            }
        }
    }

    func stop() {
        consumers = max(0, consumers - 1)
        guard consumers == 0 else { return }
        updatesTask?.cancel()
        updatesTask = nil
        isUpdating = false
    }

    /// Waits until a location with accuracy ≤ `maxAccuracy` arrives or `timeout` elapses; returns the best
    /// location seen (possibly less accurate), or nil if there is none at all.
    func waitForFix(maxAccuracy: Double = LocationService.goodAccuracy,
                    timeout: TimeInterval = LocationService.fixTimeout) async -> CLLocation? {
        start()
        defer { stop() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let loc = location, loc.horizontalAccuracy <= maxAccuracy, abs(loc.timestamp.timeIntervalSinceNow) < 30 {
                return loc
            }
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return location
    }

    // MARK: - Simulation (mock mode)

    /// Mock only: moves the simulated worker close to `coordinate` (a new fix then starts coarse and improves).
    func simulateArrival(at coordinate: CLLocationCoordinate2D) {
        guard isSimulated, simulateAtTask else { return }
        simulatedTarget = coordinate
        simulationStep = 0
    }

    @ObservationIgnored private var simulationStep = 0

    private func runSimulation() async {
        let accuracies: [Double] = [140, 90, 60, 38, 22, 14, 9]
        while !Task.isCancelled {
            let accuracy = accuracies[min(simulationStep, accuracies.count - 1)] + Double.random(in: -2...2)
            simulationStep += 1
            // ≈ 1e-5° ≈ 1.1 m. Jitter shrinks with accuracy; stays ~10 m from the target.
            let jitter = accuracy / 4 / 111_000
            let coordinate = CLLocationCoordinate2D(
                latitude: simulatedTarget.latitude + 0.00006 + Double.random(in: -jitter...jitter),
                longitude: simulatedTarget.longitude + 0.00005 + Double.random(in: -jitter...jitter))
            location = CLLocation(coordinate: coordinate, altitude: 42 + Double.random(in: -1...1),
                                  horizontalAccuracy: max(5, accuracy), verticalAccuracy: 8, timestamp: Date())
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
    }
}

private final class AuthorizationDelegate: NSObject, CLLocationManagerDelegate {
    var onChange: ((CLAuthorizationStatus) -> Void)?

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onChange?(manager.authorizationStatus)
    }
}

extension CLLocation {
    /// `true` when iOS reports the location as produced by a simulator/spoofing tool.
    var isSimulatedBySoftware: Bool {
        sourceInformation?.isSimulatedBySoftware ?? false
    }
}

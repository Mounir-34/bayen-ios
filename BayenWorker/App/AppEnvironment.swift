import Foundation
import Observation
import SwiftData

/// Composition root: builds and owns every long-lived service.
@MainActor
@Observable
final class AppEnvironment {
    let config: AppConfig
    let api: APIClient
    let session: SessionStore
    let language: LanguageManager
    let location: LocationService
    let network: NetworkMonitor
    let uploads: UploadManager
    let push: PushService
    let tasks: TaskStore
    let router: TaskRouter
    let modelContainer: ModelContainer
    @ObservationIgnored let backgroundTransport: BackgroundUploadTransport?

    /// Created once at launch (also when iOS relaunches the app in the background for finished uploads).
    static let shared = AppEnvironment(config: .current)

    init(config: AppConfig) {
        let languageManager = LanguageManager.shared

        let container: ModelContainer
        do {
            container = try QueueStore.makeContainer(inMemory: AppConfig.isRunningTests)
        } catch {
            // Should never happen; fall back to memory so the app still opens.
            print("SwiftData store failed: \(error)")
            container = try! QueueStore.makeContainer(inMemory: true)
        }
        let networkMonitor = NetworkMonitor()

        let apiClient: APIClient
        let transport: PhotoUploadTransport
        let background: BackgroundUploadTransport?
        let locationService: LocationService
        switch config.mode {
        case .mock:
            let mock = MockAPIClient(tokenStore: KeychainTokenStore(service: "ma.bayen.worker.mock.tokens"),
                                     photoUploadFailureRate: 0.25, latency: 0.5)
            apiClient = mock
            transport = DirectUploadTransport(api: mock)
            background = nil
            locationService = LocationService(simulated: true)
        case .live:
            let http = HTTPAPIClient(baseURL: config.baseURL, tokenStore: KeychainTokenStore(),
                                     language: { languageManager.language.rawValue })
            apiClient = http
            if config.usesBackgroundUploads {
                let bg = BackgroundUploadTransport(api: http)
                transport = bg
                background = bg
            } else {
                // Dev server over plain HTTP / Simulator: upload from the app process itself.
                transport = DirectUploadTransport(api: http)
                background = nil
            }
            locationService = LocationService(simulated: false)
        }

        UploadLog.info("config: mode=\(config.mode) baseURL=\(config.baseURL) backgroundUploads=\(config.usesBackgroundUploads)")

        let sessionStore = SessionStore(api: apiClient, language: languageManager)
        let uploadManager = UploadManager(container: container, api: apiClient, transport: transport, network: networkMonitor)
        let pushService = PushService(api: apiClient)
        let taskStore = TaskStore(api: apiClient, uploads: uploadManager)
        let taskRouter = TaskRouter()

        networkMonitor.onReconnect = {
            uploadManager.kick()
            Task { await taskStore.refresh() }
        }
        uploadManager.onTaskSubmitted = { taskId in
            taskStore.markSubmitted(taskId)
            Task { await taskStore.refresh() }
        }
        pushService.onOpenTask = { taskId in
            taskRouter.path = [.detail(taskId: taskId)]
        }
        sessionStore.onLogin = {
            uploadManager.kick()
            Task {
                await taskStore.refresh()
                await pushService.requestAuthorizationAndRegister()
            }
        }

        self.config = config
        self.language = languageManager
        self.modelContainer = container
        self.network = networkMonitor
        self.api = apiClient
        self.backgroundTransport = background
        self.location = locationService
        self.session = sessionStore
        self.uploads = uploadManager
        self.push = pushService
        self.tasks = taskStore
        self.router = taskRouter
    }
}

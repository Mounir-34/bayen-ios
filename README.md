# Bayen Worker — iOS app

Native SwiftUI app for workers doing small municipal jobs. They see their assigned tasks, navigate to them, and prove the work with **live photos stamped with GPS position and time**. The photos go to the Bayen API (`server/`) and admins review them in the dashboard (`dashboard/`).

- Swift 5.10+, SwiftUI, **iOS 17+**, MVVM with `@Observable`, async/await
- No third-party dependencies: URLSession, AVFoundation, CoreLocation, MapKit, SwiftData, Network, Security (Keychain)
- Arabic (default, RTL), French and English, using String Catalogs. The language can be switched inside the app.
- Offline-first: everything the worker captures is saved on the phone first, then uploaded in the background with retries.

## Run it

| Scheme | Configuration | Backend | Use it for |
|---|---|---|---|
| **BayenWorker Mock** | `Mock` | In-memory `MockAPIClient` + simulated GPS in Aïn Sebaâ, Casablanca | Running the whole app in the simulator with no server |
| **BayenWorker Debug** | `Debug` | `http://localhost:3000/api/v1` | Working against the local server (`cd server && npm run dev`) |
| **BayenWorker Release** | `Release` | `https://api.bayen.ma/api/v1` | TestFlight / App Store |

1. Open `BayenWorker.xcodeproj` in **Xcode 16 or newer**. The project uses folder-synchronised groups, so files you add under `BayenWorker/` or `BayenWorkerTests/` are picked up automatically.
2. Pick a scheme and an iPhone simulator, then press Run.
3. Set your Team under *Signing & Capabilities* before running on a real device.

### Demo accounts (Mock scheme)

The password is `Bayen2026!` for every account (the same as `server/prisma/seed.ts`).

| Phone | Result |
|---|---|
| `6 00 00 00 02` | Active worker (Arabic) with 6 tasks in every state |
| `6 00 00 00 03` | Active worker (French) |
| `6 00 00 00 04` | "Waiting for approval" screen |
| `6 00 00 00 05` | "Account suspended" screen |

For registration, use the municipality code `CASA-AINSEBAA`. A newly registered mock account is approved automatically after 15 seconds, so you can try the **Refresh** button on the pending screen.

In Mock mode, 25 % of photo uploads fail on purpose so you can watch the retry queue work. The simulator has no camera, so the shutter produces a generated test photo. Under *Profile → Demo mode* you can turn off "Simulate being at the task" to see the distance warnings.

### Point the app at a server

The base URL comes from `Config/<Configuration>.xcconfig` and reaches the app through `Info.plist` (`BayenAPIBaseURL`):

```xcconfig
// Config/Debug.xcconfig
API_BASE_URL = http:/$()/192.168.1.20:3000/api/v1   // "//" starts a comment in xcconfig, hence $()
```

- **Simulator:** `localhost` works as it is.
- **Real device:** use your Mac's LAN IP. `NSAllowsLocalNetworking` already allows plain HTTP to local addresses. Anything else needs HTTPS.
- **Without rebuilding:** add the environment variables `BAYEN_API_BASE_URL` and/or `BAYEN_API_MODE=mock|live` under *Scheme → Run → Arguments*. They override the build settings.
- **Photo uploads:** background `URLSession` uploads are only used for HTTPS on a real device. Against a plain-HTTP dev server (or in the Simulator) photos upload from the app process instead, because the system upload daemon can't reach it and silently waits forever. Force either with `BAYEN_UPLOAD_MODE=background|foreground`.

## Architecture

```
BayenWorker/
├── App/                      entry point, AppDelegate (background URLSession events, APNs), composition root
│   ├── BayenWorkerApp.swift
│   ├── AppEnvironment.swift  builds every service once (live or mock)
│   └── RootView.swift        switches on SessionStore.state
├── Core/
│   ├── Models/               Codable DTOs mirroring server/src/api/schemas.ts (unknown enum values tolerated)
│   ├── Networking/           APIClient protocol, HTTPAPIClient, MockAPIClient, APIError, JSON coders, multipart
│   ├── Auth/                 Keychain token store, TokenRefresher (single in-flight refresh), SessionStore
│   ├── Location/             LocationService (CLLocationUpdate.liveUpdates, simulated GPS), Geo (haversine)
│   ├── Camera/               AVFoundation CameraService, PhotoProcessor (resize + EXIF/GPS)
│   ├── Persistence/          SwiftData models for the queue, PhotoFileStore (Application Support)
│   ├── Upload/               UploadManager, background/direct transports, RetryPolicy, NetworkMonitor
│   ├── Push/                 PushService stub (phase 2)
│   ├── Localization/         LanguageManager + L10n (in-app language, String Catalog lookup)
│   └── Design/               Theme (logo navy), big buttons, banners, badges
├── Features/
│   ├── Auth/                 Login, Register, Pending approval, Suspended
│   ├── Tasks/                TaskStore (cached list), list + map
│   ├── TaskDetail/           detail, map with radius, Open in Maps, primary action
│   ├── Camera/               live camera with GPS/accuracy/distance overlay
│   ├── Submit/               review + "I'm done"
│   └── Profile/
└── Resources/                Assets, Localizable.xcstrings, InfoPlist.xcstrings
```

**MVVM.** Each screen has an `@Observable` view model (for example `TaskDetailViewModel` or `CameraViewModel`). App-wide services are also `@Observable` and are injected with `.environment(...)`: `SessionStore`, `TaskStore`, `UploadManager`, `LocationService`, `NetworkMonitor` and `LanguageManager`.

**API layer.** Views and view models only see the `APIClient` protocol. `HTTPAPIClient` adds the bearer token. When a request gets a `401`, it asks `TokenRefresher` (an actor) to refresh. The actor lets only one `POST /auth/refresh` run at a time, which matters because refresh tokens are single-use and re-using one revokes the whole family. The original request is then retried once. Error bodies `{ error: { code, message } }` become `APIError.server`, and `code` maps to a localised `error.<CODE>` string. `ACCOUNT_PENDING` and `ACCOUNT_SUSPENDED` switch the whole app to the matching screen.

**Photos are live-only.** The app never touches the photo library: there is no picker and no `NSPhotoLibraryUsageDescription`. For each shot the app records:

- `capturedAt`, latitude, longitude, `horizontalAccuracy` and altitude
- `isSimulatedLocation` (from `CLLocation.sourceInformation.isSimulatedBySoftware`)
- device model, iOS version, app version and a UUID `clientPhotoId`

`PhotoProcessor` shrinks the JPEG to 2500 px on the long edge at quality 0.8. It keeps the camera's EXIF and writes the GPS and time into EXIF too.

**Location.** The app asks for When-In-Use permission only. While the camera is open it waits for a fix of 50 m accuracy or better (the same threshold as the server's `LOW_GPS_ACCURACY` flag). After 20 s it allows the capture anyway, with a warning. It also warns when the worker is outside the task's radius. If permission is denied, capture is blocked and the screen points to Settings. Distances use the same haversine formula and Earth radius as `server/src/lib/geo.ts`.

**Offline queue (`UploadManager`).**

1. When a photo is captured, the JPEG is written to `Application Support/Bayen/Photos` (excluded from backup) and a `PendingPhoto` row is saved in SwiftData. This happens before any network call.
2. Uploads go through a **background `URLSession`** (`BackgroundUploadTransport`), so they keep going when the app is suspended or closed. iOS relaunches the app to deliver the results. After a relaunch, the transport joins transfers that are still running instead of starting new ones. Retries are safe because the server is idempotent on `clientPhotoId`.
3. On failure the app backs off exponentially (2 s, 4 s, 8 s … up to 5 min, ±20 % jitter). `NWPathMonitor` reconnects and app foregrounding trigger a new pass right away. Non-retryable errors (for example `TASK_NOT_IN_PROGRESS`) wait for a manual retry.
4. "Start task" and "I'm done" are queued too (`PendingTaskStart`, `PendingSubmission`). A task's photos are uploaded only after its start has been sent. A submission is sent only once all of its photos are on the server. If `submit` answers `INVALID_TRANSITION from SUBMITTED`, the app treats it as a success, because the earlier response was probably lost.
5. Each photo shows its status: waiting, uploading, uploaded, retrying or failed. A global banner shows counts such as "3 photos waiting to upload". After a successful submission, the local copies are deleted.

**Localisation.** `L10n.tr("key")` reads `Localizable.xcstrings` for the language chosen in the app, not the device language. The root view is keyed on the language, so switching re-renders every screen immediately with the right direction (RTL for Arabic). Phone numbers and codes are always laid out left-to-right. The camera and location permission texts are in `InfoPlist.xcstrings`. To add a language, add a case to `AppLanguage`, its locale in `L10n.locale`, the region in the project's `knownRegions`, and translations in both catalogs. Arabic plural forms (zero/one/two/few/many/other) are included for the upload counters.

**Accessibility and low-tech users.** Primary buttons are at least 64 pt tall and always have an icon and a label. The app uses Dynamic Type text styles everywhere, VoiceOver labels and announcements (for example "Photo saved"), high-contrast colours in light and dark mode, and very little typing (phone mask, dictation hint for the note).

**Status colours** match the dashboard: assigned is grey, in progress blue, submitted amber, approved green and rejected red. The primary colour is `hsl(158 64% 24%)` in light mode and `hsl(156 55% 42%)` in dark mode.

## Push notifications (phase 2)

`Core/Push/PushService.swift` holds the structure: it asks for permission, registers with APNs, `POST /me/device-token`, and has a deep link hook to open a task. To turn it on:

1. Add the *Push Notifications* capability to the target.
2. Set `PushService.isEnabled = true`.
3. Add the route to the server. It is not implemented there yet.

## Tests

Run them with ⌘U, or:

```sh
xcodebuild test -project BayenWorker.xcodeproj -scheme "BayenWorker Mock" -destination 'platform=iOS Simulator,name=iPhone 15'
```

| Suite | Covers |
|---|---|
| `APIClientDecodingTests` | DTO decoding with and without fractional ISO-8601 dates, unknown enum values, pagination, error envelopes, metadata encoding, multipart body |
| `TokenRefreshTests` | Refreshes and retries once on 401, concurrent 401s share one refresh, a failed refresh logs out, network errors keep the tokens |
| `UploadQueueTests` | Photo saved before upload, backoff timing, same `clientPhotoId` on every retry, server de-duplication, permanent vs. retryable errors, offline then reconnect, submission waits for its photos, queued start sent before photos, remote delete |
| `DistanceTests` and others | Haversine against the server formula and CoreLocation, radius check, formatting, Moroccan phone normalisation, resize + GPS EXIF written into the JPEG |

## Notes and limits

- The user DTO carries only `municipalityId`. The profile shows the municipality code typed at registration, or a short id otherwise. A `GET /me` that includes the municipality name would fix this.
- The rejection reason is fetched from `GET /worker/tasks/:id` for rejected tasks, because the list endpoint does not return it.
- If a different worker logs in on the same phone, photos still queued from the previous account are sent under the new session. The server rejects them (`NOT_FOUND`) and they show as failed.

## Branding

The logo lives in `Resources/Assets.xcassets`:

- `BrandLogo` — full logo (emblem + بيّن / BAYEN), used on the launch and login screens (`BrandMark` view).
- `BrandEmblem` — the pin-and-grid emblem only, used in the task list toolbar, empty state, register, pending/suspended and profile screens (`BrandEmblem` view).
- Both have a dark-mode variant where the navy turns light. `AppIcon` uses the emblem on white, because the wordmark is unreadable at home-screen size.
- `Theme.primary` / `AccentColor` use the logo navy `#1A2C52` (`#84A0DE` in dark mode).

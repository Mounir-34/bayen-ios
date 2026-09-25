import SwiftUI

struct ProfileView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(SessionStore.self) private var session
    @Environment(UploadManager.self) private var uploads
    @Environment(LocationService.self) private var location
    @State private var confirmLogout = false

    var body: some View {
        NavigationStack {
            List {
                if let user = session.user {
                    Section {
                        HStack(spacing: 16) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 56))
                                .foregroundStyle(Theme.primary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(user.fullName).font(.title2.weight(.bold))
                                Text(verbatim: PhoneNumber.display(user.phone))
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                    .environment(\.layoutDirection, .leftToRight)
                            }
                        }
                        .padding(.vertical, 6)
                        row(L10n.tr("profile.municipality"), value: session.municipalityCode ?? String(user.municipalityId.prefix(8)),
                            systemImage: "building.columns.fill")
                        if let cin = user.cin {
                            row(L10n.tr("field.cin"), value: cin, systemImage: "person.text.rectangle.fill")
                        }
                    }
                }

                Section(L10n.tr("field.language")) {
                    LanguagePicker()
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                }

                Section(L10n.tr("profile.uploads")) {
                    row(L10n.tr("profile.uploads.photos"), value: "\(uploads.pendingPhotoCount)", systemImage: "photo.stack")
                    row(L10n.tr("profile.uploads.submissions"), value: "\(uploads.pendingSubmissionTaskIds.count)",
                        systemImage: "tray.and.arrow.up")
                    if uploads.pendingPhotoCount > 0 {
                        Button {
                            uploads.retryAll()
                        } label: {
                            Label(L10n.tr("profile.uploads.retryNow"), systemImage: "arrow.clockwise").font(.headline)
                        }
                    }
                }

                if location.isSimulated {
                    Section(L10n.tr("profile.mock")) {
                        Toggle(L10n.tr("profile.mock.atTask"), isOn: Binding(get: { location.simulateAtTask },
                                                                               set: { location.simulateAtTask = $0 }))
                        Text(L10n.tr("profile.mock.help")).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        confirmLogout = true
                    } label: {
                        Label(L10n.tr("profile.logout"), systemImage: "rectangle.portrait.and.arrow.right")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                } footer: {
                    VStack(spacing: 8) {
                        BrandEmblem(size: 40)
                        Text(verbatim: "Bayen \(DeviceInfo.appVersion)\(env.config.mode == .mock ? " · MOCK" : "")")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                }
            }
            .navigationTitle(L10n.tr("tab.profile"))
            .confirmationDialog(L10n.tr("profile.logout.confirm"), isPresented: $confirmLogout, titleVisibility: .visible) {
                Button(L10n.tr("profile.logout"), role: .destructive) {
                    Task {
                        await session.logout()
                        env.tasks.clear()
                    }
                }
                Button(L10n.tr("common.cancel"), role: .cancel) {}
            } message: {
                if uploads.pendingPhotoCount > 0 || !uploads.pendingSubmissionTaskIds.isEmpty {
                    Text(L10n.tr("profile.logout.pendingWarning"))
                }
            }
        }
    }

    private func row(_ title: String, value: String, systemImage: String) -> some View {
        LabeledContent {
            Text(value).font(.headline)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

import SwiftUI

struct ProfileView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(SessionStore.self) private var session
    @Environment(UploadManager.self) private var uploads
    @Environment(LocationService.self) private var location
    @State private var confirmLogout = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let user = session.user {
                        identityCard(user)
                            .appearAnimation(index: 0)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: L10n.tr("field.language"), systemImage: "globe")
                        LanguagePicker()
                    }
                    .cardStyle(padding: 16)
                    .appearAnimation(index: 1)

                    uploadsCard
                        .appearAnimation(index: 2)

                    if location.isSimulated {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: L10n.tr("profile.mock"), systemImage: "location.viewfinder")
                            Toggle(L10n.tr("profile.mock.atTask"), isOn: Binding(get: { location.simulateAtTask },
                                                                                   set: { location.simulateAtTask = $0 }))
                                .font(.subheadline.weight(.medium))
                                .tint(Theme.success)
                            Text(L10n.tr("profile.mock.help")).font(.footnote).foregroundStyle(Theme.textTertiary)
                        }
                        .cardStyle(padding: 16)
                        .appearAnimation(index: 3)
                    }

                    Button(role: .destructive) {
                        confirmLogout = true
                    } label: {
                        Label(L10n.tr("profile.logout"), systemImage: "rectangle.portrait.and.arrow.right")
                            .font(.headline)
                            .foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity, minHeight: Theme.bigButtonHeight)
                            .background(Theme.danger.opacity(0.09),
                                        in: RoundedRectangle(cornerRadius: Theme.innerRadius + 2, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: Theme.innerRadius + 2, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
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
                    .padding(.top, 4)
                    .appearAnimation(index: 4)

                    VStack(spacing: 8) {
                        BrandEmblem(size: 36).opacity(0.85)
                        Text(verbatim: "Bayen \(DeviceInfo.appVersion)\(env.config.mode == .mock ? " · MOCK" : "")")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                }
                .padding(.horizontal, Theme.screenPadding)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(AmbientBackground(intensity: 0.55))
            .navigationTitle(L10n.tr("tab.profile"))
        }
    }

    private func identityCard(_ user: User) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Monogram(name: user.fullName, size: 68)
                VStack(alignment: .leading, spacing: 4) {
                    Text(user.fullName)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(verbatim: PhoneNumber.display(user.phone))
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .environment(\.layoutDirection, .leftToRight)
                }
                Spacer(minLength: 0)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            VStack(spacing: 4) {
                InfoRow(title: L10n.tr("profile.municipality"),
                        value: session.municipalityCode ?? String(user.municipalityId.prefix(8)),
                        systemImage: "building.columns.fill", forceLTRValue: true)
                if let cin = user.cin {
                    InfoRow(title: L10n.tr("field.cin"), value: cin, systemImage: "person.text.rectangle.fill",
                            forceLTRValue: true)
                }
            }
        }
        .cardStyle(padding: 18)
    }

    private var uploadsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: L10n.tr("profile.uploads"), systemImage: "icloud.and.arrow.up")
            HStack(spacing: 12) {
                statTile(value: uploads.pendingPhotoCount, title: L10n.tr("profile.uploads.photos"), systemImage: "photo.stack")
                statTile(value: uploads.pendingSubmissionTaskIds.count, title: L10n.tr("profile.uploads.submissions"),
                         systemImage: "tray.and.arrow.up")
            }
            if uploads.pendingPhotoCount > 0 {
                BigButton(title: L10n.tr("profile.uploads.retryNow"), systemImage: "arrow.clockwise", style: .tinted) {
                    uploads.retryAll()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .cardStyle(padding: 16)
        .animation(Motion.spring, value: uploads.pendingPhotoCount)
    }

    private func statTile(value: Int, title: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(value > 0 ? Theme.warning : Theme.success)
            Text(verbatim: "\(value)")
                .font(.system(.title, design: .rounded, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText())
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Initials on the brand gradient — a calmer, more personal avatar than a generic person glyph.
struct Monogram: View {
    let name: String
    var size: CGFloat = 64

    private var initials: String {
        let parts = name.split(whereSeparator: \.isWhitespace).prefix(2)
        // The zero-width non-joiner keeps Arabic initials as separate letters instead of shaping them into a word.
        return parts.compactMap(\.first).map { String($0).uppercased() }.joined(separator: "\u{200C}")
    }

    var body: some View {
        Text(verbatim: initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.onPrimary)
            .frame(width: size, height: size)
            .background(Circle().fill(Theme.primaryGradient))
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .background(Circle().fill(Theme.primary.opacity(0.25)).blur(radius: 10).offset(y: 6))
            .accessibilityHidden(true)
    }
}

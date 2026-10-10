import SwiftUI

// MARK: - Choose a new password (first login with a temporary password)

@MainActor
@Observable
final class ChangePasswordViewModel {
    var newPassword = ""
    var confirmation = ""
    var isLoading = false
    var errorMessage: String?

    var canSubmit: Bool { !newPassword.isEmpty && !confirmation.isEmpty && !isLoading }

    /// Local checks, mirroring the server rules (8–128 characters, different from the current password).
    func validationMessage(isTemporaryPassword: (String) -> Bool) -> String? {
        if newPassword.count < PasswordRules.minLength { return L10n.tr("validation.password") }
        if newPassword.count > PasswordRules.maxLength { return L10n.tr("validation.passwordTooLong") }
        if newPassword != confirmation { return L10n.tr("validation.passwordMismatch") }
        if isTemporaryPassword(newPassword) { return L10n.tr("validation.passwordSame") }
        return nil
    }

    func submit(session: SessionStore) async {
        if let message = validationMessage(isTemporaryPassword: session.isTemporaryPassword) {
            errorMessage = message
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await session.changePassword(to: newPassword)
        } catch {
            errorMessage = APIError.from(error).localizedMessage
        }
    }
}

/// Blocking screen shown instead of the main app while `user.mustChangePassword` is true.
struct ChangePasswordView: View {
    @Environment(SessionStore.self) private var session
    @State private var model = ChangePasswordViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                BrandEmblem(size: 52)
                    .padding(.top, 28)
                    .appearAnimation(index: 0)

                VStack(spacing: 10) {
                    Text(L10n.tr("changePassword.title"))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                    Text(L10n.tr("changePassword.message"))
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, 20)
                .padding(.horizontal, 12)
                .appearAnimation(index: 1)

                VStack(spacing: 18) {
                    PasswordField(title: L10n.tr("field.newPassword"), password: $model.newPassword, isNew: true)
                    PasswordField(title: L10n.tr("field.confirmPassword"), password: $model.confirmation, isNew: true)
                    if let error = model.errorMessage {
                        NoticeBanner(kind: .danger, title: error)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .cardStyle(padding: 18)
                .padding(.top, 28)
                .appearAnimation(index: 2)

                VStack(spacing: 12) {
                    BigButton(title: L10n.tr("changePassword.button"), systemImage: "checkmark", isLoading: model.isLoading) {
                        Task { await model.submit(session: session) }
                    }
                    .disabled(!model.canSubmit)

                    BigButton(title: L10n.tr("profile.logout"), systemImage: "rectangle.portrait.and.arrow.right", style: .secondary) {
                        Task { await session.logout() }
                    }
                    .disabled(model.isLoading)
                }
                .padding(.top, 24)
                .appearAnimation(index: 3)
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.bottom, 32)
            .animation(Motion.spring, value: model.errorMessage)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AmbientBackground())
        .sensoryFeedback(.error, trigger: model.errorMessage) { _, new in new != nil }
    }
}

import SwiftUI

struct AuthFlowView: View {
    @State private var showRegister = false

    var body: some View {
        NavigationStack {
            LoginView(onRegister: { showRegister = true })
                .navigationDestination(isPresented: $showRegister) { RegisterView() }
        }
    }
}

// MARK: - Login

@MainActor
@Observable
final class LoginViewModel {
    var phoneDigits = ""
    var password = ""
    var isLoading = false
    var errorMessage: String?

    var canSubmit: Bool { PhoneNumber.e164(fromNational: phoneDigits) != nil && !password.isEmpty && !isLoading }

    func login(session: SessionStore) async {
        guard let phone = PhoneNumber.e164(fromNational: phoneDigits) else {
            errorMessage = L10n.tr("validation.phone")
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await session.login(phone: phone, password: password)
        } catch {
            errorMessage = APIError.from(error).localizedMessage
        }
    }
}

struct LoginView: View {
    let onRegister: () -> Void
    @Environment(SessionStore.self) private var session
    @State private var model = LoginViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                LanguagePicker()
                    .padding(.top, 8)
                    .appearAnimation(index: 0)

                BrandMark(height: 150)
                    .padding(.top, 36)
                    .appearAnimation(index: 1)

                Text(L10n.tr("login.subtitle"))
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 20)
                    .padding(.horizontal, 12)
                    .appearAnimation(index: 2)

                VStack(spacing: 18) {
                    PhoneField(nationalDigits: $model.phoneDigits)
                    PasswordField(title: L10n.tr("field.password"), password: $model.password)
                    if let error = model.errorMessage {
                        NoticeBanner(kind: .danger, title: error)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .cardStyle(padding: 18)
                .padding(.top, 32)
                .appearAnimation(index: 3)

                VStack(spacing: 12) {
                    BigButton(title: L10n.tr("login.button"), systemImage: "arrow.forward", isLoading: model.isLoading) {
                        Task { await model.login(session: session) }
                    }
                    .disabled(!model.canSubmit)

                    BigButton(title: L10n.tr("login.register"), systemImage: "person.badge.plus", style: .secondary,
                              action: onRegister)
                }
                .padding(.top, 24)
                .appearAnimation(index: 4)
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.bottom, 32)
            .animation(Motion.spring, value: model.errorMessage)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AmbientBackground())
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.error, trigger: model.errorMessage) { _, new in new != nil }
    }
}

// MARK: - Register

@MainActor
@Observable
final class RegisterViewModel {
    var fullName = ""
    var phoneDigits = ""
    var password = ""
    var municipalityCode = ""
    var cin = ""
    var isLoading = false
    var errorMessage: String?

    var validationMessage: String? {
        if fullName.trimmingCharacters(in: .whitespaces).count < 2 { return L10n.tr("validation.name") }
        if PhoneNumber.e164(fromNational: phoneDigits) == nil { return L10n.tr("validation.phone") }
        if password.count < 8 { return L10n.tr("validation.password") }
        if municipalityCode.trimmingCharacters(in: .whitespaces).count < 2 { return L10n.tr("validation.municipality") }
        let cinTrimmed = cin.trimmingCharacters(in: .whitespaces)
        if !cinTrimmed.isEmpty, !(4...20).contains(cinTrimmed.count) { return L10n.tr("validation.cin") }
        return nil
    }

    func register(session: SessionStore, language: AppLanguage) async {
        if let validationMessage {
            errorMessage = validationMessage
            return
        }
        guard let phone = PhoneNumber.e164(fromNational: phoneDigits) else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let cinTrimmed = cin.trimmingCharacters(in: .whitespaces)
        let request = RegisterRequest(fullName: fullName.trimmingCharacters(in: .whitespaces), phone: phone, password: password,
                                      municipalityCode: municipalityCode.trimmingCharacters(in: .whitespaces).uppercased(),
                                      cin: cinTrimmed.isEmpty ? nil : cinTrimmed.uppercased(), preferredLanguage: language)
        do {
            try await session.register(request)
        } catch {
            errorMessage = APIError.from(error).localizedMessage
        }
    }
}

struct RegisterView: View {
    @Environment(SessionStore.self) private var session
    @Environment(LanguageManager.self) private var language
    @State private var model = RegisterViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    BrandEmblem(size: 52)
                    Text(L10n.tr("register.intro"))
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .appearAnimation(index: 0)

                VStack(alignment: .leading, spacing: 18) {
                    LabeledField(title: L10n.tr("field.fullName"), systemImage: "person") {
                        TextField(L10n.tr("field.fullName"), text: $model.fullName)
                            .textContentType(.name)
                    }
                    PhoneField(nationalDigits: $model.phoneDigits)
                    PasswordField(title: L10n.tr("field.newPassword"), password: $model.password, isNew: true)
                }
                .cardStyle(padding: 18)
                .appearAnimation(index: 1)

                VStack(alignment: .leading, spacing: 18) {
                    LabeledField(title: L10n.tr("field.municipalityCode"), systemImage: "building.columns") {
                        TextField(text: $model.municipalityCode) { Text(verbatim: "CASA-AINSEBAA") }
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .environment(\.layoutDirection, .leftToRight)
                    }
                    LabeledField(title: L10n.tr("field.cin"), systemImage: "person.text.rectangle") {
                        TextField(text: $model.cin) { Text(verbatim: "BE123456") }
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
                .cardStyle(padding: 18)
                .appearAnimation(index: 2)

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: L10n.tr("field.language"), systemImage: "globe")
                    LanguagePicker()
                }
                .appearAnimation(index: 3)

                if let error = model.errorMessage {
                    NoticeBanner(kind: .danger, title: error)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                BigButton(title: L10n.tr("register.button"), systemImage: "checkmark", isLoading: model.isLoading) {
                    Task { await model.register(session: session, language: language.language) }
                }
                .appearAnimation(index: 4)
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.vertical, 12)
            .animation(Motion.spring, value: model.errorMessage)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AmbientBackground(intensity: 0.6))
        .navigationTitle(L10n.tr("register.title"))
        .navigationBarTitleDisplayMode(.large)
        .sensoryFeedback(.error, trigger: model.errorMessage) { _, new in new != nil }
    }
}

// MARK: - Account states

struct PendingApprovalView: View {
    let phone: String
    @Environment(SessionStore.self) private var session
    @State private var isChecking = false
    @State private var message: String?

    var body: some View {
        StateScreen(systemImage: "hourglass", color: Theme.warning,
                    title: L10n.tr("pending.title"), message: L10n.tr("pending.message")) {
            if !phone.isEmpty {
                Text(verbatim: PhoneNumber.display(phone))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.fill, in: Capsule())
                    .environment(\.layoutDirection, .leftToRight)
            }
            if let message {
                NoticeBanner(kind: .info, title: message)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            VStack(spacing: 12) {
                BigButton(title: L10n.tr("pending.refresh"), systemImage: "arrow.clockwise", isLoading: isChecking) {
                    Task {
                        isChecking = true
                        defer { isChecking = false }
                        do {
                            let approved = try await session.recheckApproval()
                            if !approved { withAnimation(Motion.spring) { message = L10n.tr("pending.stillPending") } }
                        } catch {
                            withAnimation(Motion.spring) { message = APIError.from(error).localizedMessage }
                        }
                    }
                }
                BigButton(title: L10n.tr("common.backToLogin"), systemImage: "chevron.backward", style: .secondary) {
                    session.backToLogin()
                }
            }
            .padding(.top, 8)
        }
    }
}

struct SuspendedView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        StateScreen(systemImage: "hand.raised.fill", color: Theme.danger,
                    title: L10n.tr("suspended.title"), message: L10n.tr("suspended.message")) {
            BigButton(title: L10n.tr("common.backToLogin"), systemImage: "chevron.backward", style: .secondary) {
                Task { await session.logout() }
            }
            .padding(.top, 8)
        }
    }
}

/// Full-screen friendly message with a big, softly glowing icon.
struct StateScreen<Actions: View>: View {
    let systemImage: String
    let color: Color
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    @State private var appeared = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                BrandEmblem(size: 44)
                    .padding(.top, 20)
                    .opacity(0.9)

                ZStack {
                    Circle()
                        .stroke(color.opacity(0.18), lineWidth: 1.5)
                        .frame(width: 176, height: 176)
                        .scaleEffect(pulse ? 1.12 : 0.92)
                        .opacity(pulse ? 0 : 1)
                    Circle().fill(color.opacity(0.07)).frame(width: 168, height: 168)
                    Circle().fill(color.opacity(0.12)).frame(width: 124, height: 124)
                    Circle()
                        .fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.75)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 84, height: 84)
                        .shadow(color: color.opacity(0.4), radius: 18, x: 0, y: 10)
                    Image(systemName: systemImage)
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.bounce, value: appeared)
                }
                .scaleEffect(appeared ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)
                .padding(.vertical, 8)
                .accessibilityHidden(true)

                VStack(spacing: 10) {
                    Text(title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                    Text(message)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.textSecondary)
                }
                .appearAnimation(index: 2)

                VStack(spacing: 14) { actions() }
                    .appearAnimation(index: 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(AmbientBackground(intensity: 0.7))
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.65)) { appeared = true }
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

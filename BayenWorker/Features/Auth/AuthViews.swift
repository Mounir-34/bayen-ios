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
            VStack(spacing: 24) {
                LanguagePicker()
                BrandMark(height: 180).padding(.top, 8)
                Text(L10n.tr("login.subtitle"))
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                PhoneField(nationalDigits: $model.phoneDigits)
                PasswordField(title: L10n.tr("field.password"), password: $model.password)

                if let error = model.errorMessage {
                    NoticeBanner(kind: .danger, title: error)
                }

                BigButton(title: L10n.tr("login.button"), systemImage: "arrow.forward.circle.fill", isLoading: model.isLoading) {
                    Task { await model.login(session: session) }
                }
                .disabled(!model.canSubmit)

                BigButton(title: L10n.tr("login.register"), systemImage: "person.badge.plus", style: .secondary, action: onRegister)
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
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
                BrandEmblem(size: 64).frame(maxWidth: .infinity)
                Text(L10n.tr("register.intro"))
                    .font(.body)
                    .foregroundStyle(.secondary)

                LabeledField(title: L10n.tr("field.fullName"), systemImage: "person.fill") {
                    TextField(L10n.tr("field.fullName"), text: $model.fullName)
                        .textContentType(.name)
                }
                PhoneField(nationalDigits: $model.phoneDigits)
                PasswordField(title: L10n.tr("field.newPassword"), password: $model.password, isNew: true)
                LabeledField(title: L10n.tr("field.municipalityCode"), systemImage: "building.columns.fill") {
                    TextField(text: $model.municipalityCode) { Text(verbatim: "CASA-AINSEBAA") }
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                }
                LabeledField(title: L10n.tr("field.cin"), systemImage: "person.text.rectangle.fill") {
                    TextField(text: $model.cin) { Text(verbatim: "BE123456") }
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.tr("field.language"), systemImage: "globe").font(.headline).foregroundStyle(.secondary)
                    LanguagePicker()
                }

                if let error = model.errorMessage {
                    NoticeBanner(kind: .danger, title: error)
                }

                BigButton(title: L10n.tr("register.button"), systemImage: "checkmark.circle.fill", isLoading: model.isLoading) {
                    Task { await model.register(session: session, language: language.language) }
                }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .navigationTitle(L10n.tr("register.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Account states

struct PendingApprovalView: View {
    let phone: String
    @Environment(SessionStore.self) private var session
    @State private var isChecking = false
    @State private var message: String?

    var body: some View {
        StateScreen(systemImage: "hourglass", color: TaskStatus.submitted.color,
                    title: L10n.tr("pending.title"), message: L10n.tr("pending.message")) {
            if !phone.isEmpty {
                Text(verbatim: PhoneNumber.display(phone))
                    .font(.headline)
                    .environment(\.layoutDirection, .leftToRight)
            }
            if let message {
                NoticeBanner(kind: .info, title: message)
            }
            BigButton(title: L10n.tr("pending.refresh"), systemImage: "arrow.clockwise", isLoading: isChecking) {
                Task {
                    isChecking = true
                    defer { isChecking = false }
                    do {
                        let approved = try await session.recheckApproval()
                        if !approved { message = L10n.tr("pending.stillPending") }
                    } catch {
                        message = APIError.from(error).localizedMessage
                    }
                }
            }
            BigButton(title: L10n.tr("common.backToLogin"), systemImage: "chevron.backward", style: .secondary) {
                session.backToLogin()
            }
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
        }
    }
}

/// Full-screen friendly message with a big icon.
struct StateScreen<Actions: View>: View {
    let systemImage: String
    let color: Color
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                BrandEmblem(size: 56).padding(.top, 24)
                Image(systemName: systemImage)
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 128, height: 128)
                    .background(color.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                actions()
            }
            .padding(24)
        }
        .background(Theme.background)
    }
}

import SwiftUI

/// "+212 | 6 12 34 56 78" input. Always laid out left-to-right (phone numbers read LTR, also in Arabic).
struct PhoneField: View {
    @Binding var nationalDigits: String

    var body: some View {
        LabeledField(title: L10n.tr("field.phone"), systemImage: "phone.fill") {
            HStack(spacing: 10) {
                Text(verbatim: "🇲🇦 +212")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Divider().frame(height: 28)
                TextField(text: Binding(
                    get: { PhoneNumber.formatNational(nationalDigits) },
                    set: { nationalDigits = PhoneNumber.nationalDigits(from: $0) })) {
                    Text(verbatim: "6 12 34 56 78")
                }
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .accessibilityLabel(L10n.tr("field.phone"))
            }
            .environment(\.layoutDirection, .leftToRight)
        }
    }
}

struct PasswordField: View {
    let title: String
    @Binding var password: String
    var isNew = false
    @State private var isVisible = false

    var body: some View {
        LabeledField(title: title, systemImage: "lock.fill") {
            HStack {
                Group {
                    if isVisible {
                        TextField(title, text: $password)
                    } else {
                        SecureField(title, text: $password)
                    }
                }
                .textContentType(isNew ? .newPassword : .password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Button {
                    isVisible.toggle()
                } label: {
                    Image(systemName: isVisible ? "eye.slash.fill" : "eye.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.tr(isVisible ? "field.password.hide" : "field.password.show"))
            }
        }
    }
}

/// Big buttons to pick Arabic / French / English.
struct LanguagePicker: View {
    @Environment(LanguageManager.self) private var language

    var body: some View {
        HStack(spacing: 12) {
            ForEach(AppLanguage.allCases) { lang in
                Button {
                    language.set(lang)
                } label: {
                    Text(verbatim: lang.nativeName)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(language.language == lang ? Theme.onPrimary : Theme.primary)
                        .background(language.language == lang ? Theme.primary : Theme.card,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.primary, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(language.language == lang ? .isSelected : [])
            }
        }
    }
}

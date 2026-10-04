import SwiftUI

/// "+212 | 6 12 34 56 78" input. Always laid out left-to-right (phone numbers read LTR, also in Arabic).
struct PhoneField: View {
    @Binding var nationalDigits: String

    var body: some View {
        LabeledField(title: L10n.tr("field.phone")) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text(verbatim: "🇲🇦")
                    Text(verbatim: "+212")
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityHidden(true)
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 24)
                TextField(text: Binding(
                    get: { PhoneNumber.formatNational(nationalDigits) },
                    set: { nationalDigits = PhoneNumber.nationalDigits(from: $0) })) {
                    Text(verbatim: "6 12 34 56 78")
                }
                .font(.body.weight(.medium).monospacedDigit())
                .multilineTextAlignment(.leading)
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
        LabeledField(title: title, systemImage: "lock") {
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
                    Image(systemName: isVisible ? "eye.slash" : "eye")
                        .font(.body.weight(.medium))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .accessibilityLabel(L10n.tr(isVisible ? "field.password.hide" : "field.password.show"))
            }
        }
    }
}

/// Segmented control to pick Arabic / French / English, with a selection pill that glides between options.
struct LanguagePicker: View {
    @Environment(LanguageManager.self) private var language
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppLanguage.allCases) { lang in
                let isSelected = language.language == lang
                Button {
                    guard !isSelected else { return }
                    withAnimation(Motion.snappy) { language.set(lang) }
                } label: {
                    Text(verbatim: lang.nativeName)
                        .font(.subheadline.weight(isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(isSelected ? Theme.onPrimary : Theme.textSecondary)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Theme.primaryGradient)
                                    .shadow(color: Theme.primary.opacity(0.25), radius: 6, x: 0, y: 3)
                                    .matchedGeometryEffect(id: "pill", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle(scale: 0.95))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.fill, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.75))
    }
}

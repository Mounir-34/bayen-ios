import Foundation

/// Moroccan phone helpers, mirroring `server/src/lib/phone.ts`.
enum PhoneNumber {
    /// Keeps the 9 national digits the user typed after the fixed "+212" prefix
    /// (a leading 0 — "06…" — is dropped, as are spaces and dashes).
    static func nationalDigits(from input: String) -> String {
        var digits = input.filter(\.isNumber)
        // Accept pasted "+212…" / "00212…" / "212…" numbers.
        if digits.hasPrefix("00212") { digits.removeFirst(5) } else if digits.hasPrefix("212"), digits.count > 9 { digits.removeFirst(3) }
        if digits.hasPrefix("0") { digits.removeFirst() }
        return String(digits.prefix(9))
    }

    /// "612345678" → "6 12 34 56 78" (display mask).
    static func formatNational(_ digits: String) -> String {
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i == 1 || i == 3 || i == 5 || i == 7 { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    /// E.164 (+212XXXXXXXXX) or nil when not a valid Moroccan number.
    static func e164(fromNational digits: String) -> String? {
        guard digits.count == 9, let first = digits.first, "5678".contains(first), digits.allSatisfy(\.isNumber) else { return nil }
        return "+212" + digits
    }

    static func normalize(_ input: String) -> String? {
        e164(fromNational: nationalDigits(from: input))
    }

    /// "+212612345678" → "+212 6 12 34 56 78"
    static func display(_ e164: String) -> String {
        guard e164.hasPrefix("+212") else { return e164 }
        return "+212 " + formatNational(String(e164.dropFirst(4)))
    }
}

import Foundation

/// Complete, separately testable catalogs for metric meaning and personal context.
/// No English fallback here: missing translation keys must be caught by parity tests.
enum MetricExplanationCatalog {
    static func table(for language: AppLanguage) -> [String: String] {
        switch language.effectiveLanguage {
        case .system, .en: return LocalizationExplanationEN.strings
        case .ru: return LocalizationExplanationRU.strings
        case .de: return LocalizationExplanationDE.strings
        case .fr: return LocalizationExplanationFR.strings
        case .es: return LocalizationExplanationES.strings
        case .it: return LocalizationExplanationIT.strings
        case .ptBR: return LocalizationExplanationPTBR.strings
        case .nl: return LocalizationExplanationNL.strings
        case .pl: return LocalizationExplanationPL.strings
        case .ja: return LocalizationExplanationJA.strings
        case .ko: return LocalizationExplanationKO.strings
        case .zhHans: return LocalizationExplanationZHHans.strings
        }
    }
}

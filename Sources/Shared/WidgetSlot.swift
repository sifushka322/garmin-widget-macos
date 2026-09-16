import Foundation
import SwiftUI

/// Stable WidgetKit kinds, with one purpose each. No user assignments or profiles.
enum WidgetSlot: String, CaseIterable, Identifiable, Codable {
    case overview, day, sport, sleep, training
    var id: String { rawValue }
    var titleKey: String { "widget.slot." + rawValue }
    var descriptionKey: String { titleKey + ".description" }
    var kind: String { self == .overview ? WidgetDataStore.kind : "GarminDesk." + rawValue }
    var includesTraining: Bool { self == .training }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .day: return "sun.max"
        case .sport: return "figure.run"
        case .sleep: return "moon.stars"
        case .training: return "calendar"
        }
    }
    // Preserve four stable IDs only for older running extension readers.
    private var legacyNumber: Int {
        switch self { case .overview: return 1; case .sport: return 2; case .sleep: return 3; case .training: return 4; case .day: return 5 }
    }
    func profile(in preferences: AppPreferences) -> WidgetProfile {
        var result = WidgetProfile()
        result.id = UUID(uuidString: String(format: "8C913B3D-EE7A-4F9E-831F-%012d", legacyNumber))!
        result.name = Localizer.text(titleKey, language: preferences.language)
        switch self {
        case .overview:
            result.metricIDs = AppPreferences.validatedSummaryMetrics(preferences.summaryMetrics)
        case .day: result.metricIDs = WidgetMetricPolicy.overview
        case .sport:
            result.metricIDs = WidgetMetricPolicy.sport
            result.style = .sport
        case .sleep: result.metricIDs = WidgetMetricPolicy.sleep
        case .training: result.contentMode = .training
        }
        result.primaryMetric = result.metricIDs[0]
        result.prefersAvailableMetrics = true
        return result
    }
    func theme(appearance: WidgetAppearance) -> DeskMetricTheme {
        switch self {
        case .overview: return .summary(appearance: appearance)
        case .day: return .metric("bodyBattery", appearance: appearance)
        case .sport: return .metric("trainingReadiness", appearance: appearance)
        case .sleep: return .metric("sleepDuration", appearance: appearance)
        case .training: return .calendar(appearance: appearance)
        }
    }
    static var requiredMetricIDs: Set<String> {
        requiredMetricIDs(in: AppPreferences())
    }
    static func requiredMetricIDs(in preferences: AppPreferences) -> Set<String> {
        return Set(allCases.filter { $0 != .training }.flatMap { $0.profile(in: preferences).metricIDs })
    }
    var previewData: WidgetData { previewData(language: .system) }
    func previewData(language: AppLanguage, at date: Date = Date()) -> WidgetData {
        var preferences = AppPreferences()
        preferences.language = language
        return WidgetPreviewData.make(preferences: preferences, at: date)
    }
}

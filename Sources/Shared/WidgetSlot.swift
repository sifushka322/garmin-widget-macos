import Foundation

/// Named gallery entries keep independent profile assignments even in a build
/// without App Intents metadata. Assignments are stored by UUID, never by name.
enum WidgetSlot: String, CaseIterable, Identifiable {
    case overview, sport, sleep, training
    var id: String { rawValue }
    var titleKey: String { "widget.slot." + rawValue }
    var descriptionKey: String { titleKey + ".description" }
    var kind: String { self == .overview ? WidgetDataStore.kind : "GarminDesk." + rawValue }

    func profileID(in preferences: AppPreferences) -> String? {
        if let assigned = preferences.widgetProfileIDs[rawValue], !assigned.isEmpty { return assigned }
        return self == .overview ? preferences.profiles.first?.id.uuidString : nil
    }

    var previewData: WidgetData { previewData(language: .system) }

    /// Gallery/setup previews never invent health readings or workout records.
    func previewData(language: AppLanguage, at date: Date = Date()) -> WidgetData {
        var data = WidgetData.preview
        data.preferences.language = language
        data.isConnected = false
        data.snapshot = .empty
        var profile = WidgetProfile()
        profile.density = .compact
        let number = (Self.allCases.firstIndex(of: self) ?? 0) + 1
        profile.id = UUID(uuidString: String(format: "8C913B3D-EE7A-4F9E-831F-%012d", number))!
        profile.name = Localizer.text(titleKey, language: language)
        switch self {
        case .overview:
            profile.metricIDs = ["bodyBattery", "steps", "stress", "restingHeartRate", "hydration", "intensityMinutes"]
            profile.style = .calm
        case .sport:
            profile.metricIDs = ["trainingReadiness", "recoveryTime", "trainingLoad", "vo2Max", "hrv", "bodyBattery"]
            profile.style = .sport
        case .sleep:
            profile.metricIDs = ["sleepDuration", "sleepScore", "hrv", "deepSleep", "remSleep", "lightSleep", "respiration"]
            profile.style = .monochrome
        case .training:
            profile.contentMode = .training
            profile.style = .calm

        }
        profile.primaryMetric = profile.metricIDs[0]
        data.preferences.profiles = [profile]
        data.preferences.widgetProfileIDs = [rawValue: profile.id.uuidString]
        return data
    }
}

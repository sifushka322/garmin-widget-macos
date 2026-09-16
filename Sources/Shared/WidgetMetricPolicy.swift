import Foundation

struct WidgetMetricSelection {
    let primary: String
    let secondary: [String]
}

/// Default candidates use existing Garmin readings, never inferred health scores.
/// Explicit fixed profiles retain their exact selection, including absent values.
enum WidgetMetricPolicy {
    /// Summary has a single ordered selection, not a profile or implicit category
    /// fallback. Unchecked measurements must never reappear as filler.
    static func summarySelection(preferences: AppPreferences, snapshot: GarminSnapshot) -> WidgetMetricSelection {
        let ordered = AppPreferences.validatedSummaryMetrics(preferences.summaryMetrics)
        let formatter = MetricFormatter(snapshot: snapshot, language: preferences.language)
        let available = ordered.filter { formatter.value($0) != nil }
        return .init(primary: available.first ?? ordered[0], secondary: Array(available.dropFirst()))
    }
    static let overview = ["bodyBattery", "steps", "stress", "sleepDuration", "restingHeartRate", "sleepScore", "intensityMinutes", "activeCalories", "distance"]
    static let sport = ["trainingReadiness", "recoveryTime", "trainingLoad", "vo2Max", "intensityMinutes", "activeCalories", "hrv", "bodyBattery", "steps", "distance"]
    static let sleep = ["sleepDuration", "sleepScore", "deepSleep", "remSleep", "lightSleep", "hrv", "restingHeartRate", "respiration", "awakeSleep"]

    static func candidates(for profile: WidgetProfile) -> [String] {
        let selected = [profile.primaryMetric] + profile.metricIDs.filter { $0 != profile.primaryMetric }
        guard profile.prefersAvailableMetrics else { return selected }
        let fallback: [String]
        if profile.style == .sport || MetricDefinition.find(profile.primaryMetric).category == .training { fallback = sport }
        else if MetricDefinition.find(profile.primaryMetric).category == .sleep { fallback = sleep }
        else { fallback = overview }
        var seen = Set<String>()
        return (selected + fallback).filter { MetricDefinition.isSupported($0) && seen.insert($0).inserted }
    }

    static func selection(for profile: WidgetProfile, snapshot: GarminSnapshot) -> WidgetMetricSelection {
        let ordered = candidates(for: profile)
        guard profile.prefersAvailableMetrics else {
            return .init(primary: profile.primaryMetric, secondary: ordered.filter { $0 != profile.primaryMetric })
        }
        let formatter = MetricFormatter(snapshot: snapshot, language: .en)
        let available = ordered.filter { formatter.value($0) != nil }
        // If the account has no usable readings, keep one honest missing primary.
        return .init(primary: available.first ?? profile.primaryMetric, secondary: Array(available.dropFirst()))
    }
}

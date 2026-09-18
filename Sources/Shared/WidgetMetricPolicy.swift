import Foundation
import WidgetKit

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
    /// Compact surfaces show interpretations only when they add a useful scale,
    /// goal or recovery state. Full explanations remain available in help/AX.
    private static let inlineStatusMetrics: Set<String> = ["bodyBattery", "stress", "sleepScore", "trainingReadiness",
                                                           "recoveryTime", "trainingLoad", "hrv", "steps"]

    static func inlineStatus(for id: String, formatter: MetricFormatter) -> String? {
        guard inlineStatusMetrics.contains(id) else { return nil }
        if id == "steps" {
            let snapshot = formatter.snapshot
            let stepDay = snapshot.retainedMetrics["steps"]?.sourceDate ?? snapshot.sourceDate
            let goalDay = snapshot.retainedMetrics["stepGoal"]?.sourceDate ?? snapshot.sourceDate
            guard snapshot.retainedMetrics["steps"] == nil, snapshot.retainedMetrics["stepGoal"] == nil,
                  stepDay == goalDay,
                  stepDay == SyncPolicy.sourceDay(for: formatter.now, timeZone: .autoupdatingCurrent),
                  let goal = formatter.value("stepGoal"), goal > 0 else { return nil }
        }
        return formatter.interpretation(id)?.status
    }

    /// A small summary prioritizes its actual value, readable interpretation and
    /// record date or notice over an optional second measurement. The timeline uses this same
    /// limit, so a hidden Body Battery never creates unnecessary minute entries.
    static func summarySecondaryLimit(data: WidgetData, family: WidgetFamily, at now: Date) -> Int {
        guard family == .systemSmall else { return family == .systemMedium ? 2 : 6 }
        let selection = summarySelection(preferences: data.preferences, snapshot: data.snapshot)
        let formatter = MetricFormatter(snapshot: data.snapshot, language: data.preferences.language, now: now)
        guard inlineStatus(for: selection.primary, formatter: formatter) != nil else { return 1 }
        let presentation = WidgetPresentation(snapshot: data.snapshot, language: data.preferences.language, now: now)
        let notice = presentation.noticeKey(metricIDs: [selection.primary] + Array(selection.secondary.prefix(1)),
                       connected: data.isConnected, staleInterval: data.preferences.staleInterval,
                       hasWarnings: !data.snapshot.warnings.isEmpty)
        return notice == nil && presentation.period(selection.primary) == nil ? 1 : 0
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

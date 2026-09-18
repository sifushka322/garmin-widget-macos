import Foundation
import Darwin

@main
struct MetricExplanationTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        }
        let now = Date(timeIntervalSince1970: 1_789_473_600)
        func reading(_ id: String, _ value: Double, context: GarminMetricContext? = nil,
                     language: AppLanguage = .en) -> MetricExplanation? {
            var snapshot = GarminSnapshot(fetchedAt: now, sourceDate: "2026-09-15", devices: [], metrics: [id: .init(value: value)])
            snapshot.metricContext = context
            return MetricExplanation.make(metricID: id, snapshot: snapshot, language: language, now: now)
        }
        for metric in MetricDefinition.catalog {
            check(MetricExplanation.make(metricID: metric.id, snapshot: .demo, language: .en) != nil,
                  "every catalog metric has an explanation: \(metric.id)")
        }
        check(reading("trainingLoad", 1)?.status == reading("trainingLoad", 5000)?.status,
              "training load has no invented global threshold")
        let range = GarminMetricContext(trainingLoadLower: 200, trainingLoadUpper: 600, trainingStatus: "DETRAINING")
        check(reading("trainingLoad", 199, context: range)?.status == "Below optimal range", "load below personal range")
        check(reading("trainingLoad", 200, context: range)?.status == "In optimal range", "lower boundary included")
        check(reading("trainingLoad", 600, context: range)?.status == "In optimal range", "upper boundary included")
        check(reading("trainingLoad", 601, context: range)?.status == "Above optimal range", "load above personal range")
        check(reading("trainingLoad", 400, context: range)?.supportingText?.contains("Detraining") == true,
              "Garmin training status remains separate from optimal load")
        let malformedRange = GarminMetricContext(trainingLoadLower: 600, trainingLoadUpper: 200, trainingStatus: "PRIVATE_UNKNOWN")
        check(reading("trainingLoad", 400, context: malformedRange)?.status == "Personal range unavailable", "inverted range rejected")
        check(reading("trainingLoad", 400, context: malformedRange)?.supportingText == nil, "unknown raw status never displayed")
        let nonfiniteRange = GarminMetricContext(trainingLoadLower: 0, trainingLoadUpper: .infinity)
        check(reading("trainingLoad", 400, context: nonfiniteRange)?.status == "Personal range unavailable", "nonfinite range rejected")
        var retained = GarminSnapshot(fetchedAt: now, sourceDate: "2026-09-15", devices: [], metrics: [:])
        retained.metricContext = range
        retained.retainedMetrics["trainingLoad"] = .init(reading: .init(value: 400), sourceDate: "2026-09-14", retrievedAt: now, changedAt: now)
        check(MetricExplanation.make(metricID: "trainingLoad", snapshot: retained, language: .en)?.status == "Personal range unavailable",
              "old retained load is never compared to current range")
        let hrv = GarminMetricContext(hrvStatus: "BALANCED", hrvWeeklyAverage: 45, hrvBaselineLow: 40, hrvBaselineHigh: 60)
        check(reading("hrv", 20, context: hrv)?.status == "Balanced weekly HRV", "nightly HRV does not override Garmin weekly status")
        check(reading("hrv", 20, context: hrv)?.supportingText?.contains("7-day average: 45") == true, "weekly average labeled distinctly")
        check(reading("hrv", 20)?.status == reading("hrv", 150)?.status, "no universal HRV norm")
        check(reading("hrv", 20, context: .init(hrvStatus: "NO_STATUS"))?.status == "Insufficient recent HRV data",
              "missing HRV status does not imply that an existing baseline was lost")
        check(reading("vo2Max", 25)?.status == reading("vo2Max", 65)?.status, "no VO2 category without profile")
        for (value, label) in [(1.0, "Poor"), (24, "Poor"), (25, "Low"), (49, "Low"), (50, "Moderate"), (74, "Moderate"), (75, "High"), (94, "High"), (95, "Prime"), (100, "Prime")] {
            check(reading("trainingReadiness", value)?.status.hasPrefix(label) == true, "readiness boundary \(value)")
        }
        check(reading("trainingReadiness", 0) == nil, "readiness zero is not silently categorized")
        check(reading("bodyBattery", 50.5)?.status == reading("bodyBattery", 51)?.status,
              "Half-point Body Battery category matches the displayed rounded value")
        check(reading("bodyBattery", 25.4)?.status == "Very low energy reserve", "fractional score matches displayed integer band")
        check(reading("bodyBattery", 25.6)?.status == "Low energy reserve", "fractional score rounds into next displayed band")
        for (value, label) in [(0.0, "Poor"), (59, "Poor"), (60, "Fair"), (79, "Fair"), (80, "Good"), (89, "Good"), (90, "Excellent"), (100, "Excellent")] {
            check(reading("sleepScore", value)?.status.hasPrefix(label) == true, "sleep score boundary \(value)")
        }
        for (value, label) in [(0.0, "Resting"), (25, "Resting"), (26, "Low"), (50, "Low"), (51, "Medium"), (75, "Medium"), (76, "High"), (100, "High")] {
            check(reading("stress", value)?.status.hasPrefix(label) == true, "stress boundary \(value)")
        }
        check(reading("sleepScore", 101) == nil, "out-of-scale score has no assessment")
        check(reading("stress", .nan) == nil, "nonfinite values have no assessment")
        check(reading("hrv", -1) == nil, "negative values have no assessment")
        check(reading("unknown", 50) == nil, "unknown metric never falls back to Body Battery")
        check(reading("trainingLoad", 400, context: range, language: .ru)?.supportingText?.contains("Детренированность") == true, "Russian status explanation")
        check(reading("sleepScore", 85, language: .de) == reading("sleepScore", 85, language: .en), "untranslated explanations have explicit English fallback")
        let oldContext = try AppJSON.decoder.decode(GarminMetricContext.self, from: Data("{}".utf8))
        check(oldContext == GarminMetricContext(), "optional context fields remain backward compatible")
        let ratioContext = GarminMetricContext(trainingStatus: "DETRAINING", trainingLoadStatus: "OPTIMAL", trainingLoadRatio: 1.2)
        check(reading("trainingLoad", 525, context: ratioContext)?.status == "Optimal load ratio", "Garmin ratio category labeled separately")
        check(reading("trainingLoad", 525, context: ratioContext)?.supportingText?.contains("Detraining") == true, "ratio category never overrides training status")
        let rawTraining: [String: Any] = ["mostRecentTrainingStatus": ["latestTrainingStatusData": [
            "unselected": ["trainingStatusFeedbackPhrase": "UNPRODUCTIVE_1", "acuteTrainingLoadDTO": ["dailyTrainingLoadAcute": 100]],
            "selected": ["primaryTrainingDevice": true, "trainingStatusFeedbackPhrase": "PRODUCTIVE_3", "trainingStatus": 7,
                         "acuteTrainingLoadDTO": ["dailyTrainingLoadAcute": 525, "acwrStatus": "OPTIMAL", "dailyAcuteChronicWorkloadRatio": 1.2,
                                                   "minTrainingLoadChronic": 300, "maxTrainingLoadChronic": 900]]]]]
        let normalized = GarminPayloadNormalizer.metricContext(group: "training", payload: rawTraining)
        check(normalized?.trainingStatus == "PRODUCTIVE", "numbered feedback phrase normalized for primary device")
        check(normalized?.trainingLoadStatus == "OPTIMAL" && normalized?.trainingLoadRatio == 1.2, "Garmin load ratio context retained")
        check(normalized?.trainingLoadLower == nil && normalized?.trainingLoadUpper == nil, "chronic bounds must not classify acute load")
        let ambiguous: [String: Any] = ["mostRecentTrainingStatus": ["latestTrainingStatusData": [
            "one": ["trainingStatusFeedbackPhrase": "PRODUCTIVE_3"], "two": ["trainingStatusFeedbackPhrase": "DETRAINING_1"]]]]
        check(GarminPayloadNormalizer.metricContext(group: "training", payload: ambiguous) == nil, "ambiguous devices cannot provide context")
        let unknown: [String: Any] = ["mostRecentTrainingStatus": ["latestTrainingStatusData": [
            "one": ["trainingStatusFeedbackPhrase": "PRODUCTIVE_UNVERIFIED", "trainingStatus": 7]]]]
        check(GarminPayloadNormalizer.metricContext(group: "training", payload: unknown) == nil, "unknown phrases and numeric status codes are not inferred")
        let rawHRV: [String: Any] = ["hrvSummary": ["status": "BALANCED", "lastNightAvg": 32, "weeklyAvg": 58,
            "baseline": ["balancedLow": 49, "balancedUpper": 72, "lowUpper": 40]]]
        let hrvContext = GarminPayloadNormalizer.metricContext(group: "hrv", payload: rawHRV)
        check(hrvContext?.hrvWeeklyAverage == 58 && hrvContext?.hrvBaselineLow == 49 && hrvContext?.hrvBaselineHigh == 72,
              "HRV uses actual balanced range, not low-status threshold")
        let badHRV: [String: Any] = ["hrvSummary": ["status": 1, "weeklyAvg": true,
            "baseline": ["balancedLow": 72, "balancedUpper": 49]]]
        check(GarminPayloadNormalizer.metricContext(group: "hrv", payload: badHRV) == nil, "invalid HRV context stays absent")
        var cache = GarminWebCache()
        cache.groups["training"] = .init(sourceDay: "2026-09-15", retrievedAt: now,
            metrics: ["trainingLoad": .init(value: 525)], metricContext: normalized)
        cache.groups["hrv"] = .init(sourceDay: "2026-09-15", retrievedAt: now,
            metrics: ["hrv": .init(value: 32)], metricContext: hrvContext)
        let combined = cache.snapshot(sourceDay: "2026-09-15", warnings: [])
        check(combined.metricContext?.trainingStatus == "PRODUCTIVE" && combined.metricContext?.hrvWeeklyAverage == 58,
              "matching-day group context combines without overwriting other groups")
        let nextDay = cache.snapshot(sourceDay: "2026-09-16", fallback: combined, warnings: [])
        check(nextDay.metricContext == nil, "prior-day metadata does not become current context")
        cache.groups["training"] = .init(sourceDay: "2026-09-15", retrievedAt: now, metrics: [:])
        let cleared = cache.snapshot(sourceDay: "2026-09-15", fallback: combined, warnings: [])
        check(cleared.metricContext?.trainingStatus == nil && cleared.metricContext?.hrvWeeklyAverage == 58,
              "successful empty training response clears only training context")
        let roundTrip = try AppJSON.decoder.decode(GarminSnapshot.self, from: AppJSON.encoder.encode(combined))
        check(roundTrip.metricContext == combined.metricContext, "context survives snapshot persistence")
        let oldGroup = try AppJSON.decoder.decode(GarminMetricGroupCache.self,
            from: Data(#"{"sourceDay":"2026-09-15","retrievedAt":"2026-09-15T12:00:00Z","metrics":{}}"#.utf8))
        check(oldGroup.metricContext == nil, "old group cache decodes without context")
        print("PASS: \(checks) metric explanation checks")
    }
}

import Foundation

@main struct WidgetMetricPolicyTests {
    struct Failure: Error { let message: String }
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw Failure(message: message) }
    }
    static func main() throws {
        var profile = WidgetSlot.day.profile(in: AppPreferences())
        try expect(!profile.metricIDs.contains("hydration") && !profile.metricIDs.contains("weight"), "Manual inputs are optional, not daily defaults")
        try expect(profile.metricIDs.allSatisfy(MetricDefinition.isSupported), "Every default metric is supported")
        profile.metricIDs = ["bodyBattery", "hydration", "weight", "steps", "stress"]
        var snapshot = GarminSnapshot.empty
        snapshot.metrics = ["bodyBattery": .init(value: 89), "steps": .init(value: 0), "stress": .init(value: 19),
                            "sleepDuration": .init(value: 414), "restingHeartRate": .init(value: 54), "activeCalories": .init(value: 120)]
        let chosen = WidgetMetricPolicy.selection(for: profile, snapshot: snapshot)
        try expect(chosen.primary == "bodyBattery", "Available primary remains the primary")
        try expect(chosen.secondary == ["steps", "stress", "sleepDuration", "restingHeartRate", "activeCalories"], "Absent water/weight are replaced with available related readings in stable priority")
        try expect(chosen.secondary.contains("steps"), "A real zero is not missing")
        try expect(profile.metricIDs.contains("hydration"), "Rendering never removes a saved selection")
        profile.prefersAvailableMetrics = false
        let fixed = WidgetMetricPolicy.selection(for: profile, snapshot: snapshot)
        try expect(fixed.secondary == ["hydration", "weight", "steps", "stress"], "Fixed mode preserves unavailable manual selections")
        let restored = try AppJSON.decoder.decode(WidgetProfile.self, from: AppJSON.encoder.encode(profile))
        try expect(!restored.prefersAvailableMetrics, "Opting out survives a restart")
        var sport = WidgetSlot.sport.profile(in: AppPreferences())
        try expect(sport.contentMode == .metrics && !sport.contentMode.includesTraining, "Sport has no workout records")
        let fallback = WidgetMetricPolicy.selection(for: sport, snapshot: snapshot)
        try expect(fallback.primary == "activeCalories", "A device without advanced metrics uses the first available metric with its real label")
        sport.contentMode = .mixed
        let migrated = try AppJSON.decoder.decode(WidgetProfile.self, from: AppJSON.encoder.encode(sport))
        try expect(migrated.id == sport.id && migrated.contentMode == .metrics, "Mixed profile migration preserves identity")
        let calendar = WidgetSlot.training.profile(in: AppPreferences())
        try expect(calendar.contentMode == .training, "Training is always a calendar")
        try expect(!WidgetSlot.sport.profile(in: AppPreferences()).contentMode.includesTraining, "Sport cannot show calendar records")
        for slot in WidgetSlot.allCases {
            let link = WidgetLink(url: WidgetLink(slot: slot).url!)
            try expect(link?.slot == slot, "Clicking a widget retains its purpose")
        }
        try expect(WidgetLink(url: URL(string: "garmindesk://profile/" + profile.id.uuidString)!)?.slot == .overview, "Existing links degrade to Summary")
        try expect(WidgetLink(url: URL(string: "https://widget/sport")!) == nil, "Only the app's own scheme opens a widget")
        let empty = WidgetMetricPolicy.selection(for: sport, snapshot: .empty)
        try expect(empty.primary == sport.primaryMetric && empty.secondary.isEmpty, "No data does not manufacture filler readings")
        snapshot.metrics["trainingReadiness"] = .init(value: .nan)
        snapshot.metrics["recoveryTime"] = .init(value: -1)
        try expect(WidgetMetricPolicy.selection(for: sport, snapshot: snapshot).primary == "activeCalories", "Invalid advanced data cannot displace a valid fallback")
        let date = Date(timeIntervalSince1970: 1_789_473_600)
        snapshot.retainedMetrics["trainingLoad"] = .init(reading: .init(value: 300), sourceDate: "2026-09-14", retrievedAt: date, changedAt: date)
        try expect(WidgetMetricPolicy.selection(for: sport, snapshot: snapshot).primary == "trainingLoad", "Retained readings stay usable with their existing period context")
        try expect(WidgetPresentation(snapshot: snapshot, language: .en, now: date).period("trainingLoad") != nil, "A retained load carries a date")
        for slot in WidgetSlot.allCases {
            let item = slot.profile(in: AppPreferences())
            let candidates = WidgetMetricPolicy.candidates(for: item)
            try expect(candidates.count == Set(candidates).count, "Candidates never duplicate rows")
            try expect(candidates.allSatisfy(MetricDefinition.isSupported), "Templates cannot request removed metric IDs")
        }
        var interpreted = GarminSnapshot.demo
        interpreted.isDemo = false
        interpreted.sourceDate = SyncPolicy.sourceDay(for: date, timeZone: .autoupdatingCurrent)
        let formatter = MetricFormatter(snapshot: interpreted, language: .en, now: date)
        for id in ["bodyBattery", "stress", "sleepScore", "trainingReadiness", "recoveryTime", "trainingLoad", "hrv", "steps"] {
            try expect(WidgetMetricPolicy.inlineStatus(for: id, formatter: formatter) != nil, "Meaningful status remains inline: " + id)
        }
        for id in ["vo2Max", "distance", "calories", "activeCalories", "sleepDuration", "weight", "hydration", "restingHeartRate"] {
            try expect(WidgetMetricPolicy.inlineStatus(for: id, formatter: formatter) == nil, "Generic descriptions belong in details: " + id)
            try expect(formatter.interpretation(id) != nil && !formatter.help(id).isEmpty, "Removing an inline phrase preserves full help: " + id)
        }
        for language in AppLanguage.supported {
            var dailySteps = interpreted
            dailySteps.metrics["stepGoal"] = .init(value: 10_000)
            let number = NumberFormatter()
            number.locale = language.locale; number.numberStyle = .decimal; number.maximumFractionDigits = 0
            let target = String(format: Localizer.text("explanation.steps.goal", language: language),
                                locale: language.locale, number.string(from: 10_000)!)
            for value in [6_842.0, 10_000, 12_000] {
                dailySteps.metrics["steps"] = .init(value: value)
                let stepFormatter = MetricFormatter(snapshot: dailySteps, language: language, now: date)
                let actual = WidgetMetricPolicy.inlineStatus(for: "steps", formatter: stepFormatter)
                if value < 10_000 {
                    try expect(actual == target,
                               "Below-goal steps show the concrete localized target: \(language)")
                    try expect(actual != Localizer.text("explanation.steps.progress", language: language),
                               "The generic progress phrase must not replace the actual target")
                } else {
                    try expect(actual == Localizer.text("explanation.steps.reached", language: language),
                               "At/above-goal steps retain the localized achievement state: \(language), \(value)")
                }
            }
        }
        interpreted.metrics["stepGoal"] = nil
        try expect(WidgetMetricPolicy.inlineStatus(for: "steps", formatter: .init(snapshot: interpreted, language: .en, now: date)) == nil,
                   "Steps without a goal do not show a generic inline phrase")
        interpreted.retainedMetrics["stepGoal"] = .init(reading: .init(value: 10_000), sourceDate: "2000-01-01", retrievedAt: date, changedAt: date)
        try expect(WidgetMetricPolicy.inlineStatus(for: "steps", formatter: .init(snapshot: interpreted, language: .en, now: date)) == nil,
                   "A goal from another day cannot create a progress interpretation")
        interpreted.metrics["steps"] = nil
        interpreted.retainedMetrics["steps"] = .init(reading: .init(value: 5_000), sourceDate: "2000-01-01", retrievedAt: date, changedAt: date)
        try expect(WidgetMetricPolicy.inlineStatus(for: "steps", formatter: .init(snapshot: interpreted, language: .en, now: date)) == nil,
                   "Matching retained steps and goal still cannot show today's progress or a generic substitute")
        interpreted.retainedMetrics = [:]
        interpreted.metrics["steps"] = .init(value: 5_000); interpreted.metrics["stepGoal"] = .init(value: 10_000)
        interpreted.sourceDate = "2000-01-01"
        try expect(WidgetMetricPolicy.inlineStatus(for: "steps", formatter: .init(snapshot: interpreted, language: .en, now: date)) == nil,
                   "A legacy prior-day current cache cannot imply today's goal progress")
        print("PASS: \(checks) widget selection and migration checks")
    }
}

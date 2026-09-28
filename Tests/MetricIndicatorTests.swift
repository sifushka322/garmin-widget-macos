import Foundation
import Darwin

@main
struct MetricIndicatorTests {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        }
        let now = Date(timeIntervalSince1970: 1_789_473_600)
        func snapshot(_ values: [String: Double], context: GarminMetricContext? = nil) -> GarminSnapshot {
            var result = GarminSnapshot(fetchedAt: now, sourceDate: "2026-09-15", devices: [],
                                        metrics: values.mapValues { .init(value: $0) })
            result.metricContext = context
            return result
        }
        func indicator(_ id: String, _ value: Double, context: GarminMetricContext? = nil) -> MetricIndicator? {
            MetricIndicator.make(metricID: id, snapshot: snapshot([id: value], context: context), language: .en, now: now)
        }
        func make(_ id: String, _ data: GarminSnapshot, language: AppLanguage = .en) -> MetricIndicator? {
            MetricIndicator.make(metricID: id, snapshot: data, language: language, now: now)
        }
        func validScale(_ scale: MetricScale?) -> Bool {
            guard let scale else { return false }
            return scale.position.isFinite && (0...1).contains(scale.position)
                && scale.bands.allSatisfy { $0.fraction.isFinite && $0.fraction > 0 }
                && abs(scale.bands.reduce(0) { $0 + $1.fraction } - 1) < 0.000_001
        }

        for (id, edges) in ["sleepScore": [0.0, 59, 60, 79, 80, 89, 90, 100],
                            "stress": [0.0, 25, 26, 50, 51, 75, 76, 100],
                            "bodyBattery": [0.0, 25, 26, 50, 51, 75, 76, 100],
                            "trainingReadiness": [1.0, 24, 25, 49, 50, 74, 75, 94, 95, 100]] {
            for edge in edges {
                let result = indicator(id, edge)
                check(validScale(result?.scale), "\(id) valid scale at \(edge)")
                check(result?.scale?.position == edge / 100, "\(id) marker matches score \(edge)")
            }
            for invalid in [-1.0, 101, Double.nan, Double.infinity] {
                check(indicator(id, invalid) == nil, "\(id) rejects invalid \(invalid)")
            }
        }
        check(indicator("trainingReadiness", 0) == nil, "zero readiness cannot imply poor readiness")
        check(indicator("bodyBattery", 25.6)?.scale?.position == 0.26, "battery marker rounds like displayed value")
        check(indicator("bodyBattery", 25.6)?.status == "Low energy reserve", "battery rounded band and status agree")
        check(indicator("sleepScore", 79.6)?.status == "Good sleep", "sleep rounded category agrees")
        check(indicator("sleepScore", 79.6)?.scale?.position == 0.8, "sleep marker uses displayed score")
        check(indicator("stress", 100)?.scale?.bands.last?.tone == .negative, "higher stress is not better")
        check(indicator("stress", 0)?.scale?.bands.first?.tone == .positive, "resting stress has positive band")
        check(indicator("trainingReadiness", 1)?.scale?.bands.first?.tone == .negative, "readiness direction differs from stress")
        check(indicator("trainingReadiness", 100)?.scale?.bands.last?.tone == .positive, "high readiness is positive")
        check(indicator("unknown", 50) == nil, "unknown metric has no indicator")
        check(make("sleepScore", snapshot([:])) == nil, "missing score stays missing")

        var sleep = snapshot(["sleepDuration": 462, "sleepScore": 86, "deepSleep": 92, "awakeSleep": 12])
        check(make("sleepDuration", sleep)?.status == "Good sleep", "duration shows matching sleep assessment")
        check(make("sleepDuration", sleep)?.reference == "Sleep score · 86/100", "duration explicitly labels quality scale")
        check(make("sleepDuration", sleep)?.scale?.position == 0.86, "duration uses score, not invented hours target")
        check(make("sleepDuration", sleep, language: .ru)?.reference == "Оценка сна · 86/100", "Russian quality reference")
        let spokenSleep = MetricFormatter(snapshot: sleep, language: .en, now: now).accessibility("sleepDuration")
        check(spokenSleep.contains("Good sleep") && spokenSleep.contains("86/100"),
              "VoiceOver receives the same sleep assessment and its score")
        check(indicator("sleepDuration", 462)?.scale == nil, "duration without quality has no invented scale")
        check(indicator("sleepDuration", 462)?.status == "Sleep score · No measurement yet", "missing quality stated plainly")
        check(make("sleepDuration", snapshot(["sleepDuration": 462, "sleepScore": 101]))?.scale == nil, "invalid companion score cannot assess sleep")
        sleep.metrics["sleepDuration"]?.measuredAt = now
        check(make("sleepDuration", sleep)?.scale == nil, "one missing sleep timestamp cannot prove same record")
        sleep.metrics["sleepScore"]?.measuredAt = now.addingTimeInterval(-60)
        check(make("sleepDuration", sleep)?.scale == nil, "different sleep-ending timestamps never combined")
        sleep.metrics["sleepScore"]?.measuredAt = now
        check(make("sleepDuration", sleep)?.scale != nil, "matching timestamps combine")
        let retained: (Double, String, Date?) -> RetainedMetricReading = { value, day, measured in
            .init(reading: .init(value: value, measuredAt: measured), sourceDate: day, retrievedAt: now, changedAt: now)
        }
        sleep.metrics["sleepScore"] = nil
        sleep.retainedMetrics["sleepScore"] = retained(86, "2026-09-14", now)
        check(make("sleepDuration", sleep)?.scale == nil, "yesterday score cannot assess today's duration")
        sleep.retainedMetrics["sleepScore"] = retained(86, "2026-09-15", now)
        check(make("sleepDuration", sleep)?.scale != nil, "same known sleep record can survive a partial fetch")
        sleep.metrics["sleepDuration"] = nil
        sleep.retainedMetrics["sleepDuration"] = retained(462, "2026-09-15", now)
        check(make("sleepDuration", sleep)?.scale != nil, "historical matched night retains honest quality scale")
        sleep.retainedMetrics["sleepDuration"] = retained(462, "2026-09-14", now)
        check(make("sleepDuration", sleep)?.scale == nil, "retained nights must match each other")
        var ambiguous = snapshot(["sleepDuration": 462])
        ambiguous.retainedMetrics["sleepScore"] = retained(86, "2026-09-15", nil)
        check(make("sleepDuration", ambiguous)?.scale == nil, "mixed current and retained untimed records remain ambiguous")
        ambiguous.metrics["sleepDuration"] = nil
        ambiguous.retainedMetrics["sleepDuration"] = retained(462, "2026-09-15", nil)
        check(make("sleepDuration", ambiguous)?.scale != nil, "same retained untimed fetch can preserve a night")
        ambiguous.retainedMetrics["sleepDuration"]?.retrievedAt = now.addingTimeInterval(60)
        check(make("sleepDuration", ambiguous)?.scale == nil, "different untimed retained fetches cannot prove same sleep record")

        let stages = snapshot(["deepSleep": 90, "sleepDuration": 450, "awakeSleep": 30])
        check(make("deepSleep", stages)?.scale?.position == 0.2, "stage uses share of actual sleep")
        check(make("deepSleep", stages)?.reference == "20% · Sleep", "stage percentage labeled as composition")
        check(make("deepSleep", stages)?.scale?.bands.first?.tone == .neutral, "stage proportion is not a health judgement")
        check(make("awakeSleep", stages)?.scale == nil, "awake time is not a component of total asleep time")
        check(make("deepSleep", snapshot(["deepSleep": 500, "sleepDuration": 450]))?.scale == nil, "impossible stage fraction rejected")
        check(make("deepSleep", snapshot(["deepSleep": 1, "sleepDuration": 0]))?.scale == nil, "zero sleep denominator rejected")

        var steps = snapshot(["steps": 8000, "stepGoal": 10000])
        check(make("steps", steps)?.scale?.position == 0.8, "steps compare to personal goal")
        check(make("steps", steps)?.reference == "Goal: 10,000 · 80%", "steps explain target and percentage")
        check(make("steps", steps)?.status == "Goal: 10,000 · 80%", "compact steps keep goal progress visible")
        check(make("steps", steps)?.scale?.bands.first?.tone == .neutral, "steps goal is not universal fitness judgement")
        steps.metrics["steps"] = .init(value: 9975)
        check(make("steps", steps)?.status == "Goal: 10,000 · 99%", "unfinished goal never rounds up to 100 percent")
        check(make("steps", steps)?.reference != "Daily goal reached", "near-goal steps remain incomplete")
        check(make("steps", steps)?.scale?.position == 0.9975, "near-goal scale retains actual fractional progress")
        steps.metrics["steps"] = .init(value: 10000)
        check(make("steps", steps)?.status == "Goal: 10,000 · 100%", "exact goal displays 100 percent")
        check(make("steps", steps)?.reference == "Daily goal reached", "exact goal is explicitly reached")
        steps.metrics["steps"] = .init(value: 15000)
        check(make("steps", steps)?.scale?.position == 1, "step goal overflow caps marker")
        check(make("steps", steps)?.status.hasSuffix("150%") == true, "exceeding step goal preserves useful percentage")
        check(make("steps", steps)?.reference == "Daily goal reached", "completed goal remains explicit")
        var cachedSteps = snapshot(["steps": 15000, "stepGoal": 10000])
        for sourceDay in [SyncPolicy.sourceDay(for: now.addingTimeInterval(-86400), timeZone: .autoupdatingCurrent),
                          SyncPolicy.sourceDay(for: now.addingTimeInterval(86400), timeZone: .autoupdatingCurrent), ""] {
            cachedSteps.sourceDate = sourceDay
            let stale = make("steps", cachedSteps)
            check(stale?.scale == nil && stale?.reference == nil, "whole snapshot outside today's date cannot assess current goal")
            check(stale?.status == "Daily walking activity", "old completed goal cannot appear reached today")
        }
        let afterMidnight = MetricIndicator.make(metricID: "steps", snapshot: steps, language: .en,
                                                now: now.addingTimeInterval(86400))
        check(afterMidnight?.scale == nil, "a widget entry after the day changes drops yesterday's target")
        check(make("steps", snapshot(["steps": .greatestFiniteMagnitude, "stepGoal": .leastNonzeroMagnitude]))?.scale?.position == 1,
              "extreme goal division cannot overflow marker")
        check(make("steps", snapshot(["steps": .greatestFiniteMagnitude, "stepGoal": .leastNonzeroMagnitude]))?.status.hasSuffix("≥1,000%") == true,
              "overflowing step ratio keeps bounded reference")
        for goal in [0.0, -1, Double.nan, Double.infinity] {
            check(make("steps", snapshot(["steps": 8000, "stepGoal": goal]))?.scale == nil, "invalid goal \(goal) rejected")
        }
        steps.metrics["steps"] = nil
        steps.retainedMetrics["steps"] = retained(8000, "2026-09-14", nil)
        check(make("steps", steps)?.scale == nil, "retained steps never compare against current target")
        steps.metrics["steps"] = .init(value: 8000)
        steps.metrics["stepGoal"] = nil
        steps.retainedMetrics["stepGoal"] = retained(10000, "2026-09-14", nil)
        check(make("steps", steps)?.scale == nil, "current steps never use retained goal")

        let range = GarminMetricContext(trainingLoadLower: 200, trainingLoadUpper: 600)
        for load in [0.0, 199, 200, 400, 600, 601, 5000] {
            check(validScale(indicator("trainingLoad", load, context: range)?.scale), "personal acute range scale at \(load)")
        }
        check(indicator("trainingLoad", 200, context: range)?.status == "In optimal range", "lower range boundary included")
        check(indicator("trainingLoad", 600, context: range)?.status == "In optimal range", "upper range boundary included")
        check(indicator("trainingLoad", 601, context: range)?.status == "Above optimal range", "load above personal range")
        check(indicator("trainingLoad", 5000, context: range)?.scale?.position == 1, "outlier load marker remains on scale")
        check(indicator("trainingLoad", 400, context: .init(trainingLoadLower: 600, trainingLoadUpper: 200))?.scale == nil, "inverted personal range rejected")
        check(indicator("trainingLoad", 400, context: .init(trainingLoadLower: 0, trainingLoadUpper: .infinity))?.scale == nil, "infinite personal range rejected")
        check(validScale(indicator("trainingLoad", .greatestFiniteMagnitude,
                                   context: .init(trainingLoadLower: 0, trainingLoadUpper: .greatestFiniteMagnitude))?.scale),
              "extreme finite range does not overflow its scale")
        check(validScale(indicator("trainingLoad", .greatestFiniteMagnitude,
                                   context: .init(trainingLoadLower: 0, trainingLoadUpper: .leastNonzeroMagnitude))?.scale),
              "extreme load-to-range division stays bounded")
        for (index, category) in ["LOW", "OPTIMAL", "HIGH", "VERY_HIGH"].enumerated() {
            let context = GarminMetricContext(trainingLoadStatus: category, trainingLoadRatio: 1.2)
            let low = indicator("trainingLoad", 1, context: context)
            let high = indicator("trainingLoad", 5000, context: context)
            check(low == high, "ratio category independent of raw acute load \(category)")
            check(low?.status == "Load ratio: " + ["low", "optimal", "high", "very high"][index],
                  "compact label identifies the ratio category \(category)")
            check(low?.scale?.position == (Double(index) + 0.5) / 4, "categorical marker centered for \(category)")
            check(low?.reference == "Acute / chronic: 1.2×", "ratio reference explicit for \(category)")
        }
        check(indicator("trainingLoad", 400, context: .init(trainingLoadRatio: 1.2))?.scale == nil, "numeric ratio alone does not invent Garmin category")
        check(indicator("trainingLoad", 400, context: .init(trainingLoadStatus: "UNKNOWN"))?.scale == nil, "unrecognized ratio category ignored")
        check(indicator("trainingLoad", 400, context: .init(trainingLoadStatus: "HIGH", trainingLoadRatio: .nan))?.reference == nil,
              "bad ratio number cannot contaminate recognized category")
        var oldLoad = snapshot([:], context: range)
        oldLoad.retainedMetrics["trainingLoad"] = retained(400, "2026-09-14", nil)
        check(make("trainingLoad", oldLoad)?.scale == nil, "retained load never uses current personal context")

        let hrv = GarminMetricContext(hrvStatus: "BALANCED", hrvWeeklyAverage: 58, hrvBaselineLow: 49, hrvBaselineHigh: 72)
        check(indicator("hrv", 20, context: hrv)?.scale == nil, "nightly HRV cannot mark weekly baseline")
        check(indicator("hrv", 20, context: hrv)?.reference == "7-day average: 58 ms · Your baseline: 49–72 ms", "HRV weekly context clearly labeled")
        for id in ["spo2", "restingHeartRate", "vo2Max", "weight", "hydration", "distance", "calories", "recoveryTime"] {
            check(indicator(id, 70)?.scale == nil, "\(id) has no invented universal health scale")
        }
        var oldScore = snapshot([:])
        oldScore.retainedMetrics["sleepScore"] = retained(86, "2026-09-14", nil)
        check(make("sleepScore", oldScore)?.scale?.position == 0.86, "dated historical score keeps its fixed scale")
        let compactOptimalRatio: [AppLanguage: String] = [
            .en: "Load ratio: optimal", .ru: "Соотношение: оптимальное", .de: "Verhältnis: optimal",
            .fr: "Ratio : optimal", .es: "Ratio: óptimo", .it: "Rapporto: ottimale",
            .ptBR: "Relação: ideal", .nl: "Verhouding: optimaal", .pl: "Stosunek: optymalny",
            .ja: "負荷比：最適", .ko: "부하 비율: 최적", .zhHans: "负荷比：最佳"
        ]
        check(Set(compactOptimalRatio.keys) == Set(AppLanguage.supported), "compact ratio copy covers every supported language")
        for language in AppLanguage.supported {
            func text(_ key: String) -> String { Localizer.text(key, language: language) }
            let localized = make("sleepDuration", snapshot(["sleepDuration": 462, "sleepScore": 86]), language: language)
            check(localized?.status == text("explanation.sleep.good"), "sleep status stays localized in \(language)")
            check(localized?.reference == text("metric.sleepScore") + " · 86/100", "sleep reference stays localized in \(language)")
            check(make("sleepDuration", snapshot(["sleepDuration": 462]), language: language)?.status
                == text("metric.sleepScore") + " · " + text("data.empty"), "missing quality stays localized in \(language)")
            check(make("bodyBattery", snapshot(["bodyBattery": 40]), language: language)?.status
                == text("explanation.battery.low"), "battery status stays localized in \(language)")
            let ratioData = snapshot(["trainingLoad": 525], context: .init(trainingStatus: "PRODUCTIVE", trainingLoadStatus: "OPTIMAL", trainingLoadRatio: 1.2))
            let ratio = make("trainingLoad", ratioData, language: language)
            check(ratio?.status == compactOptimalRatio[language], "compact ratio category stays localized in \(language)")
            let spoken = MetricFormatter(snapshot: ratioData, language: language, now: now).accessibility("trainingLoad")
            check(spoken.contains(text("explanation.training.PRODUCTIVE.title")), "VoiceOver preserves separate training status in \(language)")
            let labeledValue = String(format: text("explanation.labeledDetail"), locale: language.locale,
                                      text("metric.trainingLoad"), "525")
            check(spoken.hasPrefix(labeledValue), "VoiceOver preserves localized label punctuation in \(language)")
            let percent = NumberFormatter()
            percent.locale = language.locale; percent.numberStyle = .percent
            percent.roundingMode = .halfUp; percent.maximumFractionDigits = 0
            let expectedPercent = percent.string(from: 0.8)!
            let localizedSteps = make("steps", snapshot(["steps": 8000, "stepGoal": 10000]), language: language)
            let integer = NumberFormatter()
            integer.locale = language.locale; integer.numberStyle = .decimal; integer.maximumFractionDigits = 0
            let goalText = String(format: text("explanation.steps.goal"), locale: language.locale,
                                  integer.string(from: 10000)!)
            check(localizedSteps?.status == goalText + " · " + expectedPercent,
                  "compact target uses localized number, template and percent spacing in \(language)")
            let localizedHRV = snapshot(["hrv": 20], context: hrv)
            let hrvFormatter = MetricFormatter(snapshot: localizedHRV, language: language, now: now)
            check(hrvFormatter.accessibility("hrv").contains(hrvFormatter.interpretation("hrv")!.supportingText!),
                  "VoiceOver preserves the complete HRV context in \(language)")
        }
        var shadowed = snapshot(["steps": 8000, "stepGoal": 10000, "trainingLoad": 400, "hrv": 20], context: range)
        for id in shadowed.metrics.keys {
            shadowed.retainedMetrics[id] = retained(1, "2026-09-14", nil)
        }
        check(make("steps", shadowed)?.scale?.position == 0.8, "current steps and goal win over duplicate retained entries")
        check(make("trainingLoad", shadowed)?.scale != nil, "current load keeps its personal context over duplicate retained entry")
        check(MetricFormatter(snapshot: shadowed, language: .en, now: now).interpretation("trainingLoad")?.status == "In optimal range",
              "current-wins rule also applies to the explanation context")
        check(MetricFormatter(snapshot: shadowed, language: .en, now: now).context("steps") == nil,
              "current steps never inherit yesterday's provenance")
        shadowed.metricContext = hrv
        check(make("hrv", shadowed)?.reference?.contains("58") == true,
              "current HRV keeps matching weekly context over duplicate retained entry")
        print("PASS: \(checks) metric indicator checks")
    }
}

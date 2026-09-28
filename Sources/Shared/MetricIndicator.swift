import Foundation

/// A scale's colors describe its meaning, independently of the widget theme.
enum MetricTone: Equatable { case neutral, positive, caution, negative }

struct MetricScaleBand: Equatable {
    var fraction: Double
    var tone: MetricTone
}

struct MetricScale: Equatable {
    var bands: [MetricScaleBand]
    /// A marker on the complete scale, not an implication that more is better.
    var position: Double
}

/// The glanceable counterpart to the longer MetricExplanation. Only published
/// Garmin scales or a matching personal target can produce a numeric marker.
struct MetricIndicator: Equatable {
    var status: String
    var reference: String? = nil
    var scale: MetricScale? = nil

    static func make(metricID id: String, snapshot: GarminSnapshot, language: AppLanguage,
                     now: Date = Date()) -> MetricIndicator? {
        let formatter = MetricFormatter(snapshot: snapshot, language: language, now: now)
        guard let value = formatter.value(id), let explanation = formatter.interpretation(id) else { return nil }
        func text(_ key: String) -> String { Localizer.text(key, language: language) }
        func format(_ key: String, _ arguments: CVarArg...) -> String {
            String(format: text(key), locale: language.locale, arguments: arguments)
        }
        func digits(_ value: Double, places: Int = 0) -> String {
            let number = NumberFormatter()
            number.locale = language.locale
            number.numberStyle = .decimal
            number.roundingMode = .halfUp
            number.maximumFractionDigits = places
            return number.string(from: NSNumber(value: value)) ?? "—"
        }
        func scale(_ position: Double, _ bands: [(Double, MetricTone)]) -> MetricScale {
            MetricScale(bands: bands.filter { $0.0 > 0 }.map { .init(fraction: $0.0, tone: $0.1) },
                        position: min(1, max(0, position)))
        }
        func percentage(_ ratio: Double, rounding: NumberFormatter.RoundingMode = .halfUp) -> String {
            // Avoid both arithmetic overflow and an unbounded widget label.
            let number = NumberFormatter()
            number.locale = language.locale
            number.numberStyle = .percent
            number.roundingMode = rounding
            number.maximumFractionDigits = 0
            let displayed = number.string(from: NSNumber(value: min(10, ratio))) ?? "—"
            return (ratio >= 10 ? "≥" : "") + displayed
        }
        let context = snapshot.metrics[id] != nil ? snapshot.metricContext : nil
        let score = value.rounded(.toNearestOrAwayFromZero)
        var result = MetricIndicator(status: explanation.status)

        switch id {
        case "sleepScore":
            result.reference = digits(score) + "/100"
            result.scale = sleepScale(score)
        case "sleepDuration":
            guard sameSleepRecord(id, "sleepScore", snapshot: snapshot),
                  let sleepScore = formatter.value("sleepScore"), sleepScore <= 100,
                  let sleep = formatter.interpretation("sleepScore") else {
                result.status = text("metric.sleepScore") + " · " + text("data.empty")
                return result
            }
            result.status = sleep.status
            result.reference = text("metric.sleepScore") + " · " + digits(sleepScore) + "/100"
            result.scale = sleepScale(sleepScore.rounded(.toNearestOrAwayFromZero))
        case "bodyBattery":
            result.reference = digits(score) + "/100"
            result.scale = scale(score / 100, [(0.25, .negative), (0.25, .caution), (0.25, .positive), (0.25, .positive)])
        case "trainingReadiness":
            result.reference = digits(score) + "/100"
            result.scale = scale(score / 100, [(0.25, .negative), (0.25, .caution), (0.25, .positive), (0.20, .positive), (0.05, .positive)])
        case "stress":
            result.reference = text("metric.short.stress") + " · " + digits(score) + "/100"
            result.scale = scale(score / 100, [(0.25, .positive), (0.25, .positive), (0.25, .caution), (0.25, .negative)])
        case "steps":
            // A whole cached snapshot can predate today without moving its
            // readings into retainedMetrics. Do not present that goal as current.
            result.status = text("explanation.steps.status")
            guard snapshot.sourceDate == SyncPolicy.sourceDay(for: now, timeZone: .autoupdatingCurrent),
                  snapshot.metrics[id] != nil, snapshot.metrics["stepGoal"] != nil,
                  let goal = snapshot.metrics["stepGoal"]?.value, goal.isFinite, goal > 0 else { return result }
            let ratio = value / goal
            // Rounding an unfinished goal upward to 100% would imply it was
            // reached. Other percentage-based metrics keep their normal rounding.
            let progress = percentage(ratio, rounding: value < goal ? .floor : .halfUp)
            result.status = format("explanation.steps.goal", digits(goal)) + " · " + progress
            result.reference = value >= goal ? text("explanation.steps.reached") : result.status
            result.scale = scale(value >= goal ? 1 : ratio, [(1, .neutral)])
        case "trainingLoad":
            if let low = context?.trainingLoadLower, let high = context?.trainingLoadUpper,
               low.isFinite, high.isFinite, low >= 0, high > low {
                // Normalize before multiplying, so even a finite extreme range
                // cannot overflow. The optimal band ends at 80% of the canvas.
                let lowerPosition = low / high * 0.8
                let position = value / high * 0.8
                result.status = value < low ? text("explanation.load.below")
                    : value > high ? text("explanation.load.above")
                    : text("explanation.load.optimal")
                result.reference = format("explanation.load.range", digits(low), digits(high))
                result.scale = scale(position, [(lowerPosition, .caution), (0.8 - lowerPosition, .positive), (0.2, .caution)])
            } else if let category = context?.trainingLoadStatus,
                      let index = ["LOW", "OPTIMAL", "HIGH", "VERY_HIGH"].firstIndex(of: category) {
                // This is Garmin's reported category of acute/chronic balance,
                // not a made-up percentage of the raw acute-load number.
                result.status = loadRatioStatus(index, language: language)
                if let ratio = context?.trainingLoadRatio, ratio.isFinite, ratio >= 0 {
                    result.reference = format("explanation.load.ratio.value", digits(ratio, places: 2) + "×")
                }
                result.scale = scale((Double(index) + 0.5) / 4,
                                     [(0.25, .caution), (0.25, .positive), (0.25, .caution), (0.25, .negative)])
            }
        case "hrv":
            var parts: [String] = []
            if let weekly = context?.hrvWeeklyAverage, weekly.isFinite, weekly > 0 {
                parts.append(format("explanation.hrv.weekly", digits(weekly), text("unit.ms")))
            }
            if let low = context?.hrvBaselineLow, let high = context?.hrvBaselineHigh,
               low.isFinite, high.isFinite, low > 0, high > low {
                parts.append(format("explanation.hrv.baseline", digits(low), digits(high), text("unit.ms")))
            }
            result.reference = parts.isEmpty ? nil : parts.joined(separator: " · ")
            // A nightly HRV value cannot mark a weekly-status scale.
        case "deepSleep", "remSleep", "lightSleep":
            guard sameSleepRecord(id, "sleepDuration", snapshot: snapshot),
                  let total = formatter.value("sleepDuration"), total > 0, value <= total else { return result }
            let fraction = value / total
            result.status = percentage(fraction) + " · " + text("metric.short.sleepDuration")
            result.reference = result.status
            result.scale = scale(fraction, [(1, .neutral)])
        default:
            // SpO2, pulse, VO2, weight, hydration and raw totals have no universal
            // good/bad percentage. Their short explanation remains visible.
            break
        }
        return result
    }

    /// Compact widget wording keeps the ratio distinct from the raw load.
    /// Detailed explanations continue to use the shared twelve-language catalog.
    private static func loadRatioStatus(_ index: Int, language: AppLanguage) -> String {
        let labels: [String]
        switch language.effectiveLanguage {
        case .system, .en: labels = ["Load ratio: low", "Load ratio: optimal", "Load ratio: high", "Load ratio: very high"]
        case .ru: labels = ["Соотношение: низкое", "Соотношение: оптимальное", "Соотношение: высокое", "Соотношение: очень высокое"]
        case .de: labels = ["Verhältnis: niedrig", "Verhältnis: optimal", "Verhältnis: hoch", "Verhältnis: sehr hoch"]
        case .fr: labels = ["Ratio : faible", "Ratio : optimal", "Ratio : élevé", "Ratio : très élevé"]
        case .es: labels = ["Ratio: bajo", "Ratio: óptimo", "Ratio: alto", "Ratio: muy alto"]
        case .it: labels = ["Rapporto: basso", "Rapporto: ottimale", "Rapporto: alto", "Rapporto: molto alto"]
        case .ptBR: labels = ["Relação: baixa", "Relação: ideal", "Relação: alta", "Relação: muito alta"]
        case .nl: labels = ["Verhouding: laag", "Verhouding: optimaal", "Verhouding: hoog", "Verhouding: zeer hoog"]
        case .pl: labels = ["Stosunek: niski", "Stosunek: optymalny", "Stosunek: wysoki", "Stosunek: bardzo wysoki"]
        case .ja: labels = ["負荷比：低い", "負荷比：最適", "負荷比：高い", "負荷比：非常に高い"]
        case .ko: labels = ["부하 비율: 낮음", "부하 비율: 최적", "부하 비율: 높음", "부하 비율: 매우 높음"]
        case .zhHans: labels = ["负荷比：偏低", "负荷比：最佳", "负荷比：偏高", "负荷比：过高"]
        }
        return labels[index]
    }

    private static func sleepScale(_ score: Double) -> MetricScale {
        .init(bands: [.init(fraction: 0.60, tone: .negative), .init(fraction: 0.20, tone: .caution),
                      .init(fraction: 0.10, tone: .positive), .init(fraction: 0.10, tone: .positive)],
              position: score / 100)
    }

    /// Never borrow yesterday's sleep score, or one from a different known
    /// sleep-ending timestamp, to assess the displayed duration or stage.
    private static func sameSleepRecord(_ first: String, _ second: String, snapshot: GarminSnapshot) -> Bool {
        guard let firstReading = snapshot.visibleReading(first), let secondReading = snapshot.visibleReading(second) else { return false }
        let firstCurrent = snapshot.metrics[first] != nil
        let secondCurrent = snapshot.metrics[second] != nil
        let firstDay = firstCurrent ? snapshot.sourceDate : snapshot.retainedMetrics[first]?.sourceDate
        let secondDay = secondCurrent ? snapshot.sourceDate : snapshot.retainedMetrics[second]?.sourceDate
        guard let firstDay, !firstDay.isEmpty, firstDay == secondDay else { return false }
        switch (firstReading.measuredAt, secondReading.measuredAt) {
        case let (.some(firstDate), .some(secondDate)): return firstDate == secondDate
        case (.none, .none):
            if firstCurrent && secondCurrent { return true }
            // Untimed retained values can originate in separate sparse fetches
            // of the same day. A shared retrieval is the remaining provenance.
            return !firstCurrent && !secondCurrent
                && snapshot.retainedMetrics[first]?.retrievedAt == snapshot.retainedMetrics[second]?.retrievedAt
        default: return false
        }
    }
}

import Foundation

struct MetricFormatter {
    let snapshot: GarminSnapshot
    let language: AppLanguage
    var now: Date = Date()

    func text(_ key: String) -> String { Localizer.text(key, language: language) }
    func interpretation(_ id: String) -> MetricExplanation? {
        MetricExplanation.make(metricID: id, snapshot: snapshot, language: language, now: now)
    }

    func help(_ id: String) -> String {
        [interpretation(id)?.supportingText, interpretation(id)?.detail, context(id)].compactMap { $0 }.joined(separator: "\n")
    }

    func accessibility(_ id: String) -> String {
        ([text(MetricDefinition.find(id).titleKey) + ": " + display(id)]
            + [interpretation(id)?.status, context(id)].compactMap { $0 }).joined(separator: ". ")
    }
    func value(_ id: String) -> Double? {
        if id == "bodyBattery", let estimate = snapshot.bodyBatteryEstimate(at: now) { return estimate }
        guard MetricDefinition.isSupported(id), let value = snapshot.visibleReading(id)?.value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    func isEstimated(_ id: String) -> Bool {
        id == "bodyBattery" && snapshot.bodyBatteryEstimate(at: now) != nil
    }

    func display(_ id: String) -> String {
        guard let value = value(id) else { return "—" }
        let unit = MetricDefinition.find(id).unit
        let number = NumberFormatter()
        number.locale = language.locale
        number.numberStyle = .decimal
        number.roundingMode = .halfUp
        number.maximumFractionDigits = [.km, .kg, .vo2, .breaths].contains(unit) ? 1 : 0
        let digits = number.string(from: NSNumber(value: value)) ?? "—"
        switch unit {
        case .minutes:
            guard value >= 0, value < Double(Int.max) else { return "—" }
            let minutes = Int(value.rounded())
            if minutes >= 60 { return "\(minutes / 60) \(text("unit.hours")) \(minutes % 60) \(text("unit.minutes"))" }
            return "\(minutes) \(text("unit.minutes"))"
        case .percent: return digits + "%"
        case .number, .score: return (isEstimated(id) ? "≈" : "") + digits
        default:
            let key: String
            switch unit {
            case .km: key = "km"
            case .kg: key = "kg"
            case .ml: key = "ml"
            case .bpm: key = "bpm"
            case .kcal: key = "kcal"
            case .ms: key = "ms"
            case .breaths: key = "breaths"
            case .vo2: key = "vo2"
            default: return digits
            }
            return digits + " " + text("unit." + key)
        }
    }

    /// Explain the period of a completed record, without treating a finished
    /// night's sleep or a past weigh-in as a failing live sensor.
    func context(_ id: String) -> String? {
        guard value(id) != nil else { return nil }
        if id == "bodyBattery", let measured = snapshot.visibleReading(id)?.measuredAt {
            let date = DateFormatter()
            date.locale = language.locale; date.dateStyle = .short; date.timeStyle = .short
            let measuredText = text("data.measured") + " " + date.string(from: measured)
            if isEstimated(id) {
                return (language.effectiveLanguage == .ru
                    ? "Линейная оценка по последнему тренду Garmin. "
                    : "Linear estimate from the latest Garmin trend. ") + measuredText
            }
            return measuredText
        }
        let scope = MetricDefinition.find(id).timeScope
        let retained = snapshot.retainedMetrics[id]
        let day = retained?.sourceDate ?? snapshot.sourceDate
        guard let date = TrainingPresentation(language: language).dayText(day) else { return nil }
        switch scope {
        case .nightlyRecord: return text("data.nightEnding") + " " + date
        case .dailyRecord: return text("data.day") + " " + date
        case .measurement:
            if let measured = snapshot.visibleReading(id)?.measuredAt {
                let formatter = DateFormatter()
                formatter.locale = language.locale
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
                return text("data.measured") + " " + formatter.string(from: measured)
            }
            return text("data.received") + " " + date
        case .progress:
            return retained == nil ? nil : text("data.previous") + " · " + date
        }
    }

    func progress(_ id: String) -> Double? {
        // Historical readings cannot imply progress toward today's goal.
        guard snapshot.retainedMetrics[id] == nil else { return nil }
        guard let value = value(id) else { return nil }
        if id == "steps", snapshot.retainedMetrics["stepGoal"] == nil, let goal = self.value("stepGoal"), goal > 0 { return min(1, max(0, value / goal)) }
        if ["bodyBattery", "stress", "sleepScore", "trainingReadiness", "spo2"].contains(id) { return min(1, max(0, value / 100)) }
        return nil
    }
}

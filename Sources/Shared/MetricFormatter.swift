import Foundation

struct MetricFormatter {
    let snapshot: GarminSnapshot
    let language: AppLanguage

    func text(_ key: String) -> String { Localizer.text(key, language: language) }
    func value(_ id: String) -> Double? {
        guard let value = snapshot.visibleReading(id)?.value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    func display(_ id: String) -> String {
        guard let value = value(id) else { return "—" }
        let unit = MetricDefinition.find(id).unit
        let number = NumberFormatter()
        number.locale = language.locale
        number.numberStyle = .decimal
        number.maximumFractionDigits = [.km, .kg, .vo2, .breaths].contains(unit) ? 1 : 0
        let digits = number.string(from: NSNumber(value: value)) ?? "—"
        switch unit {
        case .minutes:
            guard value >= 0, value < Double(Int.max) else { return "—" }
            let minutes = Int(value.rounded())
            if minutes >= 60 { return "\(minutes / 60) \(text("unit.hours")) \(minutes % 60) \(text("unit.minutes"))" }
            return "\(minutes) \(text("unit.minutes"))"
        case .percent: return digits + "%"
        case .number, .score: return digits
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

    func progress(_ id: String) -> Double? {
        // Historical readings cannot imply progress toward today's goal.
        guard snapshot.retainedMetrics[id] == nil else { return nil }
        guard let value = value(id) else { return nil }
        if id == "steps", snapshot.retainedMetrics["stepGoal"] == nil, let goal = self.value("stepGoal"), goal > 0 { return min(1, max(0, value / goal)) }
        if ["bodyBattery", "stress", "sleepScore", "trainingReadiness", "spo2"].contains(id) { return min(1, max(0, value / 100)) }
        return nil
    }
}

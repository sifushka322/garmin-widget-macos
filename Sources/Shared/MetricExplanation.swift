import Foundation

/// Context supplied by Garmin for the same records as the snapshot. Missing
/// personal ranges stay missing; a raw number is never a fitness diagnosis.
struct GarminMetricContext: Codable, Equatable {
    var trainingLoadLower: Double? = nil
    var trainingLoadUpper: Double? = nil
    var trainingStatus: String? = nil
    var hrvStatus: String? = nil
    var hrvWeeklyAverage: Double? = nil
    var hrvBaselineLow: Double? = nil
    var hrvBaselineHigh: Double? = nil
    /// Garmin's acute-to-chronic ratio label is distinct from an acute-load range.
    var trainingLoadStatus: String? = nil
    var trainingLoadRatio: Double? = nil
}

struct MetricExplanation: Equatable {
    /// A short interpretation suitable for a widget or a metric card.
    var status: String
    /// Personal range, or a separate Garmin training status, when supplied.
    var supportingText: String? = nil
    var detail: String
    var sourceURL: URL? = nil

    static func helpLabel(language: AppLanguage) -> String {
        Localizer.text("explanation.help", language: language)
    }

    static func sourceLabel(language: AppLanguage) -> String {
        Localizer.text("explanation.source", language: language)
    }

    static func make(metricID id: String, snapshot: GarminSnapshot, language: AppLanguage,
                     now: Date = Date()) -> MetricExplanation? {
        guard let value = MetricFormatter(snapshot: snapshot, language: language, now: now).value(id) else { return nil }
        func text(_ key: String) -> String { Localizer.text("explanation." + key, language: language) }
        func format(_ key: String, _ arguments: CVarArg...) -> String {
            String(format: text(key), locale: language.locale, arguments: arguments)
        }
        func explanation(_ status: String, _ detail: String, supporting: String? = nil, source: String? = nil) -> MetricExplanation {
            MetricExplanation(status: status, supportingText: supporting, detail: detail, sourceURL: source.flatMap(URL.init(string:)))
        }
        func digits(_ number: Double) -> String {
            let formatter = NumberFormatter()
            formatter.locale = language.locale; formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 0
            return formatter.string(from: NSNumber(value: number)) ?? "—"
        }
        let context = snapshot.retainedMetrics[id] == nil ? snapshot.metricContext : nil
        // These Garmin scales are displayed as whole points, including a
        // projected Body Battery value. Keep the label on the displayed band.
        let score = value.rounded(.toNearestOrAwayFromZero)
        switch id {
        case "trainingLoad":
            let loadSource = "https://www.garmin.com/en-GB/garmin-technology/cycling-science/physiological-measurements/training-load/"
            var status = text("load.rangeUnavailable")
            var lines: [String] = []
            switch context?.trainingLoadStatus {
            case "LOW": status = text("load.ratio.low")
            case "OPTIMAL": status = text("load.ratio.optimal")
            case "HIGH": status = text("load.ratio.high")
            case "VERY_HIGH": status = text("load.ratio.veryHigh")
            default: break
            }
            if let ratio = context?.trainingLoadRatio, ratio.isFinite, ratio >= 0 {
                let formatter = NumberFormatter()
                formatter.locale = language.locale; formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 2
                if let value = formatter.string(from: NSNumber(value: ratio)) {
                    lines.append(format("load.ratio.value", value))
                }
            }
            if let low = context?.trainingLoadLower, let high = context?.trainingLoadUpper,
               low.isFinite, high.isFinite, low >= 0, high > low {
                status = value < low ? text("load.below")
                    : value > high ? text("load.above")
                    : text("load.optimal")
                lines.append(format("load.range", digits(low), digits(high)))
            }
            var detail = text("load.detail")
            if context?.trainingLoadRatio != nil || context?.trainingLoadStatus != nil {
                detail += "\n\n" + text("load.ratio.detail")
            }
            if let training = trainingStatus(context?.trainingStatus, language: language) {
                lines.append(format("load.garminStatus", training.title))
                detail += "\n\n" + format("labeledDetail", training.title, training.detail)
            } else {
                detail += "\n\n" + text("load.noStatusDetail")
            }
            return explanation(status, detail, supporting: lines.isEmpty ? nil : lines.joined(separator: "\n"), source: loadSource)
        case "hrv":
            var status = text("hrv.compare")
            switch context?.hrvStatus?.uppercased().replacingOccurrences(of: "-", with: "_") {
            case "BALANCED": status = text("hrv.balanced")
            case "UNBALANCED": status = text("hrv.unbalanced")
            case "LOW": status = text("hrv.low")
            case "POOR": status = text("hrv.poor")
            case "NONE", "NO_STATUS": status = text("hrv.insufficient")
            default: break
            }
            var lines: [String] = []
            if let weekly = context?.hrvWeeklyAverage, weekly.isFinite, weekly > 0 {
                lines.append(format("hrv.weekly", digits(weekly), Localizer.text("unit.ms", language: language)))
            }
            if let low = context?.hrvBaselineLow, let high = context?.hrvBaselineHigh,
               low.isFinite, high.isFinite, low > 0, high > low {
                lines.append(format("hrv.baseline", digits(low), digits(high), Localizer.text("unit.ms", language: language)))
            }
            return explanation(status, text("hrv.detail"),
                supporting: lines.isEmpty ? nil : lines.joined(separator: "\n"),
                source: "https://www8.garmin.com/manuals/webhelp/GUID-25E3235D-44D2-4384-A591-DD1D71BEBCB1/EN-US/GUID-9282196F-D969-404D-B678-F48A13D8D0CB.html")
        case "trainingReadiness":
            guard value >= 1, value <= 100 else { return nil }
            let status = score >= 95 ? text("readiness.prime")
                : score >= 75 ? text("readiness.high")
                : score >= 50 ? text("readiness.moderate")
                : score >= 25 ? text("readiness.low")
                : text("readiness.poor")
            return explanation(status, text("readiness.detail"),
                source: "https://www.garmin.com/en-MY/garmin-technology/running-science-entry-level/after-running/training-readiness/")
        case "sleepScore":
            guard value <= 100 else { return nil }
            let status = score >= 90 ? text("sleep.excellent")
                : score >= 80 ? text("sleep.good")
                : score >= 60 ? text("sleep.fair") : text("sleep.poor")
            return explanation(status, text("sleep.detail"),
                source: "https://support.garmin.com/en-IN/?faq=mBRMf4ks7XAQ03qtsbI8J6")
        case "stress":
            guard value <= 100 else { return nil }
            let status = score <= 25 ? text("stress.resting")
                : score <= 50 ? text("stress.low")
                : score <= 75 ? text("stress.medium") : text("stress.high")
            return explanation(status, text("stress.detail"),
                source: "https://www8.garmin.com/manuals/webhelp/legacy/EN-US/GUID-9282196F-D969-404D-B678-F48A13D8D0CB.html")
        case "bodyBattery":
            guard value <= 100 else { return nil }
            let status = score <= 25 ? text("battery.veryLow")
                : score <= 50 ? text("battery.low")
                : score <= 75 ? text("battery.moderate") : text("battery.high")
            return explanation(status, text("battery.detail"),
                source: "https://www8.garmin.com/manuals/webhelp/GUID-2CF5620C-E585-4E0A-9CC3-9565533EEE4D/EN-US/GUID-87E1392B-2C55-40B7-A1FF-3AB9252DA0A0.html")
        case "recoveryTime":
            return explanation(value == 0 ? text("recovery.complete") : text("recovery.remaining"), text("recovery.detail"),
                source: "https://www8.garmin.com/manuals/webhelp/GUID-5D183A14-BB43-4A9B-B441-5F824214CE40/EN-US/GUID-DAC27D10-886A-4EA8-8339-674479E9574A.html")
        case "vo2Max":
            return explanation(text("vo2.status"), text("vo2.detail"),
                source: "https://www8.garmin.com/manuals/webhelp/GUID-AC520B63-3C82-4266-90F6-6E9F22D5F76E/EN-US/GUID-1FBCCD9E-19E1-4E4C-BD60-1793B5B97EB3.html")
        case "restingHeartRate":
            return explanation(text("restingHR.status"), text("restingHR.detail"))
        case "spo2":
            return explanation(text("oxygen.status"), text("oxygen.detail"))
        case "respiration":
            return explanation(text("respiration.status"), text("respiration.detail"))
        case "sleepDuration":
            return explanation(text("sleepDuration.status"), text("sleepDuration.detail"))
        case "deepSleep", "remSleep", "lightSleep", "awakeSleep":
            let status = id == "awakeSleep" ? text("sleepStage.awake") : text("sleepStage.status")
            return explanation(status, text("sleepStage.detail"))
        case "steps":
            var status = text("steps.status")
            if snapshot.retainedMetrics[id] == nil, snapshot.retainedMetrics["stepGoal"] == nil,
               let goal = snapshot.metrics["stepGoal"]?.value, goal.isFinite, goal > 0 {
                status = value >= goal ? text("steps.reached") : text("steps.progress")
                return explanation(status, text("steps.goalDetail"), supporting: format("steps.goal", digits(goal)))
            }
            return explanation(status, text("steps.detail"))
        case "stepGoal":
            return explanation(text("stepsTarget.status"), text("stepsTarget.detail"))
        case "intensityMinutes":
            return explanation(text("intensity.status"), text("intensity.detail"))
        case "calories":
            return explanation(text("calories.status"), text("calories.detail"))
        case "activeCalories":
            return explanation(text("activeCalories.status"), text("activeCalories.detail"))
        case "distance":
            return explanation(text("distance.status"), text("distance.detail"))
        case "floors":
            return explanation(text("floors.status"), text("floors.detail"))
        case "weight":
            return explanation(text("weight.status"), text("weight.detail"))
        case "hydration":
            return explanation(text("hydration.status"), text("hydration.detail"))
        default: return nil
        }
    }

    private static func trainingStatus(_ raw: String?, language: AppLanguage) -> (title: String, detail: String)? {
        guard let raw else { return nil }
        let key = raw.uppercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        let code: String
        switch key {
        case "DETRAINING": code = "DETRAINING"
        case "RECOVERY": code = "RECOVERY"
        case "MAINTAINING": code = "MAINTAINING"
        case "PRODUCTIVE": code = "PRODUCTIVE"
        case "PEAKING": code = "PEAKING"
        case "OVERREACHING": code = "OVERREACHING"
        case "UNPRODUCTIVE": code = "UNPRODUCTIVE"
        case "STRAINED": code = "STRAINED"
        case "NO_STATUS", "NONE": code = "NO_STATUS"
        case "PAUSED": code = "PAUSED"
        default: return nil
        }
        return (Localizer.text("explanation.training." + code + ".title", language: language),
                Localizer.text("explanation.training." + code + ".detail", language: language))
    }
}

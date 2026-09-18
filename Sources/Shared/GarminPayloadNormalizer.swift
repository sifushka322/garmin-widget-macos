import Foundation
import CoreFoundation

/// Converts unmodified Garmin JSON payloads into the widget's canonical units.
/// This type has no transport, storage, clock or authentication dependencies.
enum GarminPayloadNormalizer {
    static let groups = ["stats", "heart", "body_battery", "sleep", "hrv", "spo2",
                         "respiration", "readiness", "vo2_max", "training", "weight", "hydration"]

    /// True means the payload is a known response shape, including an explicit absence.
    /// Transport errors and HTML must be rejected by the caller before reaching this API.
    static func isRecognizedPayload(group: String, payload: Any) -> Bool {
        guard groups.contains(group) else { return false }
        if payload is NSNull { return true }

        func has(_ object: [String: Any], _ keys: Set<String>) -> Bool {
            !keys.isDisjoint(with: object.keys)
        }
        func objectEnvelope(_ object: [String: Any], _ key: String) -> Bool {
            guard let nested = object[key] else { return false }
            return nested is NSNull || nested is [String: Any]
        }
        func arrayEnvelope(_ object: [String: Any], _ key: String,
                           accepts: ([String: Any]) -> Bool) -> Bool {
            guard let nested = object[key] else { return false }
            if nested is NSNull { return true }
            guard let array = nested as? [Any] else { return false }
            return array.allSatisfy { ($0 as? [String: Any]).map(accepts) ?? false }
        }
        func recordArray(_ accepts: ([String: Any]) -> Bool) -> Bool {
            guard let array = payload as? [Any] else { return false }
            return array.allSatisfy { ($0 as? [String: Any]).map(accepts) ?? false }
        }

        let object = dictionary(payload)
        switch group {
        case "stats":
            return has(object, ["totalSteps", "dailyStepGoal", "totalDistanceMeters", "totalKilocalories",
                                "activeKilocalories", "floorsAscended", "restingHeartRate", "averageStressLevel",
                                "moderateIntensityMinutes", "vigorousIntensityMinutes", "bodyBatteryMostRecentValue", "calendarDate", "privacyProtected"])
        case "heart":
            return has(object, ["heartRateValues", "restingHeartRate", "calendarDate"])
                && (object["heartRateValues"] == nil || object["heartRateValues"] is NSNull || object["heartRateValues"] is [Any])
        case "body_battery":
            return recordArray {
                has($0, ["bodyBatteryValuesArray", "date", "charged", "drained"])
                    && ($0["bodyBatteryValuesArray"] == nil || $0["bodyBatteryValuesArray"] is NSNull || $0["bodyBatteryValuesArray"] is [Any])
            }
        case "sleep": return objectEnvelope(object, "dailySleepDTO")
        case "hrv": return objectEnvelope(object, "hrvSummary")
        case "spo2": return has(object, ["averageSpO2", "calendarDate", "lastSevenDaysAvgSpO2"])
        case "respiration": return has(object, ["avgSleepRespirationValue", "calendarDate"])
        case "readiness":
            return recordArray { has($0, ["score", "recoveryTime", "recoveryTimeChangePhrase", "timestamp", "inputContext"]) }
        case "vo2_max":
            let accepts: ([String: Any]) -> Bool = { objectEnvelope($0, "generic") || objectEnvelope($0, "cycling") }
            return payload is [String: Any] ? accepts(object) : recordArray(accepts)
        case "training": return objectEnvelope(object, "mostRecentTrainingStatus")
        case "weight":
            return arrayEnvelope(object, "dateWeightList") { has($0, ["weight", "timestampGMT", "samplePk"]) }
        case "hydration": return has(object, ["valueInML", "calendarDate"])
        default: return false
        }
    }

    /// Validate only explicit day labels with established daily semantics.
    /// Overnight/historical measurements must not infer a local day from UTC.
    static func matchesSourceDay(group: String, payload: Any, sourceDay: String) -> Bool {
        func matches(_ value: Any?) -> Bool {
            guard let value, !(value is NSNull) else { return true }
            return (value as? String) == sourceDay
        }
        switch group {
        case "stats", "hydration": return matches(dictionary(payload)["calendarDate"])
        case "body_battery": return records(payload).allSatisfy { matches($0["date"]) }
        default: return true
        }
    }

    static func normalize(group: String, payload: Any, asOf: Date? = nil) -> [String: MetricReading] {
        var result: [String: MetricReading] = [:]
        let object = dictionary(payload)

        func put(_ key: String, _ raw: Any?, scale: Double = 1, measuredAt: Date? = nil,
                 positive: Bool = false, maximum: Double? = nil) {
            guard let value = number(raw, positive: positive),
                  maximum.map({ value <= $0 }) ?? true else { return }
            let converted = value * scale
            guard converted.isFinite else { return }
            // Match the bridge's four-decimal payload precision without overflow.
            let rounded = abs(converted) <= Double.greatestFiniteMagnitude / 10_000
                ? (converted * 10_000).rounded(.toNearestOrEven) / 10_000 : converted
            result[key] = MetricReading(value: rounded, measuredAt: measuredAt)
        }

        switch group {
        case "stats":
            for (key, field) in ["steps": "totalSteps", "stepGoal": "dailyStepGoal",
                                 "calories": "totalKilocalories", "activeCalories": "activeKilocalories",
                                 "floors": "floorsAscended", "restingHeartRate": "restingHeartRate"] {
                put(key, object[field], positive: key == "stepGoal" || key == "restingHeartRate")
            }
            put("distance", object["totalDistanceMeters"], scale: 0.001)
            put("stress", object["averageStressLevel"], maximum: 100)
            // Garmin's daily report can be sparse; its daily summary also exposes
            // the current scalar. No documented measurement time accompanies it.
            put("bodyBattery", object["bodyBatteryMostRecentValue"], maximum: 100)
            if let moderate = number(object["moderateIntensityMinutes"]),
               let vigorous = number(object["vigorousIntensityMinutes"]) {
                put("intensityMinutes", moderate + 2 * vigorous)
            }
        case "heart":
            if let sample = latestPair(object["heartRateValues"], positive: true) {
                put("heartRate", sample.value, measuredAt: sample.date, positive: true)
            }
            put("restingHeartRate", object["restingHeartRate"], positive: true)
        case "body_battery":
            let samples = bodyBatterySamples(payload: payload).filter {
                asOf == nil || $0.measuredAt! <= asOf!
            }
            if let sample = samples.max(by: { $0.measuredAt! < $1.measuredAt! }) {
                put("bodyBattery", sample.value, measuredAt: sample.measuredAt, maximum: 100)
            }
        case "sleep":
            let sleep = dictionary(object["dailySleepDTO"])
            let measuredAt = timestamp(sleep["sleepEndTimestampGMT"], knownUTC: true)
            for (key, field) in ["sleepDuration": "sleepTimeSeconds", "deepSleep": "deepSleepSeconds",
                                 "remSleep": "remSleepSeconds", "lightSleep": "lightSleepSeconds",
                                 "awakeSleep": "awakeSleepSeconds"] {
                put(key, sleep[field], scale: 1 / 60, measuredAt: measuredAt)
            }
            let overall = dictionary(dictionary(sleep["sleepScores"])["overall"])
            put("sleepScore", overall["value"], measuredAt: measuredAt, maximum: 100)
        case "hrv":
            put("hrv", dictionary(object["hrvSummary"])["lastNightAvg"],
                measuredAt: timestamp(object["sleepEndTimestampGMT"], knownUTC: true), positive: true)
        case "spo2":
            put("spo2", object["averageSpO2"], positive: true, maximum: 100)
        case "respiration":
            put("respiration", object["avgSleepRespirationValue"], positive: true)
        case "readiness":
            let entries = records(payload)
            let dated = entries.compactMap { entry -> (date: Date, entry: [String: Any])? in
                guard let date = timestamp(entry["timestamp"], knownUTC: true) else { return nil }
                return (date, entry)
            }
            let selected: [String: Any]
            let measuredAt: Date?
            if let latest = dated.max(by: { $0.date < $1.date }) {
                selected = latest.entry; measuredAt = latest.date
            } else if entries.count == 1 {
                selected = entries[0]; measuredAt = nil
            } else { return [:] }
            put("trainingReadiness", selected["score"], measuredAt: measuredAt, maximum: 100)
            let recovery: Any? = selected["recoveryTimeChangePhrase"] as? String == "REACHED_ZERO"
                ? 0 : selected["recoveryTime"]
            put("recoveryTime", recovery, measuredAt: measuredAt)
        case "vo2_max":
            var entries = records(payload)
            if entries.isEmpty, payload is [String: Any] { entries = [object] }
            let generic = entries.map { dictionary($0["generic"]) }.filter { !$0.isEmpty }
            guard let latest = generic.max(by: {
                ($0["calendarDate"] as? String ?? "") < ($1["calendarDate"] as? String ?? "")
            }) else { return [:] }
            let value = number(latest["vo2MaxPreciseValue"], positive: true)
                ?? number(latest["vo2MaxValue"], positive: true)
            put("vo2Max", value, positive: true)
        case "training":
            guard let selected = trainingEntry(object) else { return [:] }
            put("trainingLoad", dictionary(selected["acuteTrainingLoadDTO"])["dailyTrainingLoadAcute"])
        case "weight":
            let entries = records(object["dateWeightList"])
            let dated = entries.compactMap { entry -> (date: Date, entry: [String: Any])? in
                guard let date = timestamp(entry["timestampGMT"], knownUTC: true),
                      number(entry["weight"], positive: true) != nil else { return nil }
                return (date, entry)
            }
            if let latest = dated.max(by: { $0.date < $1.date }) {
                put("weight", latest.entry["weight"], scale: 0.001, measuredAt: latest.date, positive: true)
            } else if entries.count == 1 {
                put("weight", entries[0]["weight"], scale: 0.001, positive: true)
            }
        case "hydration":
            put("hydration", object["valueInML"])
        default:
            break
        }
        return result
    }

    static func bodyBatteryProjection(payload: Any, asOf: Date) -> BodyBatteryProjection? {
        BodyBatteryProjection.make(samples: bodyBatterySamples(payload: payload), asOf: asOf)
    }

    private static func bodyBatterySamples(payload: Any) -> [MetricReading] {
        records(payload).flatMap { entry in
            (entry["bodyBatteryValuesArray"] as? [Any] ?? []).compactMap { raw -> MetricReading? in
                // The daily report is a documented pair array. Do not guess the
                // meaning of extra fields or turn a status string into a number.
                guard let row = raw as? [Any], row.count == 2,
                      let date = timestamp(row[0]), let value = number(row[1]), value <= 100 else { return nil }
                return .init(value: value, measuredAt: date)
            }
        }
    }

    /// Preserve only known interpretation fields from the very same device
    /// selection used for the metric. Unknown strings never enter the UI.
    static func metricContext(group: String, payload: Any) -> GarminMetricContext? {
        let object = dictionary(payload)
        var result = GarminMetricContext()
        switch group {
        case "training":
            guard let selected = trainingEntry(object) else { return nil }
            let statuses: Set<String> = ["DETRAINING", "RECOVERY", "MAINTAINING", "PRODUCTIVE", "PEAKING",
                                         "OVERREACHING", "UNPRODUCTIVE", "STRAINED", "NO_STATUS", "NONE", "PAUSED"]
            result.trainingStatus = statusToken(selected["trainingStatusFeedbackPhrase"], allowed: statuses, numberedPhrase: true)
                ?? statusToken(selected["trainingStatus"], allowed: statuses)
            let acute = dictionary(selected["acuteTrainingLoadDTO"])
            result.trainingLoadStatus = statusToken(acute["acwrStatus"], allowed: ["LOW", "OPTIMAL", "HIGH", "VERY_HIGH"])
            result.trainingLoadRatio = number(acute["dailyAcuteChronicWorkloadRatio"])
            // min/maxTrainingLoadChronic refer to chronic load. Do not present
            // them as an acute-load target or classify an acute reading by them.
        case "hrv":
            let summary = dictionary(object["hrvSummary"])
            result.hrvStatus = statusToken(summary["status"], allowed: ["BALANCED", "UNBALANCED", "LOW", "POOR", "NONE", "NO_STATUS"])
            result.hrvWeeklyAverage = number(summary["weeklyAvg"], positive: true)
            let baseline = dictionary(summary["baseline"])
            if let low = number(baseline["balancedLow"], positive: true),
               let high = number(baseline["balancedUpper"], positive: true), high > low {
                result.hrvBaselineLow = low; result.hrvBaselineHigh = high
            }
        default: return nil
        }
        return result == GarminMetricContext() ? nil : result
    }

    private static func trainingEntry(_ object: [String: Any]) -> [String: Any]? {
        let latest = dictionary(object["mostRecentTrainingStatus"])
        var entries = dictionary(latest["latestTrainingStatusData"]).values.compactMap { $0 as? [String: Any] }
        let primary = entries.filter { trueBoolean($0["primaryTrainingDevice"]) }
        if !primary.isEmpty { entries = primary }
        return entries.count == 1 ? entries[0] : nil
    }

    private static func statusToken(_ raw: Any?, allowed: Set<String>, numberedPhrase: Bool = false) -> String? {
        guard let raw = raw as? String, raw.utf8.count <= 80 else { return nil }
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if numberedPhrase, let split = token.lastIndex(of: "_") {
            let suffix = token[token.index(after: split)...]
            if !suffix.isEmpty && suffix.allSatisfy({ $0.isASCII && $0.isNumber }) {
                token = String(token[..<split])
            }
        }
        return allowed.contains(token) ? token : nil
    }

    static func deviceNames(from payload: Any) -> [String] {
        var seen = Set<String>()
        return records(payload).compactMap { entry in
            guard let raw = entry["displayName"] as? String else { return nil }
            let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            return !name.isEmpty && seen.insert(name).inserted ? name : nil
        }
    }

    private static func dictionary(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    private static func records(_ value: Any?) -> [[String: Any]] {
        (value as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    private static func number(_ value: Any?, positive: Bool = false) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let numeric = value.doubleValue
        guard numeric.isFinite, numeric >= 0, !positive || numeric > 0 else { return nil }
        return numeric
    }

    private static func trueBoolean(_ value: Any?) -> Bool {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return value.boolValue
    }

    private static func latestPair(_ value: Any?, maximum: Double? = nil,
                                   positive: Bool = false) -> (value: Double, date: Date)? {
        var best: (value: Double, date: Date)?
        for raw in value as? [Any] ?? [] {
            guard let row = raw as? [Any], row.count >= 2,
                  let date = timestamp(row[0]), let value = number(row[1], positive: positive),
                  maximum.map({ value <= $0 }) ?? true else { continue }
            if best == nil || date > best!.date { best = (value, date) }
        }
        return best
    }

    /// Garmin sample arrays use milliseconds; date-only and unknown local strings are not instants.
    private static func timestamp(_ raw: Any?, knownUTC: Bool = false) -> Date? {
        if let epoch = number(raw, positive: true) {
            guard epoch >= 946_684_800_000, epoch < 253_402_300_800_000 else { return nil }
            return Date(timeIntervalSince1970: floor(epoch / 1_000))
        }
        guard var string = raw as? String,
              string.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?$"#,
                           options: .regularExpression) != nil,
              validISOComponents(string) else { return nil }
        let hasZone = string.hasSuffix("Z")
            || string.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
        if !hasZone {
            guard knownUTC else { return nil }
            string += "Z"
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var parsed = formatter.date(from: string)
        if parsed == nil {
            formatter.formatOptions = [.withInternetDateTime]
            parsed = formatter.date(from: string)
        }
        guard let parsed else { return nil }
        return Date(timeIntervalSince1970: floor(parsed.timeIntervalSince1970))
    }

    private static func validISOComponents(_ string: String) -> Bool {
        // ISO8601DateFormatter accepts normalized dates such as February 30 and
        // 24:00. Garmin instants must be valid without silently rolling a date.
        let components = string.prefix(19).split { "-T:".contains($0) }.compactMap { Int($0) }
        guard components.count == 6 else { return false }
        let year = components[0], month = components[1], day = components[2]
        guard (1...9999).contains(year), (1...12).contains(month),
              (0...23).contains(components[3]), (0...59).contains(components[4]),
              (0...59).contains(components[5]) else { return false }
        let leap = year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...days[month - 1]).contains(day) else { return false }
        if let zoneRange = string.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) {
            let digits = string[zoneRange].filter { $0.isNumber }
            guard let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)),
                  hours <= 23, minutes <= 59 else { return false }
        }
        return true
    }
}

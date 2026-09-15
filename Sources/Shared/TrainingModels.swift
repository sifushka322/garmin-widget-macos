import Foundation
import CoreFoundation

enum TrainingSource: String, Codable, Equatable, Sendable {
    case calendar
    case adaptiveCalendar = "adaptive_calendar"
}

enum PastTrainingCoverage: String, Codable, Equatable, Sendable {
    case recentActivities = "recent_activities"
    case unavailable
}

enum FutureTrainingCoverage: String, Codable, Equatable, Sendable {
    case publishedCalendar = "published_calendar"
    case adaptiveVerified = "adaptive_verified"
    case unavailable
}

struct PastActivitySummary: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var sportKey: String
    var startedAt: Date? = nil
    var localStart: String? = nil
    var durationMinutes: Double? = nil
    var movingMinutes: Double? = nil
    var distanceKM: Double? = nil
    var calories: Double? = nil
    var averageHeartRate: Double? = nil
    var maximumHeartRate: Double? = nil
}

struct PlannedWorkoutSummary: Codable, Equatable, Identifiable, Sendable {
    var occurrenceID: String
    var id: String { occurrenceID }
    var workoutID: String? = nil
    var localDate: String
    var startsAt: Date? = nil
    var title: String
    var sportKey: String
    var durationMinutes: Double? = nil
    var distanceKM: Double? = nil
    var source: TrainingSource = .calendar
    var planID: String? = nil
}

struct TrainingTimelineSnapshot: Codable, Equatable, Identifiable, Sendable {
    var fetchedAt: Date
    var id: Date { fetchedAt }
    var past: [PastActivitySummary] = []
    var upcoming: [PlannedWorkoutSummary] = []
    var pastCoverageStart: String? = nil
    var futureCoverageEnd: String? = nil
    var pastCoverage: PastTrainingCoverage = .unavailable
    var futureCoverage: FutureTrainingCoverage = .unavailable
    var warnings: [String] = []
    // Retrieval times are distinct from activity dates and workout appointments.
    // A retained section keeps its original time after a failed refresh.
    var pastUpdatedAt: Date? = nil
    var futureUpdatedAt: Date? = nil
    var futureCoveredMonths: [String]? = nil
    var pastIssue: String? = nil
    var futureIssue: String? = nil
}

/// Pure, read-only conversion of activity-list and calendar payloads.
/// Saved workout templates and calendar history never become completed activities.
enum TrainingNormalizer {
    static let pastLimit = 20

    static func isRecognizedPastPayload(payload: Any) -> Bool {
        if payload is NSNull { return true }
        guard let rows = activityRows(payload) else { return false }
        return rows.allSatisfy { row in
            guard let row = row as? [String: Any] else { return false }
            return row["activityId"] != nil
        }
    }

    static func isRecognizedPlannedPayload(payload: Any) -> Bool {
        if payload is NSNull { return true }
        guard let envelopes = calendarEnvelopes(payload) else { return false }
        return envelopes.allSatisfy { envelope in
            if envelope["calendarItems"] is NSNull { return true }
            guard let rows = envelope["calendarItems"] as? [Any] else { return false }
            return rows.allSatisfy { ($0 as? [String: Any])?["itemType"] is String }
        }
    }

    static func past(payload: Any) -> [PastActivitySummary] {
        var byID: [String: PastActivitySummary] = [:]
        for raw in activityRows(payload) ?? [] {
            guard let row = raw as? [String: Any], let id = decimalID(row["activityId"]) else { continue }
            let utc = instant(row["startTimeGMT"], knownUTC: true)
            let local = utc == nil ? localDateTime(row["startTimeLocal"]) : nil
            let item = PastActivitySummary(
                id: id, title: plainText(row["activityName"]), sportKey: sport(dictionary(row["activityType"])["typeKey"]),
                startedAt: utc, localStart: local,
                durationMinutes: converted(row["duration"], divisor: 60),
                movingMinutes: converted(row["movingDuration"], divisor: 60),
                distanceKM: converted(row["distance"], divisor: 1_000),
                calories: number(row["calories"]), averageHeartRate: number(row["averageHR"], positive: true),
                maximumHeartRate: number(row["maxHR"], positive: true))
            // The list endpoint is newest first. Keep its first valid identity,
            // while allowing a duplicate to supply a previously missing instant.
            if byID[id] == nil || (byID[id]?.startedAt == nil && item.startedAt != nil) { byID[id] = item }
        }
        return Array(byID.values.sorted(by: activityOrder).prefix(pastLimit))
    }

    /// Reads one month or a batch of at most two month envelopes.
    /// The retained window is sourceDay through the end of the following month.
    static func planned(payload: Any, sourceDay: String) -> [PlannedWorkoutSummary] {
        guard validDay(sourceDay) else { return [] }
        let exclusiveEnd = calendarWindowEnd(sourceDay)
        var byID: [String: PlannedWorkoutSummary] = [:]
        for envelope in calendarEnvelopes(payload) ?? [] {
            for raw in envelope["calendarItems"] as? [Any] ?? [] {
                guard let row = raw as? [String: Any], row["itemType"] as? String == "workout",
                      let day = row["date"] as? String, validDay(day), day >= sourceDay,
                      exclusiveEnd.map({ day < $0 }) ?? true else { continue }
                let workoutID = decimalID(row["workoutId"])
                let calendarID = identifier(row["id"]) ?? decimalID(row["scheduledWorkoutId"])
                let identity: String
                if let calendarID {
                    identity = "calendar:occurrence:\(calendarID):\(day)"
                } else if let workoutID {
                    // Without a schedule ID the source cannot distinguish two
                    // occurrences of the same template on the same date.
                    identity = "calendar:workout:\(workoutID):\(day)"
                } else { continue }
                let item = PlannedWorkoutSummary(
                    occurrenceID: identity, workoutID: workoutID, localDate: day,
                    startsAt: instant(row["startTimeGMT"], knownUTC: true),
                    title: plainText(row["title"]), sportKey: sport(row["sportTypeKey"]),
                    durationMinutes: converted(row["estimatedDurationInSecs"], divisor: 60)
                        ?? converted(row["durationInMilliseconds"], divisor: 60_000),
                    // The calendar's bare distance/duration fields have not had
                    // their units verified. Do not silently turn them into km/min.
                    distanceKM: nil, source: .calendar,
                    planID: decimalID(row["atpPlanId"]) ?? decimalID(row["trainingPlanId"]))
                if byID[identity] == nil { byID[identity] = item }
            }
        }
        return byID.values.sorted {
            if $0.localDate != $1.localDate { return $0.localDate < $1.localDate }
            if let left = $0.startsAt, let right = $1.startsAt, left != right { return left < right }
            // Date-only entries remain all-day instead of receiving midnight.
            if ($0.startsAt == nil) != ($1.startsAt == nil) { return $0.startsAt == nil }
            return $0.occurrenceID < $1.occurrenceID
        }
    }

    private static func activityRows(_ payload: Any) -> [Any]? {
        if let array = payload as? [Any] { return array }
        guard let object = payload as? [String: Any] else { return nil }
        if object["activityList"] is NSNull { return [] }
        return object["activityList"] as? [Any]
    }

    private static func calendarEnvelopes(_ payload: Any) -> [[String: Any]]? {
        if let object = payload as? [String: Any], object["calendarItems"] != nil { return [object] }
        guard let array = payload as? [Any], array.count <= 2 else { return nil }
        let envelopes = array.compactMap { $0 as? [String: Any] }
        guard envelopes.count == array.count, envelopes.allSatisfy({ $0["calendarItems"] != nil }) else { return nil }
        return envelopes
    }

    private static func activityOrder(_ left: PastActivitySummary, _ right: PastActivitySummary) -> Bool {
        if let leftDate = left.startedAt, let rightDate = right.startedAt, leftDate != rightDate { return leftDate > rightDate }
        if (left.startedAt == nil) != (right.startedAt == nil) { return left.startedAt != nil }
        if left.localStart != right.localStart { return (left.localStart ?? "") > (right.localStart ?? "") }
        return left.id < right.id
    }

    private static func dictionary(_ raw: Any?) -> [String: Any] { raw as? [String: Any] ?? [:] }

    private static func plainText(_ raw: Any?, limit: Int = 160) -> String {
        guard let string = raw as? String else { return "" }
        let withoutTags = string.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
        let safe = withoutTags.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        return String(safe.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(limit))
    }

    private static func sport(_ raw: Any?) -> String {
        guard let string = raw as? String, !string.isEmpty, string.count <= 64,
              string.range(of: #"^[A-Za-z0-9_]+$"#, options: .regularExpression) != nil else { return "unknown" }
        return string
    }

    private static func number(_ raw: Any?, positive: Bool = false) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, !positive || value > 0 else { return nil }
        return value
    }

    private static func converted(_ raw: Any?, divisor: Double) -> Double? {
        guard let raw = number(raw) else { return nil }
        let value = raw / divisor
        return value.isFinite ? value : nil
    }

    private static func decimalID(_ raw: Any?) -> String? {
        if let string = raw as? String {
            guard !string.isEmpty, string.count <= 64,
                  string.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil else { return nil }
            let normalized = String(string.drop(while: { $0 == "0" }))
            return normalized.isEmpty ? nil : normalized
        }
        guard let value = number(raw, positive: true), value.rounded(.towardZero) == value,
              value <= 9_007_199_254_740_991 else { return nil }
        return String(Int64(value))
    }

    private static func identifier(_ raw: Any?) -> String? {
        if let decimal = decimalID(raw) { return decimal }
        guard let string = raw as? String, !string.isEmpty, string.count <= 64,
              string.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil,
              string.range(of: #"[A-Za-z_-]"#, options: .regularExpression) != nil else { return nil }
        return string
    }

    private static func validDay(_ string: String) -> Bool {
        guard string.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { return false }
        let components = string.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3, (1...9999).contains(components[0]), (1...12).contains(components[1]) else { return false }
        let year = components[0]
        let leap = year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...days[components[1] - 1]).contains(components[2])
    }

    private static func calendarWindowEnd(_ sourceDay: String) -> String? {
        let parts = sourceDay.split(separator: "-").compactMap { Int($0) }
        let zeroBased = parts[1] - 1 + 2
        let year = parts[0] + zeroBased / 12
        guard year <= 9999 else { return nil }
        return String(format: "%04d-%02d-01", year, zeroBased % 12 + 1)
    }

    private static func localDateTime(_ raw: Any?) -> String? {
        guard let string = raw as? String,
              string.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?$"#,
                           options: .regularExpression) != nil,
              validTimeComponents(string) else { return nil }
        // Activity-list responses also use a space separator. Preserve local
        // wall time without inventing an offset, in our existing ISO-like form.
        return String(string.prefix(19)).replacingOccurrences(of: " ", with: "T")
    }

    private static func validTimeComponents(_ string: String) -> Bool {
        guard validDay(String(string.prefix(10))) else { return false }
        let components = string.prefix(19).dropFirst(11).split(separator: ":").compactMap { Int($0) }
        return components.count == 3 && (0...23).contains(components[0])
            && (0...59).contains(components[1]) && (0...59).contains(components[2])
    }

    private static func instant(_ raw: Any?, knownUTC: Bool) -> Date? {
        guard var string = raw as? String,
              string.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:?[0-9]{2})?$"#,
                           options: .regularExpression) != nil,
              validTimeComponents(string) else { return nil }
        string = string.replacingOccurrences(of: " ", with: "T")
        let zone = string.range(of: #"[+-][0-9]{2}:?[0-9]{2}$"#, options: .regularExpression)
        if let zone {
            let digits = string[zone].filter { $0.isNumber }
            guard let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)), hours <= 23, minutes <= 59 else { return nil }
        } else if !string.hasSuffix("Z") {
            guard knownUTC else { return nil }
            string += "Z"
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: string)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: string)
        }
        return date.map { Date(timeIntervalSince1970: floor($0.timeIntervalSince1970)) }
    }
}

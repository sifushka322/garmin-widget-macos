import Foundation

@main
struct TrainingModelsTests {
    static var checked = 0
    enum Failure: Error { case expectation(String) }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checked += 1
        if !condition() { throw Failure.expectation(message) }
    }
    static func json(_ text: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) }
    static func activity(_ id: Int, _ date: String) -> [String: Any] {
        ["activityId": id, "activityName": "Synthetic run", "activityType": ["typeKey": "running"],
         "startTimeGMT": date, "duration": 2700, "movingDuration": 2400, "distance": 5000,
         "calories": 300, "averageHR": 140, "maxHR": 170]
    }
    static func workout(_ id: Int, date: String, workoutID: Int = 42) -> [String: Any] {
        ["itemType": "workout", "id": id, "workoutId": workoutID, "date": date,
         "title": "Synthetic workout", "sportTypeKey": "running"]
    }

    static func testCompletedActivityUnitsAndIdentity() throws {
        var first = activity(1, "2026-09-15T08:00:00+03:00")
        first["activityName"] = " <b>Morning</b>\n run\u{0000} "
        first["startLatitude"] = 12.34
        first["ownerId"] = "private"
        let output = TrainingNormalizer.past(payload: [activity(2, "2026-09-14T05:00:00Z"), first, first])
        try expect(output.count == 2, "Duplicate activity IDs must collapse")
        try expect(output[0].id == "1", "Newest absolute timestamp must be first")
        try expect(output[0].title == "Morning run", "Titles must be bounded plain text")
        try expect(output[0].sportKey == "running", "Garmin sport key must survive")
        try expect(output[0].durationMinutes == 45 && output[0].movingMinutes == 40, "Total and moving durations are distinct seconds-to-minutes conversions")
        try expect(output[0].distanceKM == 5 && output[0].calories == 300, "Activity distance uses metres and calories use kcal")
        try expect(output[0].averageHeartRate == 140 && output[0].maximumHeartRate == 170, "Pulse values must use their own fields")
        let equivalent = TrainingNormalizer.past(payload: [activity(1, "2026-09-15T05:00:00Z")])
        try expect(output[0].startedAt == equivalent[0].startedAt, "Explicit offset must preserve the same instant")
        let wrapped = TrainingNormalizer.past(payload: ["activityList": [first]])
        try expect(wrapped.count == 1, "Known activityList envelope must work")
        let encoded = try JSONEncoder().encode(output)
        let text = String(decoding: encoded, as: UTF8.self)
        try expect(!text.contains("startLatitude") && !text.contains("ownerId") && !text.contains("private"), "Model storage must exclude GPS and raw identity fields")
        let decoded = try JSONDecoder().decode([PastActivitySummary].self, from: encoded)
        try expect(decoded == output, "Past summaries must round-trip through Codable")
    }

    static func testLimitsMissingDataAndInvalidNumbers() throws {
        let rows = (1...25).map { activity($0, String(format: "2026-09-%02dT05:00:00Z", $0)) }
        let output = TrainingNormalizer.past(payload: rows)
        try expect(output.count == 20 && output.first?.id == "25" && output.last?.id == "6", "Retain the latest 20 unique activities")
        let bad = try json(#"[{"activityId":true},{"activityId":0},{"activityId":1.5},{"activityId":"abc"},{"activityId":2,"duration":false,"distance":"5000","calories":-1,"averageHR":0,"maxHR":null}]"#)
        let validIdentity = TrainingNormalizer.past(payload: bad)
        try expect(validIdentity.count == 1 && validIdentity[0].id == "2", "Invalid IDs cannot create or merge activities")
        try expect(validIdentity[0].durationMinutes == nil && validIdentity[0].distanceKM == nil && validIdentity[0].calories == nil,
                   "Nulls, booleans, numeric strings and negative sentinels must remain absent")
        try expect(validIdentity[0].averageHeartRate == nil && validIdentity[0].maximumHeartRate == nil, "Zero/missing pulse is unavailable")
        try expect(validIdentity[0].title.isEmpty && validIdentity[0].sportKey == "unknown", "Model must not inject an untranslated fallback title")
        for invalid in [Double.nan, Double.infinity, -1.0] {
            let result = TrainingNormalizer.past(payload: [["activityId": 1, "duration": invalid, "distance": invalid]])
            try expect(result[0].durationMinutes == nil && result[0].distanceKM == nil, "Nonfinite values are unavailable")
        }
        let zero = TrainingNormalizer.past(payload: [["activityId": "0007", "duration": 0, "distance": 0, "calories": 0]])
        try expect(zero[0].id == "7" && zero[0].durationMinutes == 0 && zero[0].distanceKM == 0 && zero[0].calories == 0,
                   "Real zero counters survive and decimal IDs canonicalize")
        let oversized = TrainingNormalizer.past(payload: [["activityId": 9_007_199_254_740_992.0]])
        try expect(oversized.isEmpty, "Unsafe JavaScript numeric IDs must not be rounded into an identity")
        let largeString = TrainingNormalizer.past(payload: [["activityId": "9007199254740992"]])
        try expect(largeString.count == 1, "Exact string IDs may exceed JavaScript integer precision")
    }

    static func testLocalAndInvalidDates() throws {
        let local = TrainingNormalizer.past(payload: [["activityId": 1, "startTimeLocal": "2026-10-25T02:30:00"]])
        try expect(local[0].startedAt == nil && local[0].localStart == "2026-10-25T02:30:00", "DST-ambiguous local activity time must stay a string")
        for date in ["2026-02-30T10:00:00Z", "2026-09-15T24:00:00Z", "2026-09-15T05:00:60Z", "2026-09-15", "2026-09-15T05:00:00+99:99"] {
            try expect(TrainingNormalizer.past(payload: [activity(1, date)])[0].startedAt == nil, "Invalid calendar/time components must not normalize into another instant")
        }
        let leap = TrainingNormalizer.past(payload: [activity(1, "2024-02-29T05:00:00")])
        try expect(leap[0].startedAt != nil, "A valid leap day in an explicitly GMT field may omit the zone")
        let expectedUTC = TrainingNormalizer.past(payload: [activity(1, "2026-09-15T05:00:00Z")])[0].startedAt
        for raw in ["2026-09-15 05:00:00", "2026-09-15 05:00:00.0", "2026-09-15 05:00:00.123", "2026-09-15 05:00:00Z", "2026-09-15 08:00:00.123+03:00"] {
            let parsed = TrainingNormalizer.past(payload: [activity(1, raw)])[0]
            try expect(parsed.startedAt == expectedUTC && parsed.startedAt != nil,
                       "Garmin space-separated GMT timestamps, fractions and offsets preserve the actual instant")
        }
        let spacedLocal = TrainingNormalizer.past(payload: [["activityId": 1, "startTimeLocal": "2026-10-25 02:30:00.0"]])[0]
        try expect(spacedLocal.startedAt == nil && spacedLocal.localStart == "2026-10-25T02:30:00",
                   "A space-separated local timestamp stays local even at a DST transition")
        let ordered = TrainingNormalizer.past(payload: [activity(2, "2026-09-14 05:00:00"), activity(1, "2026-09-15 05:00:00.0")])
        try expect(ordered.map(\.id) == ["1", "2"], "Real Garmin date formatting must sort completed activities by date instead of ID")
        for raw in ["2026-02-30 10:00:00", "2026-09-15 24:00:00", "2026-09-15  05:00:00", "2026-09-15\n05:00:00", " 2026-09-15 05:00:00"] {
            let parsed = TrainingNormalizer.past(payload: [["activityId": 1, "startTimeGMT": raw, "startTimeLocal": raw]])[0]
            try expect(parsed.startedAt == nil && parsed.localStart == nil,
                       "Supporting Garmin's single space must not relax calendar validation or accept arbitrary whitespace")
        }
        let title = TrainingNormalizer.past(payload: [["activityId": 1, "activityName": String(repeating: "я", count: 200), "activityType": ["typeKey": "<bad>"]]])
        try expect(title[0].title.count == 160 && title[0].sportKey == "unknown", "Untrusted labels must be bounded and sport keys validated")
    }

    static func testScheduledOccurrencesAndCalendarWindow() throws {
        var first = workout(11, date: "2026-09-15")
        first["estimatedDurationInSecs"] = 2700
        first["duration"] = 999
        first["distance"] = 5000
        first["atpPlanId"] = 72
        let second = workout(12, date: "2026-10-01")
        let months: [[String: Any]] = [
            ["calendarItems": [first, ["itemType": "weight", "date": "2026-09-15"],
                               workout(10, date: "2026-09-14"), ["itemType": "activity", "activityId": 8, "date": "2026-09-15"]]],
            ["calendarItems": [first, second, workout(13, date: "2026-11-01")]]
        ]
        let output = TrainingNormalizer.planned(payload: months, sourceDay: "2026-09-15")
        try expect(output.count == 2, "Two month envelopes must deduplicate, filter past/unrelated rows and exclude beyond the requested horizon")
        try expect(output.map(\.localDate) == ["2026-09-15", "2026-10-01"], "Planned items must sort by local dates")
        try expect(output[0].workoutID == output[1].workoutID && output[0].id != output[1].id,
                   "Reusing a workout template must preserve different scheduled occurrences")
        try expect(output[0].startsAt == nil && output[0].durationMinutes == 45, "Date-only is all-day; explicit seconds are an estimate")
        try expect(output[0].distanceKM == nil && output[1].durationMinutes == nil, "Unverified calendar units must remain absent")
        try expect(output[0].source == .calendar && output[0].planID == "72", "Calendar source and plan linkage must remain explicit")
        let year = TrainingNormalizer.planned(payload: ["calendarItems": [workout(1, date: "2027-01-31"), workout(2, date: "2027-02-01")]], sourceDay: "2026-12-31")
        try expect(year.map(\.localDate) == ["2027-01-31"], "Two-month calendar horizon must handle year rollover")
        try expect(TrainingNormalizer.planned(payload: months, sourceDay: "2026-02-30").isEmpty, "Invalid source day cannot produce a timeline")
        try expect(TrainingNormalizer.planned(payload: ["calendarItems": [workout(1, date: "2026-09-15T00:00:00Z")]], sourceDay: "2026-09-15").isEmpty,
                   "A date-only field must not be interpreted as an arbitrary instant")
        var fallback = workout(1, date: "2026-09-15"); fallback.removeValue(forKey: "id")
        var nextFallback = fallback; nextFallback["date"] = "2026-09-16"
        let fallbackRows = TrainingNormalizer.planned(payload: ["calendarItems": [fallback, fallback, nextFallback]], sourceDay: "2026-09-15")
        try expect(fallbackRows.count == 2 && Set(fallbackRows.map(\.id)).count == 2, "Fallback identities must include workout date")
        var millis = first; millis.removeValue(forKey: "estimatedDurationInSecs"); millis["durationInMilliseconds"] = 120000
        millis["startTimeGMT"] = "2026-09-15T07:00:00Z"
        let explicit = TrainingNormalizer.planned(payload: ["calendarItems": [millis]], sourceDay: "2026-09-15")
        try expect(explicit[0].durationMinutes == 2 && explicit[0].startsAt != nil, "Explicit milliseconds and UTC start must preserve their units")
        let invalidIdentity = TrainingNormalizer.planned(payload: ["calendarItems": [["itemType": "workout", "id": "-1", "date": "2026-09-15"]]], sourceDay: "2026-09-15")
        try expect(invalidIdentity.isEmpty, "A negative numeric ID must not be accepted as an opaque calendar identifier")
    }

    static func testRecognitionAndCodable() throws {
        for absence: Any in [NSNull(), [Any](), ["activityList": [Any]()]] {
            try expect(TrainingNormalizer.isRecognizedPastPayload(payload: absence), "Known empty activity payload must be recognized")
        }
        for absence: Any in [NSNull(), [Any](), ["calendarItems": [Any]()]] {
            try expect(TrainingNormalizer.isRecognizedPlannedPayload(payload: absence), "Known empty calendar payload must be recognized")
        }
        for malformed: Any in ["<html>login</html>", ["error": "unauthorized"], ["workouts": [["workoutId": 1]]]] {
            try expect(!TrainingNormalizer.isRecognizedPastPayload(payload: malformed), "Templates/error pages must not masquerade as past activities")
            try expect(!TrainingNormalizer.isRecognizedPlannedPayload(payload: malformed), "Templates/error pages must not masquerade as a schedule")
        }
        try expect(TrainingNormalizer.isRecognizedPastPayload(payload: [activity(1, "2026-09-15T05:00:00Z")]), "Activity list must be recognized")
        try expect(TrainingNormalizer.isRecognizedPlannedPayload(payload: ["calendarItems": [["itemType": "nap"]]]), "Unrelated but recognized calendar entries should produce a valid empty workout view")
        try expect(!TrainingNormalizer.isRecognizedPlannedPayload(payload: ["calendarItems": "bad"]), "Malformed calendar envelope is a schema mismatch")
        let thirdMonth = Array(repeating: ["calendarItems": [Any]()], count: 3)
        try expect(!TrainingNormalizer.isRecognizedPlannedPayload(payload: thirdMonth), "Monthly batches must remain bounded to two")
        let snapshot = TrainingTimelineSnapshot(fetchedAt: Date(timeIntervalSince1970: 1789440000),
            past: TrainingNormalizer.past(payload: [activity(1, "2026-09-15T05:00:00Z")]),
            upcoming: TrainingNormalizer.planned(payload: ["calendarItems": [workout(11, date: "2026-09-16")]], sourceDay: "2026-09-15"),
            pastCoverageStart: "2026-09-15", futureCoverageEnd: "2026-10-31",
            pastCoverage: .recentActivities, futureCoverage: .publishedCalendar, warnings: ["adaptive_calendar_unverified"])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let decoded = try decoder.decode(TrainingTimelineSnapshot.self, from: data)
        try expect(decoded == snapshot, "Timeline must round-trip with explicit coverage and dates")
        try expect(snapshot.id == snapshot.fetchedAt, "Snapshot identity comes from its supplied acquisition time")
        let defaults = TrainingTimelineSnapshot(fetchedAt: Date(timeIntervalSince1970: 0))
        try expect(defaults.futureCoverage == .unavailable && defaults.pastCoverage == .unavailable, "An unpopulated timeline must not claim coverage")
        try expect(TrainingNormalizer.planned(payload: ["workouts": [["workoutId": 11]]], sourceDay: "2026-09-15").isEmpty, "Saved workout library is not a schedule")
    }

    static func main() {
        do {
            try testCompletedActivityUnitsAndIdentity()
            try testLimitsMissingDataAndInvalidNumbers()
            try testLocalAndInvalidDates()
            try testScheduledOccurrencesAndCalendarWindow()
            try testRecognitionAndCodable()
            print("PASS: \(checked) training model checks")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}

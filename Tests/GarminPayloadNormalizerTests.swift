import Foundation

@main
struct GarminPayloadNormalizerTests {
    static var checks = 0
    enum Failure: Error { case expectation(String) }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw Failure.expectation(message) }
    }
    static func normalize(_ group: String, _ payload: Any) -> [String: MetricReading] {
        GarminPayloadNormalizer.normalize(group: group, payload: payload)
    }
    static func value(_ result: [String: MetricReading], _ key: String, _ expected: Double) throws {
        try expect(result[key].map { abs($0.value - expected) < 0.00001 } ?? false, "Wrong canonical value for \(key)")
    }
    static func json(_ text: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) }

    static func testAllCanonicalFields() throws {
        let groups: [(String, Any)] = [
            ("stats", ["totalSteps": 0, "dailyStepGoal": 10000, "totalDistanceMeters": 5600,
                       "totalKilocalories": 1700, "activeKilocalories": 420, "floorsAscended": 12,
                       "restingHeartRate": 53, "averageStressLevel": 0,
                       "moderateIntensityMinutes": 20, "vigorousIntensityMinutes": 12]),
            ("heart", ["heartRateValues": [[1789430400000, 61]], "restingHeartRate": 53]),
            ("body_battery", [["bodyBatteryValuesArray": [[1789430400000, 75]]]]),
            ("sleep", ["dailySleepDTO": ["sleepTimeSeconds": 27720, "deepSleepSeconds": 5400,
                        "lightSleepSeconds": 16320, "remSleepSeconds": 6000, "awakeSleepSeconds": 600,
                        "sleepScores": ["overall": ["value": 87]]]]),
            ("hrv", ["hrvSummary": ["lastNightAvg": 64, "weeklyAvg": 51]]),
            ("spo2", ["averageSpO2": 97]), ("respiration", ["avgSleepRespirationValue": 14]),
            ("readiness", [["score": 82, "recoveryTime": 480]]),
            ("vo2_max", [["generic": ["vo2MaxPreciseValue": 48.456789, "vo2MaxValue": 48]]]),
            ("training", ["mostRecentTrainingStatus": ["latestTrainingStatusData": [
                "synthetic-device": ["acuteTrainingLoadDTO": ["dailyTrainingLoadAcute": 500]]]]]),
            ("weight", ["dateWeightList": [["weight": 76400]]]),
            ("hydration", ["valueInML": 1750])
        ]
        var combined: [String: MetricReading] = [:]
        for (group, payload) in groups {
            try expect(GarminPayloadNormalizer.isRecognizedPayload(group: group, payload: payload), "Known nonempty \(group) payload must be recognized")
            combined.merge(normalize(group, payload)) { _, new in new }
        }
        let expected: [String: Double] = ["steps": 0, "stepGoal": 10000, "distance": 5.6,
            "calories": 1700, "activeCalories": 420, "floors": 12, "intensityMinutes": 44,
            "restingHeartRate": 53, "heartRate": 61, "stress": 0, "bodyBattery": 75,
            "sleepDuration": 462, "sleepScore": 87, "deepSleep": 90, "remSleep": 100,
            "lightSleep": 272, "awakeSleep": 10, "hrv": 64, "spo2": 97, "respiration": 14,
            "trainingReadiness": 82, "recoveryTime": 480, "vo2Max": 48.4568,
            "trainingLoad": 500, "weight": 76.4, "hydration": 1750]
        try expect(Set(combined.keys) == Set(expected.keys), "Exactly the 26 canonical keys should be produced")
        for (key, expectedValue) in expected { try value(combined, key, expectedValue) }
        try expect(combined["sleepDuration"]?.measuredAt == nil, "Undated sleep must not use the current time")
    }

    static func testJSONTypesAndSentinels() throws {
        let mixed = try json(#"{"totalSteps":0,"dailyStepGoal":false,"restingHeartRate":0,"averageStressLevel":-1,"totalDistanceMeters":"5600","floorsAscended":true}"#)
        let result = normalize("stats", mixed)
        try expect(Set(result.keys) == ["steps"], "JSON booleans, strings and sentinels must not become measurements")
        for invalid: Any in [NSNull(), true, false, "51", Double.nan, Double.infinity, -1] {
            try expect(normalize("hydration", ["valueInML": invalid]).isEmpty, "Invalid JSON number must remain absent")
        }
        try expect(normalize("stats", ["moderateIntensityMinutes": 20]).isEmpty, "Missing vigorous minutes cannot imply zero")
        try value(normalize("stats", ["moderateIntensityMinutes": 0, "vigorousIntensityMinutes": 0]), "intensityMinutes", 0)
        try expect(normalize("stats", ["moderateIntensityMinutes": Double.greatestFiniteMagnitude,
                                       "vigorousIntensityMinutes": Double.greatestFiniteMagnitude]).isEmpty,
                   "Overflow during intensity calculation must remain absent")
        for group in GarminPayloadNormalizer.groups {
            for invalid: Any in [NSNull(), [], "bad", ["unknown": ["score": 99]], ["bad", 99]] {
                try expect(normalize(group, invalid).isEmpty, "Unknown shape in \(group) must not be recursively guessed")
            }
        }
        try expect(normalize("not_a_group", ["totalSteps": 10]).isEmpty, "Unknown group should be empty")
        try expect(normalize("spo2", ["averageSpO2": 101]).isEmpty, "SpO2 above 100 is invalid")
        try expect(normalize("readiness", [["score": -1, "recoveryTime": -1]]).isEmpty, "Readiness sentinels must be absent")
    }

    static func testSampleOrderingAndTimestamps() throws {
        let heart = normalize("heart", ["heartRateValues": [
            [1789430520000, NSNull()], [1789430400000, 62], [1789430460000, 64],
            [1789430600000, -1], [1789430800000, 0], [1789430900, 99]]])
        try value(heart, "heartRate", 64)
        try expect(heart["heartRate"]?.measuredAt == Date(timeIntervalSince1970: 1789430460), "Latest valid milliseconds should win")
        let battery = normalize("body_battery", [
            ["charged": 99, "drained": 10, "bodyBatteryValuesArray": [[1789430400000, 70]]],
            ["bodyBatteryValuesArray": [[1789430460000, 0], [1789430520000, 101]]]])
        try value(battery, "bodyBattery", 0)
        for badTimestamp: Any in ["2026-09-15T08:00:00", "2026-09-15", 1789430400, true,
                                 Double.greatestFiniteMagnitude, "not-a-date", "2026-02-30T08:00:00Z",
                                 "2026-09-15T24:00:00Z", "2026-09-15T05:00:60Z"] {
            try expect(normalize("heart", ["heartRateValues": [[badTimestamp, 62]]]).isEmpty, "Ambiguous timestamp must not be fabricated")
        }
        let offset = normalize("heart", ["heartRateValues": [["2026-09-15T08:00:00+03:00", 62]]])
        let utc = normalize("heart", ["heartRateValues": [["2026-09-15T05:00:00Z", 62]]])
        try expect(offset["heartRate"]?.measuredAt != nil && offset["heartRate"]?.measuredAt == utc["heartRate"]?.measuredAt, "Explicit offsets must preserve the UTC instant")
        let fraction = normalize("heart", ["heartRateValues": [["2026-09-15T05:00:00.999Z", 62]]])
        try expect(fraction["heartRate"]?.measuredAt == utc["heartRate"]?.measuredAt, "Bridge timestamps use whole-second precision")
        let sleep = normalize("sleep", ["dailySleepDTO": ["sleepTimeSeconds": 60,
                                "sleepEndTimestampGMT": "2026-09-15T05:00:00"]])
        try expect(sleep["sleepDuration"]?.measuredAt == utc["heartRate"]?.measuredAt, "Known GMT fields may omit their offset")
        let localOnly = normalize("sleep", ["dailySleepDTO": ["sleepTimeSeconds": 60,
                                      "sleepEndTimestampLocal": "2026-09-15T08:00:00"]])
        try expect(localOnly["sleepDuration"]?.measuredAt == nil, "Local sleep fields must not be mislabeled UTC")
    }

    static func testReadinessWeightAndDevices() throws {
        let ready = normalize("readiness", [
            ["timestamp": "2026-09-15T09:00:00", "score": 82, "recoveryTime": 480,
             "recoveryTimeChangePhrase": "REACHED_ZERO"],
            ["timestamp": "2026-09-15T06:00:00", "score": 69, "recoveryTime": 660]])
        try value(ready, "trainingReadiness", 82); try value(ready, "recoveryTime", 0)
        try expect(ready["recoveryTime"]?.measuredAt != nil, "Readiness timestamp must be retained")
        try expect(normalize("readiness", [["score": 69], ["score": 82]]).isEmpty, "Multiple undated snapshots must not be arbitrarily ordered")
        let weight = normalize("weight", ["dateWeightList": [
            ["timestampGMT": "2026-09-15T09:00:00", "weight": -1],
            ["timestampGMT": "2026-09-15T06:00:00", "weight": 76400],
            ["timestampGMT": "2026-09-14T06:00:00", "weight": 75000]]])
        try value(weight, "weight", 76.4)
        try expect(weight["weight"]?.measuredAt != nil, "Last valid weigh-in keeps its own date")
        try expect(normalize("weight", ["dateWeightList": [["weight": 74000], ["weight": 75000]]]).isEmpty, "Undated weights cannot be ordered")
        let primary = normalize("training", ["mostRecentTrainingStatus": ["latestTrainingStatusData": [
            "old": ["acuteTrainingLoadDTO": ["dailyTrainingLoadAcute": 123]],
            "primary": ["primaryTrainingDevice": true, "acuteTrainingLoadDTO": ["dailyTrainingLoadAcute": 583]]]]])
        try value(primary, "trainingLoad", 583)
        let ambiguous = try json(#"{"mostRecentTrainingStatus":{"latestTrainingStatusData":{"a":{"primaryTrainingDevice":1,"acuteTrainingLoadDTO":{"dailyTrainingLoadAcute":123}},"b":{"acuteTrainingLoadDTO":{"dailyTrainingLoadAcute":583}}}}}"#)
        try expect(normalize("training", ambiguous).isEmpty, "Numeric one is not a true primary-device flag")
        try value(normalize("vo2_max", ["generic": ["vo2MaxPreciseValue": -1, "vo2MaxValue": 48]]), "vo2Max", 48)
        let names = GarminPayloadNormalizer.deviceNames(from: [["displayName": " fēnix 8 ", "deviceId": "private"],
            ["displayName": "fēnix 8"], ["displayName": "  "], ["serialNumber": "private"]])
        try expect(names == ["fēnix 8"], "Device summaries must trim/deduplicate names and omit identifiers")
    }

    static func testRecognizedAbsenceVersusSchemaMismatch() throws {
        for group in GarminPayloadNormalizer.groups {
            try expect(GarminPayloadNormalizer.isRecognizedPayload(group: group, payload: NSNull()), "Explicit null is an absence in \(group)")
            try expect(!GarminPayloadNormalizer.isRecognizedPayload(group: group, payload: ["error": "unrecognized"]), "An unrelated dictionary must preserve the cached \(group)")
            try expect(!GarminPayloadNormalizer.isRecognizedPayload(group: group, payload: "<html>login</html>"), "HTML is never a measurement payload")
        }
        for group in ["body_battery", "readiness", "vo2_max"] {
            try expect(GarminPayloadNormalizer.isRecognizedPayload(group: group, payload: [Any]()), "A valid empty \(group) array can clear its values")
            try expect(!GarminPayloadNormalizer.isRecognizedPayload(group: group, payload: ["bad", 12]), "Invalid array members are a schema mismatch")
        }
        let emptyEnvelopes: [(String, Any)] = [
            ("sleep", ["dailySleepDTO": [String: Any]()]), ("hrv", ["hrvSummary": NSNull()]),
            ("weight", ["dateWeightList": [Any]()]), ("training", ["mostRecentTrainingStatus": [String: Any]()]),
            ("heart", ["heartRateValues": [Any]()]), ("hydration", ["valueInML": NSNull()])
        ]
        for (group, payload) in emptyEnvelopes {
            try expect(GarminPayloadNormalizer.isRecognizedPayload(group: group, payload: payload), "Known empty envelope for \(group) must remain recognized")
            try expect(normalize(group, payload).isEmpty, "Known absence must not invent a \(group) measurement")
        }
        try expect(!GarminPayloadNormalizer.isRecognizedPayload(group: "sleep", payload: ["dailySleepDTO": "bad"]), "Invalid sleep DTO is a schema mismatch")
        try expect(!GarminPayloadNormalizer.isRecognizedPayload(group: "weight", payload: ["dateWeightList": ["wrong": 1]]), "Invalid weight envelope is a schema mismatch")
        try expect(!GarminPayloadNormalizer.isRecognizedPayload(group: "unknown", payload: NSNull()), "Null must not legitimize an unknown group")
    }

    static func main() {
        do {
            try expect(!GarminPayloadNormalizer.matchesSourceDay(group: "stats", payload: ["calendarDate": "2026-09-14", "totalSteps": 900], sourceDay: "2026-09-15"), "Wrong-day stats must fail provenance validation")
            try expect(!GarminPayloadNormalizer.matchesSourceDay(group: "body_battery", payload: [["date": "2026-09-14"]], sourceDay: "2026-09-15"), "Wrong-day Body Battery must fail provenance validation")
            try expect(!GarminPayloadNormalizer.matchesSourceDay(group: "hydration", payload: ["calendarDate": "2026-09-14"], sourceDay: "2026-09-15"), "Wrong-day hydration must fail provenance validation")
            try expect(GarminPayloadNormalizer.matchesSourceDay(group: "sleep", payload: ["dailySleepDTO": ["calendarDate": "2026-09-14"]], sourceDay: "2026-09-15"), "Overnight sleep is not relabeled by guessing day semantics")
            try testAllCanonicalFields()
            try testJSONTypesAndSentinels()
            try testSampleOrderingAndTimestamps()
            try testReadinessWeightAndDevices()
            try testRecognizedAbsenceVersusSchemaMismatch()
            print("PASS: \(checks) Garmin payload normalization checks")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}

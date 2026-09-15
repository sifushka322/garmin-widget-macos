import Foundation

/// Versioned website adapter. This builds GET paths, never authentication URLs.
enum GarminWebAPI {
    static let profilePath = "/gc-api/userprofile-service/socialProfile"

    static func path(group: SyncPolicy.Group, sourceDay: String, displayName: String) -> String? {
        guard validDay(sourceDay), let profile = displayName.addingPercentEncoding(withAllowedCharacters: .alphanumerics), !profile.isEmpty else { return nil }
        let base = "/gc-api"
        switch group {
        case .profile: return profilePath
        case .devices: return base + "/device-service/deviceregistration/devices"
        case .stats: return base + "/usersummary-service/usersummary/daily/\(profile)?calendarDate=\(sourceDay)"
        case .heart: return base + "/wellness-service/wellness/dailyHeartRate/\(profile)?date=\(sourceDay)"
        case .bodyBattery: return base + "/wellness-service/wellness/bodyBattery/reports/daily?startDate=\(sourceDay)&endDate=\(sourceDay)"
        case .sleep: return base + "/sleep-service/sleep/dailySleepData?date=\(sourceDay)&nonSleepBufferMinutes=60"
        case .hrv: return base + "/hrv-service/hrv/\(sourceDay)"
        case .spo2: return base + "/wellness-service/wellness/daily/spo2/\(sourceDay)"
        case .respiration: return base + "/wellness-service/wellness/daily/respiration/\(sourceDay)"
        case .readiness: return base + "/metrics-service/metrics/trainingreadiness/\(sourceDay)"
        case .vo2Max: return base + "/metrics-service/metrics/maxmet/daily/\(sourceDay)/\(sourceDay)"
        case .training: return base + "/metrics-service/metrics/trainingstatus/aggregated/\(sourceDay)"
        case .weight: return base + "/weight-service/weight/dayview/\(sourceDay)?includeAll=true"
        case .hydration: return base + "/usersummary-service/usersummary/hydration/daily/\(sourceDay)"
        case .activities: return base + "/activitylist-service/activities/search/activities?start=0&limit=20"
        case .plannedWorkouts: return nil // A month-boundary request needs two explicit calendar paths.
        }
    }

    static func calendarPaths(sourceDay: String) -> [String] {
        calendarRequests(sourceDay: sourceDay).map(\.path)
    }

    struct CalendarRequest {
        var month: String
        var path: String
        var lastDay: String
    }
    static func calendarRequests(sourceDay: String) -> [CalendarRequest] {
        guard validDay(sourceDay) else { return [] }
        let parts = sourceDay.split(separator: "-").compactMap { Int($0) }
        let year = parts[0], month = parts[1]
        return [(year, month - 1), (month == 12 ? year + 1 : year, month == 12 ? 0 : month)]
            .filter { $0.0 <= 9999 }
            .map { year, zeroMonth in
                let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
                let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
                return CalendarRequest(month: String(format: "%04d-%02d", year, zeroMonth + 1),
                    path: "/gc-api/calendar-service/year/\(year)/month/\(zeroMonth)",
                    lastDay: String(format: "%04d-%02d-%02d", year, zeroMonth + 1, days[zeroMonth]))
            }
    }

    static func validDay(_ value: String) -> Bool {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    static func requiredGroups(metricIDs: Set<String>, includeTraining: Bool = false) -> Set<SyncPolicy.Group> {
        var groups: Set<SyncPolicy.Group> = [.profile, .devices]
        if includeTraining { groups.formUnion([.activities, .plannedWorkouts]) }
        for id in metricIDs {
            switch id {
            case "steps", "stepGoal", "distance", "calories", "activeCalories", "floors", "intensityMinutes", "restingHeartRate", "stress": groups.insert(.stats)
            case "heartRate": groups.insert(.heart)
            case "bodyBattery": groups.insert(.bodyBattery)
            case "sleepDuration", "sleepScore", "deepSleep", "lightSleep", "remSleep", "awakeSleep": groups.insert(.sleep)
            case "hrv": groups.insert(.hrv)
            case "spo2": groups.insert(.spo2)
            case "respiration": groups.insert(.respiration)
            case "trainingReadiness", "recoveryTime": groups.insert(.readiness)
            case "vo2Max": groups.insert(.vo2Max)
            case "trainingLoad": groups.insert(.training)
            case "weight": groups.insert(.weight)
            case "hydration": groups.insert(.hydration)
            default: break
            }
        }
        return groups
    }
}

struct GarminMetricGroupCache: Codable {
    var sourceDay: String
    var retrievedAt: Date
    var metrics: [String: MetricReading]
}

struct GarminPastActivitiesCache: Codable {
    var sourceDay: String
    var retrievedAt: Date
    var items: [PastActivitySummary]
}

struct GarminCalendarMonthCache: Codable {
    var sourceDay: String
    var retrievedAt: Date
    var items: [PlannedWorkoutSummary]
}

struct GarminWebCache: Codable {
    var version = 1
    var groups: [String: GarminMetricGroupCache] = [:]
    var devices: [String] = []
    // Optional additive fields keep version-1 caches readable.
    var pastActivities: GarminPastActivitiesCache?
    var calendarMonths: [String: GarminCalendarMonthCache]?
    var trainingIssues: [String: String]?

    func trainingTimeline(sourceDay: String) -> TrainingTimelineSnapshot? {
        let requests = GarminWebAPI.calendarRequests(sourceDay: sourceDay)
        let covered = requests.filter { calendarMonths?[$0.month] != nil }
        guard pastActivities != nil || !covered.isEmpty || !(trainingIssues ?? [:]).isEmpty else { return nil }
        let stamps = covered.compactMap { calendarMonths?[$0.month]?.retrievedAt }
        var timeline = TrainingTimelineSnapshot(fetchedAt: ([pastActivities?.retrievedAt].compactMap { $0 } + stamps).max() ?? .distantPast)
        timeline.past = pastActivities?.items ?? []
        timeline.pastUpdatedAt = pastActivities?.retrievedAt
        timeline.pastCoverage = pastActivities == nil ? .unavailable : .recentActivities
        // This is a latest-N list, not proof that every activity in a date range exists.
        timeline.pastCoverageStart = nil
        timeline.upcoming = covered.flatMap { request in
            (calendarMonths?[request.month]?.items ?? []).filter { $0.localDate >= sourceDay && String($0.localDate.prefix(7)) == request.month }
        }
        var seen = Set<String>()
        timeline.upcoming = timeline.upcoming.filter { seen.insert($0.id).inserted }
            .sorted { $0.localDate == $1.localDate ? $0.id < $1.id : $0.localDate < $1.localDate }
        timeline.futureUpdatedAt = stamps.min()
        timeline.futureCoveredMonths = covered.map(\.month)
        timeline.futureCoverage = covered.isEmpty ? .unavailable : .publishedCalendar
        // Only report a continuous calendar window starting at the requested day.
        for request in requests {
            guard calendarMonths?[request.month] != nil else { break }
            timeline.futureCoverageEnd = request.lastDay
        }
        timeline.pastIssue = trainingIssues?[SyncPolicy.Group.activities.rawValue]
        timeline.futureIssue = trainingIssues?[SyncPolicy.Group.plannedWorkouts.rawValue]
        if covered.count < requests.count && timeline.futureIssue == nil { timeline.futureIssue = "partial_calendar" }
        timeline.warnings = [timeline.pastIssue.map { $0 + ".activities" }, timeline.futureIssue.map { $0 + ".planned_workouts" }].compactMap { $0 }
        return timeline
    }

    func snapshot(sourceDay: String, fallback: GarminSnapshot = .empty, warnings: [String]) -> GarminSnapshot {
        var training = trainingTimeline(sourceDay: sourceDay)
        if training == nil && !fallback.isDemo {
            training = fallback.trainingTimeline
            let months = Set(GarminWebAPI.calendarRequests(sourceDay: sourceDay).map(\.month))
            training?.upcoming.removeAll { $0.localDate < sourceDay || !months.contains(String($0.localDate.prefix(7))) }
        }
        var metrics: [String: MetricReading] = [:]
        var newest = Date.distantPast
        var retrievals: [String: Date] = [:]
        // Sorted order makes shared fields deterministic; stats owns daily resting HR.
        for key in groups.keys.sorted(by: { lhs, rhs in lhs == "stats" ? false : (rhs == "stats" ? true : lhs < rhs) }) {
            guard let group = groups[key], group.sourceDay == sourceDay else { continue }
            newest = max(newest, group.retrievedAt)
            retrievals[key] = group.retrievedAt
            metrics.merge(group.metrics) { _, current in current }
        }
        // A known empty response means this day has no measurements. It must not
        // resurrect yesterday's data, or a stale value from an earlier same-day read.
        if retrievals.isEmpty && !fallback.isDemo && fallback.sourceDate == sourceDay {
            var retained = fallback
            retained.warnings = warnings
            retained.trainingTimeline = training ?? retained.trainingTimeline
            if let training { retained.fetchedAt = max(retained.fetchedAt, training.fetchedAt) }
            return retained
        }
        return GarminSnapshot(fetchedAt: max(newest, training?.fetchedAt ?? .distantPast), sourceDate: sourceDay, devices: devices, metrics: metrics,
                              warnings: warnings, groupUpdatedAt: retrievals, trainingTimeline: training)
    }
}

import Foundation
import Darwin

@main
struct TrainingPresentationTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_789_473_600) // Synthetic fixed instant.
        let zone = TimeZone(secondsFromGMT: 0)!
        let en = TrainingPresentation(language: .en, now: now, timeZone: zone)
        let ru = TrainingPresentation(language: .ru, now: now, timeZone: TimeZone(secondsFromGMT: 10_800)!)
        var count = 0
        func check(_ condition: Bool, _ label: String) {
            count += 1
            guard condition else { fputs("FAIL: \(label)\n", stderr); exit(1) }
        }
        check(en.duration(nil) == nil, "missing duration remains absent")
        check(en.duration(.infinity) == nil, "invalid duration remains absent")
        check(en.duration(-1) == nil, "negative duration remains absent")
        check(en.duration(0) == "0 min", "real zero remains zero")
        check(ru.duration(62) == "1 ч 2 мин", "localized hours and minutes")
        check(en.distance(1.25) == "1.25 km", "English distance")
        check(ru.distance(1.25) == "1,25 км", "Russian distance")
        check(ru.sportTitle("unrecognized_private_key") == "Тренировка", "unknown sport uses a localized label")
        check(en.dayText("2026-02-30") == nil, "invalid day is not rolled forward")
        let dateOnly = PlannedWorkoutSummary(occurrenceID: "synthetic-day", localDate: "2026-10-01", title: "", sportKey: "running")
        check(en.dateText(for: dateOnly).contains("Time not provided") && !en.dateText(for: dateOnly).contains("12:00"), "date-only schedule never receives midnight")
        let local = PastActivitySummary(id: "synthetic-local", title: "", sportKey: "running", localStart: "2026-09-15T06:30:00")
        check(ru.dateText(for: local).contains("06:30") && ru.dateText(for: local).contains("местное"), "timezone-free local time is preserved and labeled")
        let available = TrainingTimelineSnapshot(fetchedAt: now, futureCoverageEnd: "2026-10-31", futureCoverage: .publishedCalendar, futureUpdatedAt: now)
        check(en.futureEmptyText(nil) != en.futureEmptyText(available), "unavailable and verified empty are distinct")
        check(en.futureEmptyText(available).hasPrefix("No published workouts through"), "verified empty keeps bounded coverage")
        var expired = available; expired.futureCoverageEnd = "2020-01-31"
        check(en.futureEmptyText(expired) == en.text("expiredCoverage"), "expired coverage makes no future-empty promise")
        check(!en.pastAvailable(TrainingTimelineSnapshot(fetchedAt: now, pastCoverage: .recentActivities)), "missing section retrieval time is not current data")
        var appointments = available
        appointments.upcoming = [
            PlannedWorkoutSummary(occurrenceID: "synthetic-old", localDate: "2020-01-01", title: "Old", sportKey: "running"),
            dateOnly,
            PlannedWorkoutSummary(occurrenceID: "synthetic-later", localDate: "2026-10-02", title: "Later", sportKey: "cycling")
        ]
        check(en.upcomingWorkouts(in: appointments).map(\.id) == ["synthetic-day", "synthetic-later"], "past appointments never appear as next planned")
        var history = TrainingTimelineSnapshot(fetchedAt: now)
        history.past = (0..<25).map { PastActivitySummary(id: "synthetic-\($0)", title: "", sportKey: "running", startedAt: now.addingTimeInterval(Double(-$0))) }
        check(en.recentActivities(in: history).count == 20, "recent history stays bounded")
        check(en.issueText("rate_limit", cached: true)?.contains("Saved data") == true, "failed refresh marks saved data")
        print("PASS: \(count) training-presentation checks")
    }
}

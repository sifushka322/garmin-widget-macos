import Foundation

@main
struct TrainingCalendarTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        count += 1
        guard condition() else { throw Failure(description: message) }
    }
    static func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    static func main() throws {
        let now = instant("2026-09-16T10:00:00Z")
        let utc = TimeZone(secondsFromGMT: 0)!
        var snapshot = TrainingTimelineSnapshot(fetchedAt: now,
            past: [.init(id: "completed", title: "Done", sportKey: "running", startedAt: instant("2026-09-15T22:30:00Z")),
                   .init(id: "local", title: "Local", sportKey: "cycling", localStart: "2026-09-14T23:30:00"),
                   .init(id: "invalid", title: "Invalid", sportKey: "running", localStart: "2026-02-30T10:00:00")],
            upcoming: [.init(occurrenceID: "date-only", localDate: "2026-09-17", title: "All day", sportKey: "running"),
                       .init(occurrenceID: "timed", localDate: "2026-09-15", startsAt: instant("2026-09-15T23:30:00Z"), title: "Timed", sportKey: "cycling"),
                       .init(occurrenceID: "invalid", localDate: "2026-02-30", title: "Invalid", sportKey: "running")],
            futureCoverageEnd: "2026-10-31", pastCoverage: .recentActivities, futureCoverage: .publishedCalendar,
            pastUpdatedAt: now, futureUpdatedAt: now, futureCoveredMonths: ["2026-09", "2026-10"])
        let us = TrainingCalendarPresentation(snapshot: snapshot, language: .en, now: now, timeZone: utc)
        let de = TrainingCalendarPresentation(snapshot: snapshot, language: .de, now: now, timeZone: utc)
        try check(us.week.count == 7 && us.week.first?.key == "2026-09-13", "US weeks start on Sunday")
        try check(de.week.first?.key == "2026-09-14", "German weeks start on Monday")
        try check(us.weekdayTitles.count == 7 && us.weekdayTitles.first == "S", "Weekday headings follow the week start")
        try check(de.weekdayTitles.first == "M", "German first weekday is Monday")
        for language in [AppLanguage.ja, .ko, .zhHans] {
            let localized = TrainingCalendarPresentation(snapshot: snapshot, language: language, now: now, timeZone: utc)
            try check(localized.week.allSatisfy { !$0.number.isEmpty && $0.number.allSatisfy(\.isNumber) },
                      "Narrow CJK calendar cells must use numeric days without a localized date suffix")
        }
        try check(us.month.filter(\.isCurrentMonth).count == 30, "Month includes every current-month day")
        try check(us.month.count.isMultiple(of: 7) && us.month.count <= 42, "Month grid has complete weeks")
        try check(us.month.filter(\.isToday).map(\.key) == ["2026-09-16"], "Only the local current date is highlighted")
        try check(us.events.count == 4, "Invalid date records cannot spill into another month")
        try check(us.events.first(where: { $0.id == "past:completed" })?.day == "2026-09-15", "UTC completed date is correct")
        let east = TrainingCalendarPresentation(snapshot: snapshot, language: .ru, now: now, timeZone: TimeZone(secondsFromGMT: 10800)!)
        try check(east.events.first(where: { $0.id == "past:completed" })?.day == "2026-09-16", "Absolute activity date follows local timezone")
        try check(east.events.first(where: { $0.id == "past:local" })?.day == "2026-09-14", "Timezone-free activity preserves its recorded calendar day")
        try check(east.events.first(where: { $0.id == "plan:date-only" })?.day == "2026-09-17", "Date-only plan must not shift with timezone")
        try check(east.events.first(where: { $0.id == "plan:date-only" })?.instant == nil, "Date-only plans receive no invented midnight")
        try check(east.events.first(where: { $0.id == "plan:timed" })?.day == "2026-09-16", "Timed plan follows local timezone rather than source date")
        try check(east.week.first(where: { $0.isToday })?.hasCompleted == true, "Completed mark appears on local today")
        try check(east.week.first(where: { $0.isToday })?.hasPlanned == true, "A planned record stays distinct on a completed day")
        try check(east.agenda.count == 2, "Today's completed and planned records form the agenda")
        try check(us.agenda.first?.id == "plan:date-only", "Without today's records, agenda selects the next planned day")
        try check(us.scheduleKnown(on: "2026-09-18"), "Verified future month coverage is known")
        try check(!us.scheduleKnown(on: "2026-09-14"), "A recent-activity list does not establish complete historical coverage")
        try check(!us.scheduleKnown(on: "2026-11-01"), "Dates outside retrieved coverage remain unknown")
        try check(us.warning == nil, "Available sections with current coverage need no error warning")
        var sparse = snapshot
        sparse.upcoming = []
        sparse.futureCoveredMonths = ["2026-09"]
        let sparseCalendar = TrainingCalendarPresentation(snapshot: sparse, language: .en, now: now, timeZone: utc)
        try check(sparseCalendar.emptyAgendaText == TrainingPresentation(language: .en).text("futureEmpty"),
                  "Empty agenda must describe only the retrieved portion, even when a later coverage end was saved")
        try check(!sparseCalendar.emptyAgendaText.contains("Oct"), "Missing later months must not be declared empty through the coverage end")
        snapshot.futureCoveredMonths = ["2026-10"]
        let missingMonth = TrainingCalendarPresentation(snapshot: snapshot, language: .en, now: now, timeZone: utc)
        try check(!missingMonth.scheduleKnown(on: "2026-09-18"), "A missing month must not be inferred from coverage end")
        try check(missingMonth.scheduleKnown(on: "2026-10-01"), "Other successfully retrieved months remain known")
        try check(missingMonth.warning != nil, "A current-month coverage hole must be visible")
        snapshot.futureCoveredMonths = nil; snapshot.futureIssue = "partial_calendar"
        let partial = TrainingCalendarPresentation(snapshot: snapshot, language: .en, now: now, timeZone: utc)
        try check(!partial.scheduleKnown(on: "2026-09-18"), "Legacy partial data cannot establish unknown day coverage")
        try check(partial.events.count == 4 && partial.warning != nil, "Partial data keeps known records with a warning")
        let unavailable = TrainingCalendarPresentation(snapshot: nil, language: .en, now: now, timeZone: utc)
        try check(unavailable.week.count == 7 && unavailable.events.isEmpty, "Unavailable calendar still shows actual dates without invented workouts")
        try check(unavailable.warning != nil && !unavailable.scheduleKnown(on: unavailable.today), "Unavailable never means a confirmed empty schedule")
        try check(!unavailable.accessibilityText(for: unavailable.week.last!).lowercased().contains("rest"), "Blank calendar cells must not claim rest days")
        snapshot.futureIssue = nil; snapshot.futureCoveredMonths = ["2026-09"]; snapshot.futureCoverageEnd = "2026-09-15"
        try check(TrainingCalendarPresentation(snapshot: snapshot, language: .en, now: now, timeZone: utc).warning?.contains("ended") == true, "Expired coverage is explicit")
        let sixWeeks = TrainingCalendarPresentation(snapshot: nil, language: .en, now: instant("2026-08-15T12:00:00Z"), timeZone: utc)
        try check(sixWeeks.month.count == 42, "Six-week months are supported")
        let dst = TrainingCalendarPresentation(snapshot: nil, language: .en, now: instant("2026-11-01T15:00:00Z"), timeZone: TimeZone(identifier: "America/New_York")!)
        try check(Set(dst.week.map(\.key)).count == 7 && dst.week.last?.key == "2026-11-07", "DST changes do not duplicate or skip calendar days")
        snapshot.past.append(snapshot.past[0])
        try check(TrainingCalendarPresentation(snapshot: snapshot, language: .en, now: now, timeZone: utc).events.filter { $0.id == "past:completed" }.count == 1, "Repeated records do not double-count completed activity")
        print("PASS: \(count) training-calendar checks")
    }
}

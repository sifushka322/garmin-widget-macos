import Foundation

/// Calendar marks are evidence of individual records, never inferred rest days.
struct TrainingCalendarPresentation {
    enum EventKind { case completed, planned }
    struct Event: Identifiable {
        let id: String
        let day: String
        let instant: Date?
        let kind: EventKind
        let title: String
        let symbol: String
        let detail: String
    }
    struct Day: Identifiable {
        let date: Date
        let key: String
        let number: String
        let isToday: Bool
        let isCurrentMonth: Bool
        let scheduleKnown: Bool
        let events: [Event]
        var id: String { key }
        var hasCompleted: Bool { events.contains { $0.kind == .completed } }
        var hasPlanned: Bool { events.contains { $0.kind == .planned } }
    }

    let snapshot: TrainingTimelineSnapshot?
    let language: AppLanguage
    let now: Date
    var timeZone: TimeZone = .autoupdatingCurrent
    private var training: TrainingPresentation { .init(language: language, now: now, timeZone: timeZone) }
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = language.locale
        value.timeZone = timeZone
        value.firstWeekday = language.locale.calendar.firstWeekday
        return value
    }
    var today: String { dayKey(now) }
    var monthTitle: String { formatted(now, template: "MMMM yyyy") }
    var weekdayTitles: [String] {
        let formatter = DateFormatter()
        formatter.locale = language.locale; formatter.calendar = calendar
        let symbols = formatter.veryShortStandaloneWeekdaySymbols ?? []
        guard symbols.count == 7 else { return [] }
        return (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
    }

    var events: [Event] {
        var items: [Event] = []
        var seen: Set<String> = []
        for record in snapshot?.past ?? [] {
            let day = record.startedAt.map(dayKey) ?? record.localStart.flatMap { sourceDay(String($0.prefix(10))) }
            guard let day, seen.insert("past:" + record.id).inserted else { continue }
            items.append(.init(id: "past:" + record.id, day: day, instant: record.startedAt,
                               kind: .completed, title: training.title(for: record), symbol: training.sportSymbol(record.sportKey),
                               detail: [training.duration(record.durationMinutes), training.distance(record.distanceKM)].compactMap { $0 }.joined(separator: " · ")))
        }
        for record in snapshot?.upcoming ?? [] {
            let day = record.startsAt.map(dayKey) ?? sourceDay(record.localDate)
            guard let day, seen.insert("plan:" + record.id).inserted else { continue }
            items.append(.init(id: "plan:" + record.id, day: day, instant: record.startsAt,
                               kind: .planned, title: training.title(for: record), symbol: training.sportSymbol(record.sportKey),
                               detail: [training.duration(record.durationMinutes), training.distance(record.distanceKM)].compactMap { $0 }.joined(separator: " · ")))
        }
        return items.sorted {
            if $0.day != $1.day { return $0.day < $1.day }
            if let left = $0.instant, let right = $1.instant, left != right { return left < right }
            if ($0.instant == nil) != ($1.instant == nil) { return $0.instant == nil }
            return $0.id < $1.id
        }
    }

    var week: [Day] {
        let start = calendar.startOfDay(for: now)
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        guard let first = calendar.date(byAdding: .day, value: -offset, to: start) else { return [] }
        return days(start: first, count: 7)
    }
    var month: [Day] {
        guard let interval = calendar.dateInterval(of: .month, for: now),
              let range = calendar.range(of: .day, in: .month, for: now) else { return [] }
        let offset = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        guard let first = calendar.date(byAdding: .day, value: -offset, to: interval.start) else { return [] }
        let cells = ((offset + range.count + 6) / 7) * 7
        return days(start: first, count: cells)
    }
    /// Prefer today's known records, then the next planned date. Never fabricate an agenda.
    var agenda: [Event] {
        let all = events
        let todays = all.filter { $0.day == today }
        if !todays.isEmpty { return todays }
        if let nextDay = all.first(where: { $0.kind == .planned && $0.day > today })?.day {
            return all.filter { $0.day == nextDay && $0.kind == .planned }
        }
        return []
    }
    func dateLabel(_ event: Event) -> String {
        guard let day = date(for: event.day) else { return training.text("dateUnknown") }
        return formatted(day, template: "EEE d MMM")
    }
    func scheduleKnown(on key: String) -> Bool {
        guard let snapshot, training.futureAvailable(snapshot), key >= today,
              let end = snapshot.futureCoverageEnd, sourceDay(end) != nil, key <= end else { return false }
        if let months = snapshot.futureCoveredMonths { return months.contains(String(key.prefix(7))) }
        // Older snapshots did not record successful months. A partial response
        // cannot establish coverage for any otherwise empty day.
        return snapshot.futureIssue == nil && snapshot.warnings.isEmpty
    }
    var warning: String? {
        guard let snapshot else { return training.text("futureUnavailable") }
        if let issue = training.issueText(snapshot.futureIssue, cached: snapshot.futureUpdatedAt != nil) { return issue }
        if !training.futureAvailable(snapshot) { return training.text("futureUnavailable") }
        if let end = snapshot.futureCoverageEnd, sourceDay(end) != nil, end < today { return training.text("expiredCoverage") }
        if !scheduleKnown(on: today) || !snapshot.warnings.isEmpty { return training.text("partial") }
        if let issue = training.issueText(snapshot.pastIssue, cached: snapshot.pastUpdatedAt != nil) { return issue }
        if !training.pastAvailable(snapshot) { return training.text("pastUnavailable") }
        return nil
    }
    var emptyAgendaText: String {
        if let warning { return warning }
        // An end date alone does not prove that every intervening month was
        // retrieved. Describe the loaded portion without promising an empty range.
        return training.text("futureEmpty")
    }
    var coverageText: String { training.text("pastCoverage") }
    func accessibilityText(for day: Day) -> String {
        let date = formatted(day.date, template: "EEEE d MMMM yyyy")
        if day.events.isEmpty {
            let state = day.key >= today
                ? training.text(day.scheduleKnown ? "futureEmpty" : "futureUnavailable")
                : training.text(training.pastAvailable(snapshot) ? "pastEmpty" : "pastUnavailable")
            return date + ". " + state
        }
        return ([date] + day.events.map { training.text($0.kind == .completed ? "completed" : "planned") + ": " + $0.title }).joined(separator: ". ")
    }

    private func days(start: Date, count: Int) -> [Day] {
        let grouped = Dictionary(grouping: events, by: \.day)
        return (0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let key = dayKey(date)
            return Day(date: date, key: key, number: dayNumber(date), isToday: key == today,
                       isCurrentMonth: calendar.isDate(date, equalTo: now, toGranularity: .month),
                       scheduleKnown: scheduleKnown(on: key), events: grouped[key] ?? [])
        }
    }
    private func dayNumber(_ date: Date) -> String {
        let formatter = NumberFormatter()
        formatter.locale = language.locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        // DateFormatter's "d" template adds 日 in CJK locales. Calendar cells
        // need the localized integer only, so all seven columns remain legible.
        return formatter.string(from: NSNumber(value: calendar.component(.day, from: date))) ?? ""
    }
    private func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = calendar
        formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    private func sourceDay(_ key: String) -> String? { date(for: key).map { _ in key } }
    private func date(for key: String) -> Date? {
        guard key.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let value = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)),
              dayKey(value) == key else { return nil }
        return calendar.startOfDay(for: value)
    }
    private func formatted(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale; formatter.calendar = calendar; formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

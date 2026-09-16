import Foundation

/// Synthetic values only for explicitly marked gallery and in-app previews.
/// This factory never reads the cache, signs in, or publishes a desktop timeline.
enum WidgetPreviewData {
    static func make(preferences: AppPreferences, at date: Date = Date(),
                     timeZone: TimeZone = .autoupdatingCurrent) -> WidgetData {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func shifted(_ days: Int) -> Date { calendar.date(byAdding: .day, value: days, to: date)! }
        func day(_ value: Date) -> String { SyncPolicy.sourceDay(for: value, timeZone: timeZone) }
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: date)!
        let months = [String(day(date).prefix(7)), String(day(nextMonth).prefix(7))]
        let nextMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: nextMonth))!
        let coverageEnd = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: nextMonthStart)!

        var snapshot = GarminSnapshot.demo
        snapshot.fetchedAt = date
        snapshot.sourceDate = day(date)
        snapshot.devices = []
        snapshot.metrics = snapshot.metrics.filter { MetricDefinition.isSupported($0.key) }
        snapshot.trainingTimeline = .init(fetchedAt: date,
            past: [
                .init(id: "preview-run", title: "", sportKey: "running", startedAt: shifted(-2),
                      durationMinutes: 42, distanceKM: 7.2),
                .init(id: "preview-cycle", title: "", sportKey: "cycling", startedAt: date.addingTimeInterval(-600),
                      durationMinutes: 55, distanceKM: 18.6)
            ],
            upcoming: [
                .init(occurrenceID: "preview-strength", localDate: day(date), title: "", sportKey: "strength_training", durationMinutes: 40),
                .init(occurrenceID: "preview-next-run", localDate: day(shifted(2)), title: "", sportKey: "running", durationMinutes: 45, distanceKM: 8),
                .init(occurrenceID: "preview-next-cycle", localDate: day(shifted(4)), title: "", sportKey: "cycling", durationMinutes: 75, distanceKM: 28)
            ],
            futureCoverageEnd: day(coverageEnd), pastCoverage: .recentActivities,
            futureCoverage: .publishedCalendar, pastUpdatedAt: date, futureUpdatedAt: date,
            futureCoveredMonths: months)
        return WidgetData(preferences: preferences, snapshot: snapshot, isConnected: true)
    }
}

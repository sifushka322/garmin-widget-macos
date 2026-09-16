import Foundation

/// The desktop shows values and actionable exceptions, never routine polling times.
struct WidgetPresentation {
    let snapshot: GarminSnapshot
    let language: AppLanguage
    let now: Date
    var timeZone: TimeZone = .autoupdatingCurrent

    func noticeKey(metricIDs: [String], connected: Bool, staleInterval: TimeInterval, hasWarnings: Bool) -> String? {
        if !connected { return "widget.notice.connection" }
        if hasWarnings { return "widget.notice.unavailable" }
        if metricIDs.contains(where: { snapshot.metricIsStale($0, at: now, timeZone: timeZone, staleInterval: staleInterval) }) {
            return "widget.notice.waiting"
        }
        return nil
    }

    /// A recent completed night needs no date on the desktop. Older records keep
    /// one short period label; the full provenance remains in accessibility/help.
    func period(_ id: String) -> String? {
        let scope = MetricDefinition.find(id).timeScope
        guard scope == .nightlyRecord || scope == .dailyRecord,
              MetricFormatter(snapshot: snapshot, language: language).value(id) != nil else { return nil }
        let day = snapshot.retainedMetrics[id]?.sourceDate ?? snapshot.sourceDate
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let today = SyncPolicy.sourceDay(for: now, timeZone: timeZone)
        if day == today { return nil }
        if scope == .nightlyRecord, let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           day == SyncPolicy.sourceDay(for: yesterday, timeZone: timeZone) { return nil }
        let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0); parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: day) else { return nil }
        let output = DateFormatter(); output.locale = language.locale
        output.timeZone = TimeZone(secondsFromGMT: 0)
        output.setLocalizedDateFormatFromTemplate(day.prefix(4) == today.prefix(4) ? "d MMM" : "d MMM yyyy")
        return output.string(from: date)
    }
}

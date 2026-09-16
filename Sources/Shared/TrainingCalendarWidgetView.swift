import SwiftUI
import WidgetKit

struct TrainingCalendarWidgetView: View {
    let presentation: TrainingCalendarPresentation
    let family: WidgetFamily
    let theme: DeskMetricTheme
    let isConnected: Bool
    private var small: Bool { family == .systemSmall }
    private var large: Bool { family == .systemLarge }
    private var cells: [TrainingCalendarPresentation.Day] { large ? presentation.month : presentation.week }
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: small ? 1 : 4), count: 7) }
    private func text(_ key: String) -> String { Localizer.text("training." + key, language: presentation.language) }
    private var warning: String? {
        if !isConnected { return Localizer.text("widget.connect", language: presentation.language) }
        return presentation.warning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                if !small { Image(systemName: "calendar").foregroundStyle(theme.highlight) }
                Text(presentation.monthTitle).font(.system(size: small ? 12 : 15, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            VStack(spacing: large ? 5 : 3) {
                LazyVGrid(columns: columns, spacing: 0) {
                    ForEach(Array(presentation.weekdayTitles.enumerated()), id: \.offset) { _, title in
                        Text(title).font(.system(size: small ? 8 : 9, weight: .medium)).foregroundStyle(theme.secondaryInk)
                    }
                }
                LazyVGrid(columns: columns, spacing: large ? 2 : 0) {
                    ForEach(cells) { day in dayCell(day) }
                }
            }
            if small {
                compactLegend
                Spacer(minLength: 0)
            } else {
                legend
                if large { Rectangle().fill(theme.ink.opacity(0.13)).frame(height: 1) }
                agenda
                Spacer(minLength: 0)
            }
            if let warning {
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(.system(size: small ? 8 : 9, weight: .medium))
                    .foregroundStyle(theme.highlight).lineLimit(small ? 2 : 1).minimumScaleFactor(0.85)
            } else {
                Text(small ? text("recent") : presentation.coverageText)
                    .font(.system(size: small ? 8 : 9)).foregroundStyle(theme.secondaryInk)
                    .lineLimit(small ? 1 : 2).minimumScaleFactor(0.8)
                    .help(presentation.coverageText)
            }
        }
        .foregroundStyle(theme.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func dayCell(_ day: TrainingCalendarPresentation.Day) -> some View {
        VStack(spacing: 2) {
            Text(day.number).lineLimit(1).minimumScaleFactor(0.8).font(.system(size: small ? 11 : (large ? 12 : 14), weight: day.isToday ? .bold : .medium, design: .rounded))
                .frame(maxWidth: .infinity).frame(height: small ? 19 : (large ? 18 : 23))
                .background(day.isToday ? theme.highlight.opacity(0.24) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(day.isToday ? theme.highlight : Color.clear, lineWidth: 1))
            HStack(spacing: 2) {
                if day.hasCompleted { Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.highlight) }
                if day.hasPlanned { Image(systemName: "circle").foregroundStyle(theme.ink) }
                if !day.hasCompleted && !day.hasPlanned { Color.clear.frame(width: 5, height: 5) }
            }
            .font(.system(size: small ? 5 : 6, weight: .bold)).frame(height: large ? 5 : 7)
        }
        .opacity(day.isCurrentMonth ? ((day.scheduleKnown || !day.events.isEmpty || day.isToday) ? 1 : 0.55) : 0.25)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityText(for: day))
    }

    private var compactLegend: some View {
        HStack(spacing: 12) {
            let events = cells.flatMap(\.events)
            Label(countText(events, kind: .completed), systemImage: "checkmark.circle.fill")
                .foregroundStyle(theme.highlight).accessibilityLabel(text("completed"))
                .accessibilityValue(countText(events, kind: .completed))
            Label(countText(events, kind: .planned), systemImage: "circle")
                .accessibilityLabel(text("planned")).accessibilityValue(countText(events, kind: .planned))
        }.font(.system(size: 10, weight: .medium)).padding(.top, 1)
    }
    private func countText(_ events: [TrainingCalendarPresentation.Event], kind: TrainingCalendarPresentation.EventKind) -> String {
        let count = events.filter { $0.kind == kind }.count
        let futureDays = cells.filter { $0.key >= presentation.today }
        let known = kind == .completed
            ? presentation.snapshot?.pastCoverage == .recentActivities && presentation.snapshot?.pastUpdatedAt != nil
            : !futureDays.isEmpty && futureDays.allSatisfy(\.scheduleKnown)
        if known { return String(count) }
        return count > 0 ? "≥" + String(count) : "—"
    }
    private var legend: some View {
        HStack(spacing: 12) {
            Label(text("completed"), systemImage: "checkmark.circle.fill").foregroundStyle(theme.highlight)
            Label(text("planned"), systemImage: "circle").foregroundStyle(theme.secondaryInk)
        }.font(.system(size: 8, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
    }
    private var agenda: some View {
        let items = Array(presentation.agenda.prefix(large ? 2 : 1))
        return VStack(alignment: .leading, spacing: 5) {
            if items.isEmpty {
                if warning == nil {
                    Text(presentation.emptyAgendaText).font(.system(size: 10)).foregroundStyle(theme.secondaryInk)
                        .lineLimit(large ? 2 : 1).minimumScaleFactor(0.85)
                }
            } else {
                ForEach(items) { event in agendaRow(event) }
            }
        }
    }

    private func agendaRow(_ event: TrainingCalendarPresentation.Event) -> some View {
        let completed = event.kind == .completed
        let symbol = completed ? "checkmark.circle.fill" : "circle"
        let color = completed ? theme.highlight : theme.ink
        let date = presentation.dateLabel(event)
        let detail = [date, event.detail].filter { !$0.isEmpty }.joined(separator: " · ")
        let accessibility = [text(completed ? "completed" : "planned"), event.title, date, event.detail].joined(separator: ". ")
        return HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol).foregroundStyle(color)
                .font(.system(size: 10)).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: large ? 12 : 11, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.85)
                if large {
                    Text(detail).font(.system(size: 9)).foregroundStyle(theme.secondaryInk)
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
            }
            if !large {
                Spacer(minLength: 2)
                Text(date).font(.system(size: 9)).foregroundStyle(theme.secondaryInk)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

}

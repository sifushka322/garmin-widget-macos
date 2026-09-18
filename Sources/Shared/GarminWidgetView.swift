import SwiftUI
import WidgetKit

struct GarminEntry: TimelineEntry {
    let date: Date
    let data: WidgetData?
    var profileID: String? = nil // Read-only compatibility for older call sites; never selects content.
    var slot: WidgetSlot = .overview
    var isGalleryPreview: Bool = false
}

struct GarminWidgetView: View {
    let entry: GarminEntry
    var previewFamily: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var systemFamily
    private var family: WidgetFamily { previewFamily ?? systemFamily }
    private var data: WidgetData { entry.data ?? .preview }
    private var language: AppLanguage { data.preferences.language }
    private var profile: WidgetProfile { entry.slot.profile(in: data.preferences) }
    private var metricSelection: WidgetMetricSelection {
        WidgetMetricPolicy.selection(for: profile, snapshot: data.snapshot)
    }
    private var formatter: MetricFormatter { MetricFormatter(snapshot: data.snapshot, language: language, now: entry.date) }
    private var timeline: TrainingTimelineSnapshot? { data.snapshot.trainingTimeline }
    private var destination: URL? { URL(string: "garmindesk://widget/" + entry.slot.rawValue) }
    private var theme: DeskMetricTheme { entry.slot.theme(appearance: data.preferences.widgetAppearance) }
    private var accent: Color { theme.highlight }
    private var presentation: WidgetPresentation { .init(snapshot: data.snapshot, language: language, now: entry.date) }
    private var noticeKey: String? {
        presentation.noticeKey(metricIDs: visibleMetricIDs, connected: data.isConnected,
                               staleInterval: data.preferences.staleInterval, hasWarnings: hasWarnings)
    }
    private func text(_ key: String) -> String { Localizer.text(key, language: language) }

    var body: some View {
        Group {
            if previewFamily != nil { widgetContent }
            else { widgetContent.containerBackground(for: .widget) { background } }
        }
        .widgetURL(destination)
        .environment(\.locale, language.locale)
        .overlay(alignment: .topTrailing) {
            if entry.isGalleryPreview {
                Text(text("widget.demo"))
                    .font(.system(size: 7, weight: .bold)).tracking(0.3)
                    .foregroundStyle(theme.ink.opacity(0.8))
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(theme.ink.opacity(0.1), in: Capsule())
                    .offset(y: -12)
                    .accessibilityLabel(text("data.demo"))
                    .help(text("data.demo"))
            }
        }
    }

    var background: some View { theme.background }

    private var widgetContent: some View {
        Group {
            if entry.data == nil {
                emptyState(symbol: "rectangle.grid.2x2", title: text("widget.openApp"), message: text("widget.openAppHint"))
            } else if data.snapshot.isDemo && !entry.isGalleryPreview {
                emptyState(symbol: "applewatch", title: text("dashboard.connect"), message: text("widget.connect"))
            } else if entry.slot == .overview {
                SummaryWidgetView(data: data, date: entry.date, family: family)
            } else if entry.slot == .training {
                trainingContent(profile)
            } else if !data.snapshot.hasMeasurements {
                emptyState(symbol: data.isConnected ? "clock" : "applewatch",
                           title: text(data.isConnected ? "widget.waiting" : "dashboard.connect"),
                           message: text(data.isConnected ? "widget.waitingHint" : "widget.connect"))
            } else {
                content(profile)
            }
        }
        .foregroundStyle(theme.ink)
        .privacySensitive(true)
    }

    private func content(_ profile: WidgetProfile) -> some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 12) {
            if profile.contentMode.includesTraining {
                trainingContent(profile)
            } else {
                metricsContent(profile)
            }
            if !profile.contentMode.includesTraining, let noticeKey {
                Label(text(noticeKey), systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(theme.highlight)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .privacySensitive(true)
    }

    private func metricsContent(_ profile: WidgetProfile) -> some View {
        Group {
            if family == .systemSmall {
                primary(metricSelection.primary, compact: true)
            } else if family == .systemMedium {
                GeometryReader { geometry in
                    let columnWidth = max(0, (geometry.size.width - 16) / 2)
                    HStack(alignment: .top, spacing: 16) {
                        primary(metricSelection.primary, compact: false)
                            .frame(width: columnWidth, alignment: .leading)
                        VStack(alignment: .leading, spacing: profile.density == .compact ? 9 : 12) {
                            ForEach(Array(secondary(profile).prefix(profile.density == .compact ? 3 : 2)), id: \.self) { metric in
                                if profile.density == .compact { compactMetricRow(metric) }
                                else { metricRow(metric) }
                            }
                        }.frame(width: columnWidth, alignment: .leading)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    primary(metricSelection.primary, compact: false)
                    Rectangle().fill(theme.ink.opacity(0.16)).frame(height: 1)
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: profile.density == .compact ? 10 : 16) {
                        ForEach(Array(secondary(profile).prefix(profile.density == .compact ? 8 : 6)), id: \.self) { metric in
                            metricRow(metric)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: family == .systemSmall ? .leading : .topLeading)
    }

    private func trainingContent(_ profile: WidgetProfile) -> some View {
        TrainingCalendarWidgetView(
            presentation: .init(snapshot: timeline, language: language, now: entry.date),
            family: family, theme: theme, isConnected: data.isConnected)
    }

    private func secondary(_ profile: WidgetProfile) -> [String] { metricSelection.secondary }

    private func primary(_ id: String, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 8) {
            HStack(spacing: 6) {
                Image(systemName: MetricDefinition.find(id).symbol).foregroundStyle(accent)
                Text(text(MetricDefinition.find(id).widgetTitleKey)).foregroundStyle(theme.secondaryInk)
            }
            .font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            MetricValueLabel(value: formatter.display(id), size: compact ? 46 : (family == .systemLarge ? 48 : 38))
                .foregroundStyle(theme.ink).layoutPriority(1)
            if let status = formatter.interpretation(id)?.status {
                Text(status).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.secondaryInk)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            if let period = presentation.period(id) {
                Text(period).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.secondaryInk)
            }
            if let progress = formatter.progress(id) {
                GeometryReader { proxy in
                    Capsule().fill(theme.ink.opacity(0.15))
                    Capsule().fill(accent).frame(width: proxy.size.width * progress)
                }.frame(height: 5).padding(.top, 2).accessibilityHidden(true)
            }
        }
        .help(formatter.help(id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(formatter.accessibility(id))
    }

    private func metricRow(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(text(MetricDefinition.find(id).widgetTitleKey), systemImage: MetricDefinition.find(id).symbol)
                .font(.system(size: 10)).foregroundStyle(theme.secondaryInk).lineLimit(1).minimumScaleFactor(0.8)
            MetricValueLabel(value: formatter.display(id), size: family == .systemLarge ? 23 : 22)
                .foregroundStyle(theme.ink)
            if let status = formatter.interpretation(id)?.status {
                Text(status).font(.system(size: 8)).foregroundStyle(theme.secondaryInk)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            if let period = presentation.period(id) {
                Text(period).font(.system(size: 8)).foregroundStyle(theme.secondaryInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(formatter.help(id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(formatter.accessibility(id))
    }

    private func compactMetricRow(_ id: String) -> some View {
        HStack(spacing: 5) {
            Text(text(MetricDefinition.find(id).widgetTitleKey))
                .font(.system(size: 10)).foregroundStyle(theme.secondaryInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            MetricValueLabel(value: formatter.display(id), size: 18).foregroundStyle(theme.ink)
        }
        .lineLimit(1).minimumScaleFactor(0.75).frame(minHeight: 21)
        .help(formatter.help(id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(formatter.accessibility(id))
    }

    private var hasWarnings: Bool {
        return (profile.contentMode.includesMetrics && !data.snapshot.warnings.isEmpty)
            || (profile.contentMode.includesTraining && (!(timeline?.warnings.isEmpty ?? true) || timeline?.pastIssue != nil || timeline?.futureIssue != nil))
    }

    private var visibleMetricIDs: [String] {
        guard profile.contentMode.includesMetrics else { return [] }
        let limit = family == .systemSmall ? 0 : (family == .systemMedium
            ? (profile.density == .compact ? 3 : 2) : (profile.density == .compact ? 8 : 6))
        return [metricSelection.primary] + Array(secondary(profile).prefix(limit))
    }

    private func emptyState(symbol: String, title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(accent)
            Text(title).font(.headline)
            Text(message).font(.caption).foregroundStyle(theme.secondaryInk)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

import SwiftUI
import WidgetKit

struct GarminEntry: TimelineEntry {
    let date: Date
    let data: WidgetData?
    let profileID: String?
}

struct GarminWidgetView: View {
    let entry: GarminEntry
    var previewFamily: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var systemFamily
    private var family: WidgetFamily { previewFamily ?? systemFamily }
    private var data: WidgetData { entry.data ?? .preview }
    private var language: AppLanguage { data.preferences.language }
    private var profile: WidgetProfile? { data.profile(id: entry.profileID) }
    private var formatter: MetricFormatter { MetricFormatter(snapshot: data.snapshot, language: language) }
    private var training: TrainingPresentation { TrainingPresentation(language: language, now: entry.date) }
    private var timeline: TrainingTimelineSnapshot? { data.snapshot.trainingTimeline }
    private var lastActivity: PastActivitySummary? { training.recentActivities(in: timeline).first }
    private var nextWorkout: PlannedWorkoutSummary? { training.upcomingWorkouts(in: timeline).first }
    private var smallShowsFuture: Bool { nextWorkout != nil || lastActivity == nil }
    private var destination: URL? {
        if let profile, data.isConnected { return URL(string: "garmindesk://profile/" + profile.id.uuidString) }
        return URL(string: "garmindesk://settings")
    }
    private var theme: DeskMetricTheme { .metric(profile?.primaryMetric ?? "bodyBattery", style: profile?.style ?? .calm) }
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
    }

    var background: some View { theme.background }

    private var widgetContent: some View {
        Group {
            if entry.data == nil {
                emptyState(symbol: "rectangle.grid.2x2", title: text("widget.openApp"), message: text("widget.openAppHint"))
            } else if data.snapshot.isDemo || (!data.isConnected && !data.snapshot.hasMeasurements) {
                emptyState(symbol: "applewatch", title: text("dashboard.connect"), message: text("widget.connect"))
            } else if let profile {
                if !data.snapshot.hasMeasurements && !profile.contentMode.includesTraining {
                    emptyState(symbol: "clock", title: text("widget.waiting"), message: text("widget.waitingHint"))
                } else { content(profile) }
            } else {
                let unconfigured = entry.profileID == "unconfigured"
                emptyState(symbol: "slider.horizontal.3", title: text(unconfigured ? "widget.openApp" : "widget.profileMissing"),
                           message: text(unconfigured || WidgetDataStore.configurationMode != .profileIntents ? "widget.openAppHint" : "widget.profileMissingHint"))
            }
        }
        .foregroundStyle(theme.ink)
    }

    private func content(_ profile: WidgetProfile) -> some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 12) {
            if profile.contentMode.includesTraining {
                trainingContent(profile)
            } else {
                metricsContent(profile)
            }
            if let noticeKey {
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
                primary(profile.primaryMetric, compact: true)
            } else if family == .systemMedium {
                HStack(alignment: .top, spacing: 16) {
                    primary(profile.primaryMetric, compact: false).frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: profile.density == .compact ? 9 : 12) {
                        ForEach(Array(secondary(profile).prefix(profile.density == .compact ? 3 : 2)), id: \.self) { metric in
                            if profile.density == .compact { compactMetricRow(metric) }
                            else { metricRow(metric) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    primary(profile.primaryMetric, compact: false)
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
        Group {
            if family == .systemSmall {
                trainingCard(future: smallShowsFuture, roomy: false)
            } else if family == .systemMedium {
                HStack(alignment: .top, spacing: 10) {
                    trainingCard(future: false, roomy: false)
                    trainingCard(future: true, roomy: false)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if profile.contentMode.includesMetrics {
                        primary(profile.primaryMetric, compact: false)
                        Rectangle().fill(theme.ink.opacity(0.16)).frame(height: 1)
                    }
                    VStack(spacing: profile.density == .compact ? 8 : 10) {
                        trainingCard(future: false, roomy: true)
                        trainingCard(future: true, roomy: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func trainingCard(future: Bool, roomy: Bool) -> some View {
        let record = future ? nextWorkout.map(workoutRecord) : lastActivity.map(activityRecord)
        let heading = training.text(future ? "next" : "last")
        let empty = future ? training.futureEmptyText(timeline) : training.pastEmptyText(timeline)
        let issue = training.issueText(future ? timeline?.futureIssue : timeline?.pastIssue,
                                       cached: (future ? timeline?.futureUpdatedAt : timeline?.pastUpdatedAt) != nil)
        let color: Color = accent
        let coverage = future ? training.futureCoverageText(timeline) : training.text("pastCoverage")
        let titleLines = roomy || family == .systemSmall ? 2 : 1
        var accessibilityParts = [heading]
        if let record { accessibilityParts += [record.title, record.date] + record.values }
        else { accessibilityParts.append(empty) }
        accessibilityParts.append(coverage)
        if let issue { accessibilityParts.append(issue) }
        let accessibilityText = accessibilityParts.joined(separator: ". ")
        return VStack(alignment: .leading, spacing: roomy ? 5 : 3) {
            HStack(spacing: 4) {
                Text(heading).font(.system(size: 9, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                if issue != nil { Image(systemName: "exclamationmark.circle").font(.system(size: 10)).foregroundStyle(.orange) }
            }.foregroundStyle(color)
            if let record {
                Label(record.title, systemImage: record.symbol)
                    .font(.system(size: roomy ? 14 : 12, weight: .semibold))
                    .lineLimit(titleLines).minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(record.date).font(.system(size: roomy ? 11 : 10)).foregroundStyle(theme.secondaryInk)
                    .lineLimit(1).minimumScaleFactor(0.85)
                if !record.values.isEmpty {
                    Text(record.values.joined(separator: " · "))
                        .font(.system(size: roomy ? 12 : 11, weight: .medium, design: .rounded))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                }
                if roomy, let issue {
                    Text(issue).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(1).minimumScaleFactor(0.85)
                }
            } else {
                Text(empty).font(.system(size: roomy ? 12 : 11, weight: .medium))
                    .lineLimit(roomy ? 3 : 4).minimumScaleFactor(0.9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(roomy ? 10 : 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(theme.ink.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private struct TrainingRecord {
        let title: String
        let symbol: String
        let date: String
        let values: [String]
    }

    private func activityRecord(_ activity: PastActivitySummary) -> TrainingRecord {
        TrainingRecord(title: training.title(for: activity), symbol: training.sportSymbol(activity.sportKey),
                       date: activity.startedAt.map(shortDateTime) ?? training.dateText(for: activity),
                       values: [training.duration(activity.durationMinutes), training.distance(activity.distanceKM)].compactMap { $0 })
    }

    private func workoutRecord(_ workout: PlannedWorkoutSummary) -> TrainingRecord {
        TrainingRecord(title: training.title(for: workout), symbol: training.sportSymbol(workout.sportKey),
                       date: workout.startsAt.map(shortDateTime) ?? training.dayText(workout.localDate) ?? training.text("dateUnknown"),
                       values: [training.duration(workout.durationMinutes), training.distance(workout.distanceKM)].compactMap { $0 })
    }

    private func shortDateTime(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = language.locale
        formatter.dateStyle = .short; formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func secondary(_ profile: WidgetProfile) -> [String] { profile.metricIDs.filter { $0 != profile.primaryMetric } }

    private func primary(_ id: String, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 8) {
            HStack(spacing: 6) {
                Image(systemName: MetricDefinition.find(id).symbol).foregroundStyle(accent)
                Text(text(MetricDefinition.find(id).widgetTitleKey)).foregroundStyle(theme.secondaryInk)
            }
            .font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            MetricValueLabel(value: formatter.display(id), size: compact ? 46 : (family == .systemLarge ? 48 : 38))
                .foregroundStyle(theme.ink).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
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
        .help(formatter.context(id) ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([text(MetricDefinition.find(id).titleKey) + ": " + formatter.display(id)] + [formatter.context(id)].compactMap { $0 }).joined(separator: ", "))
    }

    private func metricRow(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(text(MetricDefinition.find(id).widgetTitleKey), systemImage: MetricDefinition.find(id).symbol)
                .font(.system(size: 10)).foregroundStyle(theme.secondaryInk).lineLimit(1).minimumScaleFactor(0.8)
            MetricValueLabel(value: formatter.display(id), size: family == .systemLarge ? 23 : 22)
                .foregroundStyle(theme.ink).fixedSize(horizontal: false, vertical: true)
            if let period = presentation.period(id) {
                Text(period).font(.system(size: 8)).foregroundStyle(theme.secondaryInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([text(MetricDefinition.find(id).titleKey) + ": " + formatter.display(id)] + [formatter.context(id)].compactMap { $0 }).joined(separator: ", "))
    }

    private func compactMetricRow(_ id: String) -> some View {
        HStack(spacing: 5) {
            Text(text(MetricDefinition.find(id).widgetTitleKey))
                .font(.system(size: 10)).foregroundStyle(theme.secondaryInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            MetricValueLabel(value: formatter.display(id), size: 18).foregroundStyle(theme.ink)
        }
        .lineLimit(1).minimumScaleFactor(0.75).frame(minHeight: 21)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([text(MetricDefinition.find(id).titleKey) + ": " + formatter.display(id)] + [formatter.context(id)].compactMap { $0 }).joined(separator: ", "))
    }

    private var hasWarnings: Bool {
        guard let profile else { return false }
        return (profile.contentMode.includesMetrics && !data.snapshot.warnings.isEmpty)
            || (profile.contentMode.includesTraining && (!(timeline?.warnings.isEmpty ?? true) || timeline?.pastIssue != nil || timeline?.futureIssue != nil))
    }

    private var visibleMetricIDs: [String] {
        guard let profile, profile.contentMode.includesMetrics else { return [] }
        if profile.contentMode.includesTraining { return family == .systemLarge ? [profile.primaryMetric] : [] }
        let limit = family == .systemSmall ? 0 : (family == .systemMedium
            ? (profile.density == .compact ? 3 : 2) : (profile.density == .compact ? 8 : 6))
        return [profile.primaryMetric] + Array(secondary(profile).prefix(limit))
    }

    private func emptyState(symbol: String, title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(accent)
            Text(title).font(.headline)
            Text(message).font(.caption).foregroundStyle(theme.secondaryInk)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

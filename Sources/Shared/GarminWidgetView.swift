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
    private var accent: Color {
        switch profile?.style ?? .calm {
        case .calm: return Color(red: 0.13, green: 0.64, blue: 0.60)
        case .sport: return Color(red: 0.95, green: 0.40, blue: 0.19)
        case .monochrome: return .primary
        }
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

    var background: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay(LinearGradient(colors: [.clear, accent.opacity(0.08)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
    }

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
    }

    private func content(_ profile: WidgetProfile) -> some View {
        VStack(alignment: .leading, spacing: family == .systemSmall || (family == .systemMedium && !profile.contentMode.includesTraining) ? 8 : 12) {
            HStack(spacing: 5) {
                GarminDeskBrandMark().frame(width: 13, height: 13)
                    .foregroundStyle(accent).accessibilityHidden(true)
                Text(profile.name.isEmpty ? text("profile.default") : profile.name).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if profile.contentMode.includesTraining {
                trainingContent(profile)
            } else {
                metricsContent(profile)
            }
            footer
        }
        .privacySensitive(!data.snapshot.isDemo)
    }

    @ViewBuilder private func metricsContent(_ profile: WidgetProfile) -> some View {
            if family == .systemSmall {
                primary(profile.primaryMetric, compact: true)
                Spacer(minLength: 0)
            } else if family == .systemMedium {
                HStack(alignment: .top, spacing: 16) {
                    primary(profile.primaryMetric, compact: false).frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: profile.density == .compact ? 5 : 8) {
                        ForEach(Array(secondary(profile).prefix(profile.density == .compact ? 3 : 2)), id: \.self) { metric in
                            if profile.density == .compact { compactMetricRow(metric) }
                            else { metricRow(metric) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            } else {
                primary(profile.primaryMetric, compact: false)
                Divider().opacity(0.5)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: profile.density == .compact ? 10 : 16) {
                    ForEach(Array(secondary(profile).prefix(profile.density == .compact ? 8 : 6)), id: \.self) { metric in
                        metricRow(metric)
                    }
                }
                Spacer(minLength: 0)
            }
    }

    @ViewBuilder private func trainingContent(_ profile: WidgetProfile) -> some View {
        if family == .systemSmall {
            trainingCard(future: smallShowsFuture, roomy: false)
            Spacer(minLength: 0)
        } else if family == .systemMedium {
            HStack(alignment: .top, spacing: 10) {
                trainingCard(future: false, roomy: false)
                trainingCard(future: true, roomy: false)
            }
            Spacer(minLength: 0)
        } else {
            if profile.contentMode.includesMetrics {
                primary(profile.primaryMetric, compact: false)
                Divider().opacity(0.5)
            }
            VStack(spacing: profile.density == .compact ? 8 : 10) {
                trainingCard(future: false, roomy: true)
                trainingCard(future: true, roomy: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func trainingCard(future: Bool, roomy: Bool) -> some View {
        let record = future ? nextWorkout.map(workoutRecord) : lastActivity.map(activityRecord)
        let heading = training.text(future ? "next" : "last")
        let empty = future ? training.futureEmptyText(timeline) : training.pastEmptyText(timeline)
        let issue = training.issueText(future ? timeline?.futureIssue : timeline?.pastIssue,
                                       cached: (future ? timeline?.futureUpdatedAt : timeline?.pastUpdatedAt) != nil)
        let color: Color = future && profile?.style != .monochrome ? .indigo : accent
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
                Text(record.date).font(.system(size: roomy ? 11 : 10)).foregroundStyle(.secondary)
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
        .background(color.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
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
        VStack(alignment: .leading, spacing: 5) {
            Label(text(MetricDefinition.find(id).widgetTitleKey), systemImage: MetricDefinition.find(id).symbol)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            Text(formatter.display(id))
                .font(.system(size: compact ? 31 : 30, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            if data.snapshot.retainedMetrics[id] != nil {
                Label(text("data.previous"), systemImage: "clock")
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            if let progress = formatter.progress(id) {
                GeometryReader { proxy in
                    Capsule().fill(accent.opacity(0.14))
                    Capsule().fill(accent).frame(width: proxy.size.width * progress)
                }.frame(height: 4).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text(MetricDefinition.find(id).titleKey) + ": " + formatter.display(id))
    }

    private func metricRow(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(text(MetricDefinition.find(id).widgetTitleKey), systemImage: MetricDefinition.find(id).symbol)
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            Text(formatter.display(id)).font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text(MetricDefinition.find(id).titleKey) + ": " + formatter.display(id))
    }

    private func compactMetricRow(_ id: String) -> some View {
        HStack(spacing: 5) {
            Text(text(MetricDefinition.find(id).widgetTitleKey))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(formatter.display(id))
                .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .lineLimit(1).minimumScaleFactor(0.75).frame(minHeight: 21)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text(MetricDefinition.find(id).titleKey) + ": " + formatter.display(id))
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if !data.isConnected {
                Image(systemName: "exclamationmark.circle")
                Text(text("status.notConnected"))
            } else if let day = visibleMetricIDs.compactMap({ data.snapshot.retainedMetrics[$0]?.sourceDate }).min() {
                Image(systemName: "clock")
                Text(text("data.day") + " " + (training.dayText(day) ?? day))
            } else if let refreshedAt {
                let stale = entry.date.timeIntervalSince(refreshedAt) > data.preferences.staleInterval
                    || visibleMetricIDs.contains { data.snapshot.metricIsStale($0, at: entry.date, staleInterval: data.preferences.staleInterval) }
                Image(systemName: stale ? "clock.badge.exclamationmark" : "arrow.triangle.2.circlepath")
                Text(text("data.updated"))
                Text(refreshedAt, style: .time)
                if hasWarnings { Image(systemName: "exclamationmark.circle") }
            } else {
                Text(text("data.empty"))
            }
        }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
    }

    private var hasWarnings: Bool {
        guard let profile else { return false }
        return (profile.contentMode.includesMetrics && !data.snapshot.warnings.isEmpty)
            || (profile.contentMode.includesTraining && (!(timeline?.warnings.isEmpty ?? true) || timeline?.pastIssue != nil || timeline?.futureIssue != nil))
    }

    private var refreshedAt: Date? {
        guard let profile else { return nil }
        guard profile.contentMode.includesTraining else { return metricRefreshedAt }
        var dates: [Date]
        if family == .systemSmall {
            dates = [smallShowsFuture ? timeline?.futureUpdatedAt : timeline?.pastUpdatedAt].compactMap { $0 }
        } else {
            dates = [timeline?.pastUpdatedAt, timeline?.futureUpdatedAt].compactMap { $0 }
        }
        if profile.contentMode.includesMetrics && family == .systemLarge, let metricRefreshedAt { dates.append(metricRefreshedAt) }
        return dates.min()
    }

    private var visibleMetricIDs: [String] {
        guard let profile, profile.contentMode.includesMetrics else { return [] }
        if profile.contentMode.includesTraining { return family == .systemLarge ? [profile.primaryMetric] : [] }
        let limit = family == .systemSmall ? 0 : (family == .systemMedium
            ? (profile.density == .compact ? 3 : 2) : (profile.density == .compact ? 8 : 6))
        return [profile.primaryMetric] + Array(secondary(profile).prefix(limit))
    }

    /// Every visible value contributes to freshness, including secondary metrics.
    private var metricRefreshedAt: Date? {
        visibleMetricIDs.compactMap { data.snapshot.metricUpdatedAt($0) }.min()
    }

    private func emptyState(symbol: String, title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(accent)
            Text(title).font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

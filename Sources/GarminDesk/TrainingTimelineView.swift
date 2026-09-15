import SwiftUI

struct TrainingTimelineView: View {
    let snapshot: TrainingTimelineSnapshot?
    let language: AppLanguage
    var compact = false
    private var presentation: TrainingPresentation { TrainingPresentation(language: language) }
    private var past: [PastActivitySummary] { presentation.recentActivities(in: snapshot) }
    private var upcoming: [PlannedWorkoutSummary] { presentation.upcomingWorkouts(in: snapshot) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            Label(presentation.text("title"), systemImage: "figure.run")
                .font(.headline)
            ViewThatFits(in: .horizontal) {
                if !compact {
                    HStack(alignment: .top, spacing: 12) {
                        pastCard.frame(minWidth: 240)
                        futureCard.frame(minWidth: 240)
                    }
                }
                VStack(spacing: 12) { pastCard; futureCard }
            }
            if past.count > 1 {
                DisclosureGroup(presentation.text("recent") + " (\(past.count))") {
                    LazyVStack(spacing: 0) {
                        ForEach(past) { activity in
                            TrainingRecordRow(record: record(activity), accent: .teal)
                            if activity.id != past.last?.id { Divider() }
                        }
                    }.padding(.top, 8)
                }.font(.subheadline)
            }
            if upcoming.count > 1 {
                DisclosureGroup(presentation.text("upcoming") + " (\(upcoming.count))") {
                    LazyVStack(spacing: 0) {
                        ForEach(upcoming) { workout in
                            TrainingRecordRow(record: record(workout), accent: .indigo)
                            if workout.id != upcoming.last?.id { Divider() }
                        }
                    }.padding(.top, 8)
                }.font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pastCard: some View {
        TrainingSummaryCard(
            heading: presentation.text("last"), symbol: "checkmark.circle", accent: .teal,
            record: past.first.map(record), empty: presentation.pastEmptyText(snapshot),
            coverage: presentation.pastAvailable(snapshot) ? presentation.text("pastCoverage") : presentation.text("pastUnavailableHint"),
            freshness: presentation.freshness(snapshot?.pastUpdatedAt),
            issue: presentation.issueText(snapshot?.pastIssue, cached: snapshot?.pastUpdatedAt != nil), compact: compact)
    }

    private var futureCard: some View {
        TrainingSummaryCard(
            heading: presentation.text("next"), symbol: "calendar", accent: .indigo,
            record: upcoming.first.map(record), empty: presentation.futureEmptyText(snapshot),
            coverage: presentation.futureCoverageText(snapshot),
            freshness: presentation.freshness(snapshot?.futureUpdatedAt),
            issue: presentation.issueText(snapshot?.futureIssue, cached: snapshot?.futureUpdatedAt != nil), compact: compact)
    }

    private func record(_ activity: PastActivitySummary) -> TrainingViewRecord {
        TrainingViewRecord(title: presentation.title(for: activity), sport: presentation.sportTitle(activity.sportKey),
            symbol: presentation.sportSymbol(activity.sportKey), date: presentation.dateText(for: activity),
            duration: presentation.duration(activity.durationMinutes), distance: presentation.distance(activity.distanceKM))
    }

    private func record(_ workout: PlannedWorkoutSummary) -> TrainingViewRecord {
        TrainingViewRecord(title: presentation.title(for: workout), sport: presentation.sportTitle(workout.sportKey),
            symbol: presentation.sportSymbol(workout.sportKey), date: presentation.dateText(for: workout),
            duration: presentation.duration(workout.durationMinutes), distance: presentation.distance(workout.distanceKM))
    }
}

private struct TrainingViewRecord {
    let title: String
    let sport: String
    let symbol: String
    let date: String
    let duration: String?
    let distance: String?
}

private struct TrainingSummaryCard: View {
    let heading: String
    let symbol: String
    let accent: Color
    let record: TrainingViewRecord?
    let empty: String
    let coverage: String
    let freshness: String
    let issue: String?
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 13) {
            Label(heading, systemImage: symbol)
                .font(.caption.weight(.semibold)).foregroundStyle(accent)
            if let record {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: record.symbol)
                        .font(.system(size: compact ? 19 : 23, weight: .medium))
                        .frame(width: 40, height: 40)
                        .foregroundStyle(accent)
                        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.title).font(.headline).lineLimit(3)
                        if record.title != record.sport { Text(record.sport).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Text(record.date).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TrainingValues(record: record).font(.subheadline.weight(.medium))
            } else {
                Text(empty).font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(accent.opacity(0.08))
            VStack(alignment: .leading, spacing: 4) {
                Text(coverage)
                Text(freshness)
                if let issue {
                    Label(issue, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 13 : 16)
        .background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(accent.opacity(0.10)))
        .accessibilityElement(children: .combine)
    }
}

private struct TrainingRecordRow: View {
    let record: TrainingViewRecord
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: record.symbol).foregroundStyle(accent).frame(width: 22).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title).font(.subheadline.weight(.medium)).lineLimit(2)
                Text(record.date).font(.caption).foregroundStyle(.secondary)
                TrainingValues(record: record).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

private struct TrainingValues: View {
    let record: TrainingViewRecord

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                if let duration = record.duration { Label(duration, systemImage: "timer") }
                if let distance = record.distance { Label(distance, systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
            }
            VStack(alignment: .leading, spacing: 4) {
                if let duration = record.duration { Label(duration, systemImage: "timer") }
                if let distance = record.distance { Label(distance, systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
            }
        }.monospacedDigit()
    }
}

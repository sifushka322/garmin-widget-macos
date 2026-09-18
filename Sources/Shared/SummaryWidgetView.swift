import SwiftUI
import WidgetKit

/// The summary is one ordered selection of measurements, displayed as a single canvas.
struct SummaryWidgetView: View {
    let data: WidgetData
    let date: Date
    let family: WidgetFamily
    private var language: AppLanguage { data.preferences.language }
    private var formatter: MetricFormatter { .init(snapshot: data.snapshot, language: language, now: date) }
    private var theme: DeskMetricTheme { .summary(appearance: data.preferences.widgetAppearance) }
    private var presentation: WidgetPresentation { .init(snapshot: data.snapshot, language: language, now: date) }
    private var selection: WidgetMetricSelection {
        WidgetMetricPolicy.summarySelection(preferences: data.preferences, snapshot: data.snapshot)
    }
    private var secondary: [String] {
        Array(selection.secondary.prefix(family == .systemSmall ? 1 : (family == .systemMedium ? 2 : 6)))
    }
    private var notice: String? {
        if !data.isConnected && !data.snapshot.hasMeasurements { return "widget.connect" }
        let visible = [selection.primary] + secondary
        if let notice = presentation.noticeKey(metricIDs: visible, connected: data.isConnected,
                                                staleInterval: data.preferences.staleInterval,
                                                hasWarnings: !data.snapshot.warnings.isEmpty) { return notice }
        return visible.allSatisfy({ formatter.value($0) == nil }) ? "widget.waiting" : nil
    }
    private func text(_ key: String) -> String { Localizer.text(key, language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 12) {
            if family == .systemSmall {
                primary(size: 46)
                if let id = secondary.first { compactRow(id) }
            } else if family == .systemMedium {
                GeometryReader { geometry in
                    let width = max(0, (geometry.size.width - 16) / 2)
                    HStack(alignment: .top, spacing: 16) {
                        primary(size: 38).frame(width: width, alignment: .leading)
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(secondary, id: \.self) { id in metric(id, size: 23) }
                        }.frame(width: width, alignment: .leading)
                    }
                }
            } else {
                primary(size: 48)
                if !secondary.isEmpty {
                    Rectangle().fill(theme.ink.opacity(0.16)).frame(height: 1)
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                              alignment: .leading, spacing: 14) {
                        ForEach(secondary, id: \.self) { id in metric(id, size: 25) }
                    }
                }
            }
            Spacer(minLength: 0)
            if let notice {
                Label(text(notice), systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(theme.highlight)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .foregroundStyle(theme.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func primary(size: CGFloat) -> some View {
        let id = selection.primary
        return VStack(alignment: .leading, spacing: 6) {
            Label(text(MetricDefinition.find(id).widgetTitleKey), systemImage: MetricDefinition.find(id).symbol)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.secondaryInk)
                .lineLimit(1).minimumScaleFactor(0.8)
            value(id, size: size)
        }
        .help(formatter.help(id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility(id))
    }

    private func metric(_ id: String, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text(MetricDefinition.find(id).widgetTitleKey))
                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.secondaryInk)
                .lineLimit(1).minimumScaleFactor(0.75)
            value(id, size: size)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(formatter.help(id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility(id))
    }

    private func value(_ id: String, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            MetricValueLabel(value: formatter.display(id), size: size).foregroundStyle(theme.ink)
            if let status = formatter.interpretation(id)?.status {
                Text(status).font(.system(size: 8, weight: .medium)).foregroundStyle(theme.secondaryInk)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            if let period = presentation.period(id) {
                Text(period).font(.system(size: 8)).foregroundStyle(theme.secondaryInk)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }

    private func compactRow(_ id: String) -> some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text(text(MetricDefinition.find(id).widgetTitleKey))
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(theme.secondaryInk)
                if let period = presentation.period(id) {
                    Text(period).font(.system(size: 8)).foregroundStyle(theme.secondaryInk)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            MetricValueLabel(value: formatter.display(id), size: 20).foregroundStyle(theme.ink)
        }
        .lineLimit(1).minimumScaleFactor(0.75)
        .help(formatter.help(id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility(id))
    }

    private func accessibility(_ id: String) -> String {
        formatter.accessibility(id)
    }
}

import AppKit
import SwiftUI
import WidgetKit

@main
struct RenderWidgets {
    @MainActor static func main() throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
            || ProcessInfo.processInfo.environment["GARMIN_ALLOW_LOCAL_TESTS"] == "1" else {
            fatalError("Run visual fixtures in CI; local rendering requires explicit opt-in")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let families: [(String, WidgetFamily, CGSize)] = [
            ("small", .systemSmall, CGSize(width: 170, height: 170)),
            ("medium", .systemMedium, CGSize(width: 360, height: 170)),
            ("large", .systemLarge, CGSize(width: 360, height: 376))
        ]
        for lang in [AppLanguage.ru, .en] {
            var data = WidgetData.preview
            data.preferences.language = lang
            data.preferences.profiles[0].density = .compact
            data.preferences.profiles[0].metricIDs += ["hrv", "trainingReadiness", "spo2", "calories"]
            for (name, family, size) in families {
                try render(data, name: "widget-\(lang.rawValue)-\(name)", family: family, size: size, now: Date(), output: output)
            }
        }
        let now = Date(timeIntervalSince1970: 1_789_473_600)
        // An extension can read the previous version's demo cache before the host
        // app has launched and replaced it. Render this exact upgrade state.
        try render(WidgetData.preview, name: "states-legacy-demo-cache", family: .systemMedium,
                   size: families[1].2, now: now, output: output, preserveDemo: true)
        // Medium rows must keep a complete numeric line in both densities;
        // long units and sleep duration exercise different horizontal proposals.
        for language in [AppLanguage.ru, .en] {
            for density in [WidgetDensity.comfortable, .compact] {
                for metric in ["bodyBattery", "sleepDuration", "vo2Max"] {
                    var layout = WidgetData.preview
                    layout.preferences.language = language
                    layout.preferences.profiles[0].density = density
                    layout.preferences.profiles[0].primaryMetric = metric
                    layout.preferences.profiles[0].metricIDs = [metric] + ["steps", "stress", "recoveryTime", "hrv", "trainingReadiness"].filter { $0 != metric }
                    try render(layout, name: "metrics-\(language.rawValue)-medium-\(density.rawValue)-\(metric)",
                               family: .systemMedium, size: families[1].2, now: now, output: output)
                }
            }
            var detailed = WidgetData.preview
            detailed.preferences.language = language
            detailed.preferences.profiles[0].density = .comfortable
            detailed.preferences.profiles[0].metricIDs = MetricDefinition.catalog.map(\.id)
            try render(detailed, name: "metrics-\(language.rawValue)-large-detailed",
                       family: .systemLarge, size: families[2].2, now: now, output: output)
        }
        for slot in WidgetSlot.allCases {
            try render(slot.previewData(language: .ru, at: now), name: "gallery-" + slot.rawValue,
                       family: .systemMedium, size: families[1].2, now: now, output: output)
        }
        var sample = WidgetData.preview
        sample.isConnected = true
        sample.snapshot.isDemo = false
        sample.snapshot.fetchedAt = now
        sample.snapshot.groupUpdatedAt = ["body_battery": now.addingTimeInterval(-3600)]
        sample.preferences.profiles[0].contentMode = .training
        sample.preferences.profiles[0].name = "Пример · Тренировки"
        sample.preferences.language = .ru
        sample.snapshot.trainingTimeline = TrainingTimelineSnapshot(fetchedAt: now,
            past: [PastActivitySummary(id: "fixture-past", title: "Утренняя тренировка с длинным названием", sportKey: "running",
                                       startedAt: now.addingTimeInterval(-86400), durationMinutes: 67.5, distanceKM: 10.5)],
            upcoming: [PlannedWorkoutSummary(occurrenceID: "fixture-next", localDate: "2026-09-16",
                                             title: "Интервальная тренировка с длинным названием", sportKey: "cycling", durationMinutes: 80)],
            futureCoverageEnd: "2026-10-31", pastCoverage: .recentActivities, futureCoverage: .publishedCalendar,
            pastUpdatedAt: now.addingTimeInterval(-3600), futureUpdatedAt: now.addingTimeInterval(-600))
        try render(sample, name: "training-ru-small", family: .systemSmall, size: families[0].2, now: now, output: output)
        sample.preferences.language = .en
        sample.preferences.profiles[0].name = "Example · Training"
        sample.snapshot.trainingTimeline?.past[0].title = "Morning endurance workout with a long title"
        sample.snapshot.trainingTimeline?.upcoming[0].title = "Scheduled interval session with a long title"
        try render(sample, name: "training-en-medium", family: .systemMedium, size: families[1].2, now: now, output: output)
        sample.preferences.language = .ru
        sample.preferences.profiles[0].name = "Пример · Спорт"
        sample.preferences.profiles[0].contentMode = .mixed
        sample.preferences.profiles[0].density = .compact
        sample.snapshot.trainingTimeline?.futureIssue = "partial_calendar"
        try render(sample, name: "mixed-ru-large", family: .systemLarge, size: families[2].2, now: now, output: output)
        sample.preferences.profiles[0].contentMode = .training
        sample.snapshot.trainingTimeline = nil
        try render(sample, name: "training-ru-unavailable", family: .systemMedium, size: families[1].2, now: now, output: output)
        sample.preferences.language = .en
        sample.preferences.profiles[0].name = "Example · Training"
        sample.snapshot.trainingTimeline = TrainingTimelineSnapshot(fetchedAt: now,
            futureCoverageEnd: "2026-10-31", pastCoverage: .recentActivities, futureCoverage: .publishedCalendar,
            pastUpdatedAt: now, futureUpdatedAt: now)
        try render(sample, name: "training-en-empty", family: .systemSmall, size: families[0].2, now: now, output: output)
        sample.snapshot.trainingTimeline?.past = [PastActivitySummary(id: "fixture-last", title: "Evening run", sportKey: "running",
            startedAt: now.addingTimeInterval(-86400), durationMinutes: 45, distanceKM: 8)]
        sample.snapshot.trainingTimeline?.futureCoverage = .unavailable
        sample.snapshot.trainingTimeline?.futureUpdatedAt = nil
        try render(sample, name: "training-en-last", family: .systemSmall, size: families[0].2, now: now, output: output)

        for language in [AppLanguage.ru, .en] {
            var data = WidgetData.preview
            data.preferences.language = language
            data.preferences.profiles[0].name = language == .ru ? "Очень длинное название профиля здоровья" : "A very long health profile name"
            data.isConnected = true
            data.snapshot.isDemo = false
            data.snapshot.fetchedAt = now
            data.snapshot.sourceDate = SyncPolicy.sourceDay(for: now, timeZone: .current)
            data.snapshot.metrics = ["steps": .init(value: 0), "bodyBattery": .init(value: 76)]
            data.snapshot.groupUpdatedAt = ["stats": now, "body_battery": now.addingTimeInterval(-7200)]
            for (name, family, size) in families {
                try render(data, name: "states-\(language.rawValue)-\(name)-partial-stale", family: family, size: size, now: now, output: output)
            }
            data.isConnected = false
            try render(data, name: "states-\(language.rawValue)-disconnected", family: .systemMedium, size: families[1].2, now: now, output: output)
            data.snapshot = .empty
            data.isConnected = true
            try render(data, name: "states-\(language.rawValue)-empty", family: .systemMedium, size: families[1].2, now: now, output: output)
            data.snapshot.retainedMetrics = ["bodyBattery": .init(reading: .init(value: 76), sourceDate: "2026-09-14",
                retrievedAt: now.addingTimeInterval(-86400), changedAt: now.addingTimeInterval(-86400))]
            for (name, family, size) in families {
                try render(data, name: "states-\(language.rawValue)-\(name)-retained", family: family, size: size, now: now, output: output)
            }
        }

    }
    @MainActor private static func render(_ data: WidgetData, name: String, family: WidgetFamily, size: CGSize,
                                          now: Date, output: URL, preserveDemo: Bool = false) throws {
        var data = data
        if data.snapshot.isDemo && !preserveDemo { data.snapshot.isDemo = false; data.isConnected = true }
        for dark in [false, true] {
            let widget = GarminWidgetView(entry: GarminEntry(date: now, data: data, profileID: data.preferences.profiles.first?.id.uuidString), previewFamily: family)
            let view = widget
                .environment(\.colorScheme, dark ? .dark : .light)
                .padding(16).frame(width: size.width, height: size.height)
                .background(widget.background)
                .environment(\.colorScheme, dark ? .dark : .light)
                .clipShape(RoundedRectangle(cornerRadius: 24))
            let renderer = ImageRenderer(content: view); renderer.scale = 2
            guard let image = renderer.cgImage else { fatalError("Unable to render widget") }
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let bytes = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { fatalError("Unable to encode PNG") }
            try bytes.write(to: output.appendingPathComponent(name + (dark ? "-dark" : "-light") + ".png"))
        }
    }

}

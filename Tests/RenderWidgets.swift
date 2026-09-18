import AppKit
import SwiftUI
import WidgetKit

@main
struct RenderWidgets {
    static let families: [(String, WidgetFamily, CGSize)] = [
        ("small", .systemSmall, .init(width: 170, height: 170)),
        ("medium", .systemMedium, .init(width: 360, height: 170)),
        ("large", .systemLarge, .init(width: 360, height: 376))
    ]
    @MainActor static func main() throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" || ProcessInfo.processInfo.environment["GARMIN_ALLOW_LOCAL_TESTS"] == "1" else { fatalError("Local rendering requires explicit opt-in") }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().date(from: "2026-09-16T12:00:00Z")!
        for language in AppLanguage.supported {
            var data = sample(language: language, now: now)
            for appearance in WidgetAppearance.allCases {
                // All languages exercise every fixed purpose; the three appearance
                // modes also get a full EN/RU/DE matrix, including long labels.
                if appearance != .colorful && ![AppLanguage.en, .ru, .de].contains(language) { continue }
                data.preferences.widgetAppearance = appearance
                for slot in WidgetSlot.allCases {
                    for (sizeName, family, size) in families {
                        try render(data, slot: slot, family: family, size: size, now: now,
                                   name: "fixed-\(language.rawValue)-\(appearance.rawValue)-\(slot.rawValue)-\(sizeName)", output: output)
                    }
                }
            }
        }
        for language in AppLanguage.supported {
            for state in ["optimal-detraining", "low-load", "high-load", "hrv-balanced-low-night", "context-missing", "garmin-ratio"] {
                var data = sample(language: language, now: now)
                data.snapshot.metricContext = GarminMetricContext(trainingLoadLower: 350, trainingLoadUpper: 780,
                    trainingStatus: "DETRAINING", hrvStatus: "BALANCED", hrvWeeklyAverage: 58,
                    hrvBaselineLow: 49, hrvBaselineHigh: 72)
                if state == "low-load" { data.snapshot.metrics["trainingLoad"] = .init(value: 180) }
                if state == "high-load" { data.snapshot.metrics["trainingLoad"] = .init(value: 985) }
                if state == "hrv-balanced-low-night" {
                    data.preferences.summaryMetrics = ["hrv", "sleepScore", "trainingLoad", "recoveryTime"]
                    data.snapshot.metrics["hrv"] = .init(value: 32)
                } else {
                    data.preferences.summaryMetrics = ["trainingLoad", "recoveryTime", "hrv", "trainingReadiness"]
                }
                if state == "context-missing" { data.snapshot.metricContext = nil }
                if state == "garmin-ratio" {
                    data.snapshot.metricContext = GarminMetricContext(trainingStatus: "PRODUCTIVE",
                        trainingLoadStatus: "OPTIMAL", trainingLoadRatio: 1.2)
                }
                for (sizeName, family, size) in families {
                    // Summary covers a load/HRV primary; sport covers load in a
                    // secondary tile while retaining readiness as its primary.
                    for slot in [WidgetSlot.overview, .sport] {
                        try render(data, slot: slot, family: family, size: size, now: now,
                                   name: "context-\(language.rawValue)-\(state)-\(slot.rawValue)-\(sizeName)", output: output)
                    }
                }
            }
            // Remaining legacy state permutations are already covered in EN/RU.
            if ![AppLanguage.en, .ru].contains(language) { continue }
            for customization in ["chosen", "zero", "unavailable"] {
                var data = sample(language: language, now: now)
                data.preferences.summaryMetrics = ["steps", "sleepDuration", "hrv", "vo2Max"]
                if customization == "zero" { data.snapshot.metrics["steps"] = .init(value: 0) }
                if customization == "unavailable" {
                    data.snapshot.metrics = ["bodyBattery": .init(value: 76)]
                }
                for (sizeName, family, size) in families {
                    try render(data, slot: .overview, family: family, size: size, now: now,
                               name: "custom-summary-\(language.rawValue)-\(customization)-\(sizeName)", output: output)
                }
            }
            for state in ["missing-primary", "partial", "only-recovery", "retained-sleep", "disconnected", "waiting", "legacy-demo", "body-battery-estimated", "body-battery-expired"] {
                var data = sample(language: language, now: now)
                switch state {
                case "missing-primary": data.snapshot.metrics.removeValue(forKey: "bodyBattery"); data.snapshot.metrics.removeValue(forKey: "trainingReadiness")
                case "partial": data.snapshot.metrics = ["steps": .init(value: 0), "bodyBattery": .init(value: 76)]; data.snapshot.warnings = ["partial_stats"]
                case "only-recovery": data.snapshot.metrics = ["recoveryTime": .init(value: 600)]
                case "retained-sleep":
                    data.snapshot.retainedMetrics = ["sleepDuration", "hrv", "sleepScore"].reduce(into: [:]) { result, id in
                        let value: Double = id == "sleepDuration" ? 480 : (id == "hrv" ? 62 : 86)
                        result[id] = .init(reading: .init(value: value), sourceDate: "2026-09-14", retrievedAt: now.addingTimeInterval(-86400), changedAt: now.addingTimeInterval(-86400))
                    }
                    data.snapshot.metrics = [:]
                case "disconnected": data.isConnected = false
                case "waiting": data.snapshot = .empty
                case "legacy-demo": data.snapshot = .demo; data.isConnected = false
                case "body-battery-estimated", "body-battery-expired":
                    let anchor = MetricReading(value: 60, measuredAt: now.addingTimeInterval(state == "body-battery-estimated" ? -1800 : -7200))
                    data.snapshot.metrics["bodyBattery"] = anchor
                    data.snapshot.bodyBatteryProjection = .init(anchor: anchor, pointsPerHour: -12,
                        validUntil: anchor.measuredAt!.addingTimeInterval(3600))
                default: break
                }
                if state == "retained-sleep" {
                    for (sizeName, family, size) in families {
                        try render(data, slot: .overview, family: family, size: size, now: now,
                                   name: "retained-summary-\(language.rawValue)-\(sizeName)", output: output)
                    }
                }
                for slot in [WidgetSlot.overview, .day, .sport, .sleep] {
                    let chosen = families[slot == .sleep ? 2 : 1]
                    try render(data, slot: slot, family: chosen.1, size: chosen.2, now: now,
                               name: "state-\(language.rawValue)-\(state)-\(slot.rawValue)", output: output)
                }
            }
        }
        // Readability stress cases combine translated interpretation, an old
        // record date, and an actionable notice in the smallest fixed family.
        // The small summary may omit its optional supporting measurement; the
        // same state also exercises medium and large layouts.
        for language in [AppLanguage.ru, .de, .pl] {
            for state in ["old-load-network", "old-hrv-disconnected", "retained-load-waiting", "dense-old-load"] {
                var data = sample(language: language, now: now)
                let old = now.addingTimeInterval(-3 * 86400)
                let oldDay = SyncPolicy.sourceDay(for: old, timeZone: .autoupdatingCurrent)
                data.snapshot.sourceDate = oldDay
                data.snapshot.fetchedAt = old
                data.snapshot.metricContext = GarminMetricContext(trainingLoadLower: 350, trainingLoadUpper: 780,
                    trainingStatus: "DETRAINING", hrvStatus: "NO_STATUS", hrvWeeklyAverage: 58,
                    hrvBaselineLow: 49, hrvBaselineHigh: 72)
                data.preferences.summaryMetrics = ["trainingLoad", "recoveryTime", "hrv", "trainingReadiness"]
                if state == "old-hrv-disconnected" {
                    data.preferences.summaryMetrics = ["hrv", "trainingLoad", "sleepScore", "recoveryTime"]
                    data.isConnected = false
                } else if state == "retained-load-waiting" {
                    for id in data.preferences.summaryMetrics {
                        if let reading = data.snapshot.metrics.removeValue(forKey: id) {
                            data.snapshot.retainedMetrics[id] = .init(reading: reading, sourceDate: oldDay,
                                retrievedAt: old, changedAt: old)
                        }
                    }
                } else {
                    data.snapshot.warnings = ["network.stats"]
                    if state == "dense-old-load" {
                        data.preferences.summaryMetrics = ["trainingLoad", "recoveryTime", "hrv", "sleepScore",
                            "stress", "trainingReadiness", "bodyBattery"]
                    }
                }
                for appearance in [WidgetAppearance.light, .dark] {
                    data.preferences.widgetAppearance = appearance
                    for (sizeName, family, size) in families {
                        try render(data, slot: .overview, family: family, size: size, now: now,
                            name: "stress-\(language.rawValue)-\(state)-\(sizeName)-\(appearance.rawValue)", output: output)
                    }
                }
            }
        }
        for language in AppLanguage.supported {
            var preferences = AppPreferences(); preferences.language = language
            let data = WidgetPreviewData.make(preferences: preferences, at: now)
            for slot in WidgetSlot.allCases {
                for (sizeName, family, size) in families {
                    try render(data, slot: slot, family: family, size: size, now: now,
                               name: "gallery-\(language.rawValue)-\(slot.rawValue)-\(sizeName)", output: output, isGalleryPreview: true)
                }
            }
        }
    }

    static func sample(language: AppLanguage, now: Date) -> WidgetData {
        var preferences = AppPreferences(); preferences.language = language
        var snapshot = GarminSnapshot.empty
        snapshot.fetchedAt = now; snapshot.sourceDate = "2026-09-16"
        snapshot.metrics = ["bodyBattery": .init(value: 76), "steps": .init(value: 6842), "stress": .init(value: 24),
            "restingHeartRate": .init(value: 54), "sleepDuration": .init(value: 462), "sleepScore": .init(value: 86),
            "deepSleep": .init(value: 85), "remSleep": .init(value: 95), "lightSleep": .init(value: 270),
            "hrv": .init(value: 62), "respiration": .init(value: 15.3), "trainingReadiness": .init(value: 78),
            "recoveryTime": .init(value: 720), "trainingLoad": .init(value: 525), "vo2Max": .init(value: 49),
            "hydration": .init(value: 1250), "intensityMinutes": .init(value: 35), "calories": .init(value: 1860)]
        snapshot.trainingTimeline = .init(fetchedAt: now,
            past: [.init(id: "fixture-completed", title: "", sportKey: "running", startedAt: now.addingTimeInterval(-86400), durationMinutes: 45, distanceKM: 8)],
            upcoming: [.init(occurrenceID: "fixture-planned", localDate: "2026-09-17", title: "", sportKey: "strength_training", durationMinutes: 60)],
            futureCoverageEnd: "2026-10-31", pastCoverage: .recentActivities, futureCoverage: .publishedCalendar,
            pastUpdatedAt: now, futureUpdatedAt: now, futureCoveredMonths: ["2026-09", "2026-10"])
        return WidgetData(preferences: preferences, snapshot: snapshot, isConnected: true)
    }

    @MainActor static func render(_ data: WidgetData, slot: WidgetSlot, family: WidgetFamily, size: CGSize,
                                  now: Date, name: String, output: URL, isGalleryPreview: Bool = false) throws {
        let widget = GarminWidgetView(entry: .init(date: now, data: data, slot: slot, isGalleryPreview: isGalleryPreview), previewFamily: family)
        let view = widget.padding(16).frame(width: size.width, height: size.height).background(widget.background)
            .environment(\.colorScheme, data.preferences.widgetAppearance == .light ? .light : .dark)
            .clipShape(RoundedRectangle(cornerRadius: 24))
        let renderer = ImageRenderer(content: view); renderer.scale = 2
        guard let image = renderer.cgImage, let bytes = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("Unable to render fixed widget") }
        try bytes.write(to: output.appendingPathComponent(name + ".png"))
    }
}

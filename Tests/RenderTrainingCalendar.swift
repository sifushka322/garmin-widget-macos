import AppKit
import SwiftUI
import WidgetKit

@main
struct RenderTrainingCalendar {
    @MainActor static func main() throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" || ProcessInfo.processInfo.environment["GARMIN_ALLOW_LOCAL_TESTS"] == "1" else { fatalError("Rendering requires explicit local opt-in") }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let date = ISO8601DateFormatter().date(from: "2026-08-19T10:00:00Z")!
        let families: [(String, WidgetFamily, CGSize)] = [("small", .systemSmall, .init(width: 170, height: 170)), ("medium", .systemMedium, .init(width: 360, height: 170)), ("large", .systemLarge, .init(width: 360, height: 376))]
        for language in [AppLanguage.en, .ru, .de] {
            for state in ["filled", "empty", "partial", "unavailable", "gallery"] {
                var data = WidgetSlot.training.previewData(language: language, at: date)
                if state != "gallery" { data.snapshot = .empty }
                if state != "unavailable" && state != "gallery" {
                    data.snapshot.trainingTimeline = .init(fetchedAt: date, futureCoverageEnd: "2026-09-30", pastCoverage: .recentActivities, futureCoverage: .publishedCalendar, pastUpdatedAt: date, futureUpdatedAt: date, futureCoveredMonths: ["2026-08", "2026-09"])
                    if state != "empty" {
                        data.snapshot.trainingTimeline?.past = [.init(id: "done", title: "", sportKey: "running", localStart: "2026-08-17T10:00:00", durationMinutes: 45, distanceKM: 8)]
                        data.snapshot.trainingTimeline?.upcoming = [.init(occurrenceID: "next", localDate: "2026-08-20", title: "", sportKey: "strength_training", durationMinutes: 60), .init(occurrenceID: "long", localDate: "2026-08-22", title: "", sportKey: "cycling", durationMinutes: 90)]
                    }
                    if state == "partial" { data.snapshot.trainingTimeline?.futureIssue = "partial_calendar"; data.snapshot.trainingTimeline?.futureCoveredMonths = ["2026-09"] }
                }
                for (name, family, size) in families {
                    let view = GarminWidgetView(entry: .init(date: date, data: data, slot: .training, isGalleryPreview: state == "gallery"), previewFamily: family)
                    let content = view.padding(16).frame(width: size.width, height: size.height).background(view.background)
                        .environment(\.colorScheme, .dark).clipShape(RoundedRectangle(cornerRadius: 24))
                    let renderer = ImageRenderer(content: content); renderer.scale = 2
                    guard let cg = renderer.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { fatalError("Render failed") }
                    try png.write(to: output.appendingPathComponent("calendar-\(language.rawValue)-\(state)-\(name).png"))
                }
            }
        }
    }
}

import SwiftUI
import WidgetKit

struct GarminTimelineProvider: TimelineProvider {
    let slot: WidgetSlot
    private func entry(date: Date, data: WidgetData?, isGalleryPreview: Bool = false) -> GarminEntry {
        GarminEntry(date: date, data: data, slot: slot, isGalleryPreview: isGalleryPreview)
    }
    private var previewData: WidgetData {
        WidgetPreviewData.make(preferences: WidgetDataStore.read()?.preferences ?? AppPreferences())
    }
    func placeholder(in context: Context) -> GarminEntry { entry(date: Date(), data: previewData, isGalleryPreview: true) }
    func getSnapshot(in context: Context, completion: @escaping (GarminEntry) -> Void) {
        completion(entry(date: Date(), data: context.isPreview ? previewData : WidgetDataStore.read(),
                         isGalleryPreview: context.isPreview))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<GarminEntry>) -> Void) {
        let now = Date(), data = WidgetDataStore.read()
        let dates = WidgetTimelineSchedule.dates(data: data, slot: slot, from: now)
        completion(Timeline(entries: dates.map { entry(date: $0, data: data) },
            policy: .after(now.addingTimeInterval(Double(max(15, data?.preferences.refreshMinutes ?? 15)) * 60))))
    }
}

struct GarminSummaryWidget: Widget {
    var slot: WidgetSlot = .overview
    private var language: AppLanguage { WidgetDataStore.read()?.preferences.language ?? .system }
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: slot.kind, provider: GarminTimelineProvider(slot: slot)) { entry in
            GarminWidgetView(entry: entry)
        }
        .configurationDisplayName(Text(Localizer.text(slot.titleKey, language: language)))
        .description(Text(Localizer.text(slot.descriptionKey, language: language)))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct GarminDeskWidgets: WidgetBundle {
    var body: some Widget {
        GarminSummaryWidget(slot: .overview)
        GarminSummaryWidget(slot: .day)
        GarminSummaryWidget(slot: .sport)
        GarminSummaryWidget(slot: .sleep)
        GarminSummaryWidget(slot: .training)
    }
}

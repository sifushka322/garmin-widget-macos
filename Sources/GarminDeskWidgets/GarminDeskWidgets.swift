import AppIntents
import SwiftUI
import WidgetKit

#if !GARMIN_WIDGET_STATIC_CONFIGURATION
struct ProfileEntity: AppEntity {
    var id: String
    var name: String
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Profile"
    static var defaultQuery = ProfileQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    static func profiles() -> [ProfileEntity] {
        guard let data = WidgetDataStore.read() else { return [] }
        return data.preferences.profiles.map {
            ProfileEntity(id: $0.id.uuidString,
                name: $0.name.isEmpty ? Localizer.text("profile.default", language: data.preferences.language) : $0.name)
        }
    }
}

struct ProfileQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ProfileEntity] {
        ProfileEntity.profiles().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [ProfileEntity] { ProfileEntity.profiles() }
    func defaultResult() async -> ProfileEntity? { ProfileEntity.profiles().first }
}

struct SelectProfileIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose a profile"
    static var description = IntentDescription("Select the metrics and appearance configured in GarminDesk.")
    @Parameter(title: "Profile") var profile: ProfileEntity?
}

struct GarminTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> GarminEntry {
        GarminEntry(date: Date(), data: WidgetSlot.overview.previewData, profileID: nil)
    }

    func snapshot(for configuration: SelectProfileIntent, in context: Context) async -> GarminEntry {
        if context.isPreview {
            let language = WidgetDataStore.read()?.preferences.language ?? .system
            return GarminEntry(date: Date(), data: WidgetSlot.overview.previewData(language: language), profileID: nil)
        }
        return GarminEntry(date: Date(), data: WidgetDataStore.read(), profileID: configuration.profile?.id)
    }

    func timeline(for configuration: SelectProfileIntent, in context: Context) async -> Timeline<GarminEntry> {
        let now = Date()
        let data = WidgetDataStore.read()
        let entry = GarminEntry(date: now, data: data, profileID: configuration.profile?.id)
        // The host fetches Garmin data. WidgetKit controls when this local cache is rendered again.
        let refresh = now.addingTimeInterval(Double(max(15, data?.preferences.refreshMinutes ?? 15)) * 60)
        return Timeline(entries: [entry], policy: .after(refresh))
    }
}

#else
struct GarminStaticTimelineProvider: TimelineProvider {
    let slot: WidgetSlot

    private func entry(date: Date, data: WidgetData?) -> GarminEntry {
        GarminEntry(date: date, data: data,
                    profileID: data.flatMap { slot.profileID(in: $0.preferences) } ?? "unconfigured")
    }
    private var previewData: WidgetData {
        slot.previewData(language: WidgetDataStore.read()?.preferences.language ?? .system)
    }
    func placeholder(in context: Context) -> GarminEntry {
        entry(date: Date(), data: previewData)
    }
    func getSnapshot(in context: Context, completion: @escaping (GarminEntry) -> Void) {
        completion(entry(date: Date(), data: context.isPreview ? previewData : WidgetDataStore.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<GarminEntry>) -> Void) {
        let now = Date(), data = WidgetDataStore.read()
        completion(Timeline(entries: [entry(date: now, data: data)],
                            policy: .after(now.addingTimeInterval(Double(max(15, data?.preferences.refreshMinutes ?? 15)) * 60))))
    }
}
#endif

struct GarminSummaryWidget: Widget {
    var slot: WidgetSlot = .overview
    private var language: AppLanguage { WidgetDataStore.read()?.preferences.language ?? .system }
    var body: some WidgetConfiguration {
        #if GARMIN_WIDGET_STATIC_CONFIGURATION
        StaticConfiguration(kind: slot.kind, provider: GarminStaticTimelineProvider(slot: slot)) { entry in
            GarminWidgetView(entry: entry)
        }
        .configurationDisplayName(Text(Localizer.text(slot.titleKey, language: language)))
        .description(Text(Localizer.text(slot.descriptionKey, language: language)))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        #else
        AppIntentConfiguration(kind: WidgetDataStore.kind, intent: SelectProfileIntent.self, provider: GarminTimelineProvider()) { entry in
            GarminWidgetView(entry: entry)
        }
        .configurationDisplayName(Text(Localizer.text("widget.galleryTitle", language: language)))
        .description(Text(Localizer.text("widget.galleryDescription", language: language)))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        #endif
    }
}

@main
struct GarminDeskWidgets: WidgetBundle {
    var body: some Widget {
        GarminSummaryWidget()
        #if GARMIN_WIDGET_STATIC_CONFIGURATION
        GarminSummaryWidget(slot: .sport)
        GarminSummaryWidget(slot: .sleep)
        GarminSummaryWidget(slot: .training)
        #endif
    }
}

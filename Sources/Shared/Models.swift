import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    // Existing values stay stable because preferences and widget snapshots persist them.
    case system, en, ru, de, fr, es, it
    case ptBR = "pt-BR"
    case nl, pl, ja, ko
    case zhHans = "zh-Hans"
    var id: String { rawValue }
    static var supported: [AppLanguage] { allCases.filter { $0 != .system } }

    /// Try each preferred language in order, including region/script variants.
    /// Traditional Chinese must not silently select the Simplified Chinese table.
    static func preferred(in identifiers: [String]) -> AppLanguage {
        for identifier in identifiers {
            let parts = identifier.replacingOccurrences(of: "_", with: "-")
                .lowercased().split(separator: "-").map(String.init)
            guard let base = parts.first else { continue }
            if base == "zh" {
                if let script = parts.dropFirst().first(where: { $0.count == 4 && $0.allSatisfy(\.isLetter) }) {
                    if script == "hans" { return .zhHans }
                    continue
                }
                if parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) { continue }
                return .zhHans
            }
            if base == "pt" { return .ptBR }
            if let match = AppLanguage(rawValue: base), match != .system { return match }
        }
        return .en
    }

    var effectiveLanguage: AppLanguage { self == .system ? Self.preferred(in: Locale.preferredLanguages) : self }
    var effectiveCode: String { effectiveLanguage.rawValue }

    /// Use autonyms so people can recover their language from any translated UI.
    var nativeName: String {
        switch self {
        case .system: return Localizer.text("general.system", language: .system)
        case .en: return "English"
        case .ru: return "Русский"
        case .de: return "Deutsch"
        case .fr: return "Français"
        case .es: return "Español"
        case .it: return "Italiano"
        case .ptBR: return "Português (Brasil)"
        case .nl: return "Nederlands"
        case .pl: return "Polski"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .zhHans: return "简体中文"
        }
    }

    var locale: Locale {
        // Following the system preserves the user's independent regional settings.
        if self == .system { return .autoupdatingCurrent }
        let identifier: String
        switch self {
        case .system, .en: identifier = "en_US"
        case .ru: identifier = "ru_RU"
        case .de: identifier = "de_DE"
        case .fr: identifier = "fr_FR"
        case .es: identifier = "es_ES"
        case .it: identifier = "it_IT"
        case .ptBR: identifier = "pt_BR"
        case .nl: identifier = "nl_NL"
        case .pl: identifier = "pl_PL"
        case .ja: identifier = "ja_JP"
        case .ko: identifier = "ko_KR"
        case .zhHans: identifier = "zh_Hans_CN"
        }
        return Locale(identifier: identifier)
    }
}

enum AppAppearance: String, CaseIterable, Codable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var colorScheme: ColorScheme? { self == .system ? nil : (self == .light ? .light : .dark) }
}

enum WidgetStyle: String, CaseIterable, Codable, Identifiable {
    case calm, sport, monochrome
    var id: String { rawValue }
}

enum WidgetDensity: String, CaseIterable, Codable, Identifiable {
    case comfortable, compact
    var id: String { rawValue }
}

enum WidgetContentMode: String, CaseIterable, Codable, Identifiable {
    case metrics, training, mixed
    var id: String { rawValue }
    // `mixed` remains decodable for existing profiles; its presentation is now metrics only.
    var includesTraining: Bool { self == .training }
    var includesMetrics: Bool { self != .training }
}

/// Fixed render recipe and legacy snapshot wire format; never a user-created profile.
struct WidgetProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var metricIDs = ["bodyBattery", "steps", "stress", "sleepDuration", "restingHeartRate", "sleepScore", "intensityMinutes"]
    var primaryMetric = "bodyBattery"
    var style: WidgetStyle = .calm
    var density: WidgetDensity = .comfortable
    var contentMode: WidgetContentMode = .metrics
    var prefersAvailableMetrics = true

    init() {}
    enum CodingKeys: String, CodingKey { case id, name, metricIDs, primaryMetric, style, density, contentMode, prefersAvailableMetrics }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        metricIDs = try c.decode([String].self, forKey: .metricIDs)
        primaryMetric = try c.decode(String.self, forKey: .primaryMetric)
        style = try c.decode(WidgetStyle.self, forKey: .style)
        density = try c.decode(WidgetDensity.self, forKey: .density)
        contentMode = try c.decodeIfPresent(WidgetContentMode.self, forKey: .contentMode) ?? .metrics
        if contentMode == .mixed { contentMode = .metrics }
        prefersAvailableMetrics = try c.decodeIfPresent(Bool.self, forKey: .prefersAvailableMetrics) ?? true
        sanitize()
    }

    mutating func sanitize() {
        let known = Set(MetricDefinition.catalog.map(\.id))
        var seen = Set<String>()
        metricIDs = metricIDs.filter { known.contains($0) && seen.insert($0).inserted }
        if !known.contains(primaryMetric) { primaryMetric = metricIDs.first ?? "bodyBattery" }
        if metricIDs.isEmpty { metricIDs = [primaryMetric] }
        if !metricIDs.contains(primaryMetric) { primaryMetric = metricIDs[0] }
    }
}

enum WidgetAppearance: String, CaseIterable, Codable, Identifiable {
    case colorful, light, dark
    var id: String { rawValue }
    var titleKey: String { "widget.appearance." + rawValue }
}

struct AppPreferences: Codable {
    var language: AppLanguage = .system
    var appearance: AppAppearance = .system
    var widgetAppearance: WidgetAppearance = .colorful
    var summaryMetrics: [String] = defaultSummaryMetrics
    var refreshMinutes = 15

    static let defaultSummaryMetrics = ["bodyBattery", "steps", "sleepDuration", "stress", "trainingReadiness", "restingHeartRate", "sleepScore", "intensityMinutes", "activeCalories", "recoveryTime", "hrv"]
    static func validatedSummaryMetrics(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        let known = ids.filter { MetricDefinition.isSupported($0) && seen.insert($0).inserted }
        return known.isEmpty ? defaultSummaryMetrics : known
    }

    var refreshInterval: TimeInterval { Double(min(1440, max(5, refreshMinutes))) * 60 }
    var staleInterval: TimeInterval { max(refreshInterval * 3, 3600) }

    init() {}
    enum CodingKeys: String, CodingKey { case language, widgetLanguage, appearance, widgetAppearance, summaryMetrics, refreshMinutes, profiles, widgetProfileIDs }
    private struct LegacyStyle: Decodable { var style: String? }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = (try? c.decode(AppLanguage.self, forKey: .widgetLanguage))
            ?? (try? c.decode(AppLanguage.self, forKey: .language)) ?? .system
        appearance = (try? c.decode(AppAppearance.self, forKey: .appearance)) ?? .system
        refreshMinutes = min(1440, max(5, (try? c.decode(Int.self, forKey: .refreshMinutes)) ?? 15))
        summaryMetrics = Self.validatedSummaryMetrics((try? c.decode([String].self, forKey: .summaryMetrics)) ?? Self.defaultSummaryMetrics)
        if let raw = try? c.decode(String.self, forKey: .widgetAppearance), let value = WidgetAppearance(rawValue: raw) {
            widgetAppearance = value
        } else if !c.contains(.widgetAppearance),
                  let previous = try? c.decode([LegacyStyle].self, forKey: .profiles), previous.first?.style == "monochrome" {
            widgetAppearance = appearance == .dark ? .dark : .light
        } else { widgetAppearance = .colorful }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(language, forKey: .language)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(widgetAppearance, forKey: .widgetAppearance)
        try c.encode(Self.validatedSummaryMetrics(summaryMetrics), forKey: .summaryMetrics)
        try c.encode(refreshMinutes, forKey: .refreshMinutes)
    }
    /// Old extension processes can briefly outlive an app update. This private
    /// snapshot-only projection keeps their four existing kinds configured.
    /// No profile or assignment is saved in the app's preferences anymore.
    func encodeWidgetSnapshot(to encoder: Encoder) throws {
        try encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        // The previous extension only understands system/en/ru. New readers use
        // widgetLanguage; old readers get an honest supported fallback.
        try c.encode(language, forKey: .widgetLanguage)
        try c.encode([AppLanguage.system, .en, .ru].contains(language) ? language : .en, forKey: .language)
        let slots: [WidgetSlot] = [.overview, .sport, .sleep, .training]
        let layouts = slots.map { $0.profile(in: self) }
        try c.encode(layouts, forKey: .profiles)
        try c.encode(Dictionary(uniqueKeysWithValues: zip(slots, layouts).map { ($0.0.rawValue, $0.1.id.uuidString) }), forKey: .widgetProfileIDs)
    }
}

enum MetricCategory: String, CaseIterable, Identifiable {
    case health, sleep, activity, training, body
    var id: String { rawValue }
    var titleKey: String { "category." + rawValue }
}

enum MetricUnit: Equatable { case number, score, percent, minutes, km, kg, ml, bpm, kcal, ms, breaths, vo2 }

/// Records remain meaningful with their date; progress values depend on recent sync.
enum MetricTimeScope { case progress, nightlyRecord, dailyRecord, measurement }

struct MetricDefinition: Identifiable {
    let id: String
    let symbol: String
    let unit: MetricUnit
    let category: MetricCategory
    var timeScope: MetricTimeScope {
        if category == .sleep || ["hrv", "respiration"].contains(id) { return .nightlyRecord }
        if ["restingHeartRate", "spo2", "trainingLoad", "stepGoal"].contains(id) { return .dailyRecord }
        if ["weight", "vo2Max"].contains(id) { return .measurement }
        return .progress
    }
    var isTimeSensitive: Bool { timeScope == .progress }
    static func isSupported(_ id: String) -> Bool { catalog.contains { $0.id == id } }
    var titleKey: String { "metric." + id }
    var widgetTitleKey: String {
        switch id {
        case "sleepDuration", "stress", "restingHeartRate", "trainingReadiness", "hrv", "respiration",
             "intensityMinutes", "activeCalories", "recoveryTime", "trainingLoad", "vo2Max", "calories", "spo2":
            return "metric.short." + id
        default: return titleKey
        }
    }

    static let catalog: [MetricDefinition] = [
        .init(id: "bodyBattery", symbol: "battery.75percent", unit: .score, category: .health),
        .init(id: "stress", symbol: "waveform.path.ecg", unit: .score, category: .health),
        .init(id: "restingHeartRate", symbol: "heart", unit: .bpm, category: .health),
        .init(id: "hrv", symbol: "waveform.path", unit: .ms, category: .health),
        .init(id: "spo2", symbol: "drop", unit: .percent, category: .health),
        .init(id: "respiration", symbol: "lungs", unit: .breaths, category: .health),
        .init(id: "sleepDuration", symbol: "moon.zzz", unit: .minutes, category: .sleep),
        .init(id: "sleepScore", symbol: "moon.stars", unit: .score, category: .sleep),
        .init(id: "deepSleep", symbol: "moon.fill", unit: .minutes, category: .sleep),
        .init(id: "remSleep", symbol: "sparkles", unit: .minutes, category: .sleep),
        .init(id: "lightSleep", symbol: "moon", unit: .minutes, category: .sleep),
        .init(id: "awakeSleep", symbol: "sunrise", unit: .minutes, category: .sleep),
        .init(id: "steps", symbol: "figure.walk", unit: .number, category: .activity),
        .init(id: "stepGoal", symbol: "target", unit: .number, category: .activity),
        .init(id: "distance", symbol: "point.topleft.down.to.point.bottomright.curvepath", unit: .km, category: .activity),
        .init(id: "calories", symbol: "flame", unit: .kcal, category: .activity),
        .init(id: "activeCalories", symbol: "flame.fill", unit: .kcal, category: .activity),
        .init(id: "floors", symbol: "figure.stairs", unit: .number, category: .activity),
        .init(id: "intensityMinutes", symbol: "timer", unit: .minutes, category: .activity),
        .init(id: "trainingReadiness", symbol: "figure.run", unit: .score, category: .training),
        .init(id: "recoveryTime", symbol: "arrow.clockwise.heart", unit: .minutes, category: .training),
        .init(id: "vo2Max", symbol: "wind", unit: .vo2, category: .training),
        .init(id: "trainingLoad", symbol: "chart.bar", unit: .number, category: .training),
        .init(id: "weight", symbol: "scalemass", unit: .kg, category: .body),
        .init(id: "hydration", symbol: "waterbottle", unit: .ml, category: .body)
    ]

    static func find(_ id: String) -> MetricDefinition { catalog.first { $0.id == id } ?? catalog[0] }
}

struct MetricReading: Codable, Equatable {
    var value: Double
    var measuredAt: Date?
}

/// A last known real reading, kept separately from the requested day's values.
struct RetainedMetricReading: Codable {
    var reading: MetricReading
    var sourceDate: String
    var retrievedAt: Date
    var changedAt: Date
}

struct GarminSnapshot: Codable {
    var fetchedAt: Date
    var sourceDate: String
    var devices: [String]
    var metrics: [String: MetricReading]
    var warnings: [String]
    var isDemo: Bool
    var groupUpdatedAt: [String: Date]
    var trainingTimeline: TrainingTimelineSnapshot?
    var retainedMetrics: [String: RetainedMetricReading] = [:]
    var metricChangedAt: [String: Date] = [:]
    var metricContext: GarminMetricContext? = nil
    var bodyBatteryProjection: BodyBatteryProjection?
    var bodyBatterySourceGroup: String?

    init(fetchedAt: Date, sourceDate: String, devices: [String], metrics: [String: MetricReading], warnings: [String] = [], isDemo: Bool = false, groupUpdatedAt: [String: Date] = [:], trainingTimeline: TrainingTimelineSnapshot? = nil) {
        self.fetchedAt = fetchedAt; self.sourceDate = sourceDate; self.devices = devices
        self.metrics = metrics; self.warnings = warnings; self.isDemo = isDemo
        self.groupUpdatedAt = groupUpdatedAt
        self.trainingTimeline = trainingTimeline
    }

    enum CodingKeys: String, CodingKey { case fetchedAt, sourceDate, devices, metrics, warnings, isDemo, groupUpdatedAt, trainingTimeline, retainedMetrics, metricChangedAt, metricContext, bodyBatteryProjection, bodyBatterySourceGroup }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
        sourceDate = try c.decode(String.self, forKey: .sourceDate)
        devices = try c.decodeIfPresent([String].self, forKey: .devices) ?? []
        metrics = try c.decode([String: MetricReading].self, forKey: .metrics)
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        isDemo = try c.decodeIfPresent(Bool.self, forKey: .isDemo) ?? false
        groupUpdatedAt = try c.decodeIfPresent([String: Date].self, forKey: .groupUpdatedAt) ?? [:]
        trainingTimeline = try c.decodeIfPresent(TrainingTimelineSnapshot.self, forKey: .trainingTimeline)
        retainedMetrics = try c.decodeIfPresent([String: RetainedMetricReading].self, forKey: .retainedMetrics) ?? [:]
        metricChangedAt = try c.decodeIfPresent([String: Date].self, forKey: .metricChangedAt) ?? [:]
        metricContext = try c.decodeIfPresent(GarminMetricContext.self, forKey: .metricContext)
        bodyBatteryProjection = try c.decodeIfPresent(BodyBatteryProjection.self, forKey: .bodyBatteryProjection)
        bodyBatterySourceGroup = try c.decodeIfPresent(String.self, forKey: .bodyBatterySourceGroup)
    }

    static var demo: GarminSnapshot {
        let values: [String: Double] = ["bodyBattery": 76, "stress": 24, "restingHeartRate": 54, "heartRate": 68,
            "hrv": 62, "spo2": 97, "respiration": 14, "sleepDuration": 462, "sleepScore": 86,
            "deepSleep": 92, "remSleep": 103, "lightSleep": 267, "awakeSleep": 12,
            "steps": 6842, "stepGoal": 10000, "distance": 5.21, "calories": 1840,
            "activeCalories": 420, "floors": 8, "intensityMinutes": 32,
            "trainingReadiness": 81, "recoveryTime": 1080, "vo2Max": 49, "trainingLoad": 512,
            "weight": 74.2, "hydration": 1750]
        return GarminSnapshot(fetchedAt: Date(), sourceDate: Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)),
            devices: ["Garmin fēnix 8"], metrics: values.mapValues { MetricReading(value: $0) }, isDemo: true)
    }

    static var empty: GarminSnapshot { .init(fetchedAt: .distantPast, sourceDate: "", devices: [], metrics: [:]) }
}

enum AppJSON {
    static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: string) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid timestamp") }
            return date
        }
        return d
    }
}

import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case system, ru, en
    var id: String { rawValue }
    var effectiveCode: String {
        self == .system ? (Locale.preferredLanguages.first?.hasPrefix("ru") == true ? "ru" : "en") : rawValue
    }
    var locale: Locale { self == .system ? .autoupdatingCurrent : Locale(identifier: self == .ru ? "ru_RU" : "en_US") }
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
    var includesTraining: Bool { self != .metrics }
    var includesMetrics: Bool { self != .training }
}

struct WidgetProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var metricIDs = ["bodyBattery", "sleepDuration", "steps", "stress", "restingHeartRate"]
    var primaryMetric = "bodyBattery"
    var style: WidgetStyle = .calm
    var density: WidgetDensity = .comfortable
    var contentMode: WidgetContentMode = .metrics

    init() {}
    enum CodingKeys: String, CodingKey { case id, name, metricIDs, primaryMetric, style, density, contentMode }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        metricIDs = try c.decode([String].self, forKey: .metricIDs)
        primaryMetric = try c.decode(String.self, forKey: .primaryMetric)
        style = try c.decode(WidgetStyle.self, forKey: .style)
        density = try c.decode(WidgetDensity.self, forKey: .density)
        contentMode = try c.decodeIfPresent(WidgetContentMode.self, forKey: .contentMode) ?? .metrics
    }
}

struct AppPreferences: Codable {
    var language: AppLanguage = .system
    var appearance: AppAppearance = .system
    var refreshMinutes = 15
    var menuMetric = "bodyBattery"
    var profiles = [WidgetProfile()]
    var widgetProfileIDs: [String: String] = [:]

    init() {}
    enum CodingKeys: String, CodingKey { case language, appearance, refreshMinutes, menuMetric, profiles, widgetProfileIDs }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        appearance = try c.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        refreshMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? 15
        menuMetric = try c.decodeIfPresent(String.self, forKey: .menuMetric) ?? "bodyBattery"
        profiles = try c.decodeIfPresent([WidgetProfile].self, forKey: .profiles) ?? [WidgetProfile()]
        widgetProfileIDs = try c.decodeIfPresent([String: String].self, forKey: .widgetProfileIDs) ?? [:]
    }
}

enum MetricCategory: String, CaseIterable, Identifiable {
    case health, sleep, activity, training, body
    var id: String { rawValue }
    var titleKey: String { "category." + rawValue }
}

enum MetricUnit: Equatable { case number, score, percent, minutes, km, kg, ml, bpm, kcal, ms, breaths, vo2 }

struct MetricDefinition: Identifiable {
    let id: String
    let symbol: String
    let unit: MetricUnit
    let category: MetricCategory
    var titleKey: String { "metric." + id }
    var widgetTitleKey: String {
        switch id {
        case "sleepDuration", "stress", "restingHeartRate", "trainingReadiness", "hrv", "respiration",
             "intensityMinutes", "activeCalories", "recoveryTime", "trainingLoad", "vo2Max", "calories":
            return "metric.short." + id
        default: return titleKey
        }
    }

    static let catalog: [MetricDefinition] = [
        .init(id: "bodyBattery", symbol: "battery.75percent", unit: .score, category: .health),
        .init(id: "stress", symbol: "waveform.path.ecg", unit: .score, category: .health),
        .init(id: "restingHeartRate", symbol: "heart", unit: .bpm, category: .health),
        .init(id: "heartRate", symbol: "heart.fill", unit: .bpm, category: .health),
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

struct MetricReading: Codable {
    var value: Double
    var measuredAt: Date?
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

    init(fetchedAt: Date, sourceDate: String, devices: [String], metrics: [String: MetricReading], warnings: [String] = [], isDemo: Bool = false, groupUpdatedAt: [String: Date] = [:], trainingTimeline: TrainingTimelineSnapshot? = nil) {
        self.fetchedAt = fetchedAt; self.sourceDate = sourceDate; self.devices = devices
        self.metrics = metrics; self.warnings = warnings; self.isDemo = isDemo
        self.groupUpdatedAt = groupUpdatedAt
        self.trainingTimeline = trainingTimeline
    }

    enum CodingKeys: String, CodingKey { case fetchedAt, sourceDate, devices, metrics, warnings, isDemo, groupUpdatedAt, trainingTimeline }
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

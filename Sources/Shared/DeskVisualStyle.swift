import SwiftUI

/// Semantic colors identify the kind of measurement; they never imply a health grade.
struct DeskMetricTheme {
    let top: Color
    let bottom: Color
    let highlight: Color
    let ink: Color
    let monochrome: Bool

    static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255)
    }

    static func metric(_ id: String, style: WidgetStyle = .calm) -> DeskMetricTheme {
        if style == .monochrome {
            return .init(top: Color(nsColor: .controlBackgroundColor), bottom: Color(nsColor: .windowBackgroundColor),
                         highlight: .primary, ink: .primary, monochrome: true)
        }
        let definition = MetricDefinition.find(id)
        let colors: (UInt32, UInt32, UInt32)
        if style == .sport {
            colors = (0xAD491D, 0x71351F, 0xFFE0A6)
        } else if definition.category == .sleep || ["hrv", "respiration"].contains(id) {
            colors = (0x403477, 0x202545, 0xD3C7FF)
        } else if definition.category == .activity {
            colors = (0xAD491D, 0x71351F, 0xFFE0A6)
        } else if ["restingHeartRate", "spo2", "stress"].contains(id) {
            colors = (0x305C78, 0x203B56, 0xA7DEF4)
        } else {
            colors = (0x11665C, 0x153F46, 0xD4F29B)
        }
        return .init(top: color(colors.0), bottom: color(colors.1), highlight: color(colors.2), ink: .white, monochrome: false)
    }

    static func calendar(style: WidgetStyle = .calm) -> DeskMetricTheme {
        if style == .monochrome { return metric("bodyBattery", style: .monochrome) }
        return .init(top: color(0x27699A), bottom: color(0x173758), highlight: color(0xB4E4FF),
                     ink: .white, monochrome: false)
    }

    static func metric(_ id: String, appearance: WidgetAppearance) -> DeskMetricTheme {
        let style: WidgetStyle = MetricDefinition.find(id).category == .training ? .sport : .calm
        return applying(appearance, to: metric(id, style: style))
    }
    static func calendar(appearance: WidgetAppearance) -> DeskMetricTheme {
        applying(appearance, to: calendar())
    }
    static func summary(appearance: WidgetAppearance) -> DeskMetricTheme {
        applying(appearance, to: .init(top: color(0x184E53), bottom: color(0x182F45),
            highlight: color(0xAFE3DA), ink: .white, monochrome: false))
    }
    private static func applying(_ appearance: WidgetAppearance, to semantic: DeskMetricTheme) -> DeskMetricTheme {
        switch appearance {
        case .colorful: return semantic
        case .light:
            return .init(top: color(0xFFFFFF), bottom: color(0xECF1F5), highlight: semantic.top,
                         ink: color(0x172D3A), monochrome: false)
        case .dark:
            return .init(top: color(0x242D38), bottom: color(0x101720), highlight: semantic.highlight,
                         ink: color(0xF3F6FB), monochrome: false)
        }
    }

    var background: LinearGradient {
        LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var secondaryInk: Color { ink.opacity(0.76) }
}

/// Units stay subordinate to the number, including localized sleep durations.
struct MetricValueLabel: View {
    let value: String
    let size: CGFloat
    var weight: Font.Weight = .semibold

    private var composed: Text {
        value.replacingOccurrences(of: "%", with: " %").split(separator: " ", omittingEmptySubsequences: false)
            .enumerated().reduce(Text("")) { result, element in
                let unit = element.element.contains { $0.isLetter || $0 == "%" }
                return result + Text((element.offset == 0 ? "" : " ") + String(element.element))
                    .font(.system(size: unit ? size * 0.43 : size, weight: unit ? .medium : weight, design: .rounded))
            }
    }
    var body: some View {
        composed.monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
            .accessibilityLabel(value)
    }
}

struct DeskButtonStyle: ButtonStyle {
    var prominent = false
    var onDark = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .foregroundStyle(onDark ? DeskMetricTheme.color(0x153F46) : (prominent ? Color.white : Color.primary))
            .background(onDark ? Color.white : (prominent ? DeskMetricTheme.color(0x11665C) : Color.primary.opacity(0.055)), in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

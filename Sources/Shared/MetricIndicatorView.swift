import SwiftUI

/// A position on a labeled scale, rather than a completion ring that implies
/// every metric should increase. Text carries the meaning without color.
struct MetricIndicatorView: View {
    let indicator: MetricIndicator
    let theme: DeskMetricTheme
    var compact = false
    var showsReference = true

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 3) {
            if let scale = indicator.scale {
                MetricScaleView(scale: scale, theme: theme, compact: compact)
                    .padding(.vertical, compact ? 0 : 1)
            }
            Text(indicator.status)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.ink)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if showsReference, let reference = indicator.reference, reference != indicator.status {
                Text(reference)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One short assessment; supporting widget values do not repeat the hero gauge
/// or the generic explanations already available through help and VoiceOver.
struct WidgetMetricCaption: View {
    let id: String
    let formatter: MetricFormatter
    let theme: DeskMetricTheme
    var primaryID: String? = nil

    var body: some View {
        if let indicator = formatter.indicator(id), indicator.scale != nil,
           primaryID.flatMap({ formatter.indicator($0)?.status }) != indicator.status {
            Text(indicator.status)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.secondaryInk)
                .lineLimit(1)
        }
    }
}

struct MetricScaleView: View {
    let scale: MetricScale
    let theme: DeskMetricTheme
    var compact = false
    @Environment(\.colorScheme) private var colorScheme

    private func color(_ tone: MetricTone) -> Color {
        let light = theme.lightBackground || (theme.monochrome && colorScheme == .light)
        switch tone {
        case .neutral: return theme.highlight
        case .positive: return DeskMetricTheme.color(light ? 0x19754C : 0x91DDB0)
        case .caution: return DeskMetricTheme.color(light ? 0x976000 : 0xF4CB78)
        case .negative: return DeskMetricTheme.color(light ? 0xB73548 : 0xFF96A5)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width)
            let markerSize: CGFloat = compact ? 6 : 8
            let trackWidth = max(0, width - markerSize)
            ZStack(alignment: .leading) {
                ForEach(Array(scale.bands.enumerated()), id: \.offset) { index, band in
                    let start = scale.bands.prefix(index).reduce(0) { $0 + $1.fraction }
                    let leadingGap: CGFloat = index == 0 ? 0 : 1
                    let trailingGap: CGFloat = index == scale.bands.count - 1 ? 0 : 1
                    Capsule().fill(color(band.tone).opacity(0.85))
                        .frame(width: max(0, trackWidth * band.fraction - leadingGap - trailingGap), height: compact ? 3 : 4)
                        .offset(x: markerSize / 2 + trackWidth * start + leadingGap)
                }
                Circle().fill(theme.ink)
                    .overlay(Circle().strokeBorder(theme.bottom, lineWidth: 1.5))
                    .frame(width: markerSize, height: markerSize)
                    .offset(x: trackWidth * scale.position)
            }
            .frame(width: width, height: markerSize, alignment: .leading)
        }
        .frame(height: compact ? 6 : 8)
        .accessibilityHidden(true)
    }
}

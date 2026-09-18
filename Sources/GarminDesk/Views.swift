import SwiftUI
import WidgetKit

private struct Surface: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.06)))
    }
}

private struct DataStatusView: View {
    @ObservedObject var store: AppStore
    var compact = false
    var metricIDs: [String]? = nil
    var connectionOnly = false

    private var statusSnapshot: GarminSnapshot {
        var snapshot = store.snapshot
        if let metricIDs {
            let ids = Set(metricIDs)
            snapshot.metrics = snapshot.metrics.filter { ids.contains($0.key) }
            snapshot.retainedMetrics = snapshot.retainedMetrics.filter { ids.contains($0.key) }
            snapshot.metricChangedAt = snapshot.metricChangedAt.filter { ids.contains($0.key) }
        }
        return snapshot
    }
    private var isStale: Bool {
        Set(statusSnapshot.metrics.keys).union(statusSnapshot.retainedMetrics.keys).contains { store.metricIsStale($0) }
    }

    private var statusKey: String {
        if store.isSyncing { return store.hasSession ? "data.syncing" : "status.connecting" }
        if store.needsWebSignIn { return "status.signInRequired" }
        if ["error.network", "error.timeout", "error.protocol", "error.partial", "error.rate_limit"].contains(store.lastErrorKey ?? "") { return "data.checkFailed" }
        if connectionOnly { return store.hasSession ? "status.connected" : "status.notConnected" }
        if store.hasSession && !statusSnapshot.hasMeasurements { return "data.waiting" }
        if store.hasSession && statusSnapshot.hasRetainedTimeSensitiveMetrics { return "data.waitingNew" }
        if isStale { return "widget.notice.waiting" }
        if store.hasSession && statusSnapshot.hasUnchangedMeasurements { return "data.unchanged" }
        return store.hasSession ? "data.available" : "status.notConnected"
    }

    private var statusSymbol: String {
        if store.needsWebSignIn { return "person.crop.circle.badge.exclamationmark" }
        if ["error.network", "error.timeout", "error.protocol", "error.partial", "error.rate_limit"].contains(store.lastErrorKey ?? "") { return "exclamationmark.triangle" }
        if connectionOnly { return store.hasSession ? "link" : "link.badge.plus" }
        if !statusSnapshot.hasMeasurements { return "clock" }
        if !store.hasSession { return "link.badge.plus" }
        return isStale ? "clock.badge.exclamationmark" : "checkmark.circle.fill"
    }

    private var hint: String? {
        if store.isSyncing { return nil }
        if let error = store.lastErrorKey { return store.text(error) }
        if store.needsWebSignIn { return store.text("connection.reconnectDetail") }
        if connectionOnly { return nil }
        guard store.hasSession else { return nil }
        if !statusSnapshot.warnings.isEmpty { return store.text("data.partial") }
        if !statusSnapshot.hasMeasurements { return store.text("data.waitingHint") }
        if statusSnapshot.hasRetainedTimeSensitiveMetrics {
            return store.text(statusSnapshot.metrics.isEmpty ? "data.retainedAllHint" : "data.retainedHint")
        }
        if statusSnapshot.hasUnchangedMeasurements { return store.text("data.unchangedHint") }
        return isStale ? store.text("data.stale") : nil
    }

    private var needsAttention: Bool { store.lastErrorKey != nil || store.needsWebSignIn }

    var body: some View {
        if compact {
            Label(store.text(store.needsWebSignIn ? "status.signInRequired" : (store.hasSession ? "status.connected" : "status.notConnected")),
                  systemImage: store.needsWebSignIn ? "person.crop.circle.badge.exclamationmark" : "link")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if needsAttention || store.isSyncing || (!connectionOnly && (!statusSnapshot.hasMeasurements || statusSnapshot.hasRetainedTimeSensitiveMetrics || isStale || !statusSnapshot.warnings.isEmpty)) {
            HStack(alignment: .top, spacing: 10) {
                if store.isSyncing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: statusSymbol).font(.system(size: 13))
                        .foregroundStyle(needsAttention ? Color.orange : .secondary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.text(statusKey)).font(.system(size: 12, weight: .semibold))
                    if needsAttention || !statusSnapshot.hasMeasurements, let hint {
                        Text(hint).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(needsAttention ? Color.orange.opacity(0.07) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .combine)
        }
    }
}

private struct NextSyncView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        if !store.isSyncing, let next = store.nextSyncAt, next > Date() {
            Label(store.text(store.hasSession ? "connection.nextSync" : "connection.retryAfter") + " " + formatted(next),
                  systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = store.preferences.language.locale
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct ErrorNotice: View {
    @ObservedObject var store: AppStore

    var body: some View {
        if let error = store.lastErrorKey {
            VStack(alignment: .leading, spacing: 10) {
                Label(store.text(error), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if let diagnostic = store.connectionDiagnostic,
                   ["error.auth", "error.rate_limit", "error.network", "error.access_denied", "error.security_challenge", "error.session_unsupported"].contains(error) {
                    DisclosureGroup(store.text("diagnostic.title")) {
                        VStack(alignment: .leading, spacing: 5) {
                            if let stage = diagnostic.stage { Text(store.text("diagnostic.stage") + ": " + stage) }
                            if let status = diagnostic.httpStatus { Text("HTTP: \(status)") }
                            if let status = diagnostic.apiErrorStatus { Text(store.text("diagnostic.apiCode") + ": \(status)") }
                            if let count = diagnostic.requestCount { Text(store.text("diagnostic.requests") + ": \(count)") }
                            if let seconds = diagnostic.retryAfterSeconds { Text("Retry-After: \(seconds) s") }
                        }.font(.caption.monospaced()).textSelection(.enabled).padding(.top, 6)
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct MainMetricView: View {
    @ObservedObject var store: AppStore
    var metricID: String
    var style: WidgetStyle
    var compact = false
    private var definition: MetricDefinition { MetricDefinition.find(metricID) }
    private var theme: DeskMetricTheme { .metric(metricID, style: style) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(at: context.date)
        }
    }

    private func content(at now: Date) -> some View {
        let formatter = MetricFormatter(snapshot: store.snapshot, language: store.preferences.language, now: now)
        let explanation = MetricExplanation.make(metricID: metricID, snapshot: store.snapshot,
                                                   language: store.preferences.language, now: now)
        return HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 8) {
                    Label(store.text(definition.titleKey), systemImage: definition.symbol)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(theme.secondaryInk)
                        .lineLimit(2)
                    if let explanation {
                        MetricInfoButton(explanation: explanation, title: store.text(definition.titleKey),
                                         language: store.preferences.language)
                            .foregroundStyle(theme.secondaryInk)
                    }
                }
                MetricValueLabel(value: formatter.display(metricID), size: compact ? 50 : 60)
                    .foregroundStyle(theme.ink)
                    .contentTransition(.numericText())
                if let explanation {
                    Text(explanation.status).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.ink).fixedSize(horizontal: false, vertical: true)
                    if let supporting = explanation.supportingText {
                        Text(supporting).font(.system(size: 11)).foregroundStyle(theme.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let context = formatter.context(metricID) {
                    Text(context).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.secondaryInk)
                } else if formatter.value(metricID) == nil {
                    Text(store.text("data.empty")).font(.caption).foregroundStyle(theme.secondaryInk)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                if let progress = formatter.progress(metricID) {
                    Circle().strokeBorder(theme.ink.opacity(0.13), lineWidth: 7)
                    Circle().trim(from: 0, to: progress)
                        .stroke(theme.highlight, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(3.5)
                    Image(systemName: definition.symbol).font(.system(size: 26, weight: .light)).foregroundStyle(theme.highlight)
                } else {
                    Circle().fill(theme.ink.opacity(0.07))
                    Image(systemName: definition.symbol).font(.system(size: 36, weight: .light)).foregroundStyle(theme.highlight)
                }
            }
            .frame(width: compact ? 76 : 88, height: compact ? 76 : 88)
            .accessibilityHidden(true)
        }
        .padding(compact ? 22 : 28)
        .frame(maxWidth: .infinity, minHeight: compact ? 154 : 176, alignment: .leading)
        .background(theme.background, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(theme.ink.opacity(0.10)))
        .accessibilityElement(children: .contain)
    }
}

private struct SmallMetricView: View {
    @ObservedObject var store: AppStore
    var metricID: String
    var style: WidgetStyle
    var compact = false
    @Environment(\.colorScheme) private var colorScheme
    private var definition: MetricDefinition { MetricDefinition.find(metricID) }
    private var theme: DeskMetricTheme { .metric(metricID, style: style) }
    private var accent: Color { colorScheme == .dark ? theme.highlight : theme.top }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(at: context.date)
        }
    }

    private func content(at now: Date) -> some View {
        let formatter = MetricFormatter(snapshot: store.snapshot, language: store.preferences.language, now: now)
        let explanation = MetricExplanation.make(metricID: metricID, snapshot: store.snapshot,
                                                   language: store.preferences.language, now: now)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: definition.symbol).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(accent).frame(width: 28, height: 28)
                    .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                Text(store.text(definition.titleKey)).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if let explanation {
                    MetricInfoButton(explanation: explanation, title: store.text(definition.titleKey),
                                     language: store.preferences.language).foregroundStyle(.secondary)
                }
            }
            MetricValueLabel(value: formatter.display(metricID), size: compact ? 28 : 32)
                .foregroundStyle(.primary)
            if let explanation {
                Text(explanation.status).font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
                    .fixedSize(horizontal: false, vertical: true)
                if let supporting = explanation.supportingText {
                    Text(supporting).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let context = formatter.context(metricID) {
                Text(context).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 82 : 100, alignment: .leading)
        .padding(compact ? 16 : 18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(accent.opacity(0.10)))
        .accessibilityElement(children: .contain)
    }
}

private struct MetricInfoButton: View {
    let explanation: MetricExplanation
    let title: String
    let language: AppLanguage
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 13))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(MetricExplanation.helpLabel(language: language))
        .accessibilityLabel(title + ": " + MetricExplanation.helpLabel(language: language))
        .popover(isPresented: $isPresented) {
            MetricExplanationPanel(explanation: explanation, title: title, language: language)
        }
    }
}

/// Shared by the actual popover and its synthetic visual fixture.
struct MetricExplanationPanel: View {
    let explanation: MetricExplanation
    let title: String
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(explanation.status).font(.subheadline.weight(.semibold))
            if let supporting = explanation.supportingText {
                Text(supporting).font(.callout).foregroundStyle(.secondary)
            }
            Text(explanation.detail).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let url = explanation.sourceURL {
                Link(MetricExplanation.sourceLabel(language: language), destination: url).font(.callout)
            }
        }
        .textSelection(.enabled).padding(20).frame(width: 360)
        .foregroundStyle(.primary)
        .environment(\.locale, language.locale)
    }
}

struct DashboardView: View {
    @ObservedObject var store: AppStore
    @Binding var widgetSlot: WidgetSlot?
    var onSettings: () -> Void
    var onConnection: () -> Void
    @State private var showWidgetHelp = false

    private var slot: WidgetSlot { widgetSlot ?? .overview }
    private var profile: WidgetProfile { slot.profile(in: store.preferences) }
    private var selectedMetrics: [String] {
        guard profile.contentMode.includesMetrics else { return [] }
        let selection = slot == .overview
            ? WidgetMetricPolicy.summarySelection(preferences: store.preferences, snapshot: store.snapshot)
            : WidgetMetricPolicy.selection(for: profile, snapshot: store.snapshot)
        return ([selection.primary] + selection.secondary).filter { store.numericValue($0) != nil }
    }
    private var slotSelection: Binding<WidgetSlot> {
        Binding(get: { slot }, set: { widgetSlot = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.text(slot.titleKey))
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                    Text(store.snapshot.devices.count == 1 ? store.snapshot.devices[0] : "Garmin Connect")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                if store.hasSession || store.snapshot.hasMeasurements {
                    Button(action: onSettings) {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(DeskButtonStyle()).help(store.text("dashboard.configure"))
                    .accessibilityLabel(store.text("dashboard.configure"))
                    Button { store.sync() } label: {
                        Label(store.text("action.sync"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(DeskButtonStyle(prominent: true))
                    .help(store.snapshot.hasMeasurements ? store.updatedText : store.text("action.sync"))
                    .disabled(store.isSyncing || !store.hasSession)
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
            .padding(28)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker(store.text("widget.type"), selection: slotSelection) {
                        ForEach(WidgetSlot.allCases) { type in
                            Text(store.text(type.titleKey)).tag(type)
                        }
                    }
                    .pickerStyle(.menu).frame(maxWidth: 400, alignment: .leading)
                    if store.hasSession || store.snapshot.hasMeasurements || store.isSyncing || store.lastErrorKey != nil || store.needsWebSignIn {
                        DataStatusView(store: store, metricIDs: profile.contentMode.includesMetrics ? selectedMetrics : nil,
                                       connectionOnly: profile.contentMode.includesTraining)
                    }
                    if !store.hasSession && store.snapshot.hasMeasurements {
                        Button {
                            if store.needsWebSignIn { store.connectGarmin() }
                            else { onConnection() }
                        } label: {
                            Label(store.text(store.needsWebSignIn ? "connection.reconnect" : "dashboard.connect"), systemImage: "link")
                        }
                        .buttonStyle(.borderedProminent).disabled(store.isSyncing)
                    }
                    if !store.hasSession && !store.snapshot.hasMeasurements {
                        VStack(alignment: .leading, spacing: 22) {
                            Image(systemName: "applewatch")
                                .font(.system(size: 30, weight: .light))
                                .foregroundStyle(DeskMetricTheme.metric("bodyBattery").highlight)
                                .frame(width: 64, height: 64)
                                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 10) {
                                Text(store.text("onboarding.title"))
                                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(store.text("onboarding.detail")).font(.system(size: 14))
                                    .foregroundStyle(Color.white.opacity(0.76)).lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Button { store.connectGarmin() } label: {
                                Label(store.text("dashboard.connect"), systemImage: "link")
                                    .padding(.horizontal, 8)
                            }.buttonStyle(DeskButtonStyle(onDark: true)).disabled(store.isSyncing)

                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(28)
                        .foregroundStyle(.white)
                        .background(DeskMetricTheme.metric("bodyBattery").background, in: RoundedRectangle(cornerRadius: 24))
                    }
                    if store.hasSession || store.snapshot.hasMeasurements {
                        if profile.contentMode.includesMetrics {
                            if let primary = selectedMetrics.first {
                                MainMetricView(store: store, metricID: primary, style: profile.style,
                                               compact: profile.density == .compact)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 12, alignment: .leading)], spacing: 12) {
                                    ForEach(Array(selectedMetrics.dropFirst()), id: \.self) { id in
                                        SmallMetricView(store: store, metricID: id, style: profile.style,
                                                        compact: profile.density == .compact)
                                    }
                                }
                            } else if store.hasSession && store.snapshot.hasMeasurements {
                                Label(store.text("data.empty"), systemImage: "clock")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        if slot.includesTraining {
                            TrainingTimelineView(snapshot: store.trainingTimeline, language: store.preferences.language,
                                                 compact: profile.density == .compact)
                        }
                        Button { showWidgetHelp = true } label: {
                            Label(store.text("widget.setup"), systemImage: "rectangle.3.group")
                        }
                        .buttonStyle(.borderless).font(.callout).foregroundStyle(.secondary)
                    }
                    WidgetSharingNotice(store: store)
                }
                .frame(maxWidth: 1060, alignment: .leading)
                .padding(.horizontal, 28).padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $showWidgetHelp) {
            VStack(alignment: .leading, spacing: 20) {
                ScrollView { NativeWidgetGuide(store: store) }
                    .frame(maxHeight: 460)
                HStack {
                    Button(store.text("widget.customize")) {
                        showWidgetHelp = false
                        onSettings()
                    }
                    Spacer()
                    Button(store.text("action.done")) { showWidgetHelp = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24).frame(width: 460)
        }
    }
}

private struct WidgetSharingNotice: View {
    @ObservedObject var store: AppStore

    var body: some View {
        if !store.widgetSharingAvailable && (store.hasSession || store.snapshot.hasMeasurements) {
            Label(store.text(WidgetDataStore.configurationAvailable ? "widget.sharingDataUnavailable" : "widget.sharingUnavailable"), systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct NativeWidgetGuide: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(store.text("widget.setup"), systemImage: "rectangle.3.group").font(.headline)
            WidgetSharingNotice(store: store)
            if WidgetDataStore.configurationAvailable {
                guideStep("1", key: "widget.guide.add")
                guideStep("2", key: "widget.guide.fixedTypes")
                Text(store.text("widget.guide.refresh")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(store.text("widget.guide.unavailable")).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func guideStep(_ number: String, key: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.caption.bold())
                .frame(width: 22, height: 22)
                .background(.primary.opacity(0.065), in: Circle())
                .accessibilityHidden(true)
            Text(store.text(key)).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum MainWindowSection: String, CaseIterable, Identifiable {
    case dashboard, widgets, connection, general
    var id: String { rawValue }
    var key: String { self == .dashboard ? "dashboard.title" : "settings.\(rawValue)" }
    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .widgets: return "rectangle.3.group"
        case .connection: return "person.crop.circle"
        case .general: return "gearshape"
        }
    }
    var shortcut: KeyEquivalent {
        switch self { case .dashboard: return "1"; case .widgets: return "2"; case .connection: return "3"; case .general: return "4" }
    }
}

@MainActor
final class MainWindowNavigation: ObservableObject {
    @Published var section: MainWindowSection? = .dashboard
    @Published var widgetSlot: WidgetSlot? = .overview
    @Published var summaryMeasurementsExpanded = false
}

private enum WidgetPreviewSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var titleKey: String { "profile.preview." + rawValue }
    // These match the native widget render fixtures, in layout points.
    var dimensions: CGSize {
        switch self {
        case .small: return CGSize(width: 170, height: 170)
        case .medium: return CGSize(width: 360, height: 170)
        case .large: return CGSize(width: 360, height: 376)
        }
    }
    var family: WidgetFamily {
        switch self { case .small: return .systemSmall; case .medium: return .systemMedium; case .large: return .systemLarge }
    }

}

/// Uses the same metric and calendar rendering as the desktop widget.
private struct FixedWidgetPreview: View {
    @ObservedObject var store: AppStore
    let slot: WidgetSlot
    let size: WidgetPreviewSize

    var body: some View {
        let date = Date()
        let usesDemo = slot == .training
            ? store.snapshot.trainingTimeline == nil
            : !store.snapshot.hasMeasurements
        let data = usesDemo
            ? WidgetPreviewData.make(preferences: store.preferences, at: date)
            : WidgetData(preferences: store.preferences, snapshot: store.snapshot, isConnected: store.hasSession)
        let widget = GarminWidgetView(entry: GarminEntry(date: date, data: data,
            profileID: nil, slot: slot, isGalleryPreview: usesDemo), previewFamily: size.family)
        widget.padding(16)
            .frame(width: size.dimensions.width, height: size.dimensions.height)
            .background(widget.background)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.primary.opacity(0.08)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(store.text("profile.preview") + ": " + store.text(size.titleKey))
    }
}

struct MainWindowView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var navigation: MainWindowNavigation
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Label {
                    Text("Garmin Desk")
                } icon: {
                    GarminDeskBrandMark().foregroundStyle(DeskMetricTheme.color(0x168575)).frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                }
                    .font(.headline).padding(20)
                VStack(spacing: 6) {
                    ForEach(MainWindowSection.allCases) { item in
                        let selected = (navigation.section ?? .dashboard) == item
                        Button {
                            if item == .dashboard { navigation.widgetSlot = nil }
                            navigation.section = item
                        } label: {
                            Label(store.text(item.key), systemImage: item.symbol)
                                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.7))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 11)
                                .background(selected ? DeskMetricTheme.color(0x11665C) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(item.shortcut, modifiers: .command)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }.padding(.horizontal, 12).padding(.top, 12)
                Spacer(minLength: 0)
                DataStatusView(store: store, compact: true).padding(18)
            }
            .frame(width: 190).background(.bar)
            Divider()
            Group {
                switch navigation.section ?? .dashboard {
                case .dashboard:
                    DashboardView(store: store, widgetSlot: $navigation.widgetSlot,
                                  onSettings: { navigation.section = .widgets },
                                  onConnection: { navigation.section = .connection })
                case .widgets: WidgetsPane(store: store, selectedSlot: $navigation.widgetSlot,
                                           summaryExpanded: $navigation.summaryMeasurementsExpanded)
                case .connection: ConnectionPane(store: store)
                case .general: GeneralPane(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, minHeight: 620)
        .background(colorScheme == .dark ? DeskMetricTheme.color(0x13191F) : DeskMetricTheme.color(0xF3F5F4))
        .environment(\.locale, store.preferences.language.locale)
    }

}

private struct WidgetsPane: View {
    @ObservedObject var store: AppStore
    @Binding var selectedSlot: WidgetSlot?
    @Binding var summaryExpanded: Bool
    @State private var previewSize: WidgetPreviewSize = .medium
    private var slot: WidgetSlot { selectedSlot ?? .overview }
    private var slotSelection: Binding<WidgetSlot> {
        Binding(get: { slot }, set: { selectedSlot = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(store.text("settings.widgets")).font(.title2.bold())
                Text(store.text("settings.widgetsSubtitle")).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    controlLabel("widget.type")
                    Picker(store.text("widget.type"), selection: slotSelection) {
                        ForEach(WidgetSlot.allCases) { type in
                            Label(store.text(type.titleKey), systemImage: type.symbol).tag(type)
                        }
                    }.pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    controlLabel("profile.previewSize")
                    Picker(store.text("profile.previewSize"), selection: $previewSize) {
                        ForEach(WidgetPreviewSize.allCases) { size in
                            Text(store.text(size.titleKey)).tag(size)
                        }
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    controlLabel("widget.appearance")
                    Picker(store.text("widget.appearance"), selection: $store.preferences.widgetAppearance) {
                        Text(store.text("widget.appearance.colorful")).tag(WidgetAppearance.colorful)
                        Text(store.text("widget.appearance.light")).tag(WidgetAppearance.light)
                        Text(store.text("widget.appearance.dark")).tag(WidgetAppearance.dark)
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity)
                }
                Text(store.text("widget.appearanceHint")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .modifier(Surface())
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    FixedWidgetPreview(store: store, slot: slot, size: previewSize)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    if slot == .overview {
                        DisclosureGroup(store.text("widget.summary.choose"), isExpanded: $summaryExpanded) {
                            SummaryMeasurements(store: store).padding(.top, 12)
                        }.modifier(Surface())
                    }
                    Text(store.text(slot.descriptionKey)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if slot != .overview {
                        Text(store.text("widget.automaticHint")).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    DisclosureGroup(store.text("widget.setup")) {
                        NativeWidgetGuide(store: store).padding(.top, 12)
                    }.modifier(Surface())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(24)
    }

    private func controlLabel(_ key: String) -> some View {
        Text(store.text(key)).font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 145, alignment: .leading)
    }
}

private struct SummaryMeasurements: View {
    @ObservedObject var store: AppStore

    private var metrics: [MetricDefinition] {
        store.preferences.summaryMetrics.map(MetricDefinition.find)
            + MetricDefinition.catalog.filter { !store.preferences.summaryMetrics.contains($0.id) }
    }

    private var primary: Binding<String> {
        Binding(get: { store.preferences.summaryMetrics.first ?? "bodyBattery" }, set: { id in
            guard store.preferences.summaryMetrics.contains(id) else { return }
            store.preferences.summaryMetrics = [id] + store.preferences.summaryMetrics.filter { $0 != id }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(store.text("widget.summary.hint")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(store.text("widget.summary.primary")).font(.callout)
                Picker(store.text("widget.summary.primary"), selection: primary) {
                    ForEach(store.preferences.summaryMetrics, id: \.self) { id in
                        Text(store.text(MetricDefinition.find(id).titleKey)).tag(id)
                    }
                }
                .pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 12) {
                ForEach(metrics) { metric in
                    Toggle(isOn: selection(metric.id)) {
                        Text(store.text(metric.titleKey)).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(store.preferences.summaryMetrics.count == 1 && store.preferences.summaryMetrics.contains(metric.id))
                }
            }
            Text(store.text("widget.summary.minimum")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func selection(_ id: String) -> Binding<Bool> {
        Binding(get: { store.preferences.summaryMetrics.contains(id) }, set: { selected in
            var metrics = store.preferences.summaryMetrics
            if selected {
                if !metrics.contains(id) { metrics.insert(id, at: min(1, metrics.count)) }
            } else if metrics.count > 1 {
                metrics.removeAll { $0 == id }
            }
            store.preferences.summaryMetrics = metrics
        })
    }
}

private struct ConnectionPane: View {
    @ObservedObject var store: AppStore
    @State private var confirmDisconnect = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.text("connection.title")).font(.title2.bold())
                    Text(store.text("connection.webSubtitle")).foregroundStyle(.secondary)
                }
                ErrorNotice(store: store)
                VStack(alignment: .leading, spacing: 16) {
                    if store.hasSession || store.needsWebSignIn {
                        DataStatusView(store: store, compact: true)
                    }
                    if store.needsWebSignIn {
                        Text(store.text("connection.reconnectDetail")).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { store.connectGarmin() } label: {
                            Label(store.text("connection.reconnect"), systemImage: "person.crop.circle.badge.checkmark")
                        }.buttonStyle(.borderedProminent).controlSize(.large).disabled(store.isSyncing)
                    } else if store.hasSession {
                        Text(store.text("connection.automaticHint")).font(.callout).foregroundStyle(.secondary)
                        Button { store.sync() } label: { Label(store.text("action.sync"), systemImage: "arrow.clockwise") }
                            .disabled(store.isSyncing)
                    } else {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 36)).foregroundStyle(.tint)
                        Text(store.text("connection.webIntro")).font(.headline)
                        Text(store.text("connection.webDetail")).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { store.connectGarmin() } label: {
                            Text(store.text("connection.webSignIn")).frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).controlSize(.large).disabled(store.isSyncing)
                        if store.isSyncing {
                            HStack { ProgressView().controlSize(.small); Text(store.text("status.connecting")) }
                        }
                    }
                    if store.isSyncing && !store.hasSession {
                        Button(store.text("connection.cancelLogin")) { store.cancelLogin() }
                    }
                    NextSyncView(store: store)
                    if store.hasSession || store.needsWebSignIn {
                        Divider()
                        Button(store.text("connection.disconnect"), role: .destructive) { confirmDisconnect = true }
                    }
                }.modifier(Surface())
                VStack(alignment: .leading, spacing: 10) {
                    Label(store.text("connection.localTitle"), systemImage: "lock.shield").font(.headline)
                    Text(store.text("connection.webPrivacy")).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(store.text("connection.syncHint")).font(.caption).foregroundStyle(.secondary)
                }.modifier(Surface())
            }.padding(28)
        }
        .confirmationDialog(store.text("connection.disconnectTitle"), isPresented: $confirmDisconnect) {
            Button(store.text("connection.disconnect"), role: .destructive) { store.disconnect() }
            Button(store.text("action.cancel"), role: .cancel) {}
        } message: { Text(store.text("connection.disconnectMessage")) }
    }
}

private struct GeneralPane: View {
    @ObservedObject var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.text("settings.general")).font(.title2.bold())
                    Text(store.text("settings.generalSubtitle")).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 18) {
                    Toggle(store.text("general.launchAtLogin"), isOn: Binding(
                        get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }
                    ))
                    Text(store.text("general.backgroundHint")).font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Picker(store.text("general.language"), selection: $store.preferences.language) {
                        Text(store.text("general.system")).tag(AppLanguage.system)
                        ForEach(AppLanguage.supported) { language in
                            Text(language.nativeName).tag(language)
                        }
                    }
                    Picker(store.text("general.appearance"), selection: $store.preferences.appearance) {
                        Text(store.text("general.system")).tag(AppAppearance.system)
                        Text(store.text("general.light")).tag(AppAppearance.light)
                        Text(store.text("general.dark")).tag(AppAppearance.dark)
                    }
                }
                .modifier(Surface())
                ErrorNotice(store: store)
                VStack(alignment: .leading, spacing: 12) {
                    Picker(store.text("general.refresh"), selection: $store.preferences.refreshMinutes) {
                        ForEach(Array(Set([5, 15, 30, 60, store.preferences.refreshMinutes])).sorted(), id: \.self) { minutes in
                            Text("\(minutes) \(store.text("unit.minutes"))").tag(minutes)
                        }
                    }
                    Text(store.text("general.refreshHint")).font(.caption).foregroundStyle(.secondary)
                }
                .modifier(Surface())
                Label(store.text("general.localNotice"), systemImage: "internaldrive")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(28)
        }
    }
}

import SwiftUI
import WidgetKit

private enum CardPalette {
    static func accent(_ style: WidgetStyle) -> Color {
        switch style {
        case .calm: return Color(red: 0.13, green: 0.64, blue: 0.60)
        case .sport: return Color(red: 0.95, green: 0.40, blue: 0.19)
        case .monochrome: return .primary
        }
    }
}

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
        if store.hasSession && !statusSnapshot.hasMeasurements { return "data.waiting" }
        if store.hasSession && statusSnapshot.hasRetainedTimeSensitiveMetrics { return "data.waitingNew" }
        if isStale { return "widget.notice.waiting" }
        if store.hasSession && statusSnapshot.hasUnchangedMeasurements { return "data.unchanged" }
        return store.hasSession ? "data.available" : "status.notConnected"
    }

    private var statusSymbol: String {
        if store.needsWebSignIn { return "person.crop.circle.badge.exclamationmark" }
        if ["error.network", "error.timeout", "error.protocol", "error.partial", "error.rate_limit"].contains(store.lastErrorKey ?? "") { return "exclamationmark.triangle" }
        if !statusSnapshot.hasMeasurements { return "clock" }
        if !store.hasSession { return "link.badge.plus" }
        return isStale ? "clock.badge.exclamationmark" : "checkmark.circle.fill"
    }

    private var hint: String? {
        if store.isSyncing { return nil }
        if let error = store.lastErrorKey { return store.text(error) }
        if store.needsWebSignIn { return store.text("connection.reconnectDetail") }
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
        } else if needsAttention || !statusSnapshot.hasMeasurements || statusSnapshot.hasRetainedTimeSensitiveMetrics || isStale || store.isSyncing || !statusSnapshot.warnings.isEmpty {
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
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Label(store.text(definition.titleKey), systemImage: definition.symbol)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(theme.secondaryInk)
                    .lineLimit(2)
                MetricValueLabel(value: store.displayValue(metricID), size: compact ? 50 : 60)
                    .foregroundStyle(theme.ink)
                    .contentTransition(.numericText())
                if let context = MetricFormatter(snapshot: store.snapshot, language: store.preferences.language).context(metricID) {
                    Text(context).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.secondaryInk)
                } else if store.numericValue(metricID) == nil {
                    Text(store.text("data.empty")).font(.caption).foregroundStyle(theme.secondaryInk)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                if let progress = store.progress(metricID) {
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
        .accessibilityElement(children: .combine)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: definition.symbol).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(accent).frame(width: 28, height: 28)
                    .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                Text(store.text(definition.titleKey)).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            MetricValueLabel(value: store.displayValue(metricID), size: compact ? 28 : 32)
                .foregroundStyle(.primary)
            if let context = MetricFormatter(snapshot: store.snapshot, language: store.preferences.language).context(metricID) {
                Text(context).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 82 : 100, alignment: .leading)
        .padding(compact ? 16 : 18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(accent.opacity(0.10)))
        .accessibilityElement(children: .combine)
    }
}

struct DashboardView: View {
    @ObservedObject var store: AppStore
    @Binding var selectedProfileID: UUID?
    var onSettings: () -> Void
    var onConnection: () -> Void
    @State private var showWidgetHelp = false

    private var profile: WidgetProfile? {
        selectedProfileID.flatMap { store.profile($0) } ?? store.preferences.profiles.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(profile.map { $0.name.isEmpty ? store.text("profile.default") : $0.name } ?? store.text("dashboard.title"))
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
                    .help(store.updatedText)
                    .disabled(store.isSyncing || !store.hasSession)
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
            .padding(28)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if store.hasSession || store.snapshot.hasMeasurements || store.isSyncing || store.lastErrorKey != nil || store.needsWebSignIn {
                        DataStatusView(store: store, metricIDs: profile.flatMap { $0.contentMode.includesMetrics ? $0.metricIDs : nil })
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
                    if let profile, store.hasSession || store.snapshot.hasMeasurements {
                        if store.preferences.profiles.count > 1 {
                            Picker(store.text("dashboard.profile"), selection: Binding(
                                get: { self.profile?.id ?? profile.id },
                                set: { selectedProfileID = $0 }
                            )) {
                                ForEach(store.preferences.profiles) { item in
                                    Text(item.name.isEmpty ? store.text("profile.default") : item.name).tag(item.id)
                                }
                            }
                            .pickerStyle(.menu).frame(maxWidth: 360, alignment: .leading)
                        }
                        if profile.contentMode.includesMetrics && store.snapshot.hasMeasurements {
                            MainMetricView(store: store, metricID: profile.primaryMetric, style: profile.style,
                                           compact: profile.density == .compact)
                            let secondary = profile.metricIDs.filter { $0 != profile.primaryMetric }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 12, alignment: .leading)], spacing: 12) {
                                ForEach(secondary, id: \.self) { id in
                                    SmallMetricView(store: store, metricID: id, style: profile.style,
                                                    compact: profile.density == .compact)
                                }
                            }
                        }
                        if profile.contentMode.includesTraining {
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
            switch WidgetDataStore.configurationMode {
            case .unavailable:
                Text(store.text("widget.guide.unavailable")).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            case .staticProfiles, .profileIntents:
                guideStep("1", key: "widget.guide.add")
                guideStep("2", key: WidgetDataStore.configurationMode == .staticProfiles ? "widget.guide.staticProfile" : "widget.guide.profile")
                if WidgetDataStore.configurationMode == .staticProfiles {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(WidgetSlot.allCases, id: \.rawValue) { slot in
                            Picker(store.text("widget.slot." + slot.rawValue), selection: Binding(
                                get: { store.preferences.widgetProfileIDs[slot.rawValue] ?? "" },
                                set: { id in store.preferences.widgetProfileIDs[slot.rawValue] = id.isEmpty ? nil : id }
                            )) {
                                Text(store.text(slot == .overview ? "widget.slot.firstProfile" : "widget.slot.unassigned")).tag("")
                                if let assigned = store.preferences.widgetProfileIDs[slot.rawValue],
                                   !store.preferences.profiles.contains(where: { $0.id.uuidString == assigned }) {
                                    Text(store.text("widget.profileMissing")).tag(assigned)
                                }
                                ForEach(store.preferences.profiles) { profile in
                                    Text(profile.name.isEmpty ? store.text("profile.default") : profile.name).tag(profile.id.uuidString)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    .padding(12)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }
                Text(store.text("widget.guide.refresh")).font(.caption).foregroundStyle(.secondary)
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
    case dashboard, profiles, connection, general
    var id: String { rawValue }
    var key: String { self == .dashboard ? "dashboard.title" : "settings.\(rawValue)" }
    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .profiles: return "slider.horizontal.3"
        case .connection: return "person.crop.circle"
        case .general: return "gearshape"
        }
    }
    var shortcut: KeyEquivalent {
        switch self { case .dashboard: return "1"; case .profiles: return "2"; case .connection: return "3"; case .general: return "4" }
    }
}

@MainActor
final class MainWindowNavigation: ObservableObject {
    @Published var section: MainWindowSection? = .dashboard
    @Published var profileID: UUID?
}

private enum ProfileTemplate: String, CaseIterable {
    case life, sport, sleep
    var titleKey: String { "profile.template." + rawValue }
    var symbol: String {
        switch self { case .life: return "sun.max"; case .sport: return "figure.run"; case .sleep: return "moon.stars" }
    }
    func make(name: String) -> WidgetProfile {
        var profile = WidgetProfile()
        profile.name = name
        switch self {
        case .life:
            profile.metricIDs = ["bodyBattery", "steps", "stress", "heartRate", "hydration", "intensityMinutes"]
            profile.style = .calm
        case .sport:
            profile.metricIDs = ["trainingReadiness", "recoveryTime", "trainingLoad", "vo2Max", "hrv", "bodyBattery"]
            profile.style = .sport
            profile.contentMode = .mixed
        case .sleep:
            profile.metricIDs = ["sleepDuration", "sleepScore", "deepSleep", "remSleep", "lightSleep", "hrv", "restingHeartRate", "respiration"]
            profile.style = .calm
        }
        profile.primaryMetric = profile.metricIDs[0]
        return profile
    }
}

private enum ProfilePreviewSize: String, CaseIterable, Identifiable {
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
    func secondaryLimit(density: WidgetDensity) -> Int {
        switch self {
        case .small: return 0
        case .medium: return density == .compact ? 3 : 2
        case .large: return density == .compact ? 8 : 6
        }
    }
}

/// Uses the production widget content for metrics, training and mixed profiles.
private struct ProfileWidgetPreview: View {
    @ObservedObject var store: AppStore
    let profile: WidgetProfile
    let size: ProfilePreviewSize

    var body: some View {
        let widget = GarminWidgetView(entry: GarminEntry(date: Date(),
            data: WidgetData(preferences: store.preferences, snapshot: store.snapshot, isConnected: store.hasSession),
            profileID: profile.id.uuidString), previewFamily: size.family)
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
    @State private var selectedProfileID: UUID?
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
                        Button { navigation.section = item } label: {
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
                    DashboardView(store: store, selectedProfileID: $navigation.profileID,
                                  onSettings: { navigation.section = .profiles },
                                  onConnection: { navigation.section = .connection })
                case .profiles: profilesPane
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

    private var profilesPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(store.text("settings.profiles")).font(.title2.bold())
                Text(store.text("settings.profilesSubtitle")).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Picker(store.text("dashboard.profile"), selection: Binding(
                        get: { selectedProfileID.flatMap { store.profile($0)?.id } ?? store.preferences.profiles.first?.id },
                        set: { selectedProfileID = $0 }
                    )) {
                        ForEach(store.preferences.profiles) { profile in
                            Text(profile.name.isEmpty ? store.text("profile.default") : profile.name).tag(Optional(profile.id))
                        }
                    }
                    .labelsHidden().frame(maxWidth: .infinity)
                    Menu {
                        Text(store.text("profile.templates"))
                        ForEach(ProfileTemplate.allCases, id: \.self) { template in
                            Button {
                                let profile = template.make(name: store.text(template.titleKey))
                                store.preferences.profiles.append(profile)
                                selectedProfileID = profile.id
                            } label: { Label(store.text(template.titleKey), systemImage: template.symbol) }
                        }
                        Divider()
                        Button(store.text("profile.custom")) {
                            store.addProfile()
                            selectedProfileID = store.preferences.profiles.last?.id
                        }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help(store.text("action.add")).accessibilityLabel(store.text("action.add"))
                }
                .padding(.top, 10)
            }
            .padding(24)
            Divider()
            if let profileID = selectedProfileID.flatMap({ store.profile($0)?.id }) ?? store.preferences.profiles.first?.id {
                ProfileEditor(store: store, profileID: profileID)
                    .id(profileID)
            }
        }
    }
}

private struct ProfileEditor: View {
    @ObservedObject var store: AppStore
    var profileID: UUID
    @State private var confirmDelete = false
    @State private var previewSize: ProfilePreviewSize = .medium
    private var profile: WidgetProfile { store.profile(profileID) ?? WidgetProfile() }

    private func binding<Value>(_ path: WritableKeyPath<WidgetProfile, Value>) -> Binding<Value> {
        Binding(get: { profile[keyPath: path] }, set: { value in
            guard var updated = store.profile(profileID) else { return }
            updated[keyPath: path] = value
            store.updateProfile(updated)
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DisclosureGroup(store.text("widget.setup")) {
                    NativeWidgetGuide(store: store).padding(.top, 12)
                }.modifier(Surface())
                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent(store.text("profile.name")) {
                        TextField(store.text("profile.name"), text: binding(\.name)).labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 290)
                    }
                    Picker(store.text("profile.content"), selection: binding(\.contentMode)) {
                        Text(store.text("content.metrics")).tag(WidgetContentMode.metrics)
                        Text(store.text("content.training")).tag(WidgetContentMode.training)
                        Text(store.text("content.mixed")).tag(WidgetContentMode.mixed)
                    }.pickerStyle(.segmented)
                    if profile.contentMode.includesMetrics {
                        Picker(store.text("profile.primary"), selection: Binding(get: { profile.primaryMetric }, set: { id in
                            var updated = profile
                            updated.primaryMetric = id
                            if !updated.metricIDs.contains(id) { updated.metricIDs.insert(id, at: 0) }
                            store.updateProfile(updated)
                        })) {
                            ForEach(MetricDefinition.catalog, id: \.id) { metric in Text(store.text(metric.titleKey)).tag(metric.id) }
                        }
                    }
                }
                .modifier(Surface())
                VStack(alignment: .leading, spacing: 12) {
                    Text(store.text("profile.appearance")).font(.headline)
                    Picker(store.text("profile.style"), selection: binding(\.style)) {
                        Text(store.text("style.calm")).tag(WidgetStyle.calm)
                        Text(store.text("style.sport")).tag(WidgetStyle.sport)
                        Text(store.text("style.monochrome")).tag(WidgetStyle.monochrome)
                    }
                    .pickerStyle(.segmented)
                    Picker(store.text("profile.density"), selection: binding(\.density)) {
                        Text(store.text("density.comfortable")).tag(WidgetDensity.comfortable)
                        Text(store.text("density.compact")).tag(WidgetDensity.compact)
                    }
                    Group {
                        Divider()
                        Picker(store.text("profile.previewSize"), selection: $previewSize) {
                            ForEach(ProfilePreviewSize.allCases) { size in
                                Text(store.text(size.titleKey)).tag(size)
                            }
                        }.pickerStyle(.segmented)
                        ProfileWidgetPreview(store: store, profile: profile, size: previewSize)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        if profile.contentMode == .metrics {
                            let visibleCount = 1 + min(profile.metricIDs.filter { $0 != profile.primaryMetric }.count,
                                                       previewSize.secondaryLimit(density: profile.density))
                            Text(String(format: store.text("profile.previewCount"), visibleCount, profile.metricIDs.count))
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .modifier(Surface())
                if profile.contentMode.includesMetrics { metricsEditor }
                HStack {
                    Button { store.duplicateProfile(profileID) } label: {
                        Label(store.text("action.duplicate"), systemImage: "plus.square.on.square")
                    }
                        .help(store.text("action.duplicate")).accessibilityLabel(store.text("action.duplicate"))
                    Spacer(minLength: 0)
                    Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                        .disabled(store.preferences.profiles.count <= 1)
                        .help(store.text(store.preferences.profiles.count <= 1 ? "profile.oneRequired" : "action.delete"))
                        .accessibilityLabel(store.text("action.delete"))
                }
                Text(store.text("general.localNotice")).font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .confirmationDialog(store.text("profile.deleteTitle"), isPresented: $confirmDelete) {
            Button(store.text("action.delete"), role: .destructive) { store.deleteProfile(profileID) }
            Button(store.text("action.cancel"), role: .cancel) {}
        } message: { Text(store.text("profile.deleteMessage")) }
    }

    private var metricsEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.text("profile.metrics")).font(.headline)
            Text(store.text("profile.metricsHint")).font(.caption).foregroundStyle(.secondary)
            ForEach([profile.primaryMetric] + profile.metricIDs.filter { $0 != profile.primaryMetric }, id: \.self) { id in
                metricRow(id, included: true)
            }
            let available = MetricDefinition.catalog.filter { !profile.metricIDs.contains($0.id) }
            if !available.isEmpty {
                Divider().padding(.vertical, 4)
                Text(store.text("profile.available")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(available, id: \.id) { metric in metricRow(metric.id, included: false) }
            }
        }
        .modifier(Surface())
    }

    private func metricRow(_ id: String, included: Bool) -> some View {
        let metric = MetricDefinition.find(id)
        return HStack(spacing: 9) {
            Toggle(isOn: Binding(get: { profile.metricIDs.contains(id) }, set: { enabled in
                var updated = profile
                if enabled { if !updated.metricIDs.contains(id) { updated.metricIDs.append(id) } }
                else { updated.metricIDs.removeAll { $0 == id } }
                store.updateProfile(updated)
            })) {
                Label(store.text(metric.titleKey), systemImage: metric.symbol)
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
            .disabled(id == profile.primaryMetric)
            Spacer(minLength: 4)
            if id == profile.primaryMetric {
                Text(store.text("profile.mainBadge")).font(.caption2).foregroundStyle(.secondary)
            }
            if included && id != profile.primaryMetric {
                Button { move(id, offset: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(profile.metricIDs.filter { $0 != profile.primaryMetric }.first == id)
                    .help(store.text("action.up")).accessibilityLabel("\(store.text("action.up")): \(store.text(metric.titleKey))")
                Button { move(id, offset: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(profile.metricIDs.filter { $0 != profile.primaryMetric }.last == id)
                    .help(store.text("action.down")).accessibilityLabel("\(store.text("action.down")): \(store.text(metric.titleKey))")
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 2)
    }

    private func move(_ id: String, offset: Int) {
        var updated = profile
        var secondary = updated.metricIDs.filter { $0 != updated.primaryMetric }
        guard let index = secondary.firstIndex(of: id), secondary.indices.contains(index + offset) else { return }
        secondary.swapAt(index, index + offset)
        updated.metricIDs = [updated.primaryMetric] + secondary
        store.updateProfile(updated)
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
                        Text("Русский").tag(AppLanguage.ru)
                        Text("English").tag(AppLanguage.en)
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

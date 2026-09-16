import Foundation

/// New links identify a fixed widget kind. Old profile links degrade to Summary
/// (or retain their explicit slot) without restoring a profile feature.
struct WidgetLink {
    let slot: WidgetSlot
    init(slot: WidgetSlot) { self.slot = slot }
    init?(url: URL) {
        guard url.scheme == "garmindesk" else { return nil }
        if url.host == "widget", let kind = WidgetSlot(rawValue: url.lastPathComponent) {
            slot = kind
        } else if url.host == "profile", UUID(uuidString: url.lastPathComponent) != nil {
            slot = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "slot" })?.value.flatMap(WidgetSlot.init(rawValue:)) ?? .overview
        } else { return nil }
    }
    var url: URL? { URL(string: "garmindesk://widget/" + slot.rawValue) }
}

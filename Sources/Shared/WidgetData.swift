import Foundation
import Darwin

/// One atomic, read-only snapshot for WidgetKit. Garmin credentials never enter this file.
struct WidgetData: Codable {
    var version = 1
    var preferences: AppPreferences
    var snapshot: GarminSnapshot
    var isConnected: Bool

    static var preview: WidgetData {
        var preferences = AppPreferences()
        preferences.profiles[0].id = UUID(uuidString: "8C913B3D-EE7A-4F9E-831F-000000000001")!
        return WidgetData(preferences: preferences, snapshot: .demo, isConnected: false)
    }

    func profile(id: String?) -> WidgetProfile? {
        guard let id else { return preferences.profiles.first }
        return preferences.profiles.first { $0.id.uuidString == id }
    }
}

enum WidgetDataStore {
    static let kind = "GarminDeskSummary"
    static let fileName = "widget-data.json"
    static let localRelativePath = "Library/Application Support/GarminDesk/Widgets"

    enum StorageMode { case localReadOnlyCache, appGroup }
    enum ConfigurationMode { case unavailable, staticProfiles, profileIntents }

    private static var appGroupIdentifier: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "GARMIN_APP_GROUP") as? String,
              !value.isEmpty else { return nil }
        return value
    }

    static var storageMode: StorageMode { appGroupIdentifier == nil ? .localReadOnlyCache : .appGroup }

    /// Describes the compiled variant, not registration or rendering in the system gallery.
    static var configurationMode: ConfigurationMode {
        guard configurationAvailable else { return .unavailable }
        switch Bundle.main.object(forInfoDictionaryKey: "GARMIN_WIDGET_CONFIGURATION_MODE") as? String {
        case "static": return .staticProfiles
        case "profile-intents": return .profileIntents
        default: return .unavailable
        }
    }

    static var configurationAvailable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "GARMIN_WIDGET_CONFIGURATION_AVAILABLE") as? Bool == true
    }

    /// Foundation's home directory is redirected inside App Sandbox. Use only the
    /// current process user's system record; never HOME, a username, or a saved path.
    static var userHomeDirectory: URL? {
        let userID = getuid()
        guard userID == geteuid() else { return nil }
        let suggested = sysconf(_SC_GETPW_R_SIZE_MAX)
        var size = suggested > 0 ? Int(suggested) : 16_384
        while size <= 1_048_576 {
            var record = passwd()
            var result: UnsafeMutablePointer<passwd>?
            var buffer = [CChar](repeating: 0, count: size)
            let response: (Int32, String?) = buffer.withUnsafeMutableBufferPointer { memory in
                let status = getpwuid_r(userID, &record, memory.baseAddress, memory.count, &result)
                guard status == 0, result != nil, record.pw_uid == userID,
                      let directory = record.pw_dir else { return (status, nil) }
                return (status, String(validatingCString: directory))
            }
            if response.0 == ERANGE { size *= 2; continue }
            guard response.0 == 0, let path = response.1,
                  path.hasPrefix("/"), path != "/" else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        }
        return nil
    }

    static var localCacheURL: URL? {
        guard let home = userHomeDirectory else { return nil }
        let directory = home.appendingPathComponent(localRelativePath, isDirectory: true)
        // Do not follow a substituted Library/App Support/cache directory into
        // another home or a different area of this user's files.
        guard directory.resolvingSymlinksInPath().path == directory.path else { return nil }
        return directory
    }

    static var containerURL: URL? {
        if let identifier = appGroupIdentifier {
            // Explicit App Group mode must not silently switch storage on error.
            return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        }
        return localCacheURL
    }

    static func read(from directory: URL? = containerURL) -> WidgetData? {
        guard let directory, directory.isFileURL else { return nil }
        let descriptor = open(directory.appendingPathComponent(fileName).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_size > 0,
              metadata.st_size <= 10 * 1_024 * 1_024,
              let bytes = try? handle.readToEnd(),
              let data = try? AppJSON.decoder.decode(WidgetData.self, from: bytes),
              data.version == 1 else { return nil }
        return data
    }

    static func write(_ data: WidgetData, to directory: URL? = containerURL) throws {
        guard let directory, directory.isFileURL else { throw StoreError.unavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent(fileName)
        let temporary = directory.appendingPathComponent(".widget-data-" + UUID().uuidString + ".tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try handle.write(contentsOf: AppJSON.encoder.encode(data))
        try handle.synchronize()
        guard rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    enum StoreError: Error { case unavailable }
}

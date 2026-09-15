import Foundation

struct BridgeDiagnostic: Decodable {
    var stage: String?
    var httpStatus: Int?
    var apiErrorStatus: Int?
    var retryAfterSeconds: Int?
    var responseKind: String?
    var requestCount: Int?
    var challenge: Bool?
}

struct BridgeResponse: Decodable {
    let event: String
    var session: String?
    var snapshot: GarminSnapshot?
    var code: String?
    var diagnostic: BridgeDiagnostic?
}

enum BridgeFailure: Error { case missingExecutable, invalidRequest }

@MainActor
final class PythonBridge {
    private var process: Process?
    private var input: FileHandle?

    func start(_ request: [String: Any]) throws -> AsyncStream<BridgeResponse> {
        stop()
        let process = Process()
        let resources = Bundle.main.resourceURL
        let bundled = resources?.appendingPathComponent("Connector/garmin-bridge/garmin-bridge")
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) {
            process.executableURL = bundled
        } else {
            // Explicit legacy development only; never embed the build machine's
            // home path or search a recipient's filesystem for an interpreter.
            guard let developmentRoot = ProcessInfo.processInfo.environment["GARMIN_DESK_DEVELOPMENT_ROOT"],
                  !developmentRoot.isEmpty else { throw BridgeFailure.missingExecutable }
            let root = URL(fileURLWithPath: developmentRoot, isDirectory: true)
            let interpreter = root.appendingPathComponent(".venv/bin/python3")
            let script = root.appendingPathComponent("Connector/bridge.py")
            guard FileManager.default.isExecutableFile(atPath: interpreter.path), FileManager.default.fileExists(atPath: script.path) else { throw BridgeFailure.missingExecutable }
            process.executableURL = interpreter
            process.arguments = ["-I", script.path]
        }
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "PYTHONPATH")
        environment.removeValue(forKey: "PYTHONHOME")
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        let stdout = Pipe(), stdin = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = stderr
        stderr.fileHandleForReading.readabilityHandler = { handle in
            // Drain helper diagnostics without retaining account-related data.
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        try process.run()
        self.process = process
        self.input = stdin.fileHandleForWriting
        try send(request)
        return AsyncStream { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = Data()
                let newline = UInt8(10)
                while true {
                    let chunk = stdout.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    if buffer.count > 4_000_000 {
                        continuation.yield(BridgeResponse(event: "error", code: "protocol"))
                        process.terminate()
                        break
                    }
                    while let end = buffer.firstIndex(of: newline) {
                        let line = buffer[..<end]
                        buffer.removeSubrange(...end)
                        if line.isEmpty { continue }
                        do {
                            continuation.yield(try AppJSON.decoder.decode(BridgeResponse.self, from: Data(line)))
                        } catch {
                            continuation.yield(BridgeResponse(event: "error", code: "protocol"))
                        }
                    }
                }
                if !buffer.isEmpty, let event = try? AppJSON.decoder.decode(BridgeResponse.self, from: buffer) { continuation.yield(event) }
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.finish()
            }
        }
    }

    func send(_ request: [String: Any]) throws {
        guard let input, JSONSerialization.isValidJSONObject(request) else { throw BridgeFailure.invalidRequest }
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(10)
        try input.write(contentsOf: data)
    }

    func stop() {
        try? input?.close()
        input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }
}

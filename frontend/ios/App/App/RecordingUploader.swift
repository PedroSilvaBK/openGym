import CryptoKit
import Foundation

/**
 * Sends the watch recordings this phone holds (WatchLink.recordingsDirectory) to the paired
 * openGym server (api/recordings.js): the motion file in chunks that each fit the server's 5 MB
 * body cap, appended in order and resumed from whatever the server already holds, then the
 * manifest with the motion file's size and sha256. A recording leaves the phone only once the
 * server has said it has it.
 *
 * The page configures it (WatchPlugin.uploadRecordings: server, headers, chunk size) whenever it
 * runs; the configuration lives in memory only, so the token is never written anywhere new. A
 * recording that arrives with the app woken in the background waits for the next run.
 */
actor RecordingUploader {
    static let shared = RecordingUploader()

    struct Config {
        let base: String
        let headers: [String: String]
        let chunkBytes: Int
    }

    struct UploadError: Error, CustomStringConvertible {
        let status: Int
        let code: String
        var description: String { "HTTP \(status) \(code)" }
    }

    private var config: Config?
    private var running = false

    func configure(_ config: Config?) { self.config = config }

    // Recordings with both files here, oldest first (a pair arrives as two separate transfers).
    static func complete() -> [String] {
        let dir = WatchLink.recordingsDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let jsons = Set(names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
        let motions = Set(names.filter { $0.hasSuffix(".motion") }.map { String($0.dropLast(7)) })
        return jsons.intersection(motions).sorted()
    }

    @discardableResult
    func run() async -> [String: Any] {
        guard let config else { return ["uploaded": 0, "remaining": Self.complete().count, "error": "not-configured"] }
        guard !running else { return ["uploaded": 0, "remaining": Self.complete().count, "error": "busy"] }
        running = true
        defer { running = false }
        var uploaded = 0
        var lastError = ""
        for name in Self.complete() {
            do {
                try await upload(name, config)
                let dir = WatchLink.recordingsDirectory
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name + ".motion"))
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name + ".json"))
                uploaded += 1
            } catch {
                lastError = "\(error)"
                NSLog("openGym watch: recording \(name) not uploaded: \(error)")
                // Signed out, server down, no network: the rest would fail the same way.
                if let e = error as? UploadError, e.status == 413 || e.status == 422 { continue }
                break
            }
        }
        return ["uploaded": uploaded, "remaining": Self.complete().count, "error": lastError]
    }

    private func upload(_ name: String, _ config: Config) async throws {
        let dir = WatchLink.recordingsDirectory
        let motion = try Data(contentsOf: dir.appendingPathComponent(name + ".motion"), options: .mappedIfSafe)
        let manifestData = try Data(contentsOf: dir.appendingPathComponent(name + ".json"))
        let manifest = try JSONSerialization.jsonObject(with: manifestData)
        let sha256 = SHA256.hash(data: motion).map { String(format: "%02x", $0) }.joined()

        var offset = 0
        while offset < motion.count {
            let end = min(offset + config.chunkBytes, motion.count)
            let (status, body) = try await send(config, path: "/api/recordings/\(name)/chunk?offset=\(offset)",
                                                body: motion.subdata(in: offset..<end), type: "application/octet-stream")
            switch status {
            case 200:
                offset = (body["size"] as? Int) ?? end
            case 409 where (body["code"] as? String) == "exists":
                return   // the server finished this one before (an answer lost on the way back)
            case 409:
                guard let size = body["size"] as? Int, size != offset else { throw UploadError(status: status, code: "offset") }
                offset = size
            default:
                throw UploadError(status: status, code: (body["code"] as? String) ?? (body["error"] as? String) ?? "")
            }
        }

        let finish = try JSONSerialization.data(withJSONObject: ["manifest": manifest, "size": motion.count, "sha256": sha256])
        let (status, body) = try await send(config, path: "/api/recordings/\(name)/finish", body: finish, type: "application/json")
        guard status == 200 else { throw UploadError(status: status, code: (body["code"] as? String) ?? "") }
    }

    private func send(_ config: Config, path: String, body: Data, type: String) async throws -> (Int, [String: Any]) {
        guard let url = URL(string: config.base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw UploadError(status: 0, code: "bad-server-address")
        }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        for (k, v) in config.headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }
}

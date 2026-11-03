import Foundation
import Phimengine

/// Bộ tải torrent nằm sẵn trong app (Go, anacrolix/torrent)
final class TorrentEngine {
    static let shared = TorrentEngine()
    private(set) var port = -1
    private let q = DispatchQueue(label: "engine")

    func start() -> Bool {
        if port > 0 { return true }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("torrent", isDirectory: true).path
        port = PhimengineStart(dir)
        return port > 0
    }

    var lastError: String { PhimengineLastError() }

    func streamURL(hash: String, fileIdx: Int?, trackers: [String], hint: String?) -> URL? {
        guard start() else { return nil }
        var magnet = "magnet:?xt=urn:btih:\(hash)"
        for t in trackers { magnet += "&tr=" + AddonStore.enc(t) }
        let h = PhimengineAddMagnet(magnet)
        guard !h.isEmpty else { return nil }
        var s = "http://127.0.0.1:\(port)/stream/\(h)/\(fileIdx ?? -1)"
        if let hint, !hint.isEmpty { s += "?hint=" + AddonStore.enc(hint) }
        return URL(string: s)
    }

    struct Status: Decodable {
        var ready: Bool?
        var name: String?
        var peers: Int?
        var seeds: Int?
        var downloaded: Int64?
        var total: Int64?
    }

    func status(_ hash: String) -> Status? {
        let s = PhimengineStatus(hash)
        return try? JSONDecoder().decode(Status.self, from: Data(s.utf8))
    }

    func stopAll() { q.async { PhimengineDropAll() } }
}

/// TorBox: nếu torrent đã có sẵn trên TorBox thì phát qua link HTTP (nhanh, mượt)
enum TorBox {
    static let api = "https://api.torbox.app/v1/api"

    private static func req(_ path: String, key: String, method: String = "GET", form: [String: String]? = nil) async throws -> JSON {
        var r = URLRequest(url: URL(string: api + path)!)
        r.httpMethod = method
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 20
        if let form {
            let boundary = "pt-\(UUID().uuidString)"
            r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            for (k, v) in form {
                body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
            }
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)
            r.httpBody = body
        }
        let (d, _) = try await URLSession.shared.data(for: r)
        return (try JSONSerialization.jsonObject(with: d) as? JSON) ?? [:]
    }

    static func isCached(_ hash: String, key: String) async -> Bool {
        guard let j = try? await req("/torrents/checkcached?hash=\(hash)&format=list", key: key) else { return false }
        if let a = j["data"] as? [Any] { return !a.isEmpty }
        if let o = j["data"] as? JSON { return !o.isEmpty }
        return false
    }

    static func link(hash: String, trackers: [String], fileIdx: Int?, hint: String?, season: Int?, episode: Int?, key: String) async throws -> URL {
        var magnet = "magnet:?xt=urn:btih:\(hash)"
        for t in trackers.prefix(10) { magnet += "&tr=" + AddonStore.enc(t) }
        let c = try await req("/torrents/createtorrent", key: key, method: "POST", form: ["magnet": magnet, "seed": "3"])
        guard let tid = jInt((c["data"] as? JSON)?["torrent_id"]) else {
            throw NSError(domain: "TorBox", code: 1, userInfo: [NSLocalizedDescriptionKey: jStr(c["detail"]) ?? "TorBox không nhận torrent"])
        }
        var files: [JSON] = []
        for _ in 0..<15 {
            let l = try await req("/torrents/mylist?id=\(tid)&bypass_cache=true", key: key)
            files = ((l["data"] as? JSON)?["files"] as? [JSON]) ?? []
            if !files.isEmpty { break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard !files.isEmpty else { throw NSError(domain: "TorBox", code: 2, userInfo: [NSLocalizedDescriptionKey: "TorBox chưa có file"]) }
        let vids = files.filter { f in
            let n = (jStr(f["name"]) ?? "").lowercased()
            return [".mkv", ".mp4", ".avi", ".mov", ".m4v", ".ts", ".webm"].contains { n.hasSuffix($0) }
        }
        let pool = vids.isEmpty ? files : vids
        var pick: JSON?
        if let hint, !hint.isEmpty {
            pick = pool.first { (jStr($0["name"]) ?? "").lowercased().contains(hint.lowercased()) }
        }
        if pick == nil, let s = season, let e = episode {
            let pats = [String(format: "s%02de%02d", s, e), "\(s)x\(String(format: "%02d", e))"]
            pick = pool.first { f in let n = (jStr(f["name"]) ?? "").lowercased(); return pats.contains { n.contains($0) } }
        }
        if pick == nil, let i = fileIdx, i >= 0, i < files.count, pool.count > 1 { pick = files[i] }
        if pick == nil { pick = pool.max { (jInt($0["size"]) ?? 0) < (jInt($1["size"]) ?? 0) } }
        guard let fid = jInt(pick?["id"]) else { throw NSError(domain: "TorBox", code: 3) }
        let d = try await req("/torrents/requestdl?token=\(key)&torrent_id=\(tid)&file_id=\(fid)", key: key)
        guard let s = jStr(d["data"]), let u = URL(string: s) else {
            throw NSError(domain: "TorBox", code: 4, userInfo: [NSLocalizedDescriptionKey: "TorBox không trả link"])
        }
        return u
    }
}

/// Chọn cách phát cho một nguồn
struct ResolvedSource {
    var url: URL
    var headers: [String: String]
    var torrentHash: String?   // khác nil = đang dùng bộ tải trong app
    var via: String
}

enum Resolver {
    static func resolve(_ s: StreamItem, season: Int?, episode: Int?) async throws -> ResolvedSource {
        if let u = s.url, u.hasPrefix("http"), let url = URL(string: u) {
            return ResolvedSource(url: url, headers: s.headers, torrentHash: nil, via: "Link trực tiếp")
        }
        var hash = s.infoHash
        if hash == nil, let u = s.url, u.hasPrefix("magnet:"),
           let r = u.range(of: "btih:") {
            hash = String(u[r.upperBound...].prefix { $0.isLetter || $0.isNumber }).lowercased()
        }
        guard let h = hash else { throw NSError(domain: "PhimTor", code: 9, userInfo: [NSLocalizedDescriptionKey: "Nguồn này không phát được trong app"]) }

        let key = await MainActor.run { AddonStore.shared.torboxKey.trimmingCharacters(in: .whitespaces) }
        if !key.isEmpty, await TorBox.isCached(h, key: key) {
            if let u = try? await TorBox.link(hash: h, trackers: s.trackers, fileIdx: s.fileIdx, hint: s.filename,
                                              season: season, episode: episode, key: key) {
                return ResolvedSource(url: u, headers: [:], torrentHash: nil, via: "TorBox")
            }
        }
        guard let u = TorrentEngine.shared.streamURL(hash: h, fileIdx: s.fileIdx, trackers: s.trackers, hint: s.fileIdx == nil ? s.filename : nil) else {
            throw NSError(domain: "PhimTor", code: 10, userInfo: [NSLocalizedDescriptionKey: "Không khởi động được bộ tải torrent: \(TorrentEngine.shared.lastError)"])
        }
        return ResolvedSource(url: u, headers: [:], torrentHash: h, via: "Torrent trong app")
    }
}

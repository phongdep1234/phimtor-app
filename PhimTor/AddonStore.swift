import Foundation
import SwiftUI

/// Gọi add-on theo đúng giao thức Stremio + lưu danh sách add-on, cài đặt.
@MainActor
final class AddonStore: ObservableObject {
    static let shared = AddonStore()

    static let cinemeta = "https://v3-cinemeta.strem.io/manifest.json"
    static let openSubs = "https://opensubtitles-v3.strem.io/manifest.json"
    static let phuDeViet = "https://phudeviet.trananhphong2208.workers.dev/manifest.json"
    static let builtIns = [cinemeta, phuDeViet, openSubs]

    @Published var addons: [Addon] = [] { didSet { save() } }
    @Published var recents: [RecentItem] = [] { didSet { saveRecents() } }
    @Published var favorites: [FavItem] = [] { didSet { if let d = try? JSONEncoder().encode(favorites) { ud.set(d, forKey: "favorites") } } }
    @AppStorage("torboxKey") var torboxKey = ""
    @AppStorage("subFontSize") var subFontSize = 22.0
    @AppStorage("subBottom") var subBottom = 28.0
    @AppStorage("autoVietSub") var autoVietSub = true
    @AppStorage("preferHuman") var preferHuman = true

    private let ud = UserDefaults.standard
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 25
        c.requestCachePolicy = .useProtocolCachePolicy
        c.urlCache = URLCache(memoryCapacity: 20 << 20, diskCapacity: 100 << 20)
        return URLSession(configuration: c)
    }()

    init() {
        if let d = ud.data(forKey: "addons"), let a = try? JSONDecoder().decode([Addon].self, from: d) { addons = a }
        if let d = ud.data(forKey: "recents"), let r = try? JSONDecoder().decode([RecentItem].self, from: d) { recents = r }
        if let d = ud.data(forKey: "favorites"), let f = try? JSONDecoder().decode([FavItem].self, from: d) { favorites = f }
        Task { await ensureBuiltIns() }
    }

    private func save() { if let d = try? JSONEncoder().encode(addons) { ud.set(d, forKey: "addons") } }
    private func saveRecents() { if let d = try? JSONEncoder().encode(recents) { ud.set(d, forKey: "recents") } }

    // MARK: cài / gỡ add-on
    nonisolated static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("stremio://") { s = "https://" + s.dropFirst("stremio://".count) }
        if !s.hasPrefix("http") { s = "https://" + s }
        if s.hasSuffix("/configure") { s.removeLast("/configure".count); s += "/manifest.json" }
        if !s.hasSuffix("manifest.json") { s = s.hasSuffix("/") ? s + "manifest.json" : s + "/manifest.json" }
        return s
    }

    func fetchManifest(_ url: String) async throws -> Manifest {
        guard let u = URL(string: url) else { throw err("Link không hợp lệ") }
        let (data, _) = try await session.data(from: u)
        guard let j = try JSONSerialization.jsonObject(with: data) as? JSON, let m = Manifest(json: j) else {
            throw err("Không đọc được manifest")
        }
        return m
    }

    func install(_ raw: String) async throws {
        let url = Self.normalize(raw)
        let m = try await fetchManifest(url)
        if let i = addons.firstIndex(where: { $0.manifest.id == m.id || $0.transportUrl == url }) {
            addons[i].manifest = m
            addons[i].transportUrl = url
        } else {
            addons.append(Addon(transportUrl: url, manifest: m, builtIn: Self.builtIns.contains(url)))
        }
    }

    func ensureBuiltIns() async {
        for (i, u) in Self.builtIns.enumerated() where !addons.contains(where: { $0.transportUrl == u }) {
            if let m = try? await fetchManifest(u) {
                addons.insert(Addon(transportUrl: u, manifest: m, builtIn: true), at: min(i, addons.count))
            }
        }
        // làm mới manifest các add-on (phiên bản mới, danh mục mới)
        for a in addons {
            if let m = try? await fetchManifest(a.transportUrl), let i = addons.firstIndex(of: a) { addons[i].manifest = m }
        }
    }

    func remove(_ a: Addon) { addons.removeAll { $0.id == a.id } }

    // MARK: gọi tài nguyên
    private func get(_ addon: Addon, _ path: String) async -> JSON? {
        guard let u = URL(string: addon.base + path) else { return nil }
        var req = URLRequest(url: u)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode ?? 500 < 400 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? JSON
    }

    nonisolated static func enc(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    nonisolated static func extraPath(_ extra: [(String, String)]) -> String {
        guard !extra.isEmpty else { return "" }
        return "/" + extra.map { "\($0.0)=\(enc($0.1))" }.joined(separator: "&")
    }

    func catalog(_ addon: Addon, _ c: CatalogDesc, extra: [(String, String)] = []) async -> [MetaItem] {
        let path = "/catalog/\(c.type)/\(Self.enc(c.id))\(Self.extraPath(extra)).json"
        let j = await get(addon, path)
        return ((j?["metas"] as? [JSON]) ?? []).compactMap { MetaItem(json: $0) }
    }

    func meta(type: String, id: String, preferred: String?) async -> MetaItem? {
        var order = addons.filter { $0.manifest.supports("meta", type: type, id: id) }
        if let p = preferred, let i = order.firstIndex(where: { $0.transportUrl == p }) { order.insert(order.remove(at: i), at: 0) }
        for a in order {
            if let j = await get(a, "/meta/\(type)/\(Self.enc(id)).json"), let m = j["meta"] as? JSON, let item = MetaItem(json: m) {
                return item
            }
        }
        return nil
    }

    /// Nguồn phát từ mọi add-on hỗ trợ, trả về theo từng add-on khi có kết quả
    func streams(type: String, id: String, onAddon: @escaping (String, [StreamItem]) -> Void) async {
        let list = addons.filter { $0.manifest.supports("stream", type: type, id: id) }
        await withTaskGroup(of: (String, [StreamItem]).self) { g in
            for a in list {
                g.addTask {
                    let j = await self.get(a, "/stream/\(type)/\(Self.enc(id)).json")
                    let s = ((j?["streams"] as? [JSON]) ?? []).compactMap { StreamItem(json: $0, addon: a.manifest.name) }
                    return (a.manifest.name, s)
                }
            }
            for await (n, s) in g { onAddon(n, s) }
        }
    }

    func subtitles(type: String, id: String, stream: StreamItem?) async -> [SubItem] {
        var extra: [(String, String)] = []
        if let h = stream?.videoHash { extra.append(("videoHash", h)) }
        if let s = stream?.videoSize { extra.append(("videoSize", String(s))) }
        if let f = stream?.filename { extra.append(("filename", f)) }
        let list = addons.filter { $0.manifest.supports("subtitles", type: type, id: id) }
        var all: [SubItem] = []
        await withTaskGroup(of: [SubItem].self) { g in
            for a in list {
                g.addTask {
                    let j = await self.get(a, "/subtitles/\(type)/\(Self.enc(id))\(Self.extraPath(extra)).json")
                    return ((j?["subtitles"] as? [JSON]) ?? []).enumerated().compactMap { i, s in
                        guard let u = jStr(s["url"]) else { return nil }
                        return SubItem(id: (jStr(s["id"]) ?? "\(i)") + "@" + a.manifest.id, url: u,
                                       lang: jStr(s["lang"]) ?? "und", label: jStr(s["label"]), addonName: a.manifest.name)
                    }
                }
            }
            for await s in g { all += s }
        }
        var seen = Set<String>()
        all = all.filter { seen.insert($0.url).inserted }
        // Việt lên đầu (bản người dịch trước bản dịch máy), rồi Anh, rồi còn lại
        func rank(_ s: SubItem) -> Int {
            if s.isVietnamese { return s.isMachine ? 1 : 0 }
            if ["eng", "en"].contains(s.lang.lowercased()) { return 2 }
            return 3
        }
        return all.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map { $0.element }
    }

    // MARK: đang xem
    // MARK: Yêu thích

    func isFavorite(_ id: String) -> Bool { favorites.contains { $0.id == id } }

    func toggleFavorite(_ m: MetaItem, addonUrl: String?) {
        if isFavorite(m.id) { favorites.removeAll { $0.id == m.id } }
        else { favorites.insert(FavItem(id: m.id, type: m.type, name: m.name, poster: m.poster, landscape: m.landscapePoster, addonUrl: addonUrl), at: 0) }
    }

    func touchRecent(_ r: RecentItem) {
        recents.removeAll { $0.id == r.id }
        recents.insert(r, at: 0)
        if recents.count > 30 { recents.removeLast(recents.count - 30) }
    }

    func position(for videoId: String) -> Double {
        ud.double(forKey: "pos:" + videoId)
    }
    func setPosition(_ p: Double, for videoId: String) { ud.set(p, forKey: "pos:" + videoId) }

    private func err(_ s: String) -> NSError { NSError(domain: "PhimTor", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
}

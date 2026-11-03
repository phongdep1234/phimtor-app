import Foundation

// MARK: - Tiện ích đọc JSON lỏng (add-on mỗi nơi viết một kiểu)
typealias JSON = [String: Any]

func jStr(_ v: Any?) -> String? {
    if let s = v as? String { return s.isEmpty ? nil : s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}
func jInt(_ v: Any?) -> Int? {
    if let n = v as? NSNumber { return n.intValue }
    if let s = v as? String { return Int(s) }
    return nil
}
func jStrs(_ v: Any?) -> [String] {
    if let a = v as? [String] { return a }
    if let a = v as? [Any] { return a.compactMap { jStr($0) } }
    if let s = v as? String { return [s] }
    return []
}

// MARK: - Manifest
struct ResourceDesc: Codable, Hashable {
    var name: String
    var types: [String]?
    var idPrefixes: [String]?
}

struct ExtraDesc: Codable, Hashable {
    var name: String
    var isRequired: Bool
    var options: [String]
}

struct CatalogDesc: Codable, Hashable, Identifiable {
    var type: String
    var id: String
    var name: String
    var extra: [ExtraDesc]
    var uid: String { type + "/" + id }
    var supportsSearch: Bool { extra.contains { $0.name == "search" } }
    var needsSomething: Bool { extra.contains { $0.isRequired } }
    var genres: [String] { extra.first { $0.name == "genre" }?.options ?? [] }
}

struct Manifest: Codable, Hashable {
    var id: String
    var name: String
    var version: String
    var description: String?
    var logo: String?
    var types: [String]
    var idPrefixes: [String]?
    var resources: [ResourceDesc]
    var catalogs: [CatalogDesc]
    var configurable: Bool

    init?(json d: JSON) {
        guard let id = jStr(d["id"]), let name = jStr(d["name"]) else { return nil }
        self.id = id; self.name = name
        version = jStr(d["version"]) ?? "?"
        description = jStr(d["description"])
        logo = jStr(d["logo"])
        types = jStrs(d["types"])
        idPrefixes = d["idPrefixes"] == nil ? nil : jStrs(d["idPrefixes"])
        resources = ((d["resources"] as? [Any]) ?? []).compactMap { r in
            if let s = r as? String { return ResourceDesc(name: s, types: nil, idPrefixes: nil) }
            if let o = r as? JSON, let n = jStr(o["name"]) {
                return ResourceDesc(name: n, types: o["types"] == nil ? nil : jStrs(o["types"]),
                                    idPrefixes: o["idPrefixes"] == nil ? nil : jStrs(o["idPrefixes"]))
            }
            return nil
        }
        catalogs = ((d["catalogs"] as? [JSON]) ?? []).compactMap { c in
            guard let t = jStr(c["type"]), let cid = jStr(c["id"]) else { return nil }
            var ex: [ExtraDesc] = ((c["extra"] as? [JSON]) ?? []).compactMap { e in
                guard let n = jStr(e["name"]) else { return nil }
                return ExtraDesc(name: n, isRequired: (e["isRequired"] as? Bool) ?? false, options: jStrs(e["options"]))
            }
            for n in jStrs(c["extraSupported"]) where !ex.contains(where: { $0.name == n }) {
                ex.append(ExtraDesc(name: n, isRequired: jStrs(c["extraRequired"]).contains(n), options: []))
            }
            return CatalogDesc(type: t, id: cid, name: jStr(c["name"]) ?? cid, extra: ex)
        }
        configurable = ((d["behaviorHints"] as? JSON)?["configurable"] as? Bool) ?? false
    }

    func supports(_ resource: String, type: String, id: String) -> Bool {
        guard let r = resources.first(where: { $0.name == resource }) else { return false }
        let ts = r.types ?? types
        if !ts.isEmpty && !ts.contains(type) { return false }
        if let pre = r.idPrefixes ?? idPrefixes, !pre.isEmpty {
            return pre.contains { id.hasPrefix($0) }
        }
        return true
    }
}

struct Addon: Codable, Hashable, Identifiable {
    var transportUrl: String
    var manifest: Manifest
    var builtIn: Bool = false
    var id: String { transportUrl }
    var base: String {
        var s = transportUrl
        if s.hasSuffix("/manifest.json") { s.removeLast("/manifest.json".count) }
        return s
    }
}

// MARK: - Phim, tập, nguồn phát, phụ đề
struct MetaItem: Identifiable, Hashable, Codable {
    var id: String
    var type: String
    var name: String
    var poster: String?
    var background: String?
    var logo: String?
    var description: String?
    var releaseInfo: String?
    var imdbRating: String?
    var runtime: String?
    var genres: [String] = []
    var videos: [VideoItem] = []
    var defaultVideoId: String?
    var landscapePoster = false

    init?(json d: JSON) {
        guard let id = jStr(d["id"]), let name = jStr(d["name"]) else { return nil }
        self.id = id; self.name = name
        type = jStr(d["type"]) ?? "movie"
        poster = jStr(d["poster"])
        background = jStr(d["background"])
        logo = jStr(d["logo"])
        description = jStr(d["description"])
        releaseInfo = jStr(d["releaseInfo"]) ?? jStr(d["year"])
        imdbRating = jStr(d["imdbRating"])
        runtime = jStr(d["runtime"])
        genres = jStrs(d["genres"] ?? d["genre"])
        landscapePoster = jStr(d["posterShape"]) == "landscape"
        defaultVideoId = jStr((d["behaviorHints"] as? JSON)?["defaultVideoId"])
        videos = ((d["videos"] as? [JSON]) ?? []).compactMap { VideoItem(json: $0) }
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
    }
}

struct VideoItem: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var season: Int?
    var episode: Int?
    var released: String?
    var thumbnail: String?
    var overview: String?

    init?(json d: JSON) {
        guard let id = jStr(d["id"]) else { return nil }
        self.id = id
        season = jInt(d["season"])
        episode = jInt(d["episode"] ?? d["number"])
        title = jStr(d["title"]) ?? jStr(d["name"]) ?? (episode.map { "Tập \($0)" } ?? id)
        released = jStr(d["released"])
        thumbnail = jStr(d["thumbnail"])
        overview = jStr(d["overview"]) ?? jStr(d["description"])
    }
}

struct StreamItem: Identifiable {
    let id = UUID()
    var addonName: String
    var name: String?
    var title: String?
    var url: String?
    var ytId: String?
    var infoHash: String?
    var fileIdx: Int?
    var externalUrl: String?
    var trackers: [String] = []
    var filename: String?
    var videoSize: Int64?
    var videoHash: String?
    var headers: [String: String] = [:]

    init?(json d: JSON, addon: String) {
        addonName = addon
        name = jStr(d["name"])
        title = jStr(d["title"]) ?? jStr(d["description"])
        url = jStr(d["url"])
        ytId = jStr(d["ytId"])
        infoHash = jStr(d["infoHash"])?.lowercased()
        fileIdx = jInt(d["fileIdx"])
        externalUrl = jStr(d["externalUrl"])
        trackers = jStrs(d["sources"]).compactMap { $0.hasPrefix("tracker:") ? String($0.dropFirst(8)) : nil }
        let bh = d["behaviorHints"] as? JSON
        filename = jStr(bh?["filename"])
        if let n = bh?["videoSize"] as? NSNumber { videoSize = n.int64Value }
        videoHash = jStr(bh?["videoHash"])
        if let req = ((bh?["proxyHeaders"] as? JSON)?["request"]) as? [String: String] { headers = req }
        if url == nil && ytId == nil && infoHash == nil && externalUrl == nil { return nil }
    }
}

struct SubItem: Identifiable, Hashable {
    var id: String
    var url: String
    var lang: String
    var label: String?
    var addonName: String

    var langName: String { SubItem.langNames[lang.lowercased()] ?? lang }
    var isVietnamese: Bool { ["vie", "vi", "vietnamese", "tiếng việt"].contains(lang.lowercased()) }
    var isMachine: Bool { (label ?? "").lowercased().contains("dịch máy") || id.contains("-tr-") }

    static let langNames: [String: String] = [
        "vie": "Tiếng Việt", "vi": "Tiếng Việt", "eng": "Tiếng Anh", "en": "Tiếng Anh",
        "chi": "Tiếng Trung", "zho": "Tiếng Trung", "zh": "Tiếng Trung", "kor": "Tiếng Hàn", "ko": "Tiếng Hàn",
        "jpn": "Tiếng Nhật", "ja": "Tiếng Nhật", "fre": "Tiếng Pháp", "fra": "Tiếng Pháp", "spa": "Tiếng Tây Ban Nha",
        "tha": "Tiếng Thái", "ind": "Tiếng Indonesia", "rus": "Tiếng Nga", "ger": "Tiếng Đức", "deu": "Tiếng Đức",
        "por": "Tiếng Bồ Đào Nha", "pob": "Tiếng Bồ Đào Nha (BR)", "ita": "Tiếng Ý", "ara": "Tiếng Ả Rập"
    ]
}

/// Mục "Đang xem"
struct RecentItem: Codable, Hashable, Identifiable {
    var id: String
    var type: String
    var name: String
    var poster: String?
    var addonUrl: String?
    var videoId: String?
    var videoTitle: String?
    var position: Double = 0
    var duration: Double = 0
    var updated = Date()
}

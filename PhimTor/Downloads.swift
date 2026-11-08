import Foundation
import SwiftUI
import Phimengine

/// Một phim tải về máy
struct DownloadRecord: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case torrent, http }
    enum State: String, Codable { case waiting, downloading, paused, done, failed }

    var id = UUID().uuidString
    var kind: Kind
    var title: String              // tên hiển thị (phim – tập)
    var metaId: String
    var type: String
    var name: String               // tên phim
    var poster: String?
    var addonUrl: String?
    var videoId: String
    var videoTitle: String?
    var source: String = ""        // tên nguồn phát (1080p, 4K…)
    // torrent
    var hash: String?
    var fileIdx: Int?
    var hint: String?
    var trackers: [String] = []
    var jobId: String?
    // link http
    var url: String?
    var headers: [String: String] = [:]
    // chung
    var path: String?              // file trong máy khi xong (đường dẫn tương đối với thư mục tải)
    var fileName: String?
    var done: Int64 = 0
    var total: Int64 = 0
    var speed: Int64 = 0           // byte/giây
    var peers: Int = 0
    var state: State = .waiting
    var error: String?
    var videoSize: Int64?
    var videoHash: String?
    var created = Date()

    var progress: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
}

/// Quản lý tải phim: torrent (bộ tải trong app) hoặc link HTTP (link trực tiếp / TorBox).
/// Mọi thao tác chạy trên luồng chính (hẹn giờ, phiên tải và giao diện đều ở luồng chính).
final class Downloads: NSObject, ObservableObject {
    static let shared = Downloads()

    @Published private(set) var items: [DownloadRecord] = []
    private var tick: Timer?
    private var tasks: [Int: String] = [:]          // URLSessionTask id → record id
    private var lastBytes: [String: (Int64, Date)] = [:]
    var backgroundCompletion: (() -> Void)?

    /// Thư mục lưu phim tải về
    static let dir: URL = {
        #if os(iOS)
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("PhimTor", isDirectory: true)
        #endif
        let d = base.appendingPathComponent("Phim tải về", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    /// Dữ liệu torrent đang tải dở (bộ tải tự quản lý, nằm trong thư mục tải)
    static var torrentDir: URL { dir }

    private lazy var session: URLSession = {
        #if os(iOS)
        let c = URLSessionConfiguration.background(withIdentifier: "com.thayphong.phimtor.downloads")
        c.sessionSendsLaunchEvents = true
        #else
        let c = URLSessionConfiguration.default
        #endif
        c.isDiscretionary = false
        c.allowsCellularAccess = true
        c.timeoutIntervalForRequest = 60
        return URLSession(configuration: c, delegate: self, delegateQueue: .main)
    }()

    override init() {
        super.init()
        if let d = UserDefaults.standard.data(forKey: "downloads"), let v = try? JSONDecoder().decode([DownloadRecord].self, from: d) { items = v }
        // nối lại các link HTTP đang tải (phiên tải nền của iPhone)
        session.getAllTasks { ts in
            DispatchQueue.main.async {
                for t in ts { if let rid = t.taskDescription { self.tasks[t.taskIdentifier] = rid } }
                // Torrent đang tải dở: tiếp tục
                for r in self.items where r.kind == .torrent && (r.state == .downloading || r.state == .waiting) { self.startTorrent(r.id) }
                for r in self.items where r.kind == .http && (r.state == .downloading || r.state == .waiting) && !self.tasks.values.contains(r.id) {
                    self.startHTTP(r.id)
                }
                self.ensureTick()
            }
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: "downloads") }
    }

    private func update(_ id: String, _ f: (inout DownloadRecord) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        f(&items[i])
    }

    func record(_ id: String) -> DownloadRecord? { items.first { $0.id == id } }

    /// Phim (theo videoId) đã tải xong chưa
    func doneRecord(videoId: String) -> DownloadRecord? { items.first { $0.videoId == videoId && $0.state == .done } }

    func fileURL(_ r: DownloadRecord) -> URL? {
        guard let p = r.path else { return nil }
        let u = p.hasPrefix("/") ? URL(fileURLWithPath: p) : Self.dir.appendingPathComponent(p)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    // MARK: Thêm

    /// Bắt đầu tải một nguồn phát. Trả về lời báo cho người dùng.
    @MainActor func add(_ s: StreamItem, link: StreamLink) async -> String {
        if items.contains(where: { $0.videoId == link.videoId && $0.source == (s.name ?? "") && ($0.title == link.title) && $0.state != .failed }) {
            return "Nguồn này đã có trong Tải về"
        }
        var r = DownloadRecord(kind: .http, title: link.title, metaId: link.meta.id, type: link.meta.type, name: link.meta.name,
                               poster: link.meta.poster, addonUrl: link.addonUrl, videoId: link.videoId,
                               videoTitle: link.episode != nil ? link.title : nil)
        r.source = [s.name, s.title?.components(separatedBy: "\n").first].compactMap { $0 }.joined(separator: " · ")
        r.videoSize = s.videoSize; r.videoHash = s.videoHash; r.fileName = s.filename
        if let u = s.url, u.hasPrefix("http") {
            r.url = u; r.headers = s.headers
        } else {
            var hash = s.infoHash
            if hash == nil, let u = s.url, u.hasPrefix("magnet:"), let rg = u.range(of: "btih:") {
                hash = String(u[rg.upperBound...].prefix { $0.isLetter || $0.isNumber }).lowercased()
            }
            guard let h = hash else { return "Nguồn này không tải về được" }
            // Có TorBox và phim có sẵn → tải bằng link HTTP của TorBox (nhanh, tải nền được)
            let key = AddonStore.shared.torboxKey.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, await TorBox.isCached(h, key: key),
               let u = try? await TorBox.link(hash: h, trackers: s.trackers, fileIdx: s.fileIdx, hint: s.filename,
                                              season: link.season, episode: link.episode, key: key) {
                r.url = u.absoluteString
            } else {
                r.kind = .torrent; r.hash = h; r.fileIdx = s.fileIdx; r.hint = s.fileIdx == nil ? s.filename : nil; r.trackers = s.trackers
            }
        }
        items.insert(r, at: 0)
        save()
        if r.kind == .torrent { startTorrent(r.id) } else { startHTTP(r.id) }
        ensureTick()
        #if os(iOS)
        return r.kind == .torrent ? "Đã thêm vào Tải về. Tải torrent cần để app mở." : "Đã thêm vào Tải về"
        #else
        return "Đã thêm vào Tải về"
        #endif
    }

    // MARK: Torrent

    private func startTorrent(_ id: String) {
        guard let r = record(id), let h = r.hash, TorrentEngine.shared.start() else {
            update(id) { $0.state = .failed; $0.error = "Không khởi động được bộ tải torrent" }; save(); return
        }
        var magnet = "magnet:?xt=urn:btih:\(h)"
        for t in r.trackers { magnet += "&tr=" + AddonStore.enc(t) }
        let job = PhimengineStartDownload(magnet, r.fileIdx ?? -1, r.hint ?? "", Self.torrentDir.path)
        if job.isEmpty {
            update(id) { $0.state = .failed; $0.error = TorrentEngine.shared.lastError }
        } else {
            update(id) { $0.jobId = job; $0.state = .downloading; $0.error = nil }
        }
        save()
    }

    private struct TStatus: Decodable { var state: String; var name: String?; var path: String?; var done: Int64?; var total: Int64?; var peers: Int?; var error: String? }

    private func pollTorrents() {
        for r in items where r.kind == .torrent && r.state == .downloading {
            guard let job = r.jobId, let s = try? JSONDecoder().decode(TStatus.self, from: Data(PhimengineDownloadStatus(job).utf8)) else { continue }
            update(r.id) { x in
                x.peers = s.peers ?? 0
                if let t = s.total, t > 0 { x.total = t }
                if let d = s.done { speedCalc(&x, d); x.done = d }
                if let n = s.name, !n.isEmpty { x.fileName = n }
                switch s.state {
                case "done":
                    x.state = .done; x.speed = 0
                    if let p = s.path { x.path = p.hasPrefix(Self.dir.path + "/") ? String(p.dropFirst(Self.dir.path.count + 1)) : p }
                case "error": x.state = .failed; x.error = s.error
                case "none": startTorrentLater(x.id)
                default: break
                }
            }
        }
    }

    private func startTorrentLater(_ id: String) { DispatchQueue.main.async { self.startTorrent(id) } }

    private func speedCalc(_ x: inout DownloadRecord, _ d: Int64) {
        let now = Date()
        if let (b, t) = lastBytes[x.id], now.timeIntervalSince(t) >= 0.8 {
            x.speed = max(0, Int64(Double(d - b) / now.timeIntervalSince(t)))
            lastBytes[x.id] = (d, now)
        } else if lastBytes[x.id] == nil { lastBytes[x.id] = (d, now) }
    }

    // MARK: HTTP

    private func startHTTP(_ id: String) {
        guard let r = record(id), let s = r.url, let u = URL(string: s) else { return }
        var req = URLRequest(url: u)
        for (k, v) in r.headers { req.setValue(v, forHTTPHeaderField: k) }
        let t = session.downloadTask(with: req)
        t.taskDescription = id
        tasks[t.taskIdentifier] = id
        t.resume()
        update(id) { $0.state = .downloading; $0.error = nil }
        save()
    }

    // MARK: Điều khiển

    func pause(_ id: String) {
        guard let r = record(id) else { return }
        if r.kind == .torrent, let j = r.jobId { PhimenginePauseDownload(j) }
        if r.kind == .http {
            session.getAllTasks { ts in ts.filter { $0.taskDescription == id }.forEach { $0.cancel() } }
        }
        update(id) { $0.state = .paused; $0.speed = 0 }
        save()
    }

    func resume(_ id: String) {
        guard let r = record(id) else { return }
        if r.kind == .torrent { startTorrent(id) } else { update(id) { $0.done = 0 }; startHTTP(id) }
        ensureTick()
    }

    func delete(_ id: String) {
        guard let r = record(id) else { return }
        if r.kind == .torrent {
            let p = r.path.map { $0.hasPrefix("/") ? $0 : Self.dir.appendingPathComponent($0).path } ?? ""
            if let j = r.jobId { PhimengineCancelDownload(j, p) }
            if !p.isEmpty { try? FileManager.default.removeItem(atPath: p) }
        } else {
            session.getAllTasks { ts in ts.filter { $0.taskDescription == id }.forEach { $0.cancel() } }
            if let u = fileURL(r) { try? FileManager.default.removeItem(at: u) }
        }
        items.removeAll { $0.id == id }
        save()
    }

    private func ensureTick() {
        guard tick == nil else { return }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pollTorrents()
            if !self.items.contains(where: { $0.state == .downloading || $0.state == .waiting }) {
                self.tick?.invalidate(); self.tick = nil
            }
            self.save()
        }
    }

    static var freeSpace: Int64 {
        (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
    }
}

extension Downloads: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let rid = downloadTask.taskDescription
        guard let rid else { return }
        update(rid) { x in
            speedCalc(&x, totalBytesWritten)
            x.done = totalBytesWritten
            if totalBytesExpectedToWrite > 0 { x.total = totalBytesExpectedToWrite }
            x.state = .downloading
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // file tạm bị xoá ngay sau hàm này → chuyển đi luôn
        guard let rid = downloadTask.taskDescription else { return }
        let suggested = downloadTask.response?.suggestedFilename
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard let r = record(rid) else { return }
        if status >= 400 {
            update(rid) { $0.state = .failed; $0.error = "Máy chủ báo lỗi \(status)" }; save()
            return
        }
        var name = r.fileName ?? suggested ?? r.title
        if (name as NSString).pathExtension.isEmpty { name += "." + (((suggested ?? "") as NSString).pathExtension.isEmpty ? "mp4" : (suggested! as NSString).pathExtension) }
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var dest = Downloads.dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            dest = Downloads.dir.appendingPathComponent("\(r.id.prefix(6))-" + name)
        }
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            let rel = dest.lastPathComponent
            update(rid) { $0.state = .done; $0.path = rel; $0.speed = 0; if $0.total == 0 { $0.total = $0.done }; $0.done = max($0.done, $0.total) }
            save()
        } catch {
            update(rid) { $0.state = .failed; $0.error = error.localizedDescription }; save()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let rid = task.taskDescription else { return }
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        if let r = record(rid), r.state != .paused, !cancelled {
            update(rid) { $0.state = .failed; $0.error = error.localizedDescription; $0.speed = 0 }
            save()
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        backgroundCompletion?(); backgroundCompletion = nil
    }
}

func formatBytes(_ b: Int64) -> String {
    let f = ByteCountFormatter(); f.countStyle = .file
    return f.string(fromByteCount: b)
}

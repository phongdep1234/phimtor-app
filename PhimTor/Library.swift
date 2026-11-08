import SwiftUI

// MARK: - Thẻ Yêu thích
struct FavoritesView: View {
    @EnvironmentObject var store: AddonStore
    @State private var filter = "all"

    var list: [FavItem] { store.favorites.filter { filter == "all" || $0.type == filter } }

    var body: some View {
        ScrollView {
            if store.favorites.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "heart").font(.system(size: 44)).foregroundColor(.pink)
                    Text("Chưa có phim yêu thích").font(.headline)
                    Text("Mở một phim rồi bấm nút ♥ (hoặc giữ / chuột phải vào thẻ phim → Thêm vào Yêu thích).")
                        .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                }
                .padding(40).frame(maxWidth: .infinity)
            } else {
                HStack {
                    chip("Tất cả", "all"); chip("Phim lẻ", "movie"); chip("Phim bộ", "series")
                    Spacer()
                }.padding(.horizontal)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 12)], spacing: 16) {
                    ForEach(list) { f in
                        NavigationLink(value: MetaLink(item: f.meta, addonUrl: f.addonUrl)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Poster(url: f.poster, width: 105)
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: "heart.fill").font(.caption.bold()).foregroundColor(.pink)
                                            .padding(5).background(Color.black.opacity(0.55), in: Circle()).padding(4)
                                    }
                                Text(f.name).font(.caption).lineLimit(2).frame(width: 105, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { store.favorites.removeAll { $0.id == f.id } } label: { Label("Bỏ Yêu thích", systemImage: "heart.slash") }
                        }
                    }
                }.padding()
            }
        }
        .navigationTitle("Yêu thích")
        .navigationDestination(for: MetaLink.self) { l in DetailView(seed: l.item, addonUrl: l.addonUrl) }
    }

    func chip(_ t: String, _ v: String) -> some View {
        Button { filter = v } label: {
            Text(t).font(.subheadline).padding(.horizontal, 12).padding(.vertical, 6)
                .background(filter == v ? Color.yellow : Color.white.opacity(0.1)).foregroundColor(filter == v ? .black : .primary).cornerRadius(14)
        }.buttonStyle(.plain)
    }
}

// MARK: - Thẻ Tải về
struct DownloadsView: View {
    @ObservedObject private var dl = Downloads.shared
    @State private var playing: Target?
    @State private var confirmDelete: DownloadRecord?

    struct Target: Identifiable { let id = UUID(); let rec: DownloadRecord; let src: ResolvedSource }

    var body: some View {
        List {
            if dl.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 44)).foregroundColor(.yellow)
                    Text("Chưa có phim tải về").font(.headline)
                    Text("Mở một phim → Chọn nguồn phát → bấm nút vàng \"Tải về\" bên phải nguồn muốn tải.")
                        .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                }
                .padding(30).frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            ForEach(dl.items) { r in
                row(r)
                    .contentShape(Rectangle())
                    .onTapGesture { play(r) }
                    .swipeActions {
                        Button(role: .destructive) { confirmDelete = r } label: { Label("Xoá", systemImage: "trash") }
                    }
                    .contextMenu {
                        Button { play(r) } label: { Label(r.state == .done ? "Xem" : "Xem ngay (đang tải)", systemImage: "play.fill") }
                        if r.state == .downloading || r.state == .waiting {
                            Button { dl.pause(r.id) } label: { Label("Tạm dừng", systemImage: "pause.fill") }
                        }
                        if r.state == .paused || r.state == .failed {
                            Button { dl.resume(r.id) } label: { Label("Tải tiếp", systemImage: "arrow.clockwise") }
                        }
                        #if os(macOS)
                        if let u = dl.fileURL(r) { Button { NSWorkspace.shared.activateFileViewerSelecting([u]) } label: { Label("Hiện trong Finder", systemImage: "folder") } }
                        #endif
                        Button(role: .destructive) { confirmDelete = r } label: { Label("Xoá", systemImage: "trash") }
                    }
            }
            if !dl.items.isEmpty {
                Section {
                    Text("Còn trống: \(formatBytes(Downloads.freeSpace))").font(.footnote).foregroundColor(.secondary)
                    #if os(iOS)
                    Text("Phim tải bằng link trực tiếp / TorBox vẫn tải khi tắt app. Phim tải bằng torrent cần để app mở (máy không khoá màn hình).")
                        .font(.footnote).foregroundColor(.secondary)
                    #else
                    Text("Phim lưu ở thư mục Phim (Movies) › PhimTor › Phim tải về.").font(.footnote).foregroundColor(.secondary)
                    #endif
                }
            }
        }
        .navigationTitle("Tải về")
        #if os(iOS)
        .fullScreenCover(item: $playing) { t in player(t) }
        #else
        .onChange(of: playing?.id) { _ in
            if let t = playing { PlayerWindow.open(title: t.rec.title, player(t)); playing = nil }
        }
        #endif
        .confirmationDialog("Xoá phim tải về?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Xoá \"\(confirmDelete?.title ?? "")\"", role: .destructive) { if let r = confirmDelete { dl.delete(r.id) }; confirmDelete = nil }
            Button("Huỷ", role: .cancel) { confirmDelete = nil }
        } message: { Text("File đã tải sẽ bị xoá khỏi máy.") }
    }

    @ViewBuilder func row(_ r: DownloadRecord) -> some View {
        HStack(spacing: 12) {
            Poster(url: r.poster, width: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(r.title).font(.subheadline.bold()).lineLimit(2)
                if !r.source.isEmpty { Text(r.source).font(.caption2).foregroundColor(.secondary).lineLimit(1) }
                if r.state != .done { ProgressView(value: r.progress).tint(r.state == .failed ? .red : .yellow) }
                Text(status(r)).font(.caption).foregroundColor(r.state == .failed ? .red : .secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            actionButton(r)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder func actionButton(_ r: DownloadRecord) -> some View {
        switch r.state {
        case .done:
            bigButton("play.fill", .yellow) { play(r) }
        case .downloading, .waiting:
            bigButton("pause.fill", .white.opacity(0.2)) { dl.pause(r.id) }
        case .paused, .failed:
            bigButton("arrow.down", .yellow) { dl.resume(r.id) }
        }
    }

    func bigButton(_ icon: String, _ bg: Color, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Image(systemName: icon).font(.system(size: 20, weight: .bold))
                .foregroundColor(bg == .yellow ? .black : .white)
                .frame(width: 48, height: 48).background(bg, in: Circle())
        }
        .buttonStyle(.borderless)
    }

    func status(_ r: DownloadRecord) -> String {
        let size = r.total > 0 ? "\(formatBytes(r.done)) / \(formatBytes(r.total))" : (r.done > 0 ? formatBytes(r.done) : "")
        switch r.state {
        case .done: return "Đã tải xong · \(formatBytes(r.total)) · bấm để xem"
        case .waiting: return "Đang chờ…"
        case .paused: return "Tạm dừng · \(size)"
        case .failed: return "Lỗi: \(r.error ?? "không tải được") · bấm ↓ để thử lại"
        case .downloading:
            if r.kind == .torrent && r.total == 0 { return "Đang tìm nguồn chia sẻ… (\(r.peers) kết nối)" }
            var s = "\(Int(r.progress * 100))% · \(size)"
            if r.speed > 0 {
                s += " · \(formatBytes(r.speed))/s"
                if r.total > r.done { let sec = Int(Double(r.total - r.done) / Double(r.speed)); s += " · còn " + (sec >= 3600 ? "\(sec / 3600) giờ \((sec % 3600) / 60) phút" : "\(max(1, sec / 60)) phút") }
            }
            if r.kind == .torrent { s += " · \(r.peers) kết nối" }
            return s
        }
    }

    func play(_ r: DownloadRecord) {
        if let u = dl.fileURL(r) {
            playing = Target(rec: r, src: ResolvedSource(url: u, headers: [:], torrentHash: nil, via: "Đã tải về máy"))
        } else if r.kind == .torrent, let h = r.hash,
                  let u = TorrentEngine.shared.streamURL(hash: h, fileIdx: r.fileIdx, trackers: r.trackers, hint: r.hint) {
            playing = Target(rec: r, src: ResolvedSource(url: u, headers: [:], torrentHash: h, via: "Đang tải về · xem trong khi tải"))
        } else if let s = r.url, let u = URL(string: s) {
            playing = Target(rec: r, src: ResolvedSource(url: u, headers: r.headers, torrentHash: nil, via: "Link trực tiếp"))
        }
    }

    func player(_ t: Target) -> PlayerView {
        let r = t.rec
        var hints: [String: Any] = [:]
        if let f = r.fileName { hints["filename"] = f }
        if let v = r.videoSize { hints["videoSize"] = NSNumber(value: v) }
        if let h = r.videoHash { hints["videoHash"] = h }
        let stream = StreamItem(json: ["url": t.src.url.absoluteString, "name": r.source, "behaviorHints": hints], addon: "Tải về")!
        return PlayerView(title: r.title, source: t.src, type: r.type, videoId: r.videoId, stream: stream,
                          recent: RecentItem(id: r.metaId, type: r.type, name: r.name, poster: r.poster, addonUrl: r.addonUrl,
                                             videoId: r.videoId, videoTitle: r.videoTitle))
    }
}

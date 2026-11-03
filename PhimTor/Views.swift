import SwiftUI

// MARK: - Ứng dụng
@main
struct PhimTorApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    #endif
    @StateObject private var store = AddonStore.shared
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).preferredColorScheme(.dark).tint(.yellow)
            #if os(macOS)
                .frame(minWidth: 900, minHeight: 600)
            #endif
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        #endif
    }
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Orientation.mask
    }
}
#endif

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { HomeView() }.tabItem { Label("Khám phá", systemImage: "film") }
            NavigationStack { SearchView() }.tabItem { Label("Tìm kiếm", systemImage: "magnifyingglass") }
            NavigationStack { AddonsView() }.tabItem { Label("Add-on", systemImage: "puzzlepiece.extension") }
            NavigationStack { SettingsView() }.tabItem { Label("Cài đặt", systemImage: "gearshape") }
        }
    }
}

// MARK: - Ảnh poster
struct Poster: View {
    let url: String?
    var landscape = false
    var width: CGFloat = 112
    var body: some View {
        let h = landscape ? width * 9 / 16 : width * 1.5
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill()
            default: Rectangle().fill(Color.white.opacity(0.08)).overlay(Image(systemName: "film").foregroundColor(.gray))
            }
        }
        .frame(width: width, height: h).clipped().cornerRadius(8)
    }
}

struct MetaCard: View {
    let item: MetaItem
    var width: CGFloat = 112
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Poster(url: item.poster, landscape: item.landscapePoster, width: width)
            Text(item.name).font(.caption).lineLimit(2).frame(width: width, alignment: .leading)
        }
    }
}

struct MetaLink: Hashable {
    var item: MetaItem
    var addonUrl: String?
}

// MARK: - Trang chủ
struct HomeView: View {
    @EnvironmentObject var store: AddonStore

    var rows: [(Addon, CatalogDesc)] {
        store.addons.flatMap { a in a.manifest.catalogs.filter { !$0.needsSomething }.map { (a, $0) } }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if !store.recents.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Đang xem").font(.title3.bold()).padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(store.recents) { r in
                                    NavigationLink(value: r) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Poster(url: r.poster)
                                            if r.duration > 0 {
                                                ProgressView(value: min(r.position / r.duration, 1)).tint(.yellow).frame(width: 112)
                                            }
                                            Text(r.videoTitle ?? r.name).font(.caption).lineLimit(2).frame(width: 112, alignment: .leading)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu { Button("Xoá khỏi Đang xem", role: .destructive) { store.recents.removeAll { $0.id == r.id } } }
                                }
                            }.padding(.horizontal)
                        }
                    }
                }
                if rows.isEmpty {
                    Text("Chưa có danh mục phim nào. Vào tab Add-on để thêm add-on.").foregroundColor(.secondary).padding()
                }
                ForEach(rows, id: \.1.uid) { a, c in
                    CatalogRow(addon: a, catalog: c)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("PhimTor")
        .navigationDestination(for: MetaLink.self) { l in DetailView(seed: l.item, addonUrl: l.addonUrl) }
        .navigationDestination(for: RecentItem.self) { r in
            DetailView(seed: MetaItem(json: ["id": r.id, "type": r.type, "name": r.name, "poster": r.poster as Any])!, addonUrl: r.addonUrl)
        }
        .navigationDestination(for: CatalogLink.self) { l in CatalogGrid(link: l) }
        .refreshable { await store.ensureBuiltIns() }
    }
}

struct CatalogLink: Hashable {
    var addonUrl: String
    var catalog: CatalogDesc
    var title: String
}

struct CatalogRow: View {
    let addon: Addon
    let catalog: CatalogDesc
    @EnvironmentObject var store: AddonStore
    @State private var items: [MetaItem] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if !loaded || !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    NavigationLink(value: CatalogLink(addonUrl: addon.transportUrl, catalog: catalog, title: catalog.name)) {
                        HStack {
                            Text(catalog.name).font(.title3.bold()).foregroundColor(.primary).lineLimit(1)
                            Text(catalog.type == "movie" ? "Phim lẻ" : catalog.type == "series" ? "Phim bộ" : catalog.type)
                                .font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            if !loaded { ForEach(0..<5, id: \.self) { _ in Poster(url: nil) } }
                            ForEach(items) { m in
                                NavigationLink(value: MetaLink(item: m, addonUrl: addon.transportUrl)) { MetaCard(item: m) }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal)
                    }
                }
            }
        }
        .task {
            guard !loaded else { return }
            items = await store.catalog(addon, catalog)
            loaded = true
        }
    }
}

struct CatalogGrid: View {
    let link: CatalogLink
    @EnvironmentObject var store: AddonStore
    @State private var items: [MetaItem] = []
    @State private var loading = false
    @State private var end = false
    @State private var genre: String?

    var addon: Addon? { store.addons.first { $0.transportUrl == link.addonUrl } }

    var body: some View {
        ScrollView {
            if !link.catalog.genres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        chip("Tất cả", genre == nil) { genre = nil; reload() }
                        ForEach(link.catalog.genres, id: \.self) { g in chip(g, genre == g) { genre = g; reload() } }
                    }.padding(.horizontal)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 12)], spacing: 16) {
                ForEach(items) { m in
                    NavigationLink(value: MetaLink(item: m, addonUrl: link.addonUrl)) { MetaCard(item: m, width: 105) }.buttonStyle(.plain)
                        .onAppear { if m.id == items.last?.id { more() } }
                }
            }.padding()
            if loading { ProgressView().padding() }
        }
        .navigationTitle(link.title)
        .task { if items.isEmpty { more() } }
    }

    func chip(_ t: String, _ on: Bool, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(.subheadline).padding(.horizontal, 12).padding(.vertical, 6)
                .background(on ? Color.yellow : Color.white.opacity(0.1)).foregroundColor(on ? .black : .primary).cornerRadius(14)
        }
    }

    func reload() { items = []; end = false; more() }

    func more() {
        guard !loading, !end, let a = addon else { return }
        loading = true
        Task {
            var ex: [(String, String)] = []
            if let g = genre { ex.append(("genre", g)) }
            if !items.isEmpty { ex.append(("skip", String(items.count))) }
            let n = await store.catalog(a, link.catalog, extra: ex)
            let fresh = n.filter { x in !items.contains { $0.id == x.id } }
            if fresh.isEmpty { end = true }
            items += fresh
            loading = false
        }
    }
}

// MARK: - Tìm kiếm
struct SearchView: View {
    @EnvironmentObject var store: AddonStore
    @State private var q = ""
    @State private var results: [(String, String, [MetaItem])] = [] // (tên danh mục, addonUrl, phim)
    @State private var searching = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if searching { ProgressView().frame(maxWidth: .infinity).padding() }
                if !searching && results.isEmpty && !q.isEmpty { Text("Không tìm thấy.").foregroundColor(.secondary).padding() }
                ForEach(results, id: \.0) { r in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(r.0).font(.headline).padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(r.2) { m in
                                    NavigationLink(value: MetaLink(item: m, addonUrl: r.1)) { MetaCard(item: m) }.buttonStyle(.plain)
                                }
                            }.padding(.horizontal)
                        }
                    }
                }
            }.padding(.vertical)
        }
        .navigationTitle("Tìm kiếm")
        .alwaysSearchable($q, prompt: "Tên phim, phim bộ…")
        .onSubmit(of: .search) { run() }
        .navigationDestination(for: MetaLink.self) { l in DetailView(seed: l.item, addonUrl: l.addonUrl) }
    }

    func run() {
        let query = q.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        searching = true
        results = []
        Task {
            let cats = store.addons.flatMap { a in a.manifest.catalogs.filter { $0.supportsSearch }.map { (a, $0) } }
            var out: [(Int, (String, String, [MetaItem]))] = []
            await withTaskGroup(of: (Int, (String, String, [MetaItem])).self) { g in
                for (i, (a, c)) in cats.enumerated() {
                    g.addTask {
                        let r = await store.catalog(a, c, extra: [("search", query)])
                        let label = "\(c.name) · \(a.manifest.name)"
                        return (i, (label, a.transportUrl, r))
                    }
                }
                for await r in g where !r.1.2.isEmpty { out.append(r) }
            }
            results = out.sorted { $0.0 < $1.0 }.map { $0.1 }
            searching = false
        }
    }
}

// MARK: - Chi tiết phim
struct DetailView: View {
    let seed: MetaItem
    let addonUrl: String?
    @EnvironmentObject var store: AddonStore
    @State private var meta: MetaItem?
    @State private var season: Int = 1
    @State private var loading = true
    @State private var showDesc = false

    var m: MetaItem { meta ?? seed }
    var seasons: [Int] { Array(Set(m.videos.compactMap { $0.season })).sorted { ($0 == 0 ? 999 : $0) < ($1 == 0 ? 999 : $1) } }
    var episodes: [VideoItem] { seasons.isEmpty ? m.videos : m.videos.filter { ($0.season ?? 0) == season } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ZStack(alignment: .bottomLeading) {
                    AsyncImage(url: (m.background ?? m.poster).flatMap(URL.init(string:))) { p in
                        if case .success(let i) = p { i.resizable().scaledToFill() } else { Color.white.opacity(0.05) }
                    }
                    .frame(height: 220).frame(maxWidth: .infinity).clipped()
                    .overlay(LinearGradient(colors: [.clear, .black], startPoint: .center, endPoint: .bottom))
                    HStack(alignment: .bottom, spacing: 12) {
                        Poster(url: m.poster, width: 96)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(m.name).font(.title2.bold()).lineLimit(3)
                            Text([m.releaseInfo, m.runtime, m.imdbRating.map { "⭐️ \($0)" }].compactMap { $0 }.joined(separator: " • "))
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }.padding()
                }
                if !m.genres.isEmpty { Text(m.genres.prefix(4).joined(separator: " · ")).font(.caption).foregroundColor(.secondary).padding(.horizontal) }
                if let d = m.description {
                    Text(d).font(.subheadline).lineLimit(showDesc ? nil : 4).padding(.horizontal)
                        .onTapGesture { showDesc.toggle() }
                }

                if loading { ProgressView().frame(maxWidth: .infinity) }

                if m.videos.isEmpty || (m.type == "movie" && m.videos.count <= 1) {
                    NavigationLink(value: StreamLink(type: m.type, videoId: m.defaultVideoId ?? m.videos.first?.id ?? m.id, title: m.name, meta: m, addonUrl: addonUrl, season: nil, episode: nil)) {
                        Label("Chọn nguồn phát", systemImage: "play.fill").font(.headline)
                            .frame(maxWidth: .infinity).padding().background(Color.yellow).foregroundColor(.black).cornerRadius(10)
                    }.padding(.horizontal)
                } else {
                    if seasons.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(seasons, id: \.self) { s in
                                    Button { season = s } label: {
                                        Text(s == 0 ? "Phụ" : "Mùa \(s)").padding(.horizontal, 14).padding(.vertical, 7)
                                            .background(season == s ? Color.yellow : Color.white.opacity(0.1))
                                            .foregroundColor(season == s ? .black : .primary).cornerRadius(16)
                                    }
                                }
                            }.padding(.horizontal)
                        }
                    }
                    LazyVStack(spacing: 10) {
                        ForEach(episodes) { v in
                            NavigationLink(value: StreamLink(type: m.type, videoId: v.id, title: "\(m.name) – \(epLabel(v))", meta: m, addonUrl: addonUrl, season: v.season, episode: v.episode)) {
                                HStack(spacing: 12) {
                                    if let t = v.thumbnail { Poster(url: t, landscape: true, width: 120) }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(epLabel(v)).font(.subheadline.bold()).foregroundColor(.primary)
                                        if let o = v.overview { Text(o).font(.caption).foregroundColor(.secondary).lineLimit(2) }
                                    }
                                    Spacer()
                                    if store.position(for: v.id) > 30 { Image(systemName: "clock.arrow.circlepath").foregroundColor(.yellow) }
                                }
                            }
                        }
                    }.padding(.horizontal)
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        .inlineTitle()
        .navigationDestination(for: StreamLink.self) { l in StreamsView(link: l) }
        .task {
            if meta == nil { meta = await store.meta(type: seed.type, id: seed.id, preferred: addonUrl) }
            loading = false
            if let first = seasons.first(where: { $0 > 0 }) ?? seasons.first { season = first }
        }
    }

    func epLabel(_ v: VideoItem) -> String {
        if let e = v.episode {
            let t = v.title.hasPrefix("Tập") || v.title.lowercased().hasPrefix("episode") ? "" : " · \(v.title)"
            return "Tập \(e)\(t)"
        }
        return v.title
    }
}

struct StreamLink: Hashable {
    var type: String
    var videoId: String
    var title: String
    var meta: MetaItem
    var addonUrl: String?
    var season: Int?
    var episode: Int?
}

// MARK: - Danh sách nguồn phát
struct StreamsView: View {
    let link: StreamLink
    @EnvironmentObject var store: AddonStore
    @State private var groups: [(String, [StreamItem])] = []
    @State private var done = false
    @State private var resolving: UUID?
    @State private var playing: PlayTarget?
    @State private var errorText: String?
    @State private var filter = ""

    struct PlayTarget: Identifiable { let id = UUID(); let src: ResolvedSource; let stream: StreamItem }

    var body: some View {
        List {
            if !done { HStack { ProgressView(); Text("Đang hỏi các add-on…").foregroundColor(.secondary) } }
            if done && groups.allSatisfy({ $0.1.isEmpty }) {
                Text("Không có nguồn phát nào. Hãy cài thêm add-on có nguồn phim (stream).").foregroundColor(.secondary)
            }
            ForEach(groups, id: \.0) { g in
                if !g.1.isEmpty {
                    Section("\(g.0) (\(g.1.count))") {
                        ForEach(g.1.filter { filter.isEmpty || (($0.name ?? "") + ($0.title ?? "")).localizedCaseInsensitiveContains(filter) }) { s in
                            Button { play(s) } label: { row(s) }.disabled(resolving != nil)
                        }
                    }
                }
            }
        }
        .navigationTitle(link.title)
        .inlineTitle()
        .searchable(text: $filter, prompt: "Lọc: 1080p, 4K, vietsub…")
        .task {
            guard groups.isEmpty else { return }
            await store.streams(type: link.type, id: link.videoId) { name, s in
                Task { @MainActor in groups.append((name, s)) }
            }
            done = true
        }
        #if os(iOS)
        .fullScreenCover(item: $playing) { t in playerView(t) }
        #else
        .onChange(of: playing?.id) { _ in
            if let t = playing { PlayerWindow.open(title: link.title, playerView(t)); playing = nil }
        }
        #endif
        .alert("Không phát được", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        } message: { Text(errorText ?? "") }
    }

    func playerView(_ t: PlayTarget) -> PlayerView {
        PlayerView(title: link.title, source: t.src, type: link.type, videoId: link.videoId, stream: t.stream,
                   recent: RecentItem(id: link.meta.id, type: link.meta.type, name: link.meta.name, poster: link.meta.poster,
                                      addonUrl: link.addonUrl, videoId: link.videoId,
                                      videoTitle: link.episode != nil ? link.title : nil))
    }

    func row(_ s: StreamItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if let n = s.name { Text(n).font(.subheadline.bold()).foregroundColor(.yellow).lineLimit(3) }
                if let t = s.title { Text(t).font(.caption).foregroundColor(.primary.opacity(0.85)).lineLimit(5) }
            }
            Spacer()
            if resolving == s.id { ProgressView() }
            else { Image(systemName: s.infoHash != nil || (s.url ?? "").hasPrefix("magnet:") ? "arrow.down.circle" : "play.circle").foregroundColor(.secondary) }
        }
        .padding(.vertical, 2)
    }

    func play(_ s: StreamItem) {
        if let yt = s.ytId, let u = URL(string: "https://www.youtube.com/watch?v=\(yt)") { Plat.open(u); return }
        if s.url == nil && s.infoHash == nil, let e = s.externalUrl, let u = URL(string: e) { Plat.open(u); return }
        resolving = s.id
        Task {
            do {
                let r = try await Resolver.resolve(s, season: link.season, episode: link.episode)
                store.touchRecent(RecentItem(id: link.meta.id, type: link.meta.type, name: link.meta.name, poster: link.meta.poster,
                                             addonUrl: link.addonUrl, videoId: link.videoId, videoTitle: link.episode != nil ? link.title : nil))
                playing = PlayTarget(src: r, stream: s)
            } catch { errorText = error.localizedDescription }
            resolving = nil
        }
    }
}

// MARK: - Quản lý add-on
struct AddonsView: View {
    @EnvironmentObject var store: AddonStore
    @State private var url = ""
    @State private var busy = false
    @State private var msg: String?

    var body: some View {
        List {
            Section {
                TextField("Dán link manifest.json hoặc stremio://", text: $url)
                    .plainInput(url: true)
                HStack {
                    Button("Dán") { url = Plat.paste() ?? url }
                    Spacer()
                    Button { add() } label: { busy ? AnyView(ProgressView()) : AnyView(Text("Cài add-on").bold()) }
                        .disabled(url.isEmpty || busy)
                }.buttonStyle(.borderless)
                if let msg { Text(msg).font(.caption).foregroundColor(.secondary) }
            } header: { Text("Thêm add-on") } footer: {
                Text("PhimTor dùng chung add-on với Stremio. Trên trang cài đặt của add-on, sao chép link cài đặt rồi dán vào đây.")
            }
            Section("Đã cài (kéo để sắp xếp)") {
                ForEach(store.addons) { a in
                    HStack(spacing: 12) {
                        AsyncImage(url: a.manifest.logo.flatMap(URL.init(string:))) { p in
                            if case .success(let i) = p { i.resizable().scaledToFit() } else { Image(systemName: "puzzlepiece.extension").foregroundColor(.gray) }
                        }.frame(width: 36, height: 36).cornerRadius(6)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(a.manifest.name).bold()
                                if a.builtIn { Text("có sẵn").font(.caption2).padding(.horizontal, 5).background(Color.yellow.opacity(0.25)).cornerRadius(4) }
                            }
                            Text("v\(a.manifest.version) · " + a.manifest.resources.map { res($0.name) }.joined(separator: ", "))
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .swipeActions {
                        if !a.builtIn || a.transportUrl != AddonStore.phuDeViet {
                            Button("Gỡ", role: .destructive) { store.remove(a) }
                        }
                        Button("Chép link") { Plat.copy(a.transportUrl) }.tint(.blue)
                    }
                }
                .onMove { store.addons.move(fromOffsets: $0, toOffset: $1) }
            }
        }
        .navigationTitle("Add-on")
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
    }

    func res(_ n: String) -> String {
        ["catalog": "danh mục", "meta": "thông tin", "stream": "nguồn phát", "subtitles": "phụ đề"][n] ?? n
    }

    func add() {
        busy = true; msg = nil
        Task {
            do { try await store.install(url); msg = "Đã cài."; url = "" }
            catch { msg = "Lỗi: \(error.localizedDescription)" }
            busy = false
        }
    }
}

// MARK: - Cài đặt
struct SettingsView: View {
    @EnvironmentObject var store: AddonStore
    @State private var cleared = false
    var body: some View {
        Form {
            Section {
                SecureField("API key TorBox (không bắt buộc)", text: $store.torboxKey)
                    .plainInput()
            } header: { Text("TorBox") } footer: {
                Text("Có key: phim đã có sẵn trên TorBox sẽ phát qua TorBox cho nhanh. Phim chưa có thì PhimTor tự tải torrent ngay trên máy.")
            }
            Section("Phụ đề") {
                Toggle("Tự bật phụ đề tiếng Việt", isOn: $store.autoVietSub)
                Toggle("Ưu tiên bản người dịch hơn dịch máy", isOn: $store.preferHuman)
                HStack { Text("Cỡ chữ"); Slider(value: $store.subFontSize, in: 14...44, step: 1); Text("\(Int(store.subFontSize))") }
                Text("Ví dụ phụ đề").font(.system(size: store.subFontSize, weight: .semibold))
                    .padding(6).background(Color.black.opacity(0.6)).cornerRadius(6).frame(maxWidth: .infinity)
            }
            Section("Bộ nhớ") {
                Button(cleared ? "Đã xoá" : "Xoá dữ liệu torrent tạm") {
                    TorrentEngine.shared.stopAll(); cleared = true
                }
                Button("Xoá danh sách Đang xem", role: .destructive) { store.recents = [] }
            }
            Section {
                Text("PhimTor 2.0 • tương thích add-on Stremio").font(.footnote).foregroundColor(.secondary)
            }
        }
        .navigationTitle("Cài đặt")
    }
}

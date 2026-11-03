import SwiftUI
import UIKit
#if canImport(MobileVLCKit)
import MobileVLCKit
#else
import VLCKitSPM
#endif

/// Điều khiển trình phát VLC (đọc được MKV, HEVC, AC3, DTS, phụ đề nhúng…)
final class PlayerModel: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()

    @Published var playing = false
    @Published var buffering = true
    @Published var time: Double = 0
    @Published var length: Double = 0
    @Published var errorText: String?
    @Published var info = ""

    @Published var subs: [SubItem] = []
    @Published var selectedSub: String? = nil     // id của SubItem, "emb:<n>" cho phụ đề nhúng, nil = tắt
    @Published var cues: [Cue] = []
    @Published var subLoading = false
    @Published var subText = ""
    @Published var subDelay: Double = 0
    @Published var embeddedSubs: [(Int32, String)] = []
    @Published var audioTracks: [(Int32, String)] = []
    @Published var currentAudio: Int32 = -1
    @Published var fill = false

    var torrentHash: String?
    var videoKey = ""
    var onProgress: ((Double, Double) -> Void)?
    private var tick: Timer?
    private var started = false
    private var resumeAt: Double = 0

    override init() {
        super.init()
        player.delegate = self
    }

    func load(_ src: ResolvedSource, resume: Double) {
        torrentHash = src.torrentHash
        resumeAt = resume
        let m = VLCMedia(url: src.url)
        m.addOption(":network-caching=\(src.torrentHash == nil ? 4000 : 8000)")
        m.addOption(":http-reconnect")
        if let ua = src.headers["User-Agent"] ?? src.headers["user-agent"] { m.addOption(":http-user-agent=\(ua)") }
        if let ref = src.headers["Referer"] ?? src.headers["referer"] { m.addOption(":http-referrer=\(ref)") }
        player.media = m
        player.play()
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.onTick() }
    }

    private var lastSave = Date()
    private var lastInfo = Date.distantPast

    private func onTick() {
        let t = Double(player.time.intValue) / 1000
        let l = Double(player.media?.length.intValue ?? 0) / 1000
        if abs(t - time) > 0.05 { time = max(0, t) }
        if l > 0 && l != length { length = l }
        if !cues.isEmpty {
            let s = SubtitleLoader.text(at: t - subDelay, in: cues)
            if s != subText { subText = s }
        } else if !subText.isEmpty { subText = "" }
        if Date().timeIntervalSince(lastSave) > 10, t > 5 { lastSave = Date(); onProgress?(t, l) }
        if buffering || !playing, let h = torrentHash, Date().timeIntervalSince(lastInfo) > 1 {
            lastInfo = Date()
            if let s = TorrentEngine.shared.status(h) {
                let mb = Double(s.downloaded ?? 0) / 1_048_576
                info = s.ready == true
                    ? String(format: "%d nguồn chia sẻ • đã tải %.0f MB", s.peers ?? 0, mb)
                    : "Đang tìm nguồn chia sẻ… (\(s.peers ?? 0))"
            }
        } else if !buffering && playing && !info.isEmpty { info = "" }
    }

    func mediaPlayerStateChanged(_ n: Notification) {
        switch player.state {
        case .playing:
            playing = true; buffering = false
            if !started {
                started = true
                if resumeAt > 30 { player.time = VLCTime(int: Int32(resumeAt * 1000)) }
                refreshTracks()
            }
        case .paused: playing = false; buffering = false
        case .buffering, .opening: buffering = !player.isPlaying
        case .error: errorText = "Không phát được nguồn này. Hãy thử nguồn khác."; buffering = false
        case .ended, .stopped: playing = false
        default: break
        }
    }

    func mediaPlayerTimeChanged(_ n: Notification) {
        if buffering { buffering = false }
        if !started, player.isPlaying { mediaPlayerStateChanged(n) }
    }

    func refreshTracks() {
        let sn = (player.videoSubTitlesNames as? [String]) ?? []
        let si = (player.videoSubTitlesIndexes as? [NSNumber]) ?? []
        embeddedSubs = zip(si, sn).compactMap { $0.0.int32Value < 0 ? nil : ($0.0.int32Value, $0.1) }
        let an = (player.audioTrackNames as? [String]) ?? []
        let ai = (player.audioTrackIndexes as? [NSNumber]) ?? []
        audioTracks = zip(ai, an).compactMap { $0.0.int32Value < 0 ? nil : ($0.0.int32Value, $0.1) }
        currentAudio = player.currentAudioTrackIndex
        // nếu đang dùng phụ đề ngoài thì tắt phụ đề nhúng của VLC
        if let s = selectedSub, !s.hasPrefix("emb:") { player.currentVideoSubTitleIndex = -1 }
    }

    func toggle() { player.isPlaying ? player.pause() : player.play() }

    func seek(to t: Double) {
        player.time = VLCTime(int: Int32(max(0, t) * 1000))
        time = t
    }
    func jump(_ d: Double) { seek(to: time + d) }

    func selectSub(_ s: SubItem?) {
        player.currentVideoSubTitleIndex = -1
        guard let s else { selectedSub = nil; cues = []; return }
        selectedSub = s.id
        cues = []
        subLoading = true
        Task { @MainActor in
            let c = (try? await SubtitleLoader.load(s.url)) ?? []
            if selectedSub == s.id { cues = c; subLoading = false }
            if c.isEmpty && selectedSub == s.id { errorText = "Phụ đề này bị lỗi, hãy chọn bản khác."; subLoading = false }
        }
    }

    func selectEmbedded(_ idx: Int32, name: String) {
        cues = []
        selectedSub = "emb:\(idx)"
        player.currentVideoSubTitleIndex = idx
    }

    func selectAudio(_ idx: Int32) { player.currentAudioTrackIndex = idx; currentAudio = idx }

    func setFill(_ f: Bool, size: CGSize) {
        fill = f
        if f, size.width > 0 { player.videoAspectRatio = strdup("\(Int(size.width)):\(Int(size.height))") }
        else { player.videoAspectRatio = nil }
    }

    func stop() {
        tick?.invalidate()
        onProgress?(time, length)
        player.stop()
        if torrentHash != nil { TorrentEngine.shared.stopAll() }
    }
}

struct VLCView: UIViewRepresentable {
    let model: PlayerModel
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        model.player.drawable = v
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - Giao diện trình phát
struct PlayerView: View {
    let title: String
    let source: ResolvedSource
    let type: String
    let videoId: String
    let stream: StreamItem
    var recent: RecentItem?

    @StateObject private var m = PlayerModel()
    @ObservedObject private var store = AddonStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showSubs = false
    @State private var showAudio = false
    @State private var scrubbing: Double?
    @State private var lock = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                VLCView(model: m).ignoresSafeArea()
                    .onTapGesture { toggleControls() }

                // phụ đề tự vẽ
                if !m.subText.isEmpty {
                    VStack {
                        Spacer()
                        Text(m.subText)
                            .font(.system(size: store.subFontSize, weight: .semibold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .shadow(color: .black, radius: 2)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.black.opacity(0.55))
                            .cornerRadius(6)
                            .padding(.horizontal, 30)
                            .padding(.bottom, showControls ? max(store.subBottom, 90) : store.subBottom)
                    }
                    .allowsHitTesting(false)
                }

                if m.buffering || !m.info.isEmpty && !m.playing {
                    VStack(spacing: 10) {
                        if m.buffering { ProgressView().tint(.white).scaleEffect(1.4) }
                        if !m.info.isEmpty { Text(m.info).font(.footnote).foregroundColor(.white.opacity(0.85)) }
                    }
                }

                if showControls && !lock { controls(geo.size) }
                if lock && showControls {
                    VStack { HStack { Spacer(); Button { lock = false } label: { Image(systemName: "lock.fill").padding(14) } }; Spacer() }
                        .foregroundColor(.white).padding()
                }
            }
            .onAppear { start() }
            .onDisappear { m.stop(); Orientation.set(.portrait) }
            .sheet(isPresented: $showSubs) { SubtitlePanel(m: m) }
            .confirmationDialog("Âm thanh", isPresented: $showAudio) {
                ForEach(m.audioTracks, id: \.0) { t in
                    Button((t.0 == m.currentAudio ? "✓ " : "") + t.1) { m.selectAudio(t.0) }
                }
            }
            .alert("Lỗi", isPresented: Binding(get: { m.errorText != nil }, set: { if !$0 { m.errorText = nil } })) {
                Button("OK") {}
            } message: { Text(m.errorText ?? "") }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    @ViewBuilder func controls(_ size: CGSize) -> some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.7), .clear, .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
            VStack {
                HStack(spacing: 18) {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.title2) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline).lineLimit(1)
                        Text(source.via).font(.caption2).foregroundColor(.white.opacity(0.7))
                    }
                    Spacer()
                    Button { lock = true; bump() } label: { Image(systemName: "lock.open") }
                    Button { m.setFill(!m.fill, size: size); bump() } label: {
                        Image(systemName: m.fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    if !m.audioTracks.isEmpty {
                        Button { showAudio = true } label: { Image(systemName: "speaker.wave.2") }
                    }
                    Button { showSubs = true } label: { Image(systemName: "captions.bubble").font(.title3) }
                }
                .padding(.horizontal).padding(.top, 8)
                Spacer()
                HStack(spacing: 56) {
                    Button { m.jump(-10); bump() } label: { Image(systemName: "gobackward.10").font(.system(size: 30)) }
                    Button { m.toggle(); bump() } label: { Image(systemName: m.playing ? "pause.fill" : "play.fill").font(.system(size: 46)) }
                    Button { m.jump(10); bump() } label: { Image(systemName: "goforward.10").font(.system(size: 30)) }
                }
                Spacer()
                HStack(spacing: 10) {
                    Text(fmt(scrubbing ?? m.time)).font(.caption.monospacedDigit())
                    Slider(value: Binding(get: { scrubbing ?? m.time }, set: { scrubbing = $0 }),
                           in: 0...max(m.length, 1)) { editing in
                        if !editing, let s = scrubbing { m.seek(to: s); scrubbing = nil }
                        bump()
                    }
                    .tint(.yellow)
                    Text(fmt(m.length)).font(.caption.monospacedDigit())
                }
                .padding(.horizontal).padding(.bottom, 10)
            }
            .foregroundColor(.white)
        }
    }

    func fmt(_ t: Double) -> String {
        let s = Int(max(0, t)); let h = s / 3600, mi = (s % 3600) / 60, se = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, mi, se) : String(format: "%02d:%02d", mi, se)
    }

    func toggleControls() { withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }; if showControls { bump() } }
    func bump() {
        hideTask?.cancel()
        hideTask = Task { try? await Task.sleep(nanoseconds: 4_000_000_000); if !Task.isCancelled && m.playing && !showSubs { withAnimation { showControls = false } } }
    }

    func start() {
        Orientation.set(.landscape)
        UIApplication.shared.isIdleTimerDisabled = true
        m.videoKey = videoId
        let resume = store.position(for: videoId)
        m.onProgress = { t, l in
            store.setPosition(l > 0 && t > l - 120 ? 0 : t, for: videoId)
            if var r = recent { r.position = t; r.duration = l; r.updated = Date(); store.touchRecent(r) }
        }
        m.load(source, resume: resume)
        bump()
        Task { @MainActor in
            let list = await store.subtitles(type: type, id: videoId, stream: stream)
            m.subs = list
            if store.autoVietSub, m.selectedSub == nil {
                let vi = list.filter { $0.isVietnamese }
                let pick = store.preferHuman ? (vi.first { !$0.isMachine } ?? vi.first) : vi.first
                if let pick { m.selectSub(pick) }
            }
        }
    }
}

/// Bảng chọn phụ đề
struct SubtitlePanel: View {
    @ObservedObject var m: PlayerModel
    @ObservedObject private var store = AddonStore.shared
    @Environment(\.dismiss) private var dismiss

    var groups: [(String, [SubItem])] {
        var order: [String] = []
        var map: [String: [SubItem]] = [:]
        for s in m.subs {
            let k = s.isVietnamese ? (s.isMachine ? "Tiếng Việt (dịch máy)" : "Tiếng Việt") : s.langName
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(s)
        }
        return order.map { ($0, map[$0]!) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("Tắt phụ đề", selected: m.selectedSub == nil) { m.selectSub(nil) }
                }
                Section("Chỉnh phụ đề") {
                    HStack {
                        Text("Độ trễ")
                        Spacer()
                        Button { m.subDelay -= 0.5 } label: { Image(systemName: "minus.circle.fill").font(.title2) }.buttonStyle(.borderless)
                        Text(String(format: "%+.1fs", m.subDelay)).monospacedDigit().frame(width: 64)
                        Button { m.subDelay += 0.5 } label: { Image(systemName: "plus.circle.fill").font(.title2) }.buttonStyle(.borderless)
                    }
                    HStack { Text("Cỡ chữ"); Slider(value: $store.subFontSize, in: 14...44, step: 1); Text("\(Int(store.subFontSize))").frame(width: 30) }
                    HStack { Text("Độ cao"); Slider(value: $store.subBottom, in: 8...200, step: 2) }
                }
                if m.subLoading { Section { HStack { ProgressView(); Text("Đang tải phụ đề…") } } }
                if m.subs.isEmpty { Section { Text("Chưa tìm thấy phụ đề ngoài cho phim này.").foregroundColor(.secondary) } }
                ForEach(groups, id: \.0) { g in
                    Section(g.0) {
                        ForEach(g.1) { s in
                            row(s.label ?? s.addonName, sub: s.label == nil ? nil : s.addonName, selected: m.selectedSub == s.id) {
                                m.selectSub(s)
                            }
                        }
                    }
                }
                if !m.embeddedSubs.isEmpty {
                    Section("Phụ đề nhúng trong file") {
                        ForEach(m.embeddedSubs, id: \.0) { t in
                            row(t.1, selected: m.selectedSub == "emb:\(t.0)") { m.selectEmbedded(t.0, name: t.1) }
                        }
                    }
                }
            }
            .navigationTitle("Phụ đề")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } } }
            .onAppear { m.refreshTracks() }
        }
        .presentationDetents([.medium, .large])
    }

    func row(_ t: String, sub: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t).foregroundColor(.primary).lineLimit(2)
                    if let sub { Text(sub).font(.caption).foregroundColor(.secondary) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundColor(.yellow) }
            }
        }
    }
}

/// Xoay màn hình khi vào/ra trình phát
enum Orientation {
    static var mask: UIInterfaceOrientationMask = .allButUpsideDown
    static func set(_ o: UIInterfaceOrientationMask) {
        mask = o == .portrait ? .allButUpsideDown : .landscape
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: o)) { _ in }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if o == .portrait { mask = .allButUpsideDown; UIApplication.shared.isIdleTimerDisabled = false }
    }
}

// Package phimengine: bộ tải torrent chạy trong app PhimTor (iPhone).
// Tạo một máy chủ HTTP nội bộ 127.0.0.1:<port>/stream/<infohash>/<fileIdx>
// để trình phát video đọc dần dữ liệu trong khi torrent đang tải.
package phimengine

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/anacrolix/torrent"
	"github.com/anacrolix/torrent/metainfo"
	"github.com/anacrolix/torrent/storage"
)

var (
	mu       sync.Mutex
	client   *torrent.Client
	port     int
	dataDir  string
	lastErr  string
	active   = map[string]*torrent.Torrent{}
	defaultTrackers = []string{
		"udp://tracker.opentrackr.org:1337/announce",
		"udp://open.demonii.com:1337/announce",
		"udp://tracker.openbittorrent.com:6969/announce",
		"udp://exodus.desync.com:6969/announce",
		"udp://tracker.torrent.eu.org:451/announce",
		"udp://open.stealth.si:80/announce",
		"udp://explodie.org:6969/announce",
		"udp://tracker.tiny-vps.com:6969/announce",
		"https://tracker.tamersunion.org:443/announce",
	}
)

var videoExt = map[string]bool{".mkv": true, ".mp4": true, ".avi": true, ".mov": true, ".m4v": true, ".ts": true, ".webm": true, ".wmv": true, ".flv": true, ".mpg": true, ".mpeg": true}

func setErr(e error) string {
	if e != nil {
		lastErr = e.Error()
	}
	return ""
}

// LastError trả về lỗi gần nhất.
func LastError() string { return lastErr }

// Start khởi động bộ tải + máy chủ HTTP. Trả về cổng, hoặc -1 nếu lỗi.
func Start(dir string) int {
	mu.Lock()
	defer mu.Unlock()
	if client != nil {
		return port
	}
	dataDir = dir
	_ = os.MkdirAll(dir, 0o755)
	cfg := torrent.NewDefaultClientConfig()
	cfg.DataDir = dir
	cfg.Seed = false
	cfg.NoUpload = false
	cfg.ListenPort = 0
	cfg.EstablishedConnsPerTorrent = 60
	cfg.HalfOpenConnsPerTorrent = 30
	cfg.DefaultStorage = storage.NewFileOpts(storage.NewFileClientOpts{
		ClientBaseDir:   dir,
		PieceCompletion: storage.NewMapPieceCompletion(),
	})
	c, err := torrent.NewClient(cfg)
	if err != nil {
		setErr(err)
		return -1
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		c.Close()
		setErr(err)
		return -1
	}
	client = c
	port = ln.Addr().(*net.TCPAddr).Port
	mux := http.NewServeMux()
	mux.HandleFunc("/stream/", serveStream)
	go http.Serve(ln, mux)
	return port
}

func getTorrent(hash string) (*torrent.Torrent, error) {
	mu.Lock()
	defer mu.Unlock()
	if client == nil {
		return nil, fmt.Errorf("engine chưa chạy")
	}
	if t, ok := active[hash]; ok {
		return t, nil
	}
	var ih metainfo.Hash
	if err := ih.FromHexString(hash); err != nil {
		return nil, err
	}
	t, _ := client.AddTorrentInfoHash(ih)
	t.AddTrackers([][]string{defaultTrackers})
	active[hash] = t
	return t, nil
}

// AddMagnet thêm torrent (magnet hoặc infohash). Trả về infohash, hoặc "" nếu lỗi.
func AddMagnet(magnet string) string {
	mu.Lock()
	c := client
	mu.Unlock()
	if c == nil {
		return setErr(fmt.Errorf("engine chưa chạy"))
	}
	if !strings.HasPrefix(magnet, "magnet:") {
		magnet = "magnet:?xt=urn:btih:" + magnet
	}
	t, err := c.AddMagnet(magnet)
	if err != nil {
		return setErr(err)
	}
	t.AddTrackers([][]string{defaultTrackers})
	h := t.InfoHash().HexString()
	mu.Lock()
	active[h] = t
	mu.Unlock()
	return h
}

func pickFile(t *torrent.Torrent, idx int, hint string) *torrent.File {
	files := t.Files()
	if idx >= 0 && idx < len(files) {
		return files[idx]
	}
	hint = strings.ToLower(hint)
	if hint != "" {
		for _, f := range files {
			if strings.Contains(strings.ToLower(f.DisplayPath()), hint) {
				return f
			}
		}
	}
	var best *torrent.File
	for _, f := range files {
		if !videoExt[strings.ToLower(filepath.Ext(f.DisplayPath()))] {
			continue
		}
		if best == nil || f.Length() > best.Length() {
			best = f
		}
	}
	if best == nil && len(files) > 0 {
		best = files[0]
	}
	return best
}

// /stream/<hash>/<fileIdx>[?hint=tên-file]
func serveStream(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/stream/"), "/")
	if len(parts) < 1 || parts[0] == "" {
		http.Error(w, "bad", 400)
		return
	}
	hash := strings.ToLower(parts[0])
	idx := -1
	if len(parts) > 1 {
		if n, err := strconv.Atoi(parts[1]); err == nil {
			idx = n
		}
	}
	t, err := getTorrent(hash)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 90*time.Second)
	defer cancel()
	select {
	case <-t.GotInfo():
	case <-ctx.Done():
		http.Error(w, "Không tìm thấy nguồn chia sẻ (timeout)", 504)
		return
	}
	f := pickFile(t, idx, r.URL.Query().Get("hint"))
	if f == nil {
		http.Error(w, "no file", 404)
		return
	}
	// chỉ tải file đang xem
	for _, o := range t.Files() {
		if o != f {
			o.SetPriority(0)
		}
	}
	rd := f.NewReader()
	defer rd.Close()
	rd.SetReadahead(16 << 20)
	rd.SetResponsive()
	name := filepath.Base(f.DisplayPath())
	w.Header().Set("Content-Type", mimeOf(name))
	http.ServeContent(w, r, name, time.Time{}, rd)
}

func mimeOf(n string) string {
	switch strings.ToLower(filepath.Ext(n)) {
	case ".mp4", ".m4v":
		return "video/mp4"
	case ".mkv":
		return "video/x-matroska"
	case ".webm":
		return "video/webm"
	case ".avi":
		return "video/x-msvideo"
	}
	return "application/octet-stream"
}

type fileInfo struct {
	Index int    `json:"index"`
	Path  string `json:"path"`
	Size  int64  `json:"size"`
}

type status struct {
	Ready      bool       `json:"ready"`
	Name       string     `json:"name"`
	Peers      int        `json:"peers"`
	Seeds      int        `json:"seeds"`
	Downloaded int64      `json:"downloaded"`
	Total      int64      `json:"total"`
	Files      []fileInfo `json:"files"`
}

// Status trả về JSON trạng thái torrent.
func Status(hash string) string {
	mu.Lock()
	t, ok := active[strings.ToLower(hash)]
	mu.Unlock()
	if !ok {
		return "{}"
	}
	s := status{}
	st := t.Stats()
	s.Peers = st.ActivePeers
	s.Seeds = st.ConnectedSeeders
	select {
	case <-t.GotInfo():
		s.Ready = true
		s.Name = t.Name()
		s.Downloaded = t.BytesCompleted()
		s.Total = t.Length()
		for i, f := range t.Files() {
			s.Files = append(s.Files, fileInfo{i, f.DisplayPath(), f.Length()})
		}
	default:
	}
	b, _ := json.Marshal(s)
	return string(b)
}

// DropAll gỡ mọi torrent (khi đóng trình phát) và xoá dữ liệu tạm.
func DropAll() {
	mu.Lock()
	defer mu.Unlock()
	for h, t := range active {
		t.Drop()
		delete(active, h)
	}
	if dataDir != "" {
		entries, _ := os.ReadDir(dataDir)
		sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
		for _, e := range entries {
			_ = os.RemoveAll(filepath.Join(dataDir, e.Name()))
		}
	}
}

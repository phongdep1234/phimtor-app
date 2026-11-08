package com.thayphong.phimtor

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.os.StatFs
import androidx.compose.runtime.mutableStateListOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/** Một phim tải về máy */
data class DlRec(
    val id: String = UUID.randomUUID().toString(),
    val kind: String,                 // "torrent" | "http"
    val title: String, val metaId: String, val type: String, val name: String, val poster: String?,
    val addonUrl: String?, val videoId: String, val videoTitle: String?, val source: String,
    val hash: String? = null, val fileIdx: Int? = null, val hint: String? = null, val trackers: List<String> = emptyList(),
    val url: String? = null, val headers: Map<String, String> = emptyMap(),
    val jobId: String? = null, val sysId: Long = -1,
    val path: String? = null, val fileName: String? = null,
    val done: Long = 0, val total: Long = 0, val speed: Long = 0, val peers: Int = 0,
    val state: String = "waiting",    // waiting | downloading | paused | done | failed
    val error: String? = null,
    val videoSize: Long? = null, val videoHash: String? = null,
    val created: Long = System.currentTimeMillis(),
) {
    val progress get() = if (total > 0) (done.toDouble() / total).coerceIn(0.0, 1.0) else 0.0
    val active get() = state == "downloading" || state == "waiting"

    fun toJson(): JSONObject = JSONObject().put("id", id).put("kind", kind).put("title", title).put("metaId", metaId).put("type", type)
        .put("name", name).put("poster", poster).put("addonUrl", addonUrl).put("videoId", videoId).put("videoTitle", videoTitle)
        .put("source", source).put("hash", hash).put("fileIdx", fileIdx).put("hint", hint).put("trackers", JSONArray(trackers))
        .put("url", url).put("headers", JSONObject(headers)).put("jobId", jobId).put("sysId", sysId).put("path", path)
        .put("fileName", fileName).put("done", done).put("total", total).put("state", state).put("error", error)
        .put("videoSize", videoSize).put("videoHash", videoHash).put("created", created)

    companion object {
        fun from(o: JSONObject): DlRec {
            val h = o.optJSONObject("headers"); val hm = mutableMapOf<String, String>()
            h?.keys()?.forEach { hm[it] = h.optString(it) }
            return DlRec(o.optString("id"), o.optString("kind"), o.optString("title"), o.optString("metaId"), o.optString("type"),
                o.optString("name"), o.str("poster"), o.str("addonUrl"), o.optString("videoId"), o.str("videoTitle"), o.optString("source"),
                o.str("hash"), o.int("fileIdx"), o.str("hint"), o.strs("trackers"), o.str("url"), hm, o.str("jobId"), o.optLong("sysId", -1),
                o.str("path"), o.str("fileName"), o.optLong("done"), o.optLong("total"), 0, 0, o.optString("state", "waiting"),
                o.str("error"), o.optLong("videoSize").takeIf { it > 0 }, o.str("videoHash"), o.optLong("created"))
        }
    }
}

/** Tải phim: torrent (bộ tải trong app) hoặc link HTTP (link trực tiếp / TorBox, qua trình tải của Android – tải nền được) */
object Downloads {
    val items = mutableStateListOf<DlRec>()
    private var loop: Job? = null
    private val scope = MainScope()
    private val last = HashMap<String, Pair<Long, Long>>()   // id → (bytes, thời điểm)

    val dir: File get() = File(Repo.appCtx.getExternalFilesDir(Environment.DIRECTORY_MOVIES) ?: Repo.appCtx.filesDir, "Phim tải về").apply { mkdirs() }
    private val dm get() = Repo.appCtx.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager

    fun init() {
        runCatching { JSONArray(Repo.prefs.getString("downloads", "[]")).objs().forEach { items.add(DlRec.from(it)) } }
        // Torrent đang tải dở → tải tiếp
        items.filter { it.kind == "torrent" && it.active }.forEach { startTorrent(it.id) }
        ensureLoop()
    }

    private fun save() {
        val a = JSONArray(); items.forEach { a.put(it.toJson()) }
        Repo.prefs.edit().putString("downloads", a.toString()).apply()
    }

    private fun upd(id: String, f: (DlRec) -> DlRec) {
        val i = items.indexOfFirst { it.id == id }
        if (i >= 0) items[i] = f(items[i])
    }

    fun get(id: String) = items.firstOrNull { it.id == id }

    fun file(r: DlRec): File? = r.path?.let { File(it) }?.takeIf { it.exists() && r.state == "done" }

    fun find(videoId: String, title: String, source: String) =
        items.firstOrNull { it.videoId == videoId && it.title == title && it.source == source && it.state != "failed" }

    /** Bắt đầu tải một nguồn phát. Trả về lời báo. */
    suspend fun add(st: Stream, s: Screen.Streams): String {
        val source = listOfNotNull(st.name, st.title?.lineSequence()?.firstOrNull()).joinToString(" · ")
        if (find(s.videoId, s.title, source) != null) return "Nguồn này đã có trong mục Tải về"
        var r = DlRec(kind = "http", title = s.title, metaId = s.meta.id, type = s.meta.type, name = s.meta.name, poster = s.meta.poster,
            addonUrl = s.addonUrl, videoId = s.videoId, videoTitle = if (s.episode != null) s.title else null, source = source,
            fileName = st.filename, videoSize = st.videoSize, videoHash = st.videoHash)
        val u = st.url
        if (u != null && u.startsWith("http")) {
            r = r.copy(url = u, headers = st.headers)
        } else {
            var hash = st.infoHash
            if (hash == null && u != null && u.startsWith("magnet:")) hash = Regex("btih:([a-zA-Z0-9]+)").find(u)?.groupValues?.get(1)?.lowercase()
            val h = hash ?: return "Nguồn này không tải về được"
            val key = Repo.torboxKey.value.trim()
            val tb = if (key.isNotEmpty()) withContext(Dispatchers.IO) {
                if (TorBox.cached(h, key)) TorBox.link(st, h, s.season, s.episode, key) else null
            } else null
            r = if (tb != null) r.copy(url = tb)
            else r.copy(kind = "torrent", hash = h, fileIdx = st.fileIdx, hint = if (st.fileIdx == null) st.filename else null, trackers = st.trackers)
        }
        items.add(0, r)
        save()
        if (r.kind == "torrent") startTorrent(r.id) else startHttp(r.id)
        ensureLoop()
        return if (r.kind == "torrent") "Đã thêm vào Tải về (tải torrent khi app đang mở)" else "Đã thêm vào Tải về"
    }

    // ---------------- torrent ----------------
    private fun startTorrent(id: String) {
        val r = get(id) ?: return
        val h = r.hash ?: return
        if (!Engine.start()) { upd(id) { it.copy(state = "failed", error = "Không khởi động được bộ tải torrent") }; save(); return }
        var magnet = "magnet:?xt=urn:btih:$h"
        r.trackers.forEach { magnet += "&tr=" + enc(it) }
        val job = runCatching { com.thayphong.phimengine.Phimengine.startDownload(magnet, (r.fileIdx ?: -1).toLong(), r.hint ?: "", dir.absolutePath) }.getOrNull()
        upd(id) { if (job.isNullOrEmpty()) it.copy(state = "failed", error = Engine.lastError) else it.copy(jobId = job, state = "downloading", error = null) }
        save()
    }

    // ---------------- http (DownloadManager của Android) ----------------
    private fun startHttp(id: String) {
        val r = get(id) ?: return
        val u = r.url ?: return
        var name = (r.fileName ?: r.title).replace(Regex("[\\\\/:*?\"<>|]"), "-")
        if (!name.contains('.')) name += ".mp4"
        val f = File(dir, name).let { if (it.exists()) File(dir, r.id.take(6) + "-" + name) else it }
        val req = DownloadManager.Request(Uri.parse(u))
            .setTitle(r.title).setDescription("PhimTor")
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE)
            .setDestinationUri(Uri.fromFile(f))
            .setAllowedOverMetered(true)
        r.headers.forEach { (k, v) -> req.addRequestHeader(k, v) }
        val sys = runCatching { dm.enqueue(req) }.getOrElse { e ->
            upd(id) { it.copy(state = "failed", error = e.message) }; save(); return
        }
        upd(id) { it.copy(sysId = sys, path = f.absolutePath, state = "downloading", error = null, done = 0) }
        save()
    }

    // ---------------- cập nhật tiến độ ----------------
    private fun ensureLoop() {
        if (loop?.isActive == true) return
        loop = scope.launch {
            while (isActive) {
                val act = items.filter { it.active }
                if (act.isEmpty()) break
                val updates = withContext(Dispatchers.IO) { act.mapNotNull { r -> poll(r)?.let { r.id to it } } }
                updates.forEach { (id, f) -> upd(id, f) }
                save()
                delay(1000)
            }
        }
    }

    private fun speedOf(id: String, bytes: Long): Long {
        val now = System.currentTimeMillis()
        val p = last[id]
        if (p == null || now - p.second >= 900) {
            last[id] = bytes to now
            if (p != null) return ((bytes - p.first) * 1000 / (now - p.second)).coerceAtLeast(0)
        }
        return -1
    }

    private fun poll(r: DlRec): ((DlRec) -> DlRec)? {
        if (r.kind == "torrent") {
            val job = r.jobId ?: return null
            val o = runCatching { JSONObject(com.thayphong.phimengine.Phimengine.downloadStatus(job)) }.getOrNull() ?: return null
            val done = o.optLong("done"); val total = o.optLong("total")
            val sp = speedOf(r.id, done)
            return { x ->
                var y = x.copy(peers = o.optInt("peers"), done = done, total = if (total > 0) total else x.total,
                    fileName = o.str("name") ?: x.fileName, speed = if (sp >= 0) sp else x.speed)
                when (o.optString("state")) {
                    "done" -> y = y.copy(state = "done", path = o.str("path"), speed = 0)
                    "error" -> y = y.copy(state = "failed", error = o.str("error"))
                    "none" -> { scope.launch { startTorrent(x.id) } }
                }
                y
            }
        }
        if (r.sysId < 0) return null
        dm.query(DownloadManager.Query().setFilterById(r.sysId))?.use { c ->
            if (!c.moveToFirst()) return { it.copy(state = "failed", error = "Đã bị huỷ") }
            val st = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
            val done = c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
            val total = c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
            val reason = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON))
            val sp = speedOf(r.id, done)
            return { x ->
                val y = x.copy(done = done, total = if (total > 0) total else x.total, speed = if (sp >= 0) sp else x.speed)
                when (st) {
                    DownloadManager.STATUS_SUCCESSFUL -> y.copy(state = "done", speed = 0, done = maxOf(done, total))
                    DownloadManager.STATUS_FAILED -> y.copy(state = "failed", error = "Lỗi tải ($reason)", speed = 0)
                    else -> y
                }
            }
        }
        return null
    }

    // ---------------- điều khiển ----------------
    fun pause(id: String) {
        val r = get(id) ?: return
        if (r.kind == "torrent") r.jobId?.let { runCatching { com.thayphong.phimengine.Phimengine.pauseDownload(it) } }
        else if (r.sysId >= 0) runCatching { dm.remove(r.sysId) }   // trình tải Android không có tạm dừng → tải lại từ đầu khi tiếp tục
        upd(id) { it.copy(state = "paused", speed = 0) }
        save()
    }

    fun resume(id: String) {
        val r = get(id) ?: return
        if (r.kind == "torrent") startTorrent(id) else startHttp(id)
        ensureLoop()
    }

    fun delete(id: String) {
        val r = get(id) ?: return
        if (r.kind == "torrent") {
            runCatching { com.thayphong.phimengine.Phimengine.cancelDownload(r.jobId ?: "", r.path ?: "") }
            r.path?.let { File(it).delete(); File("$it.part").delete() }
        } else {
            if (r.sysId >= 0) runCatching { dm.remove(r.sysId) }
            r.path?.let { File(it).delete() }
        }
        items.removeAll { it.id == id }
        save()
    }

    fun freeSpace(): Long = runCatching { StatFs(dir.absolutePath).availableBytes }.getOrDefault(0)
}

fun fmtBytes(b: Long): String = when {
    b >= 1L shl 30 -> "%.2f GB".format(b / 1073741824.0)
    b >= 1L shl 20 -> "%.0f MB".format(b / 1048576.0)
    else -> "%.0f KB".format(b / 1024.0)
}

package com.thayphong.phimtor

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.nio.charset.Charset
import java.util.zip.GZIPInputStream

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        Repo.init(this)
    }
}

// ---------------------------------------------------------------- tiện ích JSON
fun JSONObject.str(k: String): String? = if (has(k) && !isNull(k)) optString(k).takeIf { it.isNotEmpty() } else null
fun JSONObject.int(k: String): Int? = if (has(k) && !isNull(k)) (opt(k) as? Number)?.toInt() ?: optString(k).toIntOrNull() else null
fun JSONObject.strs(k: String): List<String> {
    val v = opt(k) ?: return emptyList()
    return when (v) {
        is JSONArray -> (0 until v.length()).mapNotNull { v.opt(it)?.toString()?.takeIf { s -> s.isNotEmpty() } }
        is String -> listOf(v)
        else -> emptyList()
    }
}
fun JSONArray?.objs(): List<JSONObject> = if (this == null) emptyList() else (0 until length()).mapNotNull { optJSONObject(it) }
fun enc(s: String): String = URLEncoder.encode(s, "UTF-8").replace("+", "%20")

// ---------------------------------------------------------------- manifest
data class Resource(val name: String, val types: List<String>?, val idPrefixes: List<String>?)
data class Extra(val name: String, val required: Boolean, val options: List<String>)
data class Catalog(val type: String, val id: String, val name: String, val extra: List<Extra>) {
    val uid get() = "$type/$id"
    val supportsSearch get() = extra.any { it.name == "search" }
    val needsSomething get() = extra.any { it.required }
    val genres get() = extra.firstOrNull { it.name == "genre" }?.options ?: emptyList()
}

class Manifest(val json: JSONObject) {
    val id = json.str("id") ?: ""
    val name = json.str("name") ?: id
    val version = json.str("version") ?: "?"
    val logo = json.str("logo")
    val types = json.strs("types")
    val idPrefixes: List<String>? = if (json.has("idPrefixes")) json.strs("idPrefixes") else null
    val resources: List<Resource> = run {
        val a = json.optJSONArray("resources") ?: JSONArray()
        (0 until a.length()).mapNotNull { i ->
            when (val r = a.opt(i)) {
                is String -> Resource(r, null, null)
                is JSONObject -> r.str("name")?.let { n ->
                    Resource(n, if (r.has("types")) r.strs("types") else null, if (r.has("idPrefixes")) r.strs("idPrefixes") else null)
                }
                else -> null
            }
        }
    }
    val catalogs: List<Catalog> = json.optJSONArray("catalogs").objs().mapNotNull { c ->
        val t = c.str("type") ?: return@mapNotNull null
        val cid = c.str("id") ?: return@mapNotNull null
        val ex = c.optJSONArray("extra").objs().mapNotNull { e ->
            e.str("name")?.let { Extra(it, e.optBoolean("isRequired", false), e.strs("options")) }
        }.toMutableList()
        val req = c.strs("extraRequired")
        for (n in c.strs("extraSupported")) if (ex.none { it.name == n }) ex.add(Extra(n, req.contains(n), emptyList()))
        Catalog(t, cid, c.str("name") ?: cid, ex)
    }

    fun supports(resource: String, type: String, id: String): Boolean {
        val r = resources.firstOrNull { it.name == resource } ?: return false
        val ts = r.types ?: types
        if (ts.isNotEmpty() && !ts.contains(type)) return false
        val pre = r.idPrefixes ?: idPrefixes
        if (!pre.isNullOrEmpty()) return pre.any { id.startsWith(it) }
        return true
    }
}

data class Addon(val transportUrl: String, val manifest: Manifest, val builtIn: Boolean) {
    val base get() = transportUrl.removeSuffix("/manifest.json")
}

// ---------------------------------------------------------------- phim, tập, nguồn, phụ đề
data class Video(val id: String, val title: String, val season: Int?, val episode: Int?, val thumbnail: String?, val overview: String?)

data class Meta(
    val id: String, val type: String, val name: String, val poster: String?, val background: String?,
    val description: String?, val releaseInfo: String?, val imdbRating: String?, val runtime: String?,
    val genres: List<String>, val videos: List<Video>, val defaultVideoId: String?, val landscape: Boolean
) {
    companion object {
        fun from(d: JSONObject): Meta? {
            val id = d.str("id") ?: return null
            val name = d.str("name") ?: return null
            val vids = d.optJSONArray("videos").objs().mapNotNull { v ->
                val vid = v.str("id") ?: return@mapNotNull null
                val ep = v.int("episode") ?: v.int("number")
                Video(vid, v.str("title") ?: v.str("name") ?: (ep?.let { "Tập $it" } ?: vid), v.int("season"), ep,
                    v.str("thumbnail"), v.str("overview") ?: v.str("description"))
            }.sortedWith(compareBy({ it.season ?: 0 }, { it.episode ?: 0 }))
            return Meta(id, d.str("type") ?: "movie", name, d.str("poster"), d.str("background"), d.str("description"),
                d.str("releaseInfo") ?: d.str("year"), d.str("imdbRating"), d.str("runtime"),
                d.strs("genres").ifEmpty { d.strs("genre") }, vids,
                d.optJSONObject("behaviorHints")?.str("defaultVideoId"), d.str("posterShape") == "landscape")
        }
        fun stub(id: String, type: String, name: String, poster: String?) =
            Meta(id, type, name, poster, null, null, null, null, null, emptyList(), emptyList(), null, false)
    }
}

data class Stream(
    val addonName: String, val name: String?, val title: String?, val url: String?, val ytId: String?,
    val infoHash: String?, val fileIdx: Int?, val externalUrl: String?, val trackers: List<String>,
    val filename: String?, val videoSize: Long?, val videoHash: String?, val headers: Map<String, String>
) {
    val isTorrent get() = infoHash != null || (url ?: "").startsWith("magnet:")
    companion object {
        fun from(d: JSONObject, addon: String): Stream? {
            val bh = d.optJSONObject("behaviorHints")
            val req = bh?.optJSONObject("proxyHeaders")?.optJSONObject("request")
            val headers = mutableMapOf<String, String>()
            req?.keys()?.forEach { k -> headers[k] = req.optString(k) }
            val s = Stream(addon, d.str("name"), d.str("title") ?: d.str("description"), d.str("url"), d.str("ytId"),
                d.str("infoHash")?.lowercase(), d.int("fileIdx"), d.str("externalUrl"),
                d.strs("sources").filter { it.startsWith("tracker:") }.map { it.removePrefix("tracker:") },
                bh?.str("filename"), bh?.optLong("videoSize", 0L)?.takeIf { it > 0 }, bh?.str("videoHash"), headers)
            return if (s.url == null && s.ytId == null && s.infoHash == null && s.externalUrl == null) null else s
        }
    }
}

data class Sub(val id: String, val url: String, val lang: String, val label: String?, val addonName: String) {
    val isViet get() = lang.lowercase() in setOf("vie", "vi", "vietnamese")
    val isMachine get() = (label ?: "").lowercase().contains("dịch máy") || id.contains("-tr-")
    val langName get() = LANGS[lang.lowercase()] ?: lang
    companion object {
        val LANGS = mapOf("vie" to "Tiếng Việt", "vi" to "Tiếng Việt", "eng" to "Tiếng Anh", "en" to "Tiếng Anh",
            "chi" to "Tiếng Trung", "zho" to "Tiếng Trung", "kor" to "Tiếng Hàn", "jpn" to "Tiếng Nhật",
            "fre" to "Tiếng Pháp", "fra" to "Tiếng Pháp", "spa" to "Tiếng Tây Ban Nha", "tha" to "Tiếng Thái",
            "ind" to "Tiếng Indonesia", "rus" to "Tiếng Nga", "ger" to "Tiếng Đức", "por" to "Tiếng Bồ Đào Nha",
            "pob" to "Tiếng Bồ Đào Nha (BR)", "ita" to "Tiếng Ý")
    }
}

data class Recent(val id: String, val type: String, val name: String, val poster: String?, val addonUrl: String?,
                  val videoTitle: String?, val position: Double, val duration: Double) {
    fun toJson() = JSONObject().put("id", id).put("type", type).put("name", name).put("poster", poster)
        .put("addonUrl", addonUrl).put("videoTitle", videoTitle).put("position", position).put("duration", duration)
    companion object {
        fun from(o: JSONObject) = Recent(o.optString("id"), o.optString("type"), o.optString("name"), o.str("poster"),
            o.str("addonUrl"), o.str("videoTitle"), o.optDouble("position", 0.0), o.optDouble("duration", 0.0))
    }
}

// ---------------------------------------------------------------- kho add-on + gọi API Stremio
object Repo {
    const val CINEMETA = "https://v3-cinemeta.strem.io/manifest.json"
    const val OPENSUBS = "https://opensubtitles-v3.strem.io/manifest.json"
    const val PHUDEVIET = "https://phudeviet.trananhphong2208.workers.dev/manifest.json"
    val BUILTINS = listOf(CINEMETA, PHUDEVIET, OPENSUBS)

    lateinit var prefs: SharedPreferences
    lateinit var appCtx: Context
    val addons = mutableStateListOf<Addon>()
    val recents = mutableStateListOf<Recent>()
    val torboxKey = mutableStateOf("")
    val subSize = mutableStateOf(22f)
    val autoViet = mutableStateOf(true)
    val preferHuman = mutableStateOf(true)

    fun init(ctx: Context) {
        appCtx = ctx
        prefs = ctx.getSharedPreferences("phimtor", Context.MODE_PRIVATE)
        runCatching {
            JSONArray(prefs.getString("addons", "[]")).objs().forEach { o ->
                addons.add(Addon(o.getString("url"), Manifest(o.getJSONObject("manifest")), o.optBoolean("builtIn")))
            }
        }
        runCatching { JSONArray(prefs.getString("recents", "[]")).objs().forEach { recents.add(Recent.from(it)) } }
        torboxKey.value = prefs.getString("torbox", "") ?: ""
        subSize.value = prefs.getFloat("subSize", 22f)
        autoViet.value = prefs.getBoolean("autoViet", true)
        preferHuman.value = prefs.getBoolean("preferHuman", true)
    }

    fun saveSettings() {
        prefs.edit().putString("torbox", torboxKey.value.trim()).putFloat("subSize", subSize.value)
            .putBoolean("autoViet", autoViet.value).putBoolean("preferHuman", preferHuman.value).apply()
    }

    fun saveAddons() {
        val a = JSONArray()
        addons.forEach { a.put(JSONObject().put("url", it.transportUrl).put("manifest", it.manifest.json).put("builtIn", it.builtIn)) }
        prefs.edit().putString("addons", a.toString()).apply()
    }

    fun saveRecents() {
        val a = JSONArray(); recents.forEach { a.put(it.toJson()) }
        prefs.edit().putString("recents", a.toString()).apply()
    }

    fun touchRecent(r: Recent) {
        recents.removeAll { it.id == r.id }
        recents.add(0, r)
        while (recents.size > 30) recents.removeAt(recents.size - 1)
        saveRecents()
    }

    fun position(videoId: String) = prefs.getFloat("pos:$videoId", 0f).toDouble()
    fun setPosition(videoId: String, p: Double) = prefs.edit().putFloat("pos:$videoId", p.toFloat()).apply()

    // HTTP
    fun httpBytes(url: String, headers: Map<String, String> = emptyMap(), timeout: Int = 25000): ByteArray? = runCatching {
        val c = URL(url).openConnection() as HttpURLConnection
        c.connectTimeout = timeout; c.readTimeout = timeout
        c.setRequestProperty("User-Agent", "PhimTor/2.0 (Android)")
        headers.forEach { (k, v) -> c.setRequestProperty(k, v) }
        c.instanceFollowRedirects = true
        if (c.responseCode >= 400) { c.disconnect(); return null }
        val out = c.inputStream.use { it.readBytes() }
        c.disconnect(); out
    }.getOrNull()

    suspend fun getJson(url: String): JSONObject? = withContext(Dispatchers.IO) {
        httpBytes(url)?.let { runCatching { JSONObject(String(it, Charsets.UTF_8)) }.getOrNull() }
    }

    fun normalize(raw: String): String {
        var s = raw.trim()
        if (s.startsWith("stremio://")) s = "https://" + s.removePrefix("stremio://")
        if (!s.startsWith("http")) s = "https://$s"
        if (s.endsWith("/configure")) s = s.removeSuffix("/configure") + "/manifest.json"
        if (!s.endsWith("manifest.json")) s = s.trimEnd('/') + "/manifest.json"
        return s
    }

    suspend fun fetchManifest(url: String): Manifest? = getJson(url)?.let { Manifest(it) }?.takeIf { it.id.isNotEmpty() }

    suspend fun install(raw: String): String {
        val url = normalize(raw)
        val m = fetchManifest(url) ?: return "Không đọc được manifest"
        val i = addons.indexOfFirst { it.manifest.id == m.id || it.transportUrl == url }
        if (i >= 0) addons[i] = Addon(url, m, addons[i].builtIn) else addons.add(Addon(url, m, BUILTINS.contains(url)))
        saveAddons()
        return "Đã cài ${m.name}"
    }

    suspend fun ensureBuiltIns() {
        BUILTINS.forEachIndexed { i, u ->
            if (addons.none { it.transportUrl == u }) fetchManifest(u)?.let { addons.add(minOf(i, addons.size), Addon(u, it, true)) }
        }
        addons.toList().forEach { a ->
            fetchManifest(a.transportUrl)?.let { m -> val i = addons.indexOf(a); if (i >= 0) addons[i] = a.copy(manifest = m) }
        }
        saveAddons()
    }

    fun extraPath(extra: List<Pair<String, String>>) =
        if (extra.isEmpty()) "" else "/" + extra.joinToString("&") { "${it.first}=${enc(it.second)}" }

    suspend fun catalog(a: Addon, c: Catalog, extra: List<Pair<String, String>> = emptyList()): List<Meta> =
        getJson("${a.base}/catalog/${c.type}/${enc(c.id)}${extraPath(extra)}.json")
            ?.optJSONArray("metas").objs().mapNotNull { Meta.from(it) }

    suspend fun meta(type: String, id: String, preferred: String?): Meta? {
        val order = addons.filter { it.manifest.supports("meta", type, id) }.toMutableList()
        order.indexOfFirst { it.transportUrl == preferred }.takeIf { it > 0 }?.let { order.add(0, order.removeAt(it)) }
        for (a in order) {
            getJson("${a.base}/meta/$type/${enc(id)}.json")?.optJSONObject("meta")?.let { Meta.from(it) }?.let { return it }
        }
        return null
    }

    suspend fun streams(type: String, id: String, onAddon: (String, List<Stream>) -> Unit) = coroutineScope {
        addons.filter { it.manifest.supports("stream", type, id) }.map { a ->
            async {
                val list = getJson("${a.base}/stream/$type/${enc(id)}.json")?.optJSONArray("streams").objs()
                    .mapNotNull { Stream.from(it, a.manifest.name) }
                withContext(Dispatchers.Main) { onAddon(a.manifest.name, list) }
            }
        }.awaitAll()
    }

    suspend fun subtitles(type: String, id: String, s: Stream?): List<Sub> = coroutineScope {
        val extra = mutableListOf<Pair<String, String>>()
        s?.videoHash?.let { extra.add("videoHash" to it) }
        s?.videoSize?.let { extra.add("videoSize" to it.toString()) }
        s?.filename?.let { extra.add("filename" to it) }
        val all = addons.filter { it.manifest.supports("subtitles", type, id) }.map { a ->
            async {
                getJson("${a.base}/subtitles/$type/${enc(id)}${extraPath(extra)}.json")?.optJSONArray("subtitles").objs()
                    .mapIndexedNotNull { i, o ->
                        o.str("url")?.let { u -> Sub((o.str("id") ?: "$i") + "@" + a.manifest.id, u, o.str("lang") ?: "und", o.str("label"), a.manifest.name) }
                    }
            }
        }.awaitAll().flatten().distinctBy { it.url }
        fun rank(x: Sub) = if (x.isViet) (if (x.isMachine) 1 else 0) else if (x.lang.lowercase() in setOf("eng", "en")) 2 else 3
        all.withIndex().sortedWith(compareBy({ rank(it.value) }, { it.index })).map { it.value }
    }
}

// ---------------------------------------------------------------- phát: torrent trong app / TorBox / link
object Engine {
    private var port = -1L
    fun start(): Boolean {
        if (port > 0) return true
        val dir = java.io.File(Repo.appCtx.cacheDir, "torrent").apply { mkdirs() }
        port = com.thayphong.phimengine.Phimengine.start(dir.absolutePath)
        return port > 0
    }
    val lastError: String get() = com.thayphong.phimengine.Phimengine.lastError()
    fun url(hash: String, fileIdx: Int?, trackers: List<String>, hint: String?): String? {
        if (!start()) return null
        var magnet = "magnet:?xt=urn:btih:$hash"
        trackers.forEach { magnet += "&tr=" + enc(it) }
        val h = com.thayphong.phimengine.Phimengine.addMagnet(magnet)
        if (h.isNullOrEmpty()) return null
        var s = "http://127.0.0.1:$port/stream/$h/${fileIdx ?: -1}"
        if (!hint.isNullOrEmpty()) s += "?hint=" + enc(hint)
        return s
    }
    fun status(hash: String): JSONObject? = runCatching { JSONObject(com.thayphong.phimengine.Phimengine.status(hash)) }.getOrNull()
    fun stopAll() { Thread { runCatching { com.thayphong.phimengine.Phimengine.dropAll() } }.start() }
}

object TorBox {
    private const val API = "https://api.torbox.app/v1/api"
    private fun call(path: String, key: String, form: Map<String, String>? = null): JSONObject? = runCatching {
        val c = URL(API + path).openConnection() as HttpURLConnection
        c.connectTimeout = 20000; c.readTimeout = 20000
        c.setRequestProperty("Authorization", "Bearer $key")
        if (form != null) {
            val b = "pt" + System.nanoTime()
            c.requestMethod = "POST"; c.doOutput = true
            c.setRequestProperty("Content-Type", "multipart/form-data; boundary=$b")
            val body = StringBuilder()
            form.forEach { (k, v) -> body.append("--$b\r\nContent-Disposition: form-data; name=\"$k\"\r\n\r\n$v\r\n") }
            body.append("--$b--\r\n")
            c.outputStream.use { it.write(body.toString().toByteArray()) }
        }
        val txt = (if (c.responseCode < 400) c.inputStream else c.errorStream).use { String(it.readBytes()) }
        JSONObject(txt)
    }.getOrNull()

    fun cached(hash: String, key: String): Boolean {
        val j = call("/torrents/checkcached?hash=$hash&format=list", key) ?: return false
        val d = j.opt("data")
        return (d is JSONArray && d.length() > 0) || (d is JSONObject && d.length() > 0)
    }

    fun link(s: Stream, hash: String, season: Int?, episode: Int?, key: String): String? {
        var magnet = "magnet:?xt=urn:btih:$hash"
        s.trackers.take(10).forEach { magnet += "&tr=" + enc(it) }
        val tid = call("/torrents/createtorrent", key, mapOf("magnet" to magnet, "seed" to "3"))?.optJSONObject("data")?.int("torrent_id") ?: return null
        var files = emptyList<JSONObject>()
        repeat(15) {
            files = call("/torrents/mylist?id=$tid&bypass_cache=true", key)?.optJSONObject("data")?.optJSONArray("files").objs()
            if (files.isNotEmpty()) return@repeat
            Thread.sleep(1000)
        }
        if (files.isEmpty()) return null
        val vids = files.filter { f -> listOf(".mkv", ".mp4", ".avi", ".mov", ".m4v", ".ts", ".webm").any { (f.str("name") ?: "").lowercase().endsWith(it) } }
        val pool = vids.ifEmpty { files }
        var pick: JSONObject? = s.filename?.let { h -> pool.firstOrNull { (it.str("name") ?: "").lowercase().contains(h.lowercase()) } }
        if (pick == null && season != null && episode != null) {
            val pats = listOf("s%02de%02d".format(season, episode), "${season}x%02d".format(episode))
            pick = pool.firstOrNull { f -> pats.any { (f.str("name") ?: "").lowercase().contains(it) } }
        }
        if (pick == null) pick = pool.maxByOrNull { it.optLong("size") }
        val fid = pick?.int("id") ?: return null
        return call("/torrents/requestdl?token=$key&torrent_id=$tid&file_id=$fid", key)?.str("data")
    }
}

data class Resolved(val url: String, val headers: Map<String, String>, val torrentHash: String?, val via: String)

suspend fun resolve(s: Stream, season: Int?, episode: Int?): Resolved = withContext(Dispatchers.IO) {
    val u = s.url
    if (u != null && u.startsWith("http")) return@withContext Resolved(u, s.headers, null, "Link trực tiếp")
    var hash = s.infoHash
    if (hash == null && u != null && u.startsWith("magnet:")) {
        hash = Regex("btih:([a-zA-Z0-9]+)").find(u)?.groupValues?.get(1)?.lowercase()
    }
    val h = hash ?: throw Exception("Nguồn này không phát được trong app")
    val key = Repo.torboxKey.value.trim()
    if (key.isNotEmpty() && TorBox.cached(h, key)) {
        TorBox.link(s, h, season, episode, key)?.let { return@withContext Resolved(it, emptyMap(), null, "TorBox") }
    }
    val url = Engine.url(h, s.fileIdx, s.trackers, if (s.fileIdx == null) s.filename else null)
        ?: throw Exception("Không khởi động được bộ tải torrent: ${Engine.lastError}")
    Resolved(url, emptyMap(), h, "Torrent trong app")
}

// ---------------------------------------------------------------- phụ đề
data class Cue(val start: Double, val end: Double, val text: String)

object Subs {
    fun load(url: String): List<Cue> {
        var data = Repo.httpBytes(url, timeout = 60000) ?: return emptyList()
        if (data.size > 2 && data[0] == 0x1f.toByte() && data[1] == 0x8b.toByte()) {
            data = runCatching { GZIPInputStream(data.inputStream()).use { it.readBytes() } }.getOrDefault(data)
        }
        val text = decode(data)
        return if (text.contains("[Script Info]", true) || text.contains("Dialogue:")) parseAss(text) else parseSrt(text)
    }

    private fun decode(b: ByteArray): String {
        if (b.size >= 3 && b[0] == 0xEF.toByte() && b[1] == 0xBB.toByte() && b[2] == 0xBF.toByte()) return String(b, 3, b.size - 3, Charsets.UTF_8)
        if (b.size >= 2 && b[0] == 0xFF.toByte() && b[1] == 0xFE.toByte()) return String(b, 2, b.size - 2, Charsets.UTF_16LE)
        if (b.size >= 2 && b[0] == 0xFE.toByte() && b[1] == 0xFF.toByte()) return String(b, 2, b.size - 2, Charsets.UTF_16BE)
        val dec = Charsets.UTF_8.newDecoder()
        runCatching { return dec.decode(java.nio.ByteBuffer.wrap(b)).toString() }
        return runCatching { java.text.Normalizer.normalize(String(b, Charset.forName("windows-1258")), java.text.Normalizer.Form.NFC) }
            .getOrElse { String(b, Charsets.ISO_8859_1) }
    }

    private fun time(s: String): Double? {
        val t = s.trim().split(" ").first().replace(',', '.')
        val parts = t.split(":")
        if (parts.size < 2) return null
        var sec = 0.0
        for (p in parts) sec = sec * 60 + (p.toDoubleOrNull() ?: return null)
        return sec
    }

    private fun clean(s: String) = s.replace(Regex("<[^>]+>"), "").replace(Regex("\\{[^}]*\\}"), "")
        .replace("&nbsp;", " ").replace("&amp;", "&").trim()

    fun parseSrt(text: String): List<Cue> {
        val cues = mutableListOf<Cue>()
        for (block in text.replace("\r\n", "\n").replace('\r', '\n').split(Regex("\n\\s*\n"))) {
            val lines = block.split("\n").filter { it.isNotBlank() }
            val ti = lines.indexOfFirst { it.contains("-->") }
            if (ti < 0) continue
            val tp = lines[ti].split("-->")
            if (tp.size != 2) continue
            val a = time(tp[0]) ?: continue
            val b = time(tp[1]) ?: continue
            val body = clean(lines.drop(ti + 1).joinToString("\n"))
            if (body.isNotEmpty()) cues.add(Cue(a, b, body))
        }
        return cues.sortedBy { it.start }
    }

    fun parseAss(text: String): List<Cue> {
        val cues = mutableListOf<Cue>()
        var fmt = listOf("layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text")
        for (raw in text.lines()) {
            val line = raw.trim()
            if (line.lowercase().startsWith("format:") && line.lowercase().contains("text") && line.lowercase().contains("start")) {
                fmt = line.substring(7).split(",").map { it.trim().lowercase() }
            } else if (line.lowercase().startsWith("dialogue:")) {
                val parts = line.substring(9).split(",", limit = fmt.size)
                if (parts.size != fmt.size) continue
                val a = time(parts[fmt.indexOf("start")]) ?: continue
                val b = time(parts[fmt.indexOf("end")]) ?: continue
                val t = clean(parts.last().replace("\\N", "\n").replace("\\n", "\n").replace("\\h", " "))
                if (t.isNotEmpty()) cues.add(Cue(a, b, t))
            }
        }
        return cues.sortedBy { it.start }
    }

    fun textAt(t: Double, cues: List<Cue>): String {
        var lo = 0; var hi = cues.size - 1; var idx = -1
        while (lo <= hi) { val m = (lo + hi) / 2; if (cues[m].start <= t) { idx = m; lo = m + 1 } else hi = m - 1 }
        if (idx < 0) return ""
        val out = mutableListOf<String>()
        var i = idx
        while (i >= 0 && i > idx - 4) { if (cues[i].start <= t && t <= cues[i].end) out.add(0, cues[i].text); i-- }
        return out.joinToString("\n")
    }
}

@Suppress("unused")
private fun ByteArray.toStr() = ByteArrayOutputStream().also { it.write(this) }.toString()

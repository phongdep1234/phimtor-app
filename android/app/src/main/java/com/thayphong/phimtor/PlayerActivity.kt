package com.thayphong.phimtor

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.util.VLCVideoLayout

class PlayerActivity : ComponentActivity() {
    companion object {
        private var pendingStream: Stream? = null
        fun start(ctx: Context, r: Resolved, title: String, type: String, videoId: String, s: Stream, recent: Recent) {
            pendingStream = s
            ctx.startActivity(Intent(ctx, PlayerActivity::class.java)
                .putExtra("url", r.url).putExtra("via", r.via).putExtra("hash", r.torrentHash)
                .putExtra("headers", JSONObject(r.headers).toString())
                .putExtra("title", title).putExtra("type", type).putExtra("videoId", videoId)
                .putExtra("recent", recent.toJson().toString()))
        }
    }

    private lateinit var vlc: LibVLC
    private lateinit var mp: MediaPlayer
    private lateinit var layout: VLCVideoLayout

    // trạng thái cho giao diện
    private val playing = mutableStateOf(false)
    private val buffering = mutableStateOf(true)
    private val timeMs = mutableStateOf(0L)
    private val lengthMs = mutableStateOf(0L)
    private val error = mutableStateOf<String?>(null)
    private val info = mutableStateOf("")
    private val controls = mutableStateOf(true)
    private val lastTouch = mutableStateOf(System.currentTimeMillis())
    private val showSubs = mutableStateOf(false)
    private val subs = mutableStateListOf<Sub>()
    private val selected = mutableStateOf<String?>(null)
    private val cues = mutableStateOf<List<Cue>>(emptyList())
    private val subDelay = mutableStateOf(0.0)
    private val fill = mutableStateOf(false)
    private var started = false
    private var hash: String? = null
    private lateinit var videoId: String
    private lateinit var recent: Recent

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        hideSystemBars()
        val url = intent.getStringExtra("url") ?: return finish()
        hash = intent.getStringExtra("hash")
        videoId = intent.getStringExtra("videoId") ?: ""
        recent = Recent.from(JSONObject(intent.getStringExtra("recent") ?: "{}"))
        val type = intent.getStringExtra("type") ?: "movie"
        val title = intent.getStringExtra("title") ?: ""
        val via = intent.getStringExtra("via") ?: ""
        val headers = runCatching { JSONObject(intent.getStringExtra("headers") ?: "{}") }.getOrDefault(JSONObject())

        vlc = LibVLC(this, arrayListOf("--network-caching=${if (hash != null) 8000 else 4000}", "--http-reconnect", "--no-sub-autodetect-file"))
        mp = MediaPlayer(vlc)
        layout = VLCVideoLayout(this)
        mp.attachViews(layout, null, false, false)
        mp.setEventListener { e ->
            when (e.type) {
                MediaPlayer.Event.Playing -> {
                    playing.value = true; buffering.value = false
                    if (!started) {
                        started = true
                        val resume = Repo.position(videoId)
                        if (resume > 30) mp.time = (resume * 1000).toLong()
                    }
                }
                MediaPlayer.Event.Paused -> playing.value = false
                MediaPlayer.Event.Buffering -> buffering.value = e.buffering < 100f
                MediaPlayer.Event.TimeChanged -> { timeMs.value = e.timeChanged; if (buffering.value && mp.isPlaying) buffering.value = false }
                MediaPlayer.Event.LengthChanged -> lengthMs.value = e.lengthChanged
                MediaPlayer.Event.EncounteredError -> { error.value = "Không phát được nguồn này. Hãy thử nguồn khác."; buffering.value = false }
                MediaPlayer.Event.EndReached -> { playing.value = false; saveProgress() }
            }
        }
        val media = Media(vlc, Uri.parse(url))
        headers.optString("User-Agent").takeIf { it.isNotEmpty() }?.let { media.addOption(":http-user-agent=$it") }
        headers.optString("Referer").takeIf { it.isNotEmpty() }?.let { media.addOption(":http-referrer=$it") }
        mp.media = media
        media.release()
        mp.play()

        setContent {
            MaterialTheme(colorScheme = darkColorScheme(primary = Yellow)) {
                PlayerUi(title, via)
            }
        }

        // phụ đề từ add-on
        val stream = pendingStream
        kotlinx.coroutines.MainScope().launch {
            val list = Repo.subtitles(type, videoId, stream)
            subs.clear(); subs.addAll(list)
            if (Repo.autoViet.value && selected.value == null) {
                val vi = list.filter { it.isViet }
                val pick = if (Repo.preferHuman.value) vi.firstOrNull { !it.isMachine } ?: vi.firstOrNull() else vi.firstOrNull()
                pick?.let { selectSub(it) }
            }
        }
        // vòng lặp: thông tin torrent, lưu vị trí, tự ẩn điều khiển
        kotlinx.coroutines.MainScope().launch {
            var n = 0
            while (!isFinishing) {
                delay(1000); n++
                if (n % 10 == 0 && timeMs.value > 5000) saveProgress()
                if (controls.value && playing.value && !showSubs.value && System.currentTimeMillis() - lastTouch.value > 4500) controls.value = false
                val h = hash
                if (h != null && (buffering.value || !playing.value)) {
                    Engine.status(h)?.let { s ->
                        val mb = s.optLong("downloaded") / 1_048_576
                        info.value = if (s.optBoolean("ready")) "${s.optInt("peers")} nguồn chia sẻ • đã tải $mb MB"
                        else "Đang tìm nguồn chia sẻ… (${s.optInt("peers")})"
                    }
                } else info.value = ""
            }
        }
    }

    private fun hideSystemBars() {
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_FULLSCREEN
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) { super.onWindowFocusChanged(hasFocus); if (hasFocus) hideSystemBars() }

    private fun saveProgress() {
        val t = timeMs.value / 1000.0; val l = lengthMs.value / 1000.0
        Repo.setPosition(videoId, if (l > 0 && t > l - 120) 0.0 else t)
        Repo.touchRecent(recent.copy(position = t, duration = l))
    }

    private fun bump() { lastTouch.value = System.currentTimeMillis() }
    private fun toggle() { if (mp.isPlaying) mp.pause() else mp.play(); bump() }
    private fun seekBy(d: Long) { val t = (mp.time + d).coerceAtLeast(0); mp.time = t; timeMs.value = t; bump() }

    private fun selectSub(s: Sub?) {
        mp.spuTrack = -1
        if (s == null) { selected.value = null; cues.value = emptyList(); return }
        selected.value = s.id
        cues.value = emptyList()
        kotlinx.coroutines.MainScope().launch {
            val c = withContext(Dispatchers.IO) { runCatching { Subs.load(s.url) }.getOrDefault(emptyList()) }
            if (selected.value == s.id) {
                cues.value = c
                if (c.isEmpty()) error.value = "Phụ đề này bị lỗi, hãy chọn bản khác."
            }
        }
    }

    private fun selectEmbedded(id: Int) { cues.value = emptyList(); selected.value = "emb:$id"; mp.spuTrack = id }

    // Phím điều khiển TV khi đang ẩn điều khiển
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (showSubs.value) return super.onKeyDown(keyCode, event)
        when (keyCode) {
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_MEDIA_PLAY, KeyEvent.KEYCODE_MEDIA_PAUSE -> { toggle(); return true }
            KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> { seekBy(30000); return true }
            KeyEvent.KEYCODE_MEDIA_REWIND -> { seekBy(-30000); return true }
        }
        if (!controls.value) {
            when (keyCode) {
                KeyEvent.KEYCODE_DPAD_LEFT -> { seekBy(-10000); return true }
                KeyEvent.KEYCODE_DPAD_RIGHT -> { seekBy(10000); return true }
                KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN -> {
                    controls.value = true; bump(); return true
                }
            }
        }
        bump()
        return super.onKeyDown(keyCode, event)
    }

    override fun onPause() { super.onPause(); saveProgress(); if (mp.isPlaying) mp.pause() }

    override fun onDestroy() {
        super.onDestroy()
        runCatching { mp.stop(); mp.detachViews(); mp.release(); vlc.release() }
        if (hash != null) Engine.stopAll()
    }

    private fun fmt(ms: Long): String {
        val s = (ms / 1000).coerceAtLeast(0); val h = s / 3600; val m = (s % 3600) / 60; val se = s % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, se) else "%02d:%02d".format(m, se)
    }

    @Composable
    fun PlayerUi(title: String, via: String) {
        val playFocus = remember { FocusRequester() }
        var subText by remember { mutableStateOf("") }
        LaunchedEffect(Unit) {
            while (true) {
                delay(100)
                val c = cues.value
                subText = if (c.isEmpty()) "" else Subs.textAt(mp.time / 1000.0 - subDelay.value, c)
            }
        }
        BackHandler(showSubs.value) { showSubs.value = false }
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            AndroidView({ layout.apply { layoutParams = FrameLayout.LayoutParams(-1, -1) } }, Modifier.fillMaxSize())
            // lớp nhận chạm
            Box(Modifier.fillMaxSize().pointerInput(Unit) {
                detectTapGestures(
                    onTap = { controls.value = !controls.value; bump() },
                    onDoubleTap = { o -> seekBy(if (o.x < size.width / 2) -10000 else 10000) }
                )
            })
            // phụ đề tự vẽ
            if (subText.isNotEmpty()) {
                Box(Modifier.fillMaxSize().padding(bottom = if (controls.value) 96.dp else 28.dp, start = 40.dp, end = 40.dp), contentAlignment = Alignment.BottomCenter) {
                    Text(subText, textAlign = TextAlign.Center, color = Color.White, fontWeight = FontWeight.SemiBold,
                        style = TextStyle(fontSize = Repo.subSize.value.sp, shadow = Shadow(Color.Black, blurRadius = 6f)),
                        modifier = Modifier.background(Color(0x88000000), RoundedCornerShape(6.dp)).padding(horizontal = 10.dp, vertical = 4.dp))
                }
            }
            if (buffering.value || (info.value.isNotEmpty() && !playing.value)) {
                Column(Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
                    if (buffering.value) CircularProgressIndicator(color = Color.White)
                    if (info.value.isNotEmpty()) Text(info.value, color = Color(0xDDFFFFFF), fontSize = 13.sp, modifier = Modifier.padding(top = 10.dp))
                }
            }
            if (controls.value) Controls(title, via, playFocus)
            if (showSubs.value) SubPanel()
            error.value?.let { e ->
                AlertDialog(onDismissRequest = { error.value = null }, confirmButton = { TextButton({ error.value = null }) { Text("OK") } },
                    title = { Text("Lỗi") }, text = { Text(e) })
            }
        }
        LaunchedEffect(controls.value) { if (controls.value) runCatching { playFocus.requestFocus() } }
    }

    @Composable
    fun Controls(title: String, via: String, playFocus: FocusRequester) {
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xB0000000), Color.Transparent, Color.Transparent, Color(0xC0000000))))) {
            Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                CtrlBtn(Icons.Filled.Close) { finish() }
                Column(Modifier.weight(1f).padding(horizontal = 8.dp)) {
                    Text(title, color = Color.White, fontWeight = FontWeight.Bold, maxLines = 1)
                    Text(via, color = Color(0xAAFFFFFF), fontSize = 11.sp)
                }
                CtrlBtn(if (fill.value) Icons.Filled.FullscreenExit else Icons.Filled.Fullscreen) {
                    fill.value = !fill.value
                    mp.videoScale = if (fill.value) MediaPlayer.ScaleType.SURFACE_FILL else MediaPlayer.ScaleType.SURFACE_BEST_FIT
                }
                CtrlBtn(Icons.Filled.Subtitles) { showSubs.value = true; bump() }
            }
            Row(Modifier.align(Alignment.Center), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(40.dp)) {
                CtrlBtn(Icons.Filled.Replay10, 40) { seekBy(-10000) }
                CtrlBtn(if (playing.value) Icons.Filled.Pause else Icons.Filled.PlayArrow, 56, Modifier.focusRequester(playFocus)) { toggle() }
                CtrlBtn(Icons.Filled.Forward10, 40) { seekBy(10000) }
            }
            Row(Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(16.dp, 0.dp, 16.dp, 14.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(fmt(timeMs.value), color = Color.White, fontSize = 12.sp)
                var drag by remember { mutableStateOf<Float?>(null) }
                Slider(value = drag ?: (if (lengthMs.value > 0) timeMs.value.toFloat() / lengthMs.value else 0f),
                    onValueChange = { drag = it; bump() },
                    onValueChangeFinished = { drag?.let { mp.time = (it * lengthMs.value).toLong(); timeMs.value = mp.time }; drag = null },
                    modifier = Modifier.weight(1f).padding(horizontal = 10.dp).tvFocus(),
                    colors = SliderDefaults.colors(thumbColor = Yellow, activeTrackColor = Yellow))
                Text(fmt(lengthMs.value), color = Color.White, fontSize = 12.sp)
            }
        }
    }

    @Composable
    fun CtrlBtn(icon: androidx.compose.ui.graphics.vector.ImageVector, size: Int = 28, modifier: Modifier = Modifier, onClick: () -> Unit) {
        IconButton(onClick = { onClick(); bump() }, modifier = modifier.size((size + 16).dp).tvFocus(RoundedCornerShape(40.dp))) {
            Icon(icon, null, tint = Color.White, modifier = Modifier.size(size.dp))
        }
    }

    @Composable
    fun SubPanel() {
        val groups = subs.groupBy { if (it.isViet) (if (it.isMachine) "Tiếng Việt (dịch máy)" else "Tiếng Việt") else it.langName }
        val embedded = remember { mp.spuTracks?.filter { it.id >= 0 } ?: emptyList() }
        val audio = remember { mp.audioTracks?.filter { it.id >= 0 } ?: emptyList() }
        Box(Modifier.fillMaxSize().background(Color(0x66000000)).clickable { showSubs.value = false }) {
            Surface(Modifier.align(Alignment.CenterEnd).fillMaxHeight().widthIn(max = 420.dp).fillMaxWidth(0.5f).clickable(enabled = false) {},
                color = Color(0xF0151129)) {
                LazyColumn(contentPadding = PaddingValues(14.dp)) {
                    item { Text("Phụ đề", fontWeight = FontWeight.Bold, fontSize = 20.sp, color = Color.White) }
                    item {
                        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 6.dp)) {
                            Text("Độ trễ  %+.1fs".format(subDelay.value), color = Color.White, modifier = Modifier.weight(1f))
                            CtrlBtn(Icons.Filled.Remove, 22) { subDelay.value -= 0.5 }
                            CtrlBtn(Icons.Filled.Add, 22) { subDelay.value += 0.5 }
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("Cỡ chữ  ${Repo.subSize.value.toInt()}", color = Color.White, modifier = Modifier.weight(1f))
                            CtrlBtn(Icons.Filled.TextDecrease, 22) { if (Repo.subSize.value > 14) { Repo.subSize.value -= 2; Repo.saveSettings() } }
                            CtrlBtn(Icons.Filled.TextIncrease, 22) { if (Repo.subSize.value < 48) { Repo.subSize.value += 2; Repo.saveSettings() } }
                        }
                    }
                    item { SubRow("Tắt phụ đề", null, selected.value == null) { selectSub(null) } }
                    if (subs.isEmpty()) item { Text("Đang tìm / chưa có phụ đề ngoài.", color = Color.Gray, fontSize = 13.sp, modifier = Modifier.padding(8.dp)) }
                    groups.forEach { (g, list) ->
                        item { Text(g, color = Yellow, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 12.dp, bottom = 4.dp)) }
                        items(list, key = { it.id }) { s -> SubRow(s.label ?: s.addonName, if (s.label != null) s.addonName else null, selected.value == s.id) { selectSub(s) } }
                    }
                    if (embedded.isNotEmpty()) {
                        item { Text("Phụ đề nhúng trong file", color = Yellow, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 12.dp, bottom = 4.dp)) }
                        items(embedded, key = { "e${it.id}" }) { t -> SubRow(t.name, null, selected.value == "emb:${t.id}") { selectEmbedded(t.id) } }
                    }
                    if (audio.size > 1) {
                        item { Text("Âm thanh", color = Yellow, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 12.dp, bottom = 4.dp)) }
                        items(audio, key = { "a${it.id}" }) { t -> SubRow(t.name, null, mp.audioTrack == t.id) { mp.audioTrack = t.id } }
                    }
                }
            }
        }
    }

    @Composable
    fun SubRow(t: String, sub: String?, on: Boolean, onClick: () -> Unit) {
        Row(Modifier.fillMaxWidth().padding(vertical = 2.dp).tvFocus().clip(RoundedCornerShape(8.dp))
            .background(if (on) Color(0x33FFD54A) else Color.Transparent).clickable { onClick(); bump() }.padding(10.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(t, color = Color.White, fontSize = 14.sp, maxLines = 2)
                sub?.let { Text(it, color = Color.Gray, fontSize = 11.sp) }
            }
            if (on) Icon(Icons.Filled.Check, null, tint = Yellow)
        }
    }
}

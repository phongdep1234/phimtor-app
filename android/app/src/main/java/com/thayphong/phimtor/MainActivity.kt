package com.thayphong.phimtor

import android.app.UiModeManager
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import kotlinx.coroutines.launch

val Yellow = Color(0xFFFFD54A)
val Bg = Color(0xFF0E0B22)

sealed class Screen {
    data object Home : Screen()
    data object Search : Screen()
    data object Addons : Screen()
    data object Settings : Screen()
    data class CatalogGrid(val addonUrl: String, val catalog: Catalog) : Screen()
    data class Detail(val seed: Meta, val addonUrl: String?) : Screen()
    data class Streams(val type: String, val videoId: String, val title: String, val meta: Meta, val addonUrl: String?, val season: Int?, val episode: Int?) : Screen()
}

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        intent?.data?.let { handleLink(it) }
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(primary = Yellow, onPrimary = Color.Black, background = Bg, surface = Color(0xFF17132E))) {
                Surface(color = Bg, modifier = Modifier.fillMaxSize()) { AppRoot() }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.data?.let { handleLink(it) }
    }

    // phimtor://install?url=...  (để cài add-on nhanh)
    private fun handleLink(u: Uri) {
        val url = u.getQueryParameter("url") ?: return
        kotlinx.coroutines.MainScope().launch { Toast.makeText(this@MainActivity, Repo.install(url), Toast.LENGTH_LONG).show() }
    }
}

fun isTv(ctx: Context): Boolean =
    (ctx.getSystemService(Context.UI_MODE_SERVICE) as UiModeManager).currentModeType == Configuration.UI_MODE_TYPE_TELEVISION

/** Viền vàng + phóng to nhẹ khi được chọn bằng điều khiển TV */
fun Modifier.tvFocus(shape: RoundedCornerShape = RoundedCornerShape(8.dp)): Modifier = composed {
    var f by remember { mutableStateOf(false) }
    this.onFocusChanged { f = it.isFocused }
        .scale(if (f) 1.06f else 1f)
        .border(BorderStroke(if (f) 3.dp else 0.dp, if (f) Yellow else Color.Transparent), shape)
}

@Composable
fun AppRoot() {
    val ctx = LocalContext.current
    val tv = remember { isTv(ctx) }
    val wide = LocalConfiguration.current.screenWidthDp >= 720
    var stack by remember { mutableStateOf(listOf<Screen>(Screen.Home)) }
    val push: (Screen) -> Unit = { stack = stack + it }
    val top = stack.last()
    LaunchedEffect(Unit) { Repo.ensureBuiltIns() }
    BackHandler(stack.size > 1) { stack = stack.dropLast(1) }

    val tabs = listOf(
        Triple(Screen.Home, "Khám phá", Icons.Filled.Movie),
        Triple(Screen.Search, "Tìm kiếm", Icons.Filled.Search),
        Triple(Screen.Addons, "Add-on", Icons.Filled.Extension),
        Triple(Screen.Settings, "Cài đặt", Icons.Filled.Settings)
    )
    val root = stack.first()
    val content: @Composable () -> Unit = {
        when (val s = top) {
            Screen.Home -> HomeScreen(push)
            Screen.Search -> SearchScreen(push)
            Screen.Addons -> AddonsScreen()
            Screen.Settings -> SettingsScreen()
            is Screen.CatalogGrid -> CatalogGridScreen(s, push)
            is Screen.Detail -> DetailScreen(s, push)
            is Screen.Streams -> StreamsScreen(s)
        }
    }
    if (tv || wide) {
        Row(Modifier.fillMaxSize()) {
            NavigationRail(containerColor = Color(0xFF120E28)) {
                Spacer(Modifier.height(12.dp))
                tabs.forEach { (sc, label, icon) ->
                    NavigationRailItem(selected = root == sc, onClick = { stack = listOf(sc) },
                        icon = { Icon(icon, label) }, label = { Text(label) }, modifier = Modifier.tvFocus())
                }
            }
            Box(Modifier.weight(1f)) { content() }
        }
    } else {
        Scaffold(containerColor = Bg, bottomBar = {
            NavigationBar(containerColor = Color(0xFF120E28)) {
                tabs.forEach { (sc, label, icon) ->
                    NavigationBarItem(selected = root == sc, onClick = { stack = listOf(sc) }, icon = { Icon(icon, label) }, label = { Text(label) })
                }
            }
        }) { pad -> Box(Modifier.padding(pad)) { content() } }
    }
}

@Composable
fun Header(t: String, sub: String? = null) {
    Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
        Text(t, fontSize = 24.sp, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis)
        sub?.let { Text(it, fontSize = 13.sp, color = Color.Gray) }
    }
}

@Composable
fun Poster(url: String?, width: Int = 112, landscape: Boolean = false, modifier: Modifier = Modifier) {
    val h = if (landscape) width * 9 / 16 else width * 3 / 2
    Box(modifier.size(width.dp, h.dp).clip(RoundedCornerShape(8.dp)).background(Color(0x22FFFFFF)), contentAlignment = Alignment.Center) {
        Icon(Icons.Filled.Movie, null, tint = Color.DarkGray)
        AsyncImage(model = url, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
    }
}

@Composable
fun MetaCard(m: Meta, width: Int = 112, onClick: () -> Unit) {
    Column(Modifier.width(width.dp).tvFocus().clip(RoundedCornerShape(8.dp)).clickable(onClick = onClick)) {
        Poster(m.poster, width, m.landscape)
        Text(m.name, fontSize = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 4.dp, bottom = 4.dp))
    }
}

// ---------------------------------------------------------------- trang chủ
@Composable
fun HomeScreen(push: (Screen) -> Unit) {
    val rows = Repo.addons.flatMap { a -> a.manifest.catalogs.filter { !it.needsSomething }.map { a to it } }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
        item { Header("PhimTor") }
        if (Repo.recents.isNotEmpty()) item {
            Column {
                Text("Đang xem", fontSize = 18.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(horizontal = 16.dp))
                LazyRow(contentPadding = PaddingValues(16.dp, 8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    items(Repo.recents.toList(), key = { it.id }) { r ->
                        Column(Modifier.width(112.dp).tvFocus().clickable {
                            push(Screen.Detail(Meta.stub(r.id, r.type, r.name, r.poster), r.addonUrl))
                        }) {
                            Poster(r.poster)
                            if (r.duration > 0) LinearProgressIndicator(progress = { (r.position / r.duration).toFloat().coerceIn(0f, 1f) },
                                modifier = Modifier.fillMaxWidth().padding(top = 3.dp), color = Yellow)
                            Text(r.videoTitle ?: r.name, fontSize = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
            }
        }
        if (rows.isEmpty()) item { Text("Chưa có danh mục phim. Vào mục Add-on để thêm add-on.", color = Color.Gray, modifier = Modifier.padding(16.dp)) }
        items(rows, key = { it.first.transportUrl + it.second.uid }) { (a, c) -> CatalogRow(a, c, push) }
    }
}

@Composable
fun CatalogRow(a: Addon, c: Catalog, push: (Screen) -> Unit) {
    var items by remember { mutableStateOf<List<Meta>?>(null) }
    LaunchedEffect(a.transportUrl, c.uid) { items = Repo.catalog(a, c) }
    if (items?.isEmpty() == true) return
    Column(Modifier.padding(top = 10.dp)) {
        Row(Modifier.fillMaxWidth().tvFocus().clickable { push(Screen.CatalogGrid(a.transportUrl, c)) }.padding(horizontal = 16.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Text(c.name, fontSize = 18.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, false))
            Text("  " + when (c.type) { "movie" -> "Phim lẻ"; "series" -> "Phim bộ"; else -> c.type }, fontSize = 12.sp, color = Color.Gray)
            Spacer(Modifier.weight(1f))
            Icon(Icons.Filled.ChevronRight, null, tint = Color.Gray)
        }
        LazyRow(contentPadding = PaddingValues(16.dp, 8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            val list = items
            if (list == null) items(5) { Poster(null) }
            else items(list, key = { it.id }) { m -> MetaCard(m) { push(Screen.Detail(m, a.transportUrl)) } }
        }
    }
}

@Composable
fun CatalogGridScreen(s: Screen.CatalogGrid, push: (Screen) -> Unit) {
    val addon = Repo.addons.firstOrNull { it.transportUrl == s.addonUrl } ?: return
    var items by remember { mutableStateOf(listOf<Meta>()) }
    var genre by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(false) }
    var end by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    fun more() {
        if (loading || end) return
        loading = true
        scope.launch {
            val ex = mutableListOf<Pair<String, String>>()
            genre?.let { ex.add("genre" to it) }
            if (items.isNotEmpty()) ex.add("skip" to items.size.toString())
            val fresh = Repo.catalog(addon, s.catalog, ex).filter { n -> items.none { it.id == n.id } }
            if (fresh.isEmpty()) end = true
            items = items + fresh
            loading = false
        }
    }
    LaunchedEffect(genre) { items = emptyList(); end = false; more() }
    Column {
        Header(s.catalog.name, addon.manifest.name)
        if (s.catalog.genres.isNotEmpty()) LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            item { Chip("Tất cả", genre == null) { genre = null } }
            items(s.catalog.genres) { g -> Chip(g, genre == g) { genre = g } }
        }
        LazyVerticalGrid(GridCells.Adaptive(110.dp), contentPadding = PaddingValues(16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            items(items, key = { it.id }) { m ->
                MetaCard(m, 110) { push(Screen.Detail(m, s.addonUrl)) }
                if (m.id == items.lastOrNull()?.id) LaunchedEffect(m.id) { more() }
            }
        }
    }
}

@Composable
fun Chip(t: String, on: Boolean, onClick: () -> Unit) {
    Text(t, color = if (on) Color.Black else Color.White, fontSize = 14.sp,
        modifier = Modifier.tvFocus(RoundedCornerShape(16.dp)).clip(RoundedCornerShape(16.dp))
            .background(if (on) Yellow else Color(0x22FFFFFF)).clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 7.dp))
}

// ---------------------------------------------------------------- tìm kiếm
@Composable
fun SearchScreen(push: (Screen) -> Unit) {
    var q by remember { mutableStateOf("") }
    var results by remember { mutableStateOf(listOf<Triple<String, String, List<Meta>>>()) }
    var searching by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    fun run() {
        val query = q.trim(); if (query.isEmpty()) return
        searching = true; results = emptyList()
        scope.launch {
            val cats = Repo.addons.flatMap { a -> a.manifest.catalogs.filter { it.supportsSearch }.map { a to it } }
            val out = kotlinx.coroutines.coroutineScope {
                cats.map { (a, c) -> kotlinx.coroutines.async { Triple("${c.name} · ${a.manifest.name}", a.transportUrl, Repo.catalog(a, c, listOf("search" to query))) } }
                    .map { it.await() }
            }
            results = out.filter { it.third.isNotEmpty() }
            searching = false
        }
    }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
        item { Header("Tìm kiếm") }
        item {
            OutlinedTextField(q, { q = it }, Modifier.fillMaxWidth().padding(horizontal = 16.dp), singleLine = true,
                placeholder = { Text("Tên phim, phim bộ…") }, leadingIcon = { Icon(Icons.Filled.Search, null) },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search), keyboardActions = KeyboardActions(onSearch = { run() }))
        }
        if (searching) item { Box(Modifier.fillMaxWidth().padding(24.dp), Alignment.Center) { CircularProgressIndicator() } }
        if (!searching && results.isEmpty() && q.isNotBlank()) item { Text("Gõ xong bấm tìm trên bàn phím.", color = Color.Gray, modifier = Modifier.padding(16.dp)) }
        items(results, key = { it.first }) { (label, url, list) ->
            Column(Modifier.padding(top = 12.dp)) {
                Text(label, fontWeight = FontWeight.Bold, modifier = Modifier.padding(horizontal = 16.dp))
                LazyRow(contentPadding = PaddingValues(16.dp, 8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    items(list, key = { it.id }) { m -> MetaCard(m) { push(Screen.Detail(m, url)) } }
                }
            }
        }
    }
}

// ---------------------------------------------------------------- chi tiết
@Composable
fun DetailScreen(s: Screen.Detail, push: (Screen) -> Unit) {
    var meta by remember { mutableStateOf<Meta?>(null) }
    var loading by remember { mutableStateOf(true) }
    LaunchedEffect(s.seed.id) { meta = Repo.meta(s.seed.type, s.seed.id, s.addonUrl); loading = false }
    val m = meta ?: s.seed
    val seasons = m.videos.mapNotNull { it.season }.distinct().sortedBy { if (it == 0) 999 else it }
    var season by remember(m.id, seasons.size) { mutableStateOf(seasons.firstOrNull { it > 0 } ?: seasons.firstOrNull() ?: 1) }
    val episodes = if (seasons.isEmpty()) m.videos else m.videos.filter { (it.season ?: 0) == season }
    val isMovieLike = m.videos.isEmpty() || (m.type == "movie" && m.videos.size <= 1)

    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
        item {
            Box(Modifier.fillMaxWidth().height(230.dp)) {
                AsyncImage(m.background ?: m.poster, null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Transparent, Bg))))
                Row(Modifier.align(Alignment.BottomStart).padding(16.dp), verticalAlignment = Alignment.Bottom) {
                    Poster(m.poster, 96)
                    Column(Modifier.padding(start = 12.dp)) {
                        Text(m.name, fontSize = 22.sp, fontWeight = FontWeight.Bold, maxLines = 3)
                        Text(listOfNotNull(m.releaseInfo, m.runtime, m.imdbRating?.let { "★ $it" }).joinToString(" • "), fontSize = 12.sp, color = Color.LightGray)
                    }
                }
            }
        }
        if (m.genres.isNotEmpty()) item { Text(m.genres.take(4).joinToString(" · "), fontSize = 12.sp, color = Color.Gray, modifier = Modifier.padding(horizontal = 16.dp)) }
        m.description?.let { d -> item { Text(d, fontSize = 14.sp, maxLines = 6, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(16.dp, 8.dp)) } }
        if (loading) item { LinearProgressIndicator(Modifier.fillMaxWidth().padding(16.dp), color = Yellow) }
        if (isMovieLike) item {
            Button(onClick = {
                push(Screen.Streams(m.type, m.defaultVideoId ?: m.videos.firstOrNull()?.id ?: m.id, m.name, m, s.addonUrl, null, null))
            }, Modifier.fillMaxWidth().padding(16.dp).tvFocus(RoundedCornerShape(24.dp))) {
                Icon(Icons.Filled.PlayArrow, null); Spacer(Modifier.width(6.dp)); Text("Chọn nguồn phát", fontWeight = FontWeight.Bold)
            }
        } else {
            if (seasons.size > 1) item {
                LazyRow(contentPadding = PaddingValues(16.dp, 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(seasons) { se -> Chip(if (se == 0) "Phụ" else "Mùa $se", season == se) { season = se } }
                }
            }
            items(episodes, key = { it.id }) { v ->
                val label = v.episode?.let { e -> "Tập $e" + (if (v.title.startsWith("Tập") || v.title.lowercase().startsWith("episode")) "" else " · ${v.title}") } ?: v.title
                Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp).tvFocus().clip(RoundedCornerShape(8.dp))
                    .clickable { push(Screen.Streams(m.type, v.id, "${m.name} – $label", m, s.addonUrl, v.season, v.episode)) }
                    .padding(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    v.thumbnail?.let { Poster(it, 120, landscape = true) ; Spacer(Modifier.width(10.dp)) }
                    Column(Modifier.weight(1f)) {
                        Text(label, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                        v.overview?.let { Text(it, fontSize = 12.sp, color = Color.Gray, maxLines = 2, overflow = TextOverflow.Ellipsis) }
                    }
                    if (Repo.position(v.id) > 30) Icon(Icons.Filled.History, null, tint = Yellow)
                }
            }
        }
    }
}

// ---------------------------------------------------------------- nguồn phát
@Composable
fun StreamsScreen(s: Screen.Streams) {
    val ctx = LocalContext.current
    val groups = remember { mutableStateListOf<Pair<String, List<Stream>>>() }
    var done by remember { mutableStateOf(false) }
    var resolving by remember { mutableStateOf<Stream?>(null) }
    var filter by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    LaunchedEffect(s.videoId) {
        groups.clear()
        Repo.streams(s.type, s.videoId) { name, list -> groups.add(name to list) }
        done = true
    }
    fun play(st: Stream) {
        st.ytId?.let { ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://www.youtube.com/watch?v=$it"))); return }
        if (st.url == null && st.infoHash == null && st.externalUrl != null) {
            ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(st.externalUrl))); return
        }
        resolving = st
        scope.launch {
            try {
                val r = resolve(st, s.season, s.episode)
                val recent = Recent(s.meta.id, s.meta.type, s.meta.name, s.meta.poster, s.addonUrl, if (s.episode != null) s.title else null, 0.0, 0.0)
                Repo.touchRecent(recent)
                PlayerActivity.start(ctx, r, s.title, s.type, s.videoId, st, recent)
            } catch (e: Exception) {
                Toast.makeText(ctx, e.message ?: "Không phát được", Toast.LENGTH_LONG).show()
            }
            resolving = null
        }
    }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
        item { Header(s.title, "Chọn nguồn phát") }
        item {
            OutlinedTextField(filter, { filter = it }, Modifier.fillMaxWidth().padding(horizontal = 16.dp), singleLine = true,
                placeholder = { Text("Lọc: 1080p, 4K, vietsub…") })
        }
        if (!done) item { Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) { CircularProgressIndicator(Modifier.size(20.dp)); Text("  Đang hỏi các add-on…", color = Color.Gray) } }
        if (done && groups.all { it.second.isEmpty() }) item { Text("Không có nguồn phát nào. Hãy cài thêm add-on có nguồn phim.", color = Color.Gray, modifier = Modifier.padding(16.dp)) }
        groups.filter { it.second.isNotEmpty() }.forEach { (name, list) ->
            item(key = "h$name") { Text("$name (${list.size})", fontWeight = FontWeight.Bold, color = Color.Gray, modifier = Modifier.padding(16.dp, 14.dp, 16.dp, 4.dp)) }
            itemsIndexed(list.filter { filter.isBlank() || ((it.name ?: "") + (it.title ?: "")).contains(filter, true) }, key = { i, _ -> "$name$i" }) { _, st ->
                Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 3.dp).tvFocus().clip(RoundedCornerShape(8.dp))
                    .background(Color(0x14FFFFFF)).clickable(enabled = resolving == null) { play(st) }.padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        st.name?.let { Text(it, color = Yellow, fontWeight = FontWeight.Bold, fontSize = 14.sp, maxLines = 3) }
                        st.title?.let { Text(it, fontSize = 12.sp, color = Color(0xDDFFFFFF), maxLines = 5) }
                    }
                    if (resolving == st) CircularProgressIndicator(Modifier.size(22.dp))
                    else Icon(if (st.isTorrent) Icons.Filled.Download else Icons.Filled.PlayCircle, null, tint = Color.Gray)
                }
            }
        }
    }
}

// ---------------------------------------------------------------- add-on
@Composable
fun AddonsScreen() {
    val ctx = LocalContext.current
    var url by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var msg by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
        item { Header("Add-on", "Dùng chung add-on với Stremio") }
        item {
            Column(Modifier.padding(horizontal = 16.dp)) {
                OutlinedTextField(url, { url = it }, Modifier.fillMaxWidth(), singleLine = true,
                    placeholder = { Text("Dán link manifest.json hoặc stremio://") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
                Row(Modifier.padding(top = 8.dp)) {
                    OutlinedButton(onClick = {
                        val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        cm.primaryClip?.getItemAt(0)?.text?.let { url = it.toString() }
                    }, Modifier.tvFocus(RoundedCornerShape(24.dp))) { Text("Dán") }
                    Spacer(Modifier.width(10.dp))
                    Button(enabled = url.isNotBlank() && !busy, onClick = {
                        busy = true
                        scope.launch { msg = Repo.install(url); if (msg?.startsWith("Đã") == true) url = ""; busy = false }
                    }, modifier = Modifier.tvFocus(RoundedCornerShape(24.dp))) { Text(if (busy) "Đang cài…" else "Cài add-on") }
                }
                msg?.let { Text(it, fontSize = 13.sp, color = Color.Gray, modifier = Modifier.padding(top = 6.dp)) }
            }
        }
        item { Text("Đã cài", fontWeight = FontWeight.Bold, color = Color.Gray, modifier = Modifier.padding(16.dp, 18.dp, 16.dp, 6.dp)) }
        itemsIndexed(Repo.addons.toList(), key = { _, a -> a.transportUrl }) { i, a ->
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 3.dp).clip(RoundedCornerShape(8.dp)).background(Color(0x14FFFFFF)).padding(10.dp),
                verticalAlignment = Alignment.CenterVertically) {
                AsyncImage(a.manifest.logo, null, Modifier.size(38.dp).clip(RoundedCornerShape(6.dp)))
                Column(Modifier.weight(1f).padding(horizontal = 10.dp)) {
                    Text(a.manifest.name + if (a.builtIn) "  • có sẵn" else "", fontWeight = FontWeight.Bold)
                    Text("v${a.manifest.version} · " + a.manifest.resources.joinToString(", ") {
                        mapOf("catalog" to "danh mục", "meta" to "thông tin", "stream" to "nguồn phát", "subtitles" to "phụ đề")[it.name] ?: it.name
                    }, fontSize = 12.sp, color = Color.Gray)
                }
                SmallIcon(Icons.Filled.KeyboardArrowUp, i > 0) { Repo.addons.add(i - 1, Repo.addons.removeAt(i)); Repo.saveAddons() }
                SmallIcon(Icons.Filled.KeyboardArrowDown, i < Repo.addons.size - 1) { Repo.addons.add(i + 1, Repo.addons.removeAt(i)); Repo.saveAddons() }
                SmallIcon(Icons.Filled.Delete, a.transportUrl != Repo.PHUDEVIET) { Repo.addons.removeAt(i); Repo.saveAddons() }
            }
        }
    }
}

@Composable
fun SmallIcon(icon: ImageVector, enabled: Boolean, onClick: () -> Unit) {
    IconButton(onClick = onClick, enabled = enabled, modifier = Modifier.tvFocus(RoundedCornerShape(20.dp))) { Icon(icon, null) }
}

// ---------------------------------------------------------------- cài đặt
@Composable
fun SettingsScreen() {
    val ctx = LocalContext.current
    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), contentPadding = PaddingValues(bottom = 24.dp)) {
        item { Header("Cài đặt") }
        item {
            Text("TorBox", fontWeight = FontWeight.Bold, color = Color.Gray)
            OutlinedTextField(Repo.torboxKey.value, { Repo.torboxKey.value = it; Repo.saveSettings() }, Modifier.fillMaxWidth(), singleLine = true,
                placeholder = { Text("API key TorBox (không bắt buộc)") }, visualTransformation = PasswordVisualTransformation())
            Text("Có key: phim đã có sẵn trên TorBox sẽ phát qua TorBox. Phim chưa có thì PhimTor tự tải torrent ngay trên máy.",
                fontSize = 12.sp, color = Color.Gray, modifier = Modifier.padding(vertical = 6.dp))
        }
        item {
            Text("Phụ đề", fontWeight = FontWeight.Bold, color = Color.Gray, modifier = Modifier.padding(top = 16.dp))
            SwitchRow("Tự bật phụ đề tiếng Việt", Repo.autoViet.value) { Repo.autoViet.value = it; Repo.saveSettings() }
            SwitchRow("Ưu tiên bản người dịch hơn dịch máy", Repo.preferHuman.value) { Repo.preferHuman.value = it; Repo.saveSettings() }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Cỡ chữ ${Repo.subSize.value.toInt()}", Modifier.weight(1f))
                SmallIcon(Icons.Filled.Remove, Repo.subSize.value > 14) { Repo.subSize.value -= 2; Repo.saveSettings() }
                SmallIcon(Icons.Filled.Add, Repo.subSize.value < 48) { Repo.subSize.value += 2; Repo.saveSettings() }
            }
            Text("Ví dụ phụ đề", fontSize = Repo.subSize.value.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.background(Color(0x99000000)).padding(6.dp))
        }
        item {
            Text("Bộ nhớ", fontWeight = FontWeight.Bold, color = Color.Gray, modifier = Modifier.padding(top = 20.dp))
            TextButton(onClick = { Engine.stopAll(); Toast.makeText(ctx, "Đã xoá dữ liệu tạm", Toast.LENGTH_SHORT).show() }, Modifier.tvFocus()) { Text("Xoá dữ liệu torrent tạm") }
            TextButton(onClick = { Repo.recents.clear(); Repo.saveRecents() }, Modifier.tvFocus()) { Text("Xoá danh sách Đang xem") }
            Text("PhimTor 2.0 • tương thích add-on Stremio", fontSize = 12.sp, color = Color.Gray, modifier = Modifier.padding(top = 16.dp))
        }
    }
}

@Composable
fun SwitchRow(t: String, v: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().tvFocus().clickable { onChange(!v) }.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(t, Modifier.weight(1f)); Switch(v, onChange)
    }
}

package app.baget.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.CropPortrait
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.baget.engine.*
import app.baget.model.*
import app.baget.ui.*
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/** The home screen: today's finds as a swipe deck (or a grid, for people who'd rather tap), then an endless For You. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TodayScreen() {
    val store = AppStore
    val s = store.observe()
    val prefs = remember { store.context.getSharedPreferences("baget.ui", 0) }
    // "cards" (the swipe deck) or "grid". Remembered on this phone.
    var layout by remember { mutableStateOf(prefs.getString("todayLayout", "cards") ?: "cards") }
    // Today's finds, fixed while you go through them so cards don't jump as likes and passes land.
    var deckIDs by rememberSaveable { mutableStateOf(listOf<String>()) }
    var deckIndex by rememberSaveable { mutableIntStateOf(0) }
    var refreshing by remember { mutableStateOf(false) }
    // Bumped each time you pull up past the bottom of Today: loads more picks, or checks for new ones at the end.
    var pullUp by remember { mutableIntStateOf(0) }
    // Bumped each time the bottom of Today scrolls into view.
    var nearBottom by remember { mutableIntStateOf(0) }
    val scroll = rememberScrollState()
    val scope = rememberCoroutineScope()
    val density = androidx.compose.ui.platform.LocalDensity.current

    fun freshDeck(): List<String> {
        val seen = HashSet<String>()
        val cands = (store.todaysPicks(TODAY_DECK_SIZE * 2) + store.swipeQueue).filter { seen.add(it.id) }
        // One card per product: the same thing from three stores is one card (its cheapest), not three.
        return ProductMatch.group(cands).take(TODAY_DECK_SIZE).map { it.lead.id }
    }
    // The deck's products, so For You below can skip them.
    val deckItemIDs = remember(deckIDs, s.finds.size) { deckIDs.mapNotNull { id -> s.finds.firstOrNull { it.id == id }?.itemID }.toSet() }

    LaunchedEffect(Unit) {
        if (deckIDs.isEmpty() || deckIndex >= deckIDs.size) { deckIDs = freshDeck(); deckIndex = 0 }
        Analytics.track(AnalyticsEvent.TODAY_VIEWED, mapOf("toSwipe" to deckIDs.size, "layout" to layout))
    }
    LaunchedEffect(s.finds.size) { if (deckIDs.isEmpty()) { deckIDs = freshDeck(); deckIndex = 0 } }
    LaunchedEffect(scroll) {
        snapshotFlow { scroll.maxValue > 0 && scroll.value >= scroll.maxValue - with(density) { 400.dp.toPx() } }
            .collect { if (it) nearBottom++ }
    }
    LaunchedEffect(Router.todayTop) { if (Router.todayTop > 0) scroll.animateScrollTo(0) }

    // Pulling up past the bottom (like pull-to-refresh, at the other end). Fires once per pull.
    val pullUpConnection = remember {
        object : androidx.compose.ui.input.nestedscroll.NestedScrollConnection {
            var over = 0f
            var fired = false
            override fun onPostScroll(consumed: androidx.compose.ui.geometry.Offset, available: androidx.compose.ui.geometry.Offset,
                                      source: androidx.compose.ui.input.nestedscroll.NestedScrollSource): androidx.compose.ui.geometry.Offset {
                if (available.y < 0 && scroll.value >= scroll.maxValue) {
                    over -= available.y
                    if (!fired && over > with(density) { 70.dp.toPx() }) { fired = true; pullUp++ }
                } else if (available.y > 0 || consumed.y > 0) { over = 0f }
                return androidx.compose.ui.geometry.Offset.Zero
            }
            override suspend fun onPreFling(available: androidx.compose.ui.unit.Velocity): androidx.compose.ui.unit.Velocity {
                over = 0f; fired = false
                return androidx.compose.ui.unit.Velocity.Zero
            }
        }
    }

    PullToRefreshBox(isRefreshing = refreshing, onRefresh = {
        refreshing = true
        store.scope.launch { refreshNow(); deckIDs = freshDeck(); deckIndex = 0; refreshing = false }
    }) {
        Column(Modifier.fillMaxSize().nestedScroll(pullUpConnection).verticalScroll(scroll).padding(horizontal = 16.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp)) {
            TodayHeader(showSwitch = deckIDs.isNotEmpty(), layout = layout) { v ->
                layout = v
                prefs.edit().putString("todayLayout", v).apply()
                Analytics.track(AnalyticsEvent.TODAY_LAYOUT, mapOf("layout" to v))
            }
            if (store.plan?.pro != true) PlanStatusPill()
            // New scout sits above today's finds (the full confirmation right after sending one).
            NewScoutCard(compact = Router.scoutSent == null)
            if (store.isCloud && s.agents.isNotEmpty() && s.finds.isEmpty()) FirstHuntCard()
            if (deckIDs.isNotEmpty()) {
                if (layout == "grid") TodayGrid(deckIDs) else TodayDeck(deckIDs, deckIndex) { deckIndex = it }
            }
            ForYouSection(ForYouMode.TODAY, exclude = deckItemIDs, pullUp = pullUp, nearBottom = nearBottom)
        }
        // Back to top, once the greeting has scrolled away.
        val showTop = scroll.value > with(density) { 120.dp.toPx() }
        androidx.compose.animation.AnimatedVisibility(showTop, Modifier.align(Alignment.BottomEnd).padding(end = 18.dp, bottom = 14.dp),
            enter = androidx.compose.animation.scaleIn() + androidx.compose.animation.fadeIn(),
            exit = androidx.compose.animation.scaleOut() + androidx.compose.animation.fadeOut()) {
            Box(Modifier.size(46.dp).shadow(10.dp, CircleShape).clip(CircleShape).background(T.gradient)
                .clickable { scope.launch { scroll.animateScrollTo(0) } }, contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.ArrowUpward, "Back to top", tint = T.accentInk, modifier = Modifier.size(20.dp))
            }
        }
    }
}

/** The greeting, with the cards / grid switch beside it. */
@Composable
private fun TodayHeader(showSwitch: Boolean, layout: String, onLayout: (String) -> Unit) {
    Row(verticalAlignment = Alignment.Bottom) {
        Box(Modifier.weight(1f)) { Greeting() }
        if (showSwitch) {
            val shape = RoundedCornerShape(10.dp)
            Row(Modifier.padding(start = 8.dp, bottom = 2.dp).clip(shape).background(T.glass).border(1.dp, T.line, shape)) {
                LayoutButton(Icons.Outlined.CropPortrait, layout == "cards", "Swipe cards") { onLayout("cards") }
                LayoutButton(Icons.Outlined.GridView, layout == "grid", "Grid") { onLayout("grid") }
            }
        }
    }
}

@Composable
private fun LayoutButton(icon: androidx.compose.ui.graphics.vector.ImageVector, on: Boolean, label: String, onClick: () -> Unit) {
    Box(Modifier.size(width = 36.dp, height = 30.dp).background(if (on) T.cyan.copy(alpha = 0.18f) else Color.Transparent)
        .clickable(enabled = !on, onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, label, tint = if (on) T.cyan else T.muted, modifier = Modifier.size(16.dp))
    }
}

/** Grid mode: today's finds as tiles, with ✕ and ♥ on each. No swiping. */
@Composable
private fun TodayGrid(ids: List<String>) {
    val s = AppStore.observe()
    val finds = ids.mapNotNull { id -> s.finds.firstOrNull { it.id == id && (it.status == FindStatus.OPEN || it.status == FindStatus.LIKED) } }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Txt("Today's finds", size = T.title3, weight = FontWeight.Black)
        if (finds.isEmpty()) Txt("You've been through today's finds. More for you below.", size = T.footnote, color = T.muted)
        else Grid(finds.size) { i -> val f = finds[i]; FindTile(f) { Router.focusFind = f.id; Router.tab = AppTab.FINDS } }
    }
}

/** Pull to refresh: re-sync (signed in) or run a sample sweep. */
suspend fun refreshNow() {
    val store = AppStore
    if (store.isCloud) store.pull() else {
        val res = store.sweep()
        Analytics.track(AnalyticsEvent.SWEEP_RUN, mapOf("found" to res.found, "manual" to true))
        Router.say(if (res.found > 0) "${res.found} new ${if (res.found == 1) "find" else "finds"}" else "Nothing new fits you right now")
    }
    store.loadForYou()
}

@Composable
private fun Greeting() {
    val store = AppStore
    val s = store.observe()
    val h = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
    val hello = if (h < 12) "Good morning" else if (h < 17) "Good afternoon" else "Good evening"
    val name = s.profile?.displayName?.split(" ")?.firstOrNull()?.takeIf { it.isNotEmpty() }
    Column(Modifier.padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Txt(if (name != null) "$hello, $name" else hello, size = 28.sp, weight = FontWeight.Black, tracking = (-0.6).sp)
        Txt("${s.agents.size} ${if (s.agents.size == 1) "scout" else "scouts"} hunting for you · ${SimpleDateFormat("EEEE, MMMM d", Locale.US).format(Date())}",
            size = T.footnote, color = T.muted)
    }
}

/** Until the first finds land: who's out hunting, so a new account never looks idle. After an hour with nothing, say why. */
@Composable
private fun FirstHuntCard() {
    val store = AppStore
    val s = store.observe()
    // When the first hunt started (kept on this phone), so a scout that's still empty after an hour says why.
    val prefs = remember { store.context.getSharedPreferences("baget.ui", 0) }
    val started = remember { prefs.getLong("firstHuntStarted", 0L) }
    val waited = if (started > 0) now() - started else 0L
    val first = s.agents.firstOrNull { !it.isOff }
    if (waited > 3_600_000L && first != null) { EmptyHuntCard(first); return }
    LaunchedEffect(Unit) {
        if (prefs.getLong("firstHuntStarted", 0L) == 0L) prefs.edit().putLong("firstHuntStarted", now()).apply()
        // Check for the first finds on its own (every 10 seconds, up to 5 minutes), so the card goes away
        // the moment they land instead of waiting for a pull-down.
        repeat(30) {
            kotlinx.coroutines.delay(10_000)
            if (store.state.finds.isNotEmpty()) return@LaunchedEffect
            store.pull()
        }
    }
    Row(Modifier.fillMaxWidth().glass(RoundedCornerShape(16.dp), T.green.copy(alpha = 0.08f), T.green.copy(alpha = 0.3f)).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Row(horizontalArrangement = Arrangement.spacedBy((-8).dp)) { s.agents.take(4).forEach { AgentAvatar(it, 30.dp) } }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Txt("Your scouts' first hunt is on", weight = FontWeight.Bold)
            Txt("Finds usually land within a few minutes. Pull down to check.", size = T.caption, color = T.muted)
        }
        Spinner()
    }
}

/** Nothing yet after an hour: say why, with a one-tap fix, instead of an endless spinner. */
@Composable
private fun EmptyHuntCard(first: Agent) {
    val store = AppStore
    val s = store.observe()
    val noSize = s.agents.firstOrNull { !it.isOff && Sizes.required(it) && !Sizes.has(it) }
    val a = noSize ?: first
    Column(Modifier.fillMaxWidth().glass(RoundedCornerShape(16.dp), T.warn.copy(alpha = 0.08f), T.warn.copy(alpha = 0.3f)).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            AgentAvatar(a, 30.dp)
            Spacer(Modifier.width(10.dp))
            Txt("Nothing worth showing you yet", weight = FontWeight.Bold)
        }
        Txt(if (noSize != null) "${a.name} only flags ${if (a.mission.category == Category.SNEAKERS) "pairs" else "pieces"} in stock in your size, and it doesn't know yours yet."
            else "${a.name} is being picky so you only see good matches. A brand, model or budget gives it much more to go on.",
            size = T.caption, color = T.muted)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.clip(CircleShape).background(T.gradient).clickable { Router.open(Sheet.Chat(a.id)) }.padding(horizontal = 14.dp, vertical = 8.dp)) {
                Txt(if (noSize != null) "Add your size" else "Tell ${a.name} more", size = T.footnote, weight = FontWeight.SemiBold, color = T.accentInk)
            }
            Txt("Hunt again now", size = T.footnote, weight = FontWeight.SemiBold, color = T.accent,
                modifier = Modifier.clickable { store.scope.launch { refreshNow() } }.padding(4.dp))
        }
    }
}

@Composable
fun VerdictChip(v: DealVerdict, showDetail: Boolean = false) {
    val tint = when (v.level) { DealVerdict.Level.GREAT -> T.green; DealVerdict.Level.FAIR -> T.warn; DealVerdict.Level.WAIT -> T.hot; DealVerdict.Level.INFO -> T.accent }
    Row(Modifier.clip(CircleShape).background(tint.copy(alpha = 0.12f)).padding(horizontal = 8.dp, vertical = 3.dp), verticalAlignment = Alignment.CenterVertically) {
        Txt(v.emoji, size = T.caption2)
        Spacer(Modifier.width(5.dp))
        Txt(v.title, size = T.caption, weight = FontWeight.Bold, color = tint, maxLines = 1)
        if (showDetail) Txt(" · ${v.detail}", size = T.caption, color = T.muted, maxLines = 1)
    }
}

enum class ForYouMode { TODAY, FULL }

/** How far Today's endless For You goes (the server's cap). */
const val FOR_YOU_MAX_TODAY = 200

/** "For You": always-on personal picks, ranked by what you like. Every heart and X sharpens it.
 *  Today: one endless feed (nothing already in today's deck), more loading as you reach the bottom. Full: everything, with filters. */
@Composable
fun ForYouSection(mode: ForYouMode = ForYouMode.FULL, exclude: Set<String> = emptySet(), pullUp: Int = 0, nearBottom: Int = 0) {
    val store = AppStore
    val s = store.observe()
    val context = LocalContext.current
    val haptic = androidx.compose.ui.platform.LocalHapticFeedback.current
    var limit by remember { mutableIntStateOf(24) }
    var category by remember { mutableStateOf<Category?>(null) }
    var checking by remember { mutableStateOf(false) }
    var loading by remember { mutableStateOf(false) }
    // The same product from several stores shows once.
    val all = ProductMatch.dedupe(store.forYou.filter { Catalog.item(it.id) != null && it.id !in exclude }).first
    val cats = all.mapNotNull { Catalog.item(it.id)?.category }.distinct().sortedBy { it.info.label }
    val filtered = all.filter { p -> category?.let { Catalog.item(p.id)?.category == it } ?: true }
    val picks = filtered
    val more = store.forYou.size >= limit - 4 && limit < FOR_YOU_MAX_TODAY
    val busy = loading || checking

    /** The next batch of picks; at the end, a check for new ones right here (no trip back to the top). */
    fun loadMoreOrCheck() {
        if (store.forYouLoading || busy) return
        store.scope.launch {
            if (store.forYou.size >= limit - 4 && limit < FOR_YOU_MAX_TODAY) {
                loading = true
                limit = minOf(FOR_YOU_MAX_TODAY, limit + 24)
                store.loadForYou(limit)
                loading = false
            } else {
                checking = true
                refreshNow()
                checking = false
            }
        }
    }
    // Reaching the bottom of Today loads the next batch once (not batch after batch while you sit there).
    LaunchedEffect(nearBottom) { if (nearBottom > 0 && mode == ForYouMode.TODAY && more) loadMoreOrCheck() }
    LaunchedEffect(pullUp) {
        if (pullUp > 0 && mode == ForYouMode.TODAY) {
            haptic.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.LongPress)
            loadMoreOrCheck()
        }
    }
    LaunchedEffect(s.accountID) {
        val at = store.forYouLoadedAt
        if (at == null || at < now() - 180_000 || store.forYou.isEmpty()) store.loadForYou(limit)
    }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (mode == ForYouMode.TODAY) {
            // Today: one endless feed, filters at the top, more loading as you reach the bottom.
            Txt("More for you", size = T.title3, weight = FontWeight.Black)
            Txt("Ranked by your taste. Every ♥ and ✕ sharpens it.", size = T.caption, color = T.muted)
            if (cats.size > 1) {
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    ForYouChip(category == null, "All") { category = null }
                    cats.forEach { c -> ForYouChip(category == c, c.info.label) { category = c } }
                }
            }
        } else {
            Txt("Picked from everything Baget's scouts have found, ranked by your taste. Every ♥ and ✕ sharpens it.", size = T.caption, color = T.muted)
            if (store.tasteTop.isNotEmpty()) {
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    store.tasteTop.forEach { t ->
                        val tint = if (t.likes) T.green else T.hot
                        Row(Modifier.clip(CircleShape).background(tint.copy(alpha = 0.13f)).clickable { Router.open(Sheet.Taste) }
                            .padding(horizontal = 9.dp, vertical = 5.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(if (t.likes) Icons.Filled.Favorite else Icons.Filled.Close, null, tint = tint, modifier = Modifier.size(10.dp))
                            Spacer(Modifier.width(4.dp))
                            Txt(t.label, size = T.caption, weight = FontWeight.Medium, color = tint, maxLines = 1)
                        }
                    }
                }
            }
            if (cats.size > 1) {
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    ForYouChip(category == null, "All") { category = null }
                    cats.forEach { c -> ForYouChip(category == c, c.info.label) { category = c } }
                }
            }
        }
        if (picks.isEmpty()) {
            if (store.forYouLoadedAt == null) {
                Grid(4) { Box(Modifier.fillMaxWidth().height(230.dp).glass(RoundedCornerShape(18.dp))) }
            } else {
                Column(Modifier.fillMaxWidth().glassCard(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Txt("Tell Baget what you're into and this fills up with picks for you.")
                    Flow {
                        listOf(Category.SNEAKERS, Category.FRAGRANCE, Category.WATCHES, Category.APPAREL, Category.FURNITURE, Category.CARS).forEach { c ->
                            Box(Modifier.clickable { Router.deployPrefill = Mission.Cat(c); Router.open(Sheet.Deploy) }) { Tag(c.info.label, T.accent) }
                        }
                    }
                }
            }
        } else {
            Grid(picks.size) { i ->
                val p = picks[i]
                Catalog.item(p.id)?.let { ForYouCard(p, it, context) }
            }
            if (mode == ForYouMode.TODAY) {
                // A button that always works (pulling up past the end does the same).
                Row(Modifier.fillMaxWidth().padding(top = 6.dp).height(46.dp).clip(RoundedCornerShape(14.dp)).background(T.gradient)
                    .clickable(enabled = !busy) { loadMoreOrCheck() }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center) {
                    if (busy) Spinner(16.dp, T.accentInk)
                    else Icon(if (more) Icons.Filled.ArrowDownward else Icons.Filled.Refresh, null, tint = T.accentInk, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(8.dp))
                    Txt(if (busy) "Loading…" else if (more) "Load more picks" else "Check for new picks", weight = FontWeight.Bold, color = T.accentInk)
                }
                // Reaching the bottom loads the next batch once (not batch after batch while you sit there).
                if (!more) Txt("That's everything for now.", size = T.caption, color = T.muted,
                    align = androidx.compose.ui.text.style.TextAlign.Center, modifier = Modifier.fillMaxWidth())
            } else if (store.forYou.size >= limit - 2 && limit < 120) {
                GhostButton("Show more", Modifier.fillMaxWidth()) {
                    limit = minOf(120, limit + 24)
                    store.scope.launch { store.loadForYou(limit) }
                }
            }
        }
    }
}

@Composable
private fun ForYouChip(on: Boolean, label: String, onClick: () -> Unit) {
    Box(Modifier.clip(CircleShape).background(if (on) T.gradient else Brush.linearGradient(listOf(T.glass, T.glass)))
        .border(1.dp, if (on) Color.Transparent else T.line, CircleShape).clickable(onClick = onClick)
        .padding(horizontal = 11.dp, vertical = 7.dp)) {
        Txt(label, size = T.footnote, weight = FontWeight.SemiBold, color = if (on) T.accentInk else T.ink, maxLines = 1)
    }
}

/** Two columns, without a lazy grid inside a scrolling column. */
@Composable
fun Grid(count: Int, cell: @Composable (Int) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        for (r in 0 until (count + 1) / 2) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.weight(1f)) { cell(r * 2) }
                Box(Modifier.weight(1f)) { if (r * 2 + 1 < count) cell(r * 2 + 1) }
            }
        }
    }
}

@Composable
private fun ForYouCard(p: ForYouItem, item: Item, context: android.content.Context) {
    val store = AppStore
    val known = item.priceKnown && item.price > 0
    fun openIt() {
        p.findID?.let { Router.focusFind = it; Router.tab = AppTab.FINDS; return }
        val url = BuyLink.tracked(item, "for_you") ?: run { Router.say("No store page for this one yet"); return }
        store.reactForYou(p, ForYouAction.OPEN)
        openUrl(context, url)
    }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.clickable { openIt() }) { Plate(item, item.brand.ifEmpty { item.category.info.label }, height = 150.dp) }
        Txt(item.title, size = T.footnote, weight = FontWeight.SemiBold, maxLines = 2, modifier = Modifier.heightIn(min = 34.dp))
        Txt(listOfNotNull(if (known) item.priceLabel else null, item.source).joinToString(" · "), size = T.caption2, color = T.muted, maxLines = 1)
        Txt(item.about ?: " ", size = T.caption2, color = T.ink.copy(alpha = 0.8f), maxLines = 2, modifier = Modifier.heightIn(min = 26.dp))
        val tint = if (p.kind == "explore") T.cyan else T.green
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(if (p.kind == "explore") Icons.Filled.AutoAwesome else if (p.kind == "yours") Icons.Filled.Inbox else Icons.Filled.AutoFixHigh, null,
                tint = tint, modifier = Modifier.size(10.dp))
            Spacer(Modifier.width(4.dp))
            Txt(p.reason, size = T.caption2, weight = FontWeight.Medium, color = tint, maxLines = 1)
        }
        // ✕ left, ♥ right: the same way you swipe.
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.weight(1f).height(34.dp).glass(CircleShape).clickable {
                store.reactForYou(p, ForYouAction.DISMISS); Router.say("Got it, fewer like this")
            }, contentAlignment = Alignment.Center) { Icon(Icons.Filled.Close, "Not for me", tint = T.muted, modifier = Modifier.size(16.dp)) }
            Box(Modifier.weight(1f).height(34.dp).clip(CircleShape).background(T.gradient).clickable {
                store.reactForYou(p, ForYouAction.LIKE)
                Router.say(if (store.state.agents.isEmpty()) "Liked. Baget will show more like this" else "Saved to Finds. More like this coming")
            }, contentAlignment = Alignment.Center) { Icon(Icons.Filled.Favorite, "Like", tint = T.accentInk, modifier = Modifier.size(16.dp)) }
        }
    }
}

fun openUrl(context: android.content.Context, url: String) {
    runCatching {
        androidx.browser.customtabs.CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(context, android.net.Uri.parse(url))
    }.onFailure { open(context, url) }
}

/** Under the greeting on Today: Pro, or (Free) whether the scouts are hunting and when that changes. */
@Composable
fun PlanStatusPill() {
    val store = AppStore
    store.observe()
    val p = store.plan ?: return
    if (!store.isCloud) return
    val text = if (p.pro) "Pro · hunting around the clock" else {
        val m = p.minutesToChange()
        val left = if (m >= 60) "${m / 60}h ${m % 60}m" else "${m}m"
        if (p.huntingNow) "Hunting now · $left left today" else "Scouts resting · back at ${PlanInfo.hourLabel(p.huntStart)}"
    }
    Row(Modifier.clip(CircleShape).background(T.glass).border(1.dp, T.line, CircleShape).clickable { if (!p.pro) Router.open(Sheet.Pro) }
        .padding(horizontal = 10.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(7.dp).clip(CircleShape).background(if (p.huntingNow) T.green else T.muted))
        Spacer(Modifier.width(6.dp))
        Txt(text, size = T.caption, weight = FontWeight.SemiBold)
        if (!p.pro) {
            Spacer(Modifier.width(6.dp))
            Box(Modifier.clip(CircleShape).background(T.gradient).padding(horizontal = 7.dp, vertical = 2.dp)) {
                Txt("Go 24/7", size = T.caption, weight = FontWeight.Bold, color = T.accentInk)
            }
        }
    }
}

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
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
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

/** The home screen: say what you want, see today's best picks, swipe the rest, then browse the feed. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TodayScreen() {
    val store = AppStore
    val s = store.observe()
    val picks = store.todaysPicks()
    val queue = store.swipeQueue.size
    var refreshing by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { Analytics.track(AnalyticsEvent.TODAY_VIEWED, mapOf("picks" to picks.size, "toSwipe" to queue)) }

    PullToRefreshBox(isRefreshing = refreshing, onRefresh = {
        refreshing = true
        store.scope.launch { refreshNow(); refreshing = false }
    }) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp)) {
            Greeting()
            PlanStatusPill()
            if (store.isCloud && s.agents.isNotEmpty() && s.finds.isEmpty()) FirstHuntCard()
            if (queue > 0) SwipeCard(queue)
            if (picks.isNotEmpty()) TodaysDrop(picks)
            ForYouSection()
            HuntBox()
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Kick("Live from your squad")
                LiveFeed()
            }
        }
    }
}

/** Pull to refresh: re-sync (signed in) or run a sample sweep. */
suspend fun refreshNow() {
    val store = AppStore
    if (store.isCloud) store.pull() else {
        val res = store.sweep()
        Analytics.track(AnalyticsEvent.SWEEP_RUN, mapOf("found" to res.found, "manual" to true))
        Router.say(if (res.found > 0) "${res.found} new find${if (res.found == 1) "" else "s"}" else "Nothing new fits you right now")
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
        Txt("${s.agents.size} agent${if (s.agents.size == 1) "" else "s"} hunting for you · ${SimpleDateFormat("EEEE, MMMM d", Locale.US).format(Date())}",
            size = T.footnote, color = T.muted)
    }
}

/** Until the first finds land: who's out hunting, so a new account never looks idle. */
@Composable
private fun FirstHuntCard() {
    val s = AppStore.observe()
    Row(Modifier.fillMaxWidth().glass(RoundedCornerShape(16.dp), T.green.copy(alpha = 0.08f), T.green.copy(alpha = 0.3f)).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Row(horizontalArrangement = Arrangement.spacedBy((-8).dp)) { s.agents.take(4).forEach { AgentAvatar(it, 30.dp) } }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Txt("Your squad's first hunt is on", weight = FontWeight.Bold)
            Txt("Finds usually land within a few minutes. Pull down to check.", size = T.caption, color = T.muted)
        }
        Spinner()
    }
}

@Composable
private fun SwipeCard(n: Int) {
    Row(Modifier.fillMaxWidth().glass(RoundedCornerShape(18.dp), T.accent.copy(alpha = 0.10f), T.accent.copy(alpha = 0.4f))
        .clickable { Router.open(Sheet.Swipe) }.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.width(50.dp).height(48.dp), contentAlignment = Alignment.Center) {
            for (i in (minOf(3, n) - 1) downTo 0) {
                Box(Modifier.offset(x = (-4 * i).dp).rotate(-8f * i).size(34.dp, 44.dp).clip(RoundedCornerShape(8.dp))
                    .background(if (i == 0) T.gradient else Brush.linearGradient(listOf(T.panel, T.panel))).background(if (i == 0) Color.Transparent else T.glass)
                    .border(1.dp, T.line, RoundedCornerShape(8.dp)))
            }
        }
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Txt("Swipe through $n new find${if (n == 1) "" else "s"}", size = T.body, weight = FontWeight.SemiBold)
            Txt("Right to like, left to pass, up to buy. Every swipe teaches your squad.", size = T.caption, color = T.muted)
        }
        Icon(Icons.Filled.ChevronRight, null, tint = T.muted)
    }
}

@Composable
private fun TodaysDrop(picks: List<Find>) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Txt("Today's Drop", size = T.title3, weight = FontWeight.Black, modifier = Modifier.weight(1f))
            Txt("See all", size = T.footnote, weight = FontWeight.SemiBold, color = T.accent, modifier = Modifier.clickable { Router.tab = AppTab.FINDS })
        }
        Txt("Your squad's best ${picks.size} right now.", size = T.caption, color = T.muted)
        picks.forEachIndexed { i, f ->
            val item = Catalog.item(f.itemID) ?: return@forEachIndexed
            Row(Modifier.fillMaxWidth().glass().clickable { Router.focusFind = f.id; Router.tab = AppTab.FINDS }.padding(10.dp)) {
                GradientText("${i + 1}", 20.sp, modifier = Modifier.width(18.dp))
                Spacer(Modifier.width(12.dp))
                ProductThumb(item, 60.dp)
                Spacer(Modifier.width(12.dp))
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Txt(item.title, weight = FontWeight.SemiBold, maxLines = 2)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        DealVerdict.of(item)?.let { VerdictChip(it); Spacer(Modifier.width(6.dp)) }
                        Txt(listOfNotNull(item.source, if (item.priceKnown && item.price > 0) Fmt.money(item.price) else null).joinToString(" · "),
                            size = T.caption, color = T.muted, maxLines = 1)
                    }
                    f.why.firstOrNull()?.let { Txt(it, size = T.caption, color = T.green.copy(alpha = 0.9f), maxLines = 1) }
                }
            }
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

/** "For You": always-on personal picks, ranked by what you like. Every heart and X sharpens it. */
@Composable
private fun ForYouSection() {
    val store = AppStore
    val s = store.observe()
    val context = LocalContext.current
    var limit by remember { mutableIntStateOf(24) }
    val picks = store.forYou.filter { Catalog.item(it.id) != null }
    LaunchedEffect(s.accountID) {
        val at = store.forYouLoadedAt
        if (at == null || at < now() - 180_000 || store.forYou.isEmpty()) store.loadForYou(limit)
    }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Txt("For You", size = T.title3, weight = FontWeight.Black)
        Txt("Picked from everything Baget's agents have found, ranked by your taste. Every ♥ and ✕ sharpens it.", size = T.caption, color = T.muted)
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
            if (picks.size >= limit - 2 && limit < 60) {
                GhostButton("Show more", Modifier.fillMaxWidth()) {
                    limit = minOf(60, limit + 24)
                    store.scope.launch { store.loadForYou(limit) }
                }
            }
        }
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
        Txt(listOfNotNull(if (known) Fmt.money(item.price) else null, item.source).joinToString(" · "), size = T.caption2, color = T.muted, maxLines = 1)
        Txt(item.about ?: " ", size = T.caption2, color = T.ink.copy(alpha = 0.8f), maxLines = 2, modifier = Modifier.heightIn(min = 26.dp))
        val tint = if (p.kind == "explore") T.cyan else T.green
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(if (p.kind == "explore") Icons.Filled.AutoAwesome else if (p.kind == "yours") Icons.Filled.Inbox else Icons.Filled.AutoFixHigh, null,
                tint = tint, modifier = Modifier.size(10.dp))
            Spacer(Modifier.width(4.dp))
            Txt(p.reason, size = T.caption2, weight = FontWeight.Medium, color = tint, maxLines = 1)
        }
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

/** "What are you hunting?" Type one sentence; an agent is created and starts searching. */
@Composable
fun HuntBox() {
    val store = AppStore
    store.observe()
    val focus = LocalFocusManager.current
    val examples = remember { listOf("oud fragrances like Frederic Malle", "a 992 GT3 under \$200k", "Supreme box logo in size L",
        "mid-century walnut credenza", "Jordan 1s in mocha, size 10.5", "vintage Rolex Explorer") }
    var example by remember { mutableStateOf(examples.random()) }
    var text by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<HuntResult?>(null) }

    fun go() {
        val t = text.trim()
        if (t.length < 2 || working) return
        focus.clearFocus()
        working = true
        store.scope.launch {
            val r = store.hunt(t)
            working = false
            if (r == null) return@launch
            text = ""
            example = examples.random()
            result = r
            if (r.needsSize) Router.open(Sheet.Chat(r.agentID))   // its first question will be your size
        }
    }

    Column(Modifier.fillMaxWidth().glassCard(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Txt("What are you hunting?", size = T.body, weight = FontWeight.SemiBold)
        Field(text, { v -> if (v.contains("\n")) { text = v.replace("\n", " ").trim(); go() } else text = v }, "e.g. $example",
            Modifier.fillMaxWidth(), singleLine = false, maxLines = 3, enabled = !working,
            keyboard = KeyboardOptions(imeAction = ImeAction.Go), actions = KeyboardActions(onGo = { go() }),
            leading = { Icon(Icons.Filled.TravelExplore, null, tint = T.cyan) },
            trailing = {
                if (working) Spinner(18.dp)
                else if (text.isNotBlank()) Box(Modifier.size(32.dp).clip(CircleShape).background(T.gradient).clickable { go() }, contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.ArrowUpward, "Start hunting", tint = T.accentInk, modifier = Modifier.size(18.dp))
                }
            })
        val r = result
        val a = r?.let { store.agent(it.agentID) }
        if (r != null && a != null) {
            Row(Modifier.fillMaxWidth().glass(RoundedCornerShape(14.dp), T.green.copy(alpha = 0.10f), Color.Transparent).padding(10.dp)) {
                AgentAvatar(a, 34.dp)
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Txt("${a.name} is on it", weight = FontWeight.Bold)
                    Txt(r.intro, size = T.caption, color = T.muted)
                    Txt("Tell it more", size = T.caption, weight = FontWeight.SemiBold, color = T.accent, modifier = Modifier.clickable { Router.open(Sheet.Chat(a.id)) })
                }
                Icon(Icons.Filled.Close, "Dismiss", tint = T.muted, modifier = Modifier.size(16.dp).clickable { result = null })
            }
        } else {
            Txt("Type it in your own words. Baget builds the right agent and it starts searching right away.", size = T.caption, color = T.muted)
        }
    }
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

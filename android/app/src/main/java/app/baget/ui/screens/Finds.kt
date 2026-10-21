package app.baget.ui.screens

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.baget.engine.*
import app.baget.model.*
import app.baget.ui.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private data class FindGroup(val id: String, val title: String, val symbol: String, val agent: Agent?, val finds: MutableList<Find>) {
    val newCount: Int get() = finds.count { it.status == FindStatus.OPEN }
}

private enum class FindsShow { ALL, NEW, LIKED }

fun categoryIcon(symbol: String): ImageVector = when (symbol) {
    "shoe" -> Icons.Filled.DirectionsRun
    "shirt" -> Icons.Filled.Checkroom
    "drop" -> Icons.Filled.WaterDrop
    "watch" -> Icons.Filled.Watch
    "car" -> Icons.Filled.DirectionsCar
    "sofa" -> Icons.Filled.Chair
    "bag" -> Icons.Filled.ShoppingBag
    "star" -> Icons.Filled.Star
    "search" -> Icons.Filled.TravelExplore
    else -> Icons.Filled.AutoAwesome
}

@Composable
fun FindsScreen() {
    val store = AppStore
    val s = store.observe()
    val prefs = remember { store.context.getSharedPreferences("baget.ui", 0) }
    var show by remember { mutableStateOf(FindsShow.ALL) }
    val collapsed = remember { mutableStateListOf<String>() }
    var expanded by remember { mutableStateOf<String?>(null) }
    var highlighted by remember { mutableStateOf<String?>(null) }
    var sweeping by remember { mutableStateOf(false) }
    var confirmClear by remember { mutableStateOf(false) }
    var tipStep by remember { mutableIntStateOf(prefs.getInt("findsTips", 0)) }
    val listState = rememberLazyListState()

    val visible = s.finds.filter { f ->
        (f.status == FindStatus.OPEN || f.status == FindStatus.LIKED) && Catalog.item(f.itemID)?.showable == true && when (show) {
            FindsShow.ALL -> true; FindsShow.NEW -> f.status == FindStatus.OPEN; FindsShow.LIKED -> f.status == FindStatus.LIKED
        }
    }
    val groups = run {
        val byKey = linkedMapOf<String, FindGroup>()
        for (f in visible) {
            val item = Catalog.item(f.itemID) ?: continue
            val agent = store.agent(f.agentID)
            val mission = agent?.mission
            val (key, title, symbol) = if (mission is Mission.Custom) Triple("custom-" + (agent?.id ?: mission.text), mission.text.capitalizedFirst(), customMissionInfo.symbol)
                else (mission?.category ?: item.category).let { c -> Triple(c.raw, c.info.label, c.info.symbol) }
            byKey.getOrPut(key) { FindGroup(key, title, symbol, agent, mutableListOf()) }.finds.add(f)
        }
        byKey.values.onEach { g -> g.finds.sortWith(compareBy<Find> { if (it.status == FindStatus.OPEN) 0 else 1 }.thenByDescending { it.score }.thenByDescending { it.foundAt }) }
            .sortedWith(compareByDescending<FindGroup> { it.newCount }.thenBy { it.title })
    }
    val newTotal = s.finds.count { it.status == FindStatus.OPEN && Catalog.item(it.itemID)?.showable == true }
    val likedTotal = s.finds.count { it.status == FindStatus.LIKED && Catalog.item(it.itemID)?.showable == true }
    val clearLabel = when (show) { FindsShow.ALL -> "Clear all"; FindsShow.NEW -> "Clear new"; FindsShow.LIKED -> "Clear liked" }

    // Opened from Today, a notification or Live: show everything, open its section and card, then scroll to it.
    LaunchedEffect(Router.focusFind) {
        val id = Router.focusFind ?: return@LaunchedEffect
        show = FindsShow.ALL
        Router.focusFind = null
        expanded = id
        groups.firstOrNull { g -> g.finds.any { it.id == id } }?.let { collapsed.remove(it.id) }
        delay(250)
        var index = 3
        for (g in groups) {
            index++
            if (g.id in collapsed) continue
            val i = g.finds.indexOfFirst { it.id == id }
            if (i >= 0) { index += i; break }
            index += g.finds.size
        }
        runCatching { listState.animateScrollToItem(index) }
        highlighted = id
        delay(2200)
        if (highlighted == id) highlighted = null
    }

    LazyColumn(state = listState, modifier = Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)) {
        item {
            Row(Modifier.padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Txt("Finds", size = 30.sp, weight = FontWeight.Black, tracking = (-0.8).sp)
                    Txt("${s.agents.size} agents hunting · $newTotal new · $likedTotal liked", size = T.footnote, color = T.muted)
                }
                GhostButton("Sweep", Modifier.width(110.dp), icon = Icons.Filled.Refresh, busy = sweeping) {
                    if (store.isCloud) {
                        sweeping = true
                        store.scope.launch { val m = store.cloudSweep(); sweeping = false; m?.let { Router.say(it) } }
                    } else {
                        val res = store.sweep()
                        Analytics.track(AnalyticsEvent.SWEEP_RUN, mapOf("found" to res.found, "manual" to true))
                        if (res.found == 0) Router.say("Nothing new fits you right now")
                    }
                }
            }
        }
        item {
            Row(Modifier.fillMaxWidth().glass(RoundedCornerShape(12.dp)).padding(3.dp)) {
                listOf(FindsShow.ALL to "All", FindsShow.NEW to (if (newTotal > 0) "New · $newTotal" else "New"),
                    FindsShow.LIKED to (if (likedTotal > 0) "♥ Liked · $likedTotal" else "♥ Liked")).forEach { (v, label) ->
                    Box(Modifier.weight(1f).clip(RoundedCornerShape(10.dp)).background(if (show == v) T.accent.copy(alpha = 0.22f) else Color.Transparent)
                        .clickable { show = v }.padding(vertical = 8.dp), contentAlignment = Alignment.Center) {
                        Txt(label, size = T.footnote, weight = FontWeight.SemiBold, color = if (show == v) T.ink else T.muted, maxLines = 1)
                    }
                }
            }
        }
        item {
            if (visible.isNotEmpty()) Row(verticalAlignment = Alignment.CenterVertically) {
                Txt("Long-press a find, or tap its trash, to remove one", size = T.caption2, color = T.muted, modifier = Modifier.weight(1f))
                Row(Modifier.clickable { confirmClear = true }.padding(4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Delete, null, tint = T.hot, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(4.dp))
                    Txt(clearLabel, size = T.footnote, weight = FontWeight.SemiBold, color = T.hot)
                }
            }
            if (groups.isEmpty()) EmptyCard(when {
                s.agents.isEmpty() -> "Deploy an agent first, then run a sweep."
                show == FindsShow.NEW -> "You're all caught up. Your squad keeps hunting in the background."
                show == FindsShow.LIKED -> "Nothing liked yet. Tap ♥ on a find you love and your agents will find more like it."
                else -> "Nothing here yet. Tap Sweep, or pull down on Today."
            })
            if (tipStep < FindsTips.size && visible.isNotEmpty()) FindsTipCard(tipStep) { tipStep = it; prefs.edit().putInt("findsTips", it).apply() }
        }
        for (g in groups) {
            val isCollapsed = g.id in collapsed
            item(key = "g-" + g.id) {
                Row(Modifier.fillMaxWidth().clickable { if (isCollapsed) collapsed.remove(g.id) else collapsed.add(g.id) }.padding(vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(30.dp).clip(RoundedCornerShape(9.dp)).background(T.gradient), contentAlignment = Alignment.Center) {
                        Icon(categoryIcon(g.symbol), null, tint = T.accentInk, modifier = Modifier.size(17.dp))
                    }
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Txt(g.title, size = T.body, weight = FontWeight.SemiBold, maxLines = 1)
                        Txt(listOfNotNull(g.agent?.name, "${g.finds.size} find${if (g.finds.size == 1) "" else "s"}").joinToString(" · "),
                            size = T.caption, color = T.muted, maxLines = 1)
                    }
                    if (g.newCount > 0) Box(Modifier.clip(CircleShape).background(T.gradient).padding(horizontal = 8.dp, vertical = 3.dp)) {
                        Txt("${g.newCount} new", size = T.caption2, weight = FontWeight.Bold, color = T.accentInk)
                    }
                    Spacer(Modifier.width(6.dp))
                    Icon(Icons.Filled.ExpandMore, null, tint = T.muted, modifier = Modifier.rotate(if (isCollapsed) -90f else 0f))
                }
            }
            if (!isCollapsed) for (f in g.finds) item(key = f.id) {
                FindCard(f, highlighted == f.id, expanded == f.id) { open -> expanded = if (open) f.id else null }
            }
        }
        if (!store.isCloud) item { Txt("Sample data: listings, prices and drop times are illustrative, and nothing is purchased.", size = T.caption, color = T.muted) }
    }

    if (confirmClear) AlertDialog(onDismissRequest = { confirmClear = false }, containerColor = T.panel,
        title = { Txt("$clearLabel?", size = T.body, weight = FontWeight.Bold) },
        text = { Txt("They leave Finds and your agents won't show them again. What your agents learned about your taste stays.", color = T.muted) },
        confirmButton = { TextButton(onClick = {
            val n = visible.size
            store.removeFinds(visible.map { it.id })
            Router.say(if (n == 1) "Cleared 1 find" else "Cleared $n finds")
            confirmClear = false
        }) { Txt("$clearLabel (${visible.size})", color = T.hot, weight = FontWeight.Bold) } },
        dismissButton = { TextButton(onClick = { confirmClear = false }) { Txt("Cancel", color = T.muted) } })
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun FindCard(find: Find, highlighted: Boolean, expanded: Boolean, setExpanded: (Boolean) -> Unit) {
    val store = AppStore
    store.observe()
    val item = Catalog.item(find.itemID) ?: return
    val agent = store.agent(find.agentID)
    var askingWhy by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(18.dp)
    fun remove() { store.removeFinds(listOf(find.id)); Router.say("Removed") }

    Box {
        Column(Modifier.fillMaxWidth().clip(shape).background(if (highlighted) T.accent.copy(alpha = 0.12f) else T.glass)
            .border(1.dp, if (highlighted) T.accent.copy(alpha = 0.6f) else T.line, shape).animateContentSize().padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.combinedClickable(onClick = { setExpanded(!expanded) }, onLongClick = { menu = true })) { Summary(find, item, expanded) }
            if (expanded) Details(find, item, agent)
            Actions(find, item, agent, onPass = { askingWhy = true }, onRemove = ::remove)
        }
        DropdownMenu(menu, onDismissRequest = { menu = false }, containerColor = T.panel) {
            DropdownMenuItem(text = { Txt("Remove", color = T.hot) }, leadingIcon = { Icon(Icons.Filled.Delete, null, tint = T.hot) },
                onClick = { menu = false; remove() })
        }
    }
    if (askingWhy) AlertDialog(onDismissRequest = { askingWhy = false }, containerColor = T.panel,
        title = { Txt("What was off? ${agent?.name ?: "Your agent"} will learn from it.", size = T.body, weight = FontWeight.Bold) },
        text = {
            Column {
                PassReason.entries.forEach { r ->
                    Txt(r.label, size = T.body, color = T.accent, modifier = Modifier.fillMaxWidth().clickable {
                        askingWhy = false
                        store.pass(find.id, r)
                        Analytics.track(AnalyticsEvent.FIND_PASSED, mapOf("reason" to r.label, "category" to item.category.raw))
                        Router.say(if (r == PassReason.LATER) "Passed" else "Passed. ${agent?.name ?: "Your agent"} is learning from that")
                    }.padding(vertical = 12.dp))
                }
            }
        },
        confirmButton = {}, dismissButton = { TextButton(onClick = { askingWhy = false }) { Txt("Cancel", color = T.muted) } })
}

@Composable
private fun Summary(find: Find, item: Item, expanded: Boolean) {
    val store = AppStore
    val known = item.priceKnown && item.price > 0
    val isNew = find.status == FindStatus.OPEN && find.foundAt > now() - 24 * 3_600_000L
    Row {
        ProductThumb(item)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                if (isNew) MonoBadge("NEW", T.accent)
                if (store.isSoldOut(item)) MonoBadge("SOLD OUT", T.warn)
                else if (!store.isLive(item)) MonoBadge(store.whenLabel(item), T.blue)
                if ("limited" in item.tags) MonoBadge("LIMITED", T.hot)
                if (store.reminder(item) != null) Icon(Icons.Filled.Notifications, "Reminder set", tint = T.blue, modifier = Modifier.size(12.dp))
                if (find.status == FindStatus.LIKED) Icon(Icons.Filled.Favorite, null, tint = T.hot, modifier = Modifier.size(13.dp))
                Spacer(Modifier.weight(1f))
                Txt("${find.score}%", size = T.caption, weight = FontWeight.Bold, mono = true,
                    color = if (find.score >= 80) T.green else if (find.score >= 60) T.accent else T.muted)
            }
            Txt(item.title, weight = FontWeight.SemiBold, maxLines = 2)
            Row(verticalAlignment = Alignment.CenterVertically) {
                DealVerdict.of(item)?.let { VerdictChip(it); Spacer(Modifier.width(6.dp)) }
                Txt(listOfNotNull(item.source, if (known) Fmt.money(item.price) else null).joinToString(" · "), size = T.caption, color = T.muted,
                    maxLines = 1, modifier = Modifier.weight(1f, fill = false))
                if (find.watching) { Spacer(Modifier.width(4.dp)); Icon(Icons.Filled.Visibility, "Watching", tint = T.warn, modifier = Modifier.size(12.dp)) }
            }
            if (hasAbout(item, expanded)) AboutBlock(item, expanded, if (expanded) 6 else 2)
            find.why.firstOrNull()?.takeIf { it.isNotEmpty() }?.let { Txt(it, size = T.caption, color = T.green.copy(alpha = 0.9f), maxLines = if (expanded) 4 else 1) }
        }
    }
}

fun hasAbout(item: Item, brand: Boolean = true): Boolean = item.about != null || (brand && item.brandAbout != null && item.brand.isNotEmpty())

/** Who the brand is, then what the product is, in plain words. */
@Composable
fun AboutBlock(item: Item, brand: Boolean = true, lines: Int = Int.MAX_VALUE) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        val b = item.brandAbout
        if (brand && b != null && item.brand.isNotEmpty()) Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Txt("ABOUT ${item.brand.uppercase()}", size = 10.sp, weight = FontWeight.Bold, color = T.accent, tracking = 0.8.sp)
            Txt(b, size = T.footnote, color = T.ink.copy(alpha = 0.85f), maxLines = lines)
        }
        item.about?.let { Txt(it, size = T.footnote, color = T.ink.copy(alpha = 0.85f), maxLines = lines) }
    }
}

@Composable
private fun Details(find: Find, item: Item, agent: Agent?) {
    val store = AppStore
    val known = item.priceKnown && item.price > 0
    val diff = if (known && item.market > 0) item.market - item.price else 0.0
    val pct = if (known && item.market > 0) safeRound(diff / item.price * 100) else 0
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (isUpcoming(item)) ReleaseRow(item, find.id)
        DealVerdict.of(item)?.let { v ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Txt(v.emoji); Spacer(Modifier.width(6.dp))
                Txt(v.title, weight = FontWeight.Bold, color = when (v.level) { DealVerdict.Level.GREAT -> T.green; DealVerdict.Level.FAIR -> T.warn; DealVerdict.Level.WAIT -> T.hot; else -> T.accent })
                Spacer(Modifier.width(6.dp))
                Txt(v.detail, size = T.footnote)
            }
        }
        item.offers?.takeIf { it.isNotEmpty() }?.let { offers ->
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Txt("OTHER STORES", size = 9.sp, weight = FontWeight.SemiBold, tracking = 1.sp, color = T.muted)
                offers.take(4).forEach { o ->
                    Row {
                        Txt(o.store, size = T.footnote, maxLines = 1, modifier = Modifier.weight(1f))
                        Txt(Fmt.money(o.price), size = T.footnote, mono = true, color = if (known && o.price < item.price) T.green else T.muted)
                    }
                }
            }
        }
        Hairline()
        Row {
            Stat("Price", if (known) Fmt.money(item.price) else "See store", modifier = Modifier.weight(1f))
            Stat("Market", if (known && item.market > 0) Fmt.money(item.market) else "—", modifier = Modifier.weight(1f))
            Stat("Spread", if (known && item.market > 0) "${if (diff > 0) "+" else ""}$pct%" else "—", if (diff > 0) T.green else if (diff < 0) T.hot else null, Modifier.weight(1f))
        }
        Hairline()
        val traits = item.traits + listOfNotNull(item.creator)
        if (traits.isNotEmpty()) Txt(traits.joinToString(" · "), size = T.caption, color = T.muted, italic = true)
        if (agent != null) {
            if (find.why.size > 1) Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                find.why.drop(1).forEach { w ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(5.dp).clip(CircleShape).background(T.accent)); Spacer(Modifier.width(7.dp)); Txt(w, size = T.footnote)
                    }
                }
            }
            if (find.status == FindStatus.OPEN) {
                val take = store.take(agent, item)
                val tint = if (take.caution) T.warn else T.accent
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(tint.copy(alpha = 0.10f)).padding(10.dp)) {
                    Txt("${agent.name}: ", size = T.footnote, weight = FontWeight.Bold, color = tint)
                    Txt(take.text, size = T.footnote)
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Chip(if (find.watching) Icons.Filled.Visibility else Icons.Outlined.Visibility, if (find.watching) "Watching" else "Watch it for me",
                tint = if (find.watching) T.warn else null) {
                val was = find.watching
                store.toggleWatch(find.id)
                if (!was) Router.say("${agent?.name ?: "Your agent"} will text you on a price drop, restock or release")
            }
            Chip(Icons.Outlined.Forum, "Ask about this") { Router.open(Sheet.Chat(find.agentID, find.id)) }
        }
        if (find.watching) Txt("${agent?.name ?: "Your agent"} checks the price twice a day and texts you if it drops" +
            "${if (store.isSoldOut(item)) ", or the moment it restocks" else if (!store.isLive(item)) ", and at release" else ""}.", size = T.caption, color = T.muted)
    }
}

fun isUpcoming(item: Item): Boolean = !item.isSample && (item.dropAt ?: 0) > now()

@Composable
private fun ReleaseRow(item: Item, findID: String) {
    val r = AppStore.reminder(item)
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(T.blue.copy(alpha = 0.10f)).padding(10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.CalendarMonth, null, tint = T.blue, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(6.dp))
            Txt("Releases ${ReminderFmt.long(item.dropAt!!)}", weight = FontWeight.SemiBold)
            if ("limited" in item.tags) Txt(" · Limited", size = T.footnote, weight = FontWeight.SemiBold, color = T.hot)
        }
        Chip(if (r == null) Icons.Outlined.Notifications else Icons.Filled.Notifications, if (r == null) "Remind me" else "Reminder · ${ReminderFmt.short(r.remindAt)}",
            primary = r == null, tint = if (r == null) null else T.blue) { Router.open(Sheet.Reminder(item.id, findID)) }
    }
}

@Composable
private fun Actions(find: Find, item: Item, agent: Agent?, onPass: () -> Unit, onRemove: () -> Unit) {
    val store = AppStore
    val context = LocalContext.current
    val link = BuyLink.url(item)
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        if (find.status == FindStatus.LIKED) Chip(Icons.Filled.Favorite, "Liked", tint = T.hot) { store.unlike(find.id) }
        else {
            Chip(Icons.Outlined.FavoriteBorder, "Like", primary = true) {
                store.like(find.id)
                Router.say("${agent?.name ?: "Your agent"} will find more like this")
            }
            Chip(Icons.Filled.Close, "Pass", onClick = onPass)
        }
        if (store.isSoldOut(item) && !item.isSample) {
            val on = find.watching
            Chip(if (on) Icons.Filled.Notifications else Icons.Outlined.Notifications, if (on) "Watching" else "Notify me", tint = if (on) T.warn else null) {
                store.toggleWatch(find.id)
                Router.say(if (on) "Stopped watching this one" else "I'll check ${item.source} and text you the moment it's back")
            }
        } else if (isUpcoming(item)) {
            val r = store.reminder(item)
            Chip(if (r == null) Icons.Outlined.Notifications else Icons.Filled.Notifications, if (r == null) "Remind me" else "Reminder set",
                tint = if (r == null) null else T.blue) { Router.open(Sheet.Reminder(item.id, find.id)) }
        } else if (link != null) {
            Chip(Icons.Filled.ArrowOutward, "Buy") {
                Analytics.track(AnalyticsEvent.CHECKOUT_OPENED, mapOf("category" to item.category.raw, "toStore" to true, "from" to "find"))
                Router.buyOpened = find.id
                openUrl(context, BuyLink.tracked(item, "find") ?: link)
            }
        }
        Spacer(Modifier.weight(1f))
        Box(Modifier.size(34.dp).clip(CircleShape).background(T.glass).clickable(onClick = onRemove), contentAlignment = Alignment.Center) {
            Icon(Icons.Outlined.Delete, "Remove from Finds", tint = T.muted, modifier = Modifier.size(17.dp))
        }
        Box(Modifier.size(34.dp).glass(CircleShape).clickable { Router.open(Sheet.ShareItem(item.id, null, false)) }, contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Share, "Share with friends", tint = T.ink, modifier = Modifier.size(16.dp))
        }
    }
}

@Composable
fun Chip(icon: ImageVector, text: String, primary: Boolean = false, tint: Color? = null, onClick: () -> Unit) {
    Row(Modifier.height(34.dp).clip(CircleShape).then(if (primary) Modifier.background(T.gradient) else Modifier.background(T.glass).border(1.dp, T.line, CircleShape))
        .clickable(onClick = onClick).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        val c = if (primary) T.accentInk else tint ?: T.ink
        Icon(icon, null, tint = c, modifier = Modifier.size(15.dp))
        Spacer(Modifier.width(5.dp))
        Txt(text, size = T.footnote, weight = FontWeight.Bold, color = c, maxLines = 1)
    }
}

// MARK: First-run tips

private data class FindsTip(val icon: ImageVector, val tint: Color, val title: String, val body: String)

private val FindsTips = listOf(
    FindsTip(Icons.Filled.Favorite, T.hot, "Like teaches your scout",
        "Tap Like on anything that's your taste. Your scout leans into that brand and style and finds more like it."),
    FindsTip(Icons.Filled.Close, T.accent, "Pass, and say why",
        "Too pricey, wrong style, not your brand: every reason sharpens the next hunt. The more you react, the better it gets."),
    FindsTip(Icons.Filled.Notifications, T.warn, "Never miss a drop",
        "On something not out yet, tap Remind me and pick when. On something sold out, tap Notify me and you'll get a text when it's back."),
)

@Composable
private fun FindsTipCard(step: Int, setStep: (Int) -> Unit) {
    val i = minOf(step, FindsTips.size - 1)
    val tip = FindsTips[i]
    val last = i == FindsTips.size - 1
    Column(Modifier.fillMaxWidth().glass(RoundedCornerShape(18.dp), T.accent.copy(alpha = 0.08f), T.accent.copy(alpha = 0.35f)).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row {
            Box(Modifier.size(38.dp).clip(CircleShape).background(tip.tint.copy(alpha = 0.16f)), contentAlignment = Alignment.Center) {
                Icon(tip.icon, null, tint = tip.tint, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.width(12.dp))
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Txt(tip.title, weight = FontWeight.Bold)
                Txt(tip.body, size = T.footnote, color = T.muted)
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            FindsTips.indices.forEach { d -> Box(Modifier.height(6.dp).width(if (d == i) 16.dp else 6.dp).clip(CircleShape).background(if (d == i) T.gradient else androidx.compose.ui.graphics.SolidColor(T.line))) }
            Spacer(Modifier.weight(1f))
            if (!last) Txt("Skip", size = T.footnote, color = T.muted, modifier = Modifier.clickable { setStep(FindsTips.size) }.padding(6.dp))
            Box(Modifier.clip(CircleShape).background(T.accent).clickable { setStep(i + 1) }.padding(horizontal = 14.dp, vertical = 7.dp)) {
                Txt(if (last) "Got it" else "Next", size = T.footnote, weight = FontWeight.Bold, color = T.accentInk)
            }
        }
        if (i < 2) Txt("↓ Try it on a find below", size = T.caption2, weight = FontWeight.SemiBold, color = T.accent)
    }
}

// MARK: Checkout

@Composable
fun CheckoutSheet(findID: String) {
    val store = AppStore
    val s = store.observe()
    val context = LocalContext.current
    var amountText by remember { mutableStateOf("") }
    val f = s.finds.firstOrNull { it.id == findID }
    val item = f?.let { Catalog.item(it.itemID) }
    SheetFrame("Checkout", leading = "Cancel", trailing = null) {
        if (f == null || item == null) return@SheetFrame
        val a = store.agent(f.agentID)
        val live = store.isLive(item); val soldOut = store.isSoldOut(item)
        val block = when {
            soldOut -> "Sold out right now. ${a?.name ?: "Your agent"} will watch for a restock and tell you the moment it's back."
            !live -> "This isn't available yet. Your agent will hold your spot and ask again at release."
            else -> null
        }
        val cloud = store.isCloud && !item.isSample
        LaunchedEffect(Unit) { Analytics.track(AnalyticsEvent.CHECKOUT_OPENED, mapOf("category" to item.category.raw, "blocked" to (block != null))) }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Txt(item.title, size = T.title2, weight = FontWeight.Black)
            Txt(listOf(item.source, item.sku).filter { it.isNotEmpty() }.joinToString(" · "), size = T.footnote, color = T.muted)
            if (hasAbout(item)) Box(Modifier.glassCard()) { AboutBlock(item) }
            Column(Modifier.fillMaxWidth().glassCard(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row {
                    Stat("Price", if (item.priceKnown) Fmt.money(item.price) else "Not listed", modifier = Modifier.weight(1f))
                    Stat("Agent", a?.name ?: "—", modifier = Modifier.weight(1f))
                }
                Row {
                    val info = item.category.info
                    Stat(if (info.sizeRequired) info.sizeLabel ?: "Size" else "Category",
                        if (info.sizeRequired) a?.size?.ifEmpty { null } ?: "Any" else info.label, modifier = Modifier.weight(1f))
                    Stat("Store", item.source.ifEmpty { "—" }, modifier = Modifier.weight(1f))
                }
            }
            if (cloud) {
                Txt(if (soldOut || !live) block ?: "" else (block?.let { "Heads up: $it " } ?: "") +
                    "You buy it at ${item.source}; Baget never charges you. Tap \"I bought it\" afterwards so your agent learns from it.", color = T.muted)
                val link = BuyLink.url(item)
                if (link != null && !soldOut) PrimaryButton("Open at ${item.source}", Modifier.fillMaxWidth(), icon = Icons.Filled.ArrowOutward) {
                    Analytics.track(AnalyticsEvent.CHECKOUT_OPENED, mapOf("category" to item.category.raw, "toStore" to true))
                    Router.buyOpened = findID
                    openUrl(context, BuyLink.tracked(item, "checkout") ?: link)
                }
                if (!item.priceKnown && live && !soldOut) Field(amountText, { amountText = it }, "What did you pay? (USD)", Modifier.fillMaxWidth(),
                    keyboard = KeyboardOptions(keyboardType = KeyboardType.Decimal))
            } else Txt(block ?: "Sample checkout. No card is charged.", color = T.muted)
            Spacer(Modifier.weight(1f))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                GhostButton("Cancel", Modifier.weight(1f)) { Router.close() }
                when {
                    soldOut || !live -> PrimaryButton(if (soldOut) "Watch for restock" else "Remind me at release", Modifier.weight(1f)) {
                        store.watch(findID)
                        Analytics.track(AnalyticsEvent.FIND_WATCHED, mapOf("category" to item.category.raw))
                        Router.say(if (soldOut) "Restock watch on" else "Got it. Your agent will ping you at release.")
                        Router.close()
                    }
                    cloud -> {
                        val typed = amountText.replace(",", "").toDoubleOrNull() ?: 0.0
                        GhostButton("I bought it", Modifier.weight(1f), enabled = item.priceKnown || typed > 0) {
                            val amount = if (item.priceKnown) item.price else typed
                            store.confirmPurchase(findID, amount)
                            Analytics.track(AnalyticsEvent.PURCHASE_CONFIRMED, mapOf("amount" to amount, "category" to item.category.raw, "score" to f.score))
                            Router.say("Logged and off your list. ${a?.name ?: "Your agent"} will learn from it.")
                            Router.close()
                        }
                    }
                    else -> PrimaryButton("Confirm purchase", Modifier.weight(1f)) {
                        store.confirmPurchase(findID)
                        Analytics.track(AnalyticsEvent.PURCHASE_CONFIRMED, mapOf("amount" to item.price, "category" to item.category.raw, "score" to f.score))
                        Router.say("Bought. It's off your list.")
                        Router.close()
                    }
                }
            }
        }
    }
}

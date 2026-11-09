package app.baget.ui.screens

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ListAlt
import androidx.compose.material.icons.automirrored.filled.ViewList
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import app.baget.engine.*
import app.baget.model.*
import app.baget.ui.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.roundToInt

/** One scout's finds (or a category's, for finds whose scout is gone). */
private data class FindGroup(val id: String, val title: String, val subtitle: String?, val symbol: String, val agent: Agent?, val finds: MutableList<Find>) {
    val newCount: Int get() = finds.count { it.status == FindStatus.OPEN }
}

/** In the order the filter row shows them. */
private enum class FindsShow { NEW, SAVED, UPCOMING, ALL }

private enum class FindsSort(val raw: String, val label: String) {
    BEST("best", "Best match"), NEWEST("newest", "Newest"), PRICE_LOW("priceLow", "Price: low to high"),
    PRICE_HIGH("priceHigh", "Price: high to low"), SCOUT("scout", "By scout");
    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } ?: BEST }
}

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

/** A product that hasn't dropped yet (it has a release date still to come). */
fun comingSoon(item: Item): Boolean = item.isProduct && (item.dropAt ?: 0L) > now()

/** Passed and bought finds leave the screen; the scouts still learn from them and never show them again. */
private fun filterFinds(finds: List<Find>, show: FindsShow): List<Find> = finds.filter { f ->
    if (f.status != FindStatus.OPEN && f.status != FindStatus.LIKED) return@filter false
    val item = Catalog.item(f.itemID) ?: return@filter false
    if (!item.showsInFinds) return@filter false
    when (show) {
        FindsShow.ALL -> true
        FindsShow.NEW -> f.status == FindStatus.OPEN
        FindsShow.SAVED -> f.status == FindStatus.LIKED || f.watching
        FindsShow.UPCOMING -> comingSoon(item)
    }
}

private fun sortFinds(finds: List<Find>, sort: FindsSort): List<Find> {
    fun price(f: Find): Double? = Catalog.item(f.itemID)?.let { if (it.priceKnown && it.price > 0) it.price else null }
    return when (sort) {
        FindsSort.NEWEST -> finds.sortedByDescending { it.foundAt }
        FindsSort.PRICE_LOW, FindsSort.PRICE_HIGH -> finds.sortedWith { a, b ->
            val x = price(a); val y = price(b)
            when {
                x != null && y != null -> if (sort == FindsSort.PRICE_LOW) x.compareTo(y) else y.compareTo(x)
                x == null && y != null -> 1
                x != null && y == null -> -1
                else -> b.score.compareTo(a.score)
            }
        }
        // New first, then liked; strongest match first; newest first on ties.
        FindsSort.BEST, FindsSort.SCOUT -> finds.sortedWith(compareBy<Find> { if (it.status == FindStatus.OPEN) 0 else 1 }
            .thenByDescending { it.score }.thenByDescending { it.foundAt })
    }
}

private fun groupFinds(visible: List<Find>, agents: List<Agent>, sort: FindsSort): List<FindGroup> {
    val byID = agents.associateBy { it.id }
    val byKey = linkedMapOf<String, FindGroup>()
    for (f in visible) {
        val item = Catalog.item(f.itemID) ?: continue
        val agent = byID[f.agentID]
        if (agent != null) byKey.getOrPut(agent.id) {
            FindGroup(agent.id, agent.name, agent.mission.label.capitalizedFirst(), agent.mission.info.symbol, agent, mutableListOf())
        }.finds.add(f)
        else byKey.getOrPut(item.category.raw) {
            FindGroup(item.category.raw, item.category.info.label, null, item.category.info.symbol, null, mutableListOf())
        }.finds.add(f)
    }
    return byKey.values.map { g -> g.copy(finds = sortFinds(g.finds, sort).toMutableList()) }
        .sortedWith(compareByDescending<FindGroup> { it.newCount }.thenBy { it.title })
}

/** What the list shows, in order, so a find can be scrolled to by position. */
private sealed class FindsEntry(val key: String) {
    class Header(val g: FindGroup) : FindsEntry("g-" + g.id)
    class One(val f: Find, val agent: Agent?) : FindsEntry(f.id)
    class Tiles(val finds: List<Find>) : FindsEntry("t-" + finds.first().id)
}

@Composable
fun FindsScreen() {
    val store = AppStore
    val s = store.observe()
    val prefs = remember { store.context.getSharedPreferences("baget.ui", 0) }
    var show by remember { mutableStateOf(FindsShow.NEW) }
    var sort by remember { mutableStateOf(FindsSort.of(prefs.getString("findsSort", null))) }
    var grid by remember { mutableStateOf(prefs.getBoolean("findsGrid", false)) }
    // The one-line tip: shown until dismissed (any value of 3 or more means done).
    var tipStep by remember { mutableIntStateOf(prefs.getInt("findsTips", 0)) }
    val collapsed = remember { mutableStateListOf<String>() }
    var highlighted by remember { mutableStateOf<String?>(null) }
    var opened by remember { mutableStateOf<String?>(null) }
    var sweeping by remember { mutableStateOf(false) }
    var confirmClear by remember { mutableStateOf(false) }
    val listState = rememberLazyListState()

    // One pass for the counts, one filter, one sort.
    var newTotal = 0; var savedTotal = 0; var upcomingTotal = 0
    for (f in s.finds) {
        if (f.status != FindStatus.OPEN && f.status != FindStatus.LIKED) continue
        val item = Catalog.item(f.itemID) ?: continue
        if (!item.showsInFinds) continue
        if (f.status == FindStatus.OPEN) newTotal++
        if (f.status == FindStatus.LIKED || f.watching) savedTotal++
        if (comingSoon(item)) upcomingTotal++
    }
    // The same product from several stores shows once (cheapest), with the others counted on its card.
    val productGroups = ProductMatch.group(filterFinds(s.finds, show))
    val visible = productGroups.map { it.lead }
    val alsoAt = productGroups.filter { it.others.isNotEmpty() }.associate { it.lead.id to it.others.size }
    // Grouped by scout for "Best match" and "By scout" in the list; one flat list otherwise, and always in the grid.
    val grouped = !grid && (sort == FindsSort.BEST || sort == FindsSort.SCOUT)
    val groups = if (grouped) groupFinds(visible, s.agents, sort) else emptyList()
    val flat = if (grouped) emptyList() else sortFinds(visible, sort)
    val entries = buildList<FindsEntry> {
        when {
            grid -> flat.chunked(2).forEach { add(FindsEntry.Tiles(it)) }
            grouped -> groups.forEach { g ->
                add(FindsEntry.Header(g))
                if (g.id !in collapsed) g.finds.forEach { add(FindsEntry.One(it, g.agent)) }
            }
            else -> flat.forEach { add(FindsEntry.One(it, null)) }
        }
    }
    val clearLabel = when (show) {
        FindsShow.ALL -> "Clear all"; FindsShow.NEW -> "Clear new"; FindsShow.SAVED -> "Clear saved"; FindsShow.UPCOMING -> "Clear coming soon"
    }
    val emptyText = when {
        s.agents.isEmpty() -> "Set up a scout first, then tap Hunt now."
        show == FindsShow.NEW -> "You're all caught up. Your scouts keep hunting in the background."
        show == FindsShow.SAVED -> "Nothing saved yet. Tap ♥ on a find you love, or watch one for price drops, and it shows up here."
        show == FindsShow.ALL -> "Nothing here yet. Tap Hunt now, or pull down on Today."
        else -> "No drops coming up yet. When your scouts spot a release with a date, it lands here, and you can set a reminder for it."
    }
    val leading = 4   // header, filters, tools, empty card or tip

    // Opened from Today, a notification or Live: show everything, its section open, scrolled to and opened.
    LaunchedEffect(Router.focusFind) {
        val id = Router.focusFind ?: return@LaunchedEffect
        show = FindsShow.ALL
        Router.focusFind = null
        groupFinds(ProductMatch.group(filterFinds(store.state.finds, FindsShow.ALL)).map { it.lead }, store.state.agents, sort)
            .firstOrNull { g -> g.finds.any { it.id == id } }?.let { collapsed.remove(it.id) }
        delay(250)
        // Recomputed after the filter change has been applied.
        val all = ProductMatch.group(filterFinds(store.state.finds, FindsShow.ALL)).map { it.lead }
        val keys = buildList<List<String>> {
            when {
                grid -> sortFinds(all, sort).chunked(2).forEach { row -> add(row.map { it.id }) }
                grouped -> groupFinds(all, store.state.agents, sort).forEach { g -> add(emptyList()); if (g.id !in collapsed) g.finds.forEach { add(listOf(it.id)) } }
                else -> sortFinds(all, sort).forEach { add(listOf(it.id)) }
            }
        }
        val i = keys.indexOfFirst { id in it }
        if (i >= 0) runCatching { listState.animateScrollToItem(leading + i) }
        highlighted = id
        opened = id
        delay(2200)
        if (highlighted == id) highlighted = null
    }

    LazyColumn(state = listState, modifier = Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item(key = "header") {
            FindsHeader(newTotal, sweeping, visible.isEmpty(), clearLabel, onSweep = {
                if (store.isCloud) {
                    sweeping = true
                    store.scope.launch { val m = store.cloudSweep(); sweeping = false; m?.let { Router.say(it) } }
                } else {
                    val res = store.sweep()
                    Analytics.track(AnalyticsEvent.SWEEP_RUN, mapOf("found" to res.found, "manual" to true))
                    if (res.found == 0) Router.say("Nothing new fits you right now")
                }
            }, onClear = { confirmClear = true })
        }
        item(key = "filters") {
            FilterRow(show, mapOf(FindsShow.NEW to newTotal, FindsShow.SAVED to savedTotal, FindsShow.UPCOMING to upcomingTotal)) { show = it }
        }
        item(key = "tools") {
            ToolsRow(sort, grid, onSort = { sort = it; prefs.edit().putString("findsSort", it.raw).apply() },
                onGrid = { grid = it; prefs.edit().putBoolean("findsGrid", it).apply() })
        }
        item(key = "top") {
            if (visible.isEmpty()) EmptyCard(emptyText)
            else if (tipStep < 3) FindsTipLine { tipStep = 3; prefs.edit().putInt("findsTips", 3).apply() }
            else Spacer(Modifier.height(0.dp))
        }
        for (e in entries) item(key = e.key) {
            when (e) {
                is FindsEntry.Header -> {
                    val isCollapsed = e.g.id in collapsed
                    SectionHeader(e.g, isCollapsed) { if (isCollapsed) collapsed.remove(e.g.id) else collapsed.add(e.g.id) }
                }
                is FindsEntry.One -> FindListRow(e.f, e.agent, highlighted == e.f.id, alsoAt[e.f.id] ?: 0) { opened = e.f.id }
                is FindsEntry.Tiles -> Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    e.finds.forEach { f -> Box(Modifier.weight(1f)) { FindTile(f, alsoAt[f.id] ?: 0) { opened = f.id } } }
                    if (e.finds.size == 1) Spacer(Modifier.weight(1f))
                }
            }
        }
        if (!store.isCloud) item(key = "sample") { Txt("Sample data: listings, prices and drop times are illustrative, and nothing is purchased.", size = T.caption, color = T.muted) }
    }

    opened?.let { id -> FindDetailDialog(id) { opened = null } }

    if (confirmClear) AlertDialog(onDismissRequest = { confirmClear = false }, containerColor = T.panel,
        title = { Txt("$clearLabel?", size = T.body, weight = FontWeight.Bold) },
        text = { Txt("They leave Finds and your scouts won't show them again. What your scouts learned about your taste stays.", color = T.muted) },
        confirmButton = { TextButton(onClick = {
            val gone = filterFinds(store.state.finds, show)
            val n = gone.size
            store.removeFinds(gone.map { it.id })
            Router.say(if (n == 1) "Cleared 1 find" else "Cleared $n finds")
            confirmClear = false
        }) { Txt("$clearLabel (${visible.size})", color = T.hot, weight = FontWeight.Bold) } },
        dismissButton = { TextButton(onClick = { confirmClear = false }) { Txt("Cancel", color = T.muted) } })
}

@Composable
private fun SquareButton(label: String, onClick: () -> Unit, enabled: Boolean = true, content: @Composable () -> Unit) {
    Box(Modifier.size(40.dp).clip(RoundedCornerShape(12.dp)).background(T.glass).border(1.dp, T.line, RoundedCornerShape(12.dp))
        .clickable(enabled = enabled, onClickLabel = label, onClick = onClick), contentAlignment = Alignment.Center) { content() }
}

@Composable
private fun FindsHeader(newTotal: Int, sweeping: Boolean, empty: Boolean, clearLabel: String, onSweep: () -> Unit, onClear: () -> Unit) {
    val n = AppStore.state.agents.size
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Txt("Finds", size = 30.sp, weight = FontWeight.Black, tracking = (-0.8).sp)
            Txt("$newTotal new · $n ${if (n == 1) "scout" else "scouts"} hunting", size = T.footnote, color = T.muted, maxLines = 1)
        }
        SquareButton("Hunt now", onSweep, enabled = !sweeping) {
            if (sweeping) Spinner(18.dp) else Icon(Icons.Filled.Refresh, "Hunt now", tint = T.ink, modifier = Modifier.size(20.dp))
        }
        Spacer(Modifier.width(8.dp))
        // Clearing lives behind this menu (and asks first), so it can't be hit by accident.
        Box {
            SquareButton("More", { menu = true }) { Icon(Icons.Filled.MoreHoriz, "More", tint = T.ink, modifier = Modifier.size(20.dp)) }
            DropdownMenu(menu, onDismissRequest = { menu = false }, containerColor = T.panel) {
                Txt("Swipe a find left, or tap ✕, to pass on one", size = T.caption, color = T.muted,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp).widthIn(max = 260.dp))
                DropdownMenuItem(text = { Txt("$clearLabel…", color = if (empty) T.muted else T.hot) }, enabled = !empty,
                    leadingIcon = { Icon(Icons.Outlined.Delete, null, tint = if (empty) T.muted else T.hot) },
                    onClick = { menu = false; onClear() })
            }
        }
    }
}

/** New, Saved, Coming soon, All: one tap each, with counts. */
@Composable
private fun FilterRow(show: FindsShow, counts: Map<FindsShow, Int>, onShow: (FindsShow) -> Unit) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        FindsShow.entries.forEach { f ->
            val n = counts[f] ?: 0
            val label = when (f) {
                FindsShow.SAVED -> if (n > 0) "♥ Saved · $n" else "♥ Saved"
                FindsShow.ALL -> "All"
                FindsShow.NEW -> if (n > 0) "New · $n" else "New"
                FindsShow.UPCOMING -> if (n > 0) "Coming soon · $n" else "Coming soon"
            }
            val on = show == f
            Box(Modifier.clip(CircleShape).then(if (on) Modifier.background(T.gradient) else Modifier.background(T.glass).border(1.dp, T.line, CircleShape))
                .clickable { onShow(f) }.padding(horizontal = 11.dp, vertical = 7.dp)) {
                Txt(label, size = T.footnote, weight = FontWeight.SemiBold, color = if (on) T.accentInk else T.ink, maxLines = 1)
            }
        }
    }
}

/** Sort, and list or grid. */
@Composable
private fun ToolsRow(sort: FindsSort, grid: Boolean, onSort: (FindsSort) -> Unit, onGrid: (Boolean) -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box {
            Row(Modifier.clip(RoundedCornerShape(8.dp)).clickable { menu = true }.padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Txt("Sort: ", size = T.footnote, color = T.muted)
                Txt(sort.label, size = T.footnote, weight = FontWeight.SemiBold)
                Icon(Icons.Filled.ExpandMore, null, tint = T.muted, modifier = Modifier.size(16.dp))
            }
            DropdownMenu(menu, onDismissRequest = { menu = false }, containerColor = T.panel) {
                FindsSort.entries.forEach { o ->
                    DropdownMenuItem(text = { Txt(o.label, weight = if (o == sort) FontWeight.Bold else FontWeight.Normal) },
                        trailingIcon = { if (o == sort) Icon(Icons.Filled.Check, null, tint = T.accent) },
                        onClick = { menu = false; onSort(o) })
                }
            }
        }
        Spacer(Modifier.weight(1f))
        Row(Modifier.clip(RoundedCornerShape(10.dp)).background(T.glass).border(1.dp, T.line, RoundedCornerShape(10.dp))) {
            ViewButton(Icons.AutoMirrored.Filled.ViewList, "List", !grid) { onGrid(false) }
            ViewButton(Icons.Filled.GridView, "Grid", grid) { onGrid(true) }
        }
    }
}

@Composable
private fun ViewButton(icon: ImageVector, label: String, on: Boolean, onClick: () -> Unit) {
    Box(Modifier.width(36.dp).height(30.dp).background(if (on) T.cyan.copy(alpha = 0.18f) else Color.Transparent).clickable(onClick = onClick),
        contentAlignment = Alignment.Center) {
        Icon(icon, label, tint = if (on) T.cyan else T.muted, modifier = Modifier.size(17.dp))
    }
}

@Composable
private fun FindsTipLine(onDismiss: () -> Unit) {
    val shape = RoundedCornerShape(12.dp)
    Row(Modifier.fillMaxWidth().clip(shape).background(T.hot.copy(alpha = 0.10f)).border(1.dp, T.hot.copy(alpha = 0.25f), shape)
        .padding(horizontal = 12.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Filled.Favorite, null, tint = T.hot, modifier = Modifier.size(13.dp))
        Spacer(Modifier.width(8.dp))
        Txt("Tap the heart (or swipe right) to teach your scout", size = T.footnote, color = T.ink.copy(alpha = 0.9f), modifier = Modifier.weight(1f))
        Box(Modifier.size(24.dp).clip(CircleShape).clickable(onClick = onDismiss), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Close, "Dismiss tip", tint = T.muted, modifier = Modifier.size(14.dp))
        }
    }
}

@Composable
private fun SectionHeader(g: FindGroup, isCollapsed: Boolean, onToggle: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onToggle).padding(top = 10.dp, bottom = 2.dp), verticalAlignment = Alignment.CenterVertically) {
        if (g.agent != null) AgentAvatar(g.agent, 30.dp)
        else Box(Modifier.size(30.dp).clip(RoundedCornerShape(9.dp)).background(T.gradient), contentAlignment = Alignment.Center) {
            Icon(categoryIcon(g.symbol), null, tint = T.accentInk, modifier = Modifier.size(17.dp))
        }
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Txt(g.title, size = T.body, weight = FontWeight.SemiBold, maxLines = 1)
            g.subtitle?.let { Txt(it, size = T.caption, color = T.muted, maxLines = 1) }
        }
        if (g.newCount > 0) Box(Modifier.clip(CircleShape).background(T.gradient).padding(horizontal = 8.dp, vertical = 3.dp)) {
            Txt("${g.newCount} new", size = T.caption2, weight = FontWeight.Bold, color = T.accentInk)
        }
        Spacer(Modifier.width(6.dp))
        Icon(Icons.Filled.ExpandMore, if (isCollapsed) "Expands the section" else "Collapses the section", tint = T.muted,
            modifier = Modifier.rotate(if (isCollapsed) -90f else 0f))
    }
}

/** What a find shows at a glance: store · price · match, and its state (sold out, drops soon). */
@Composable
private fun FindMeta(find: Find, item: Item) {
    val store = AppStore
    val known = item.priceKnown && item.price > 0
    val text = buildAnnotatedString {
        withStyle(SpanStyle(color = T.muted)) { append(listOfNotNull(item.source, if (known) item.priceLabel else null).joinToString(" · ")); append(" · ") }
        withStyle(SpanStyle(color = if (find.score >= 80) T.green else if (find.score >= 60) T.accent else T.muted, fontWeight = FontWeight.SemiBold)) {
            append("${find.score}% match")
        }
        if (store.isSoldOut(item)) { withStyle(SpanStyle(color = T.muted)) { append(" · ") }; withStyle(SpanStyle(color = T.warn)) { append("Sold out") } }
        else if (!store.isLive(item)) { withStyle(SpanStyle(color = T.muted)) { append(" · ") }; withStyle(SpanStyle(color = T.blue)) { append(store.whenLabel(item)) } }
    }
    Text(text, fontSize = T.caption, maxLines = 1, overflow = TextOverflow.Ellipsis)
}

@Composable
private fun PassDialog(find: Find, item: Item, agent: Agent?, onDone: () -> Unit, onDismiss: () -> Unit) {
    val store = AppStore
    AlertDialog(onDismissRequest = onDismiss, containerColor = T.panel,
        title = { Txt("What was off? ${agent?.name ?: "Your scout"} will learn from it.", size = T.body, weight = FontWeight.Bold) },
        text = {
            Column {
                PassReason.options(item).forEach { r ->
                    Txt(r.label(item), size = T.body, color = T.accent, modifier = Modifier.fillMaxWidth().clickable {
                        onDismiss()
                        store.pass(find.id, r)
                        Analytics.track(AnalyticsEvent.FIND_PASSED, mapOf("reason" to r.raw, "category" to item.category.raw))
                        Router.passed(r, agent)
                        onDone()
                    }.padding(vertical = 12.dp))
                }
            }
        },
        confirmButton = {}, dismissButton = { TextButton(onClick = onDismiss) { Txt("Cancel", color = T.muted) } })
}

@Composable
private fun RoundAction(icon: ImageVector, label: String, filled: Boolean, tint: Color, onClick: () -> Unit) {
    Box(Modifier.size(36.dp).clip(CircleShape).then(if (filled) Modifier.background(T.gradient) else Modifier.background(T.glass).border(1.dp, T.line, CircleShape))
        .clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, label, tint = tint, modifier = Modifier.size(16.dp))
    }
}

/** One find in the list: photo, title, store · price · match, one line on why; ♥ and ✕. Swipe right to like, left to pass. */
@Composable
private fun FindListRow(find: Find, groupAgent: Agent?, highlighted: Boolean, alsoAt: Int = 0, open: () -> Unit) {
    val store = AppStore
    val item = Catalog.item(find.itemID) ?: return
    val agent = groupAgent ?: store.agent(find.agentID)
    val scope = rememberCoroutineScope()
    val dx = remember(find.id) { Animatable(0f) }
    var askingWhy by remember { mutableStateOf(false) }
    val discovery = find.why.any { it.startsWith("Discovery") }
    val shape = RoundedCornerShape(16.dp)
    fun like() {
        store.like(find.id)
        Router.say("${agent?.name ?: "Your scout"} will find more like this")
    }
    val d = dx.value
    val swipeTint = if (d > 0) T.green else T.hot
    Row(Modifier.fillMaxWidth()
        .offset { IntOffset(d.roundToInt(), 0) }
        .clip(shape)
        .background(if (highlighted) T.accent.copy(alpha = 0.12f) else T.glass)
        .then(if (d != 0f) Modifier.background(Brush.horizontalGradient(
            if (d > 0) listOf(swipeTint.copy(alpha = minOf(0.45f, abs(d) / 220f)), Color.Transparent)
            else listOf(Color.Transparent, swipeTint.copy(alpha = minOf(0.45f, abs(d) / 220f))))) else Modifier)
        .border(1.dp, if (highlighted) T.accent.copy(alpha = 0.6f) else T.line, shape)
        .pointerInput(find.id, find.status) {
            // Only sideways drags: an up-and-down one belongs to the list's scrolling.
            detectHorizontalDragGestures(
                onDragEnd = {
                    val w = dx.value / 0.85f
                    when {
                        w > 100 && find.status != FindStatus.LIKED -> { scope.launch { dx.animateTo(0f) }; like() }
                        w < -100 -> scope.launch {
                            dx.animateTo(-1500f, tween(200))
                            store.pass(find.id, PassReason.PRODUCT)
                            Analytics.track(AnalyticsEvent.FIND_PASSED, mapOf("reason" to "swipe", "category" to item.category.raw))
                            Router.say("Passed. ${agent?.name ?: "Your scout"} is learning from that")
                            dx.snapTo(0f)
                        }
                        else -> scope.launch { dx.animateTo(0f) }
                    }
                },
                onDragCancel = { scope.launch { dx.animateTo(0f) } },
            ) { change, amount ->
                change.consume()
                scope.launch { dx.snapTo(dx.value + amount * 0.85f) }
            }
        }
        .clickable(onClick = open)
        .padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
        Box {
            ProductThumb(item, 66.dp)
            if (discovery) Box(Modifier.offset((-3).dp, (-3).dp).size(11.dp).clip(CircleShape).background(T.bg).padding(2.dp).clip(CircleShape).background(T.cyan))
        }
        Spacer(Modifier.width(11.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Txt(item.title, weight = FontWeight.SemiBold, maxLines = 2)
            FindMeta(find, item)
            if (alsoAt > 0) StoresBadge(alsoAt)
            (find.why.firstOrNull { !it.startsWith("Discovery") && it.isNotEmpty() } ?: find.why.firstOrNull())?.let {
                Txt(it, size = T.caption, color = T.green.copy(alpha = 0.9f), maxLines = 1)
            }
        }
        Spacer(Modifier.width(8.dp))
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            if (find.status == FindStatus.LIKED) RoundAction(Icons.Filled.Favorite, "Liked. Tap to unlike", false, T.hot) { store.unlike(find.id) }
            else {
                RoundAction(Icons.Filled.Favorite, "Like", true, T.accentInk) { like() }
                RoundAction(Icons.Filled.Close, "Pass", false, T.muted) { askingWhy = true }
            }
            if (find.watching) Icon(Icons.Filled.Visibility, "Watching", tint = T.warn, modifier = Modifier.size(12.dp))
        }
    }
    if (askingWhy) PassDialog(find, item, agent, onDone = {}, onDismiss = { askingWhy = false })
}

/** One find in the grid: a big photo with its match, title, store · price, ✕ and ♥. */
@Composable
fun FindTile(find: Find, alsoAt: Int = 0, open: () -> Unit) {
    val store = AppStore
    val item = Catalog.item(find.itemID) ?: return
    val agent = store.agent(find.agentID)
    var askingWhy by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.clip(RoundedCornerShape(18.dp)).clickable(onClick = open)) {
            Plate(item, item.brand.ifEmpty { item.category.info.label }, height = 140.dp)
            Box(Modifier.align(Alignment.TopEnd).padding(7.dp).clip(CircleShape).background(T.bg.copy(alpha = 0.85f)).padding(horizontal = 6.dp, vertical = 3.dp)) {
                Txt("${find.score}%", size = T.caption2, weight = FontWeight.Black, mono = true, color = if (find.score >= 80) T.green else T.accent)
            }
        }
        Txt(item.title, size = T.footnote, weight = FontWeight.SemiBold, maxLines = 2, modifier = Modifier.fillMaxWidth().heightIn(min = 34.dp))
        Txt(listOfNotNull(item.source, if (item.priceKnown && item.price > 0) item.priceLabel else null).joinToString(" · "),
            size = T.caption2, color = T.muted, maxLines = 1)
        if (alsoAt > 0) StoresBadge(alsoAt)
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            if (find.status == FindStatus.LIKED) TilePill(Icons.Filled.Favorite, "Liked. Tap to unlike", false, T.hot, Modifier.weight(1f)) { store.unlike(find.id) }
            else {
                // ✕ left, ♥ right: the same way you swipe.
                TilePill(Icons.Filled.Close, "Pass", false, T.muted, Modifier.weight(1f)) { askingWhy = true }
                TilePill(Icons.Filled.Favorite, "Like", true, T.accentInk, Modifier.weight(1f)) {
                    store.like(find.id)
                    Router.say("${agent?.name ?: "Your scout"} will find more like this")
                }
            }
        }
    }
    if (askingWhy) PassDialog(find, item, agent, onDone = {}, onDismiss = { askingWhy = false })
}

@Composable
private fun TilePill(icon: ImageVector, label: String, filled: Boolean, tint: Color, modifier: Modifier, onClick: () -> Unit) {
    Box(modifier.height(32.dp).clip(CircleShape).then(if (filled) Modifier.background(T.gradient) else Modifier.background(T.glass).border(1.dp, T.line, CircleShape))
        .clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, label, tint = tint, modifier = Modifier.size(15.dp))
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

fun isUpcoming(item: Item): Boolean = !item.isSample && (item.dropAt ?: 0) > now()

// MARK: A find on its own page

/** A find on its own page: a big photo, why it's for you, what it is, prices, Buy, and everything else you can do. */
@Composable
private fun FindDetailDialog(findID: String, onClose: () -> Unit) {
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false, dismissOnClickOutside = false)) {
        Box(Modifier.fillMaxSize().litBackground()) { FindDetail(findID, onClose) }
    }
}

@Composable
private fun FindDetail(findID: String, close: () -> Unit) {
    val store = AppStore
    val s = store.observe()
    val find = s.finds.firstOrNull { it.id == findID }
    val item = find?.let { Catalog.item(it.itemID) }
    var askingWhy by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp)) {
            Spacer(Modifier.weight(1f))
            Box(Modifier.size(34.dp).clip(CircleShape).background(T.glass).border(1.dp, T.line, CircleShape).clickable(onClick = close),
                contentAlignment = Alignment.Center) { Icon(Icons.Filled.Close, "Close", tint = T.ink, modifier = Modifier.size(17.dp)) }
        }
        if (find == null || item == null) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Txt("This find isn't here anymore.", color = T.muted) }
        } else {
        val agent = store.agent(find.agentID)
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(start = 18.dp, end = 18.dp, bottom = 30.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Box {
                Plate(item, item.brand.ifEmpty { item.category.info.label }, height = 290.dp)
                // Top right, clear of the brand name.
                Box(Modifier.align(Alignment.TopEnd).padding(10.dp).clip(CircleShape).background(T.bg.copy(alpha = 0.85f)).padding(horizontal = 8.dp, vertical = 4.dp)) {
                    Txt("${find.score}% MATCH", size = T.caption2, weight = FontWeight.Black, tracking = 0.6.sp, color = if (find.score >= 80) T.green else T.accent)
                }
            }
            Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Txt(item.title, size = T.title3, weight = FontWeight.Black)
                Text(buildAnnotatedString {
                    withStyle(SpanStyle(color = T.ink, fontWeight = FontWeight.SemiBold, fontSize = T.body)) {
                        append(if (item.priceKnown && item.price > 0) item.priceLabel else "Price at store")
                    }
                    withStyle(SpanStyle(color = T.muted, fontSize = T.subhead)) { append(" · ${item.source}${agent?.let { " · from ${it.name}" } ?: ""}") }
                })
            }
            find.why.firstOrNull()?.takeIf { it.isNotEmpty() }?.let { reason ->
                val shape = RoundedCornerShape(14.dp)
                Row(Modifier.fillMaxWidth().clip(shape).background(T.green.copy(alpha = 0.08f)).border(1.dp, T.green.copy(alpha = 0.25f), shape).padding(12.dp)) {
                    Icon(Icons.Filled.Favorite, null, tint = T.green, modifier = Modifier.size(16.dp).padding(top = 2.dp))
                    Spacer(Modifier.width(8.dp))
                    Txt(reason, color = T.green.copy(alpha = 0.95f))
                }
            }
            if (hasAbout(item, true)) AboutBlock(item, true)
            DetailActions(find, item, agent, onPass = { askingWhy = true }, close = close)
            DetailFacts(find, item, agent)
        }
        }
    }
    if (askingWhy && find != null && item != null) PassDialog(find, item, store.agent(find.agentID), onDone = close, onDismiss = { askingWhy = false })
}

@Composable
private fun DetailActions(find: Find, item: Item, agent: Agent?, onPass: () -> Unit, close: () -> Unit) {
    val store = AppStore
    val context = LocalContext.current
    val link = BuyLink.url(item)
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            when {
                item.isProduct && store.isSoldOut(item) && !item.isSample -> {
                    // Sold out: watch the store's page and get a text when it's back.
                    val on = find.watching
                    BigButton(if (on) Icons.Filled.Notifications else Icons.Outlined.Notifications,
                        if (on) "Watching for a restock" else "Notify me when it's back", primary = !on, modifier = Modifier.weight(1f)) {
                        store.toggleWatch(find.id)
                        Router.say(if (on) "Stopped watching this one" else "I'll check ${item.source} and text you the moment it's back")
                    }
                }
                isUpcoming(item) -> {
                    val r = store.reminder(item)
                    BigButton(if (r == null) Icons.Outlined.Notifications else Icons.Filled.Notifications, if (r == null) "Remind me" else "Reminder set",
                        primary = r == null, modifier = Modifier.weight(1f)) { Router.open(Sheet.Reminder(item.id, find.id)) }
                }
                link != null -> BigButton(Icons.Filled.ArrowOutward, "Buy at ${item.source}", primary = true, modifier = Modifier.weight(1f)) {
                    Analytics.track(AnalyticsEvent.CHECKOUT_OPENED, mapOf("category" to item.category.raw, "toStore" to true, "from" to "find"))
                    Router.buyOpened = find.id
                    openUrl(context, BuyLink.tracked(item, "find") ?: link)
                }
            }
            // Beside a long first button (Notify me when it's back, Buy at <store>), Like takes only the room it needs.
            val beside = (item.isProduct && store.isSoldOut(item) && !item.isSample) || isUpcoming(item) || link != null
            val likeMod = if (beside) Modifier else Modifier.weight(1f)
            if (find.status == FindStatus.LIKED) BigButton(Icons.Filled.Favorite, "Liked", primary = false, tint = T.hot, modifier = likeMod, compact = beside) { store.unlike(find.id) }
            else BigButton(Icons.Outlined.FavoriteBorder, "Like", primary = link == null && !isUpcoming(item), modifier = likeMod, compact = beside) {
                store.like(find.id)
                Router.say("${agent?.name ?: "Your scout"} will find more like this")
            }
        }
        Row(Modifier.fillMaxWidth()) {
            SmallAction(if (find.watching) Icons.Filled.Visibility else Icons.Outlined.Visibility, if (find.watching) "Watching" else "Watch price",
                if (find.watching) T.warn else null, Modifier.weight(1f)) {
                val was = find.watching
                store.toggleWatch(find.id)
                if (!was) Router.say("${agent?.name ?: "Your scout"} will text you on a price drop, restock or release")
            }
            SmallAction(Icons.Outlined.Forum, "Ask scout", null, Modifier.weight(1f)) { Router.open(Sheet.Chat(find.agentID, find.id)) }
            SmallAction(Icons.Outlined.Share, "Share", null, Modifier.weight(1f)) { Router.open(Sheet.ShareItem(item.id, null, false)) }
            if (find.status == FindStatus.OPEN) SmallAction(Icons.Filled.Close, "Pass", null, Modifier.weight(1f), onPass)
            else SmallAction(Icons.Outlined.Delete, "Remove", null, Modifier.weight(1f)) {
                store.removeFinds(listOf(find.id)); Router.say("Removed"); close()
            }
        }
        if (find.watching) Txt("${agent?.name ?: "Your scout"} checks the price twice a day and texts you if it drops" +
            "${if (store.isSoldOut(item)) ", or the moment it restocks" else if (!store.isLive(item)) ", and at release" else ""}.", size = T.caption, color = T.muted)
    }
}

@Composable
/** `compact`: only as wide as its own words, so the button beside it ("Notify me when it's back") has room to show in full. */
private fun BigButton(icon: ImageVector, text: String, primary: Boolean, modifier: Modifier = Modifier, tint: Color? = null, compact: Boolean = false, onClick: () -> Unit) {
    val shape = RoundedCornerShape(14.dp)
    Row(modifier.height(48.dp).clip(shape).then(if (primary) Modifier.background(T.gradient) else Modifier.background(T.glass).border(1.dp, T.line, shape))
        .clickable(onClick = onClick).padding(horizontal = if (compact) 20.dp else 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center) {
        val c = if (primary) T.accentInk else tint ?: T.ink
        Icon(icon, null, tint = c, modifier = Modifier.size(17.dp))
        Spacer(Modifier.width(6.dp))
        Txt(text, size = T.subhead, weight = FontWeight.Black, color = c, maxLines = 1)
    }
}

@Composable
private fun SmallAction(icon: ImageVector, text: String, tint: Color?, modifier: Modifier, onClick: () -> Unit) {
    Column(modifier.clip(RoundedCornerShape(10.dp)).clickable(onClick = onClick).padding(vertical = 6.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Icon(icon, null, tint = tint ?: T.muted, modifier = Modifier.size(19.dp))
        Txt(text, size = T.caption2, color = tint ?: T.muted, maxLines = 1)
    }
}

@Composable
private fun DetailFacts(find: Find, item: Item, agent: Agent?) {
    val store = AppStore
    val context = LocalContext.current
    val known = item.priceKnown && item.price > 0
    val diff = if (known && item.market > 0) item.market - item.price else 0.0
    val pct = if (known && item.market > 0) safeRound(diff / item.price * 100) else 0
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (isUpcoming(item)) ReleaseRow(item, find.id)
        val twins = store.sameProductFinds(find)
        if (twins.isNotEmpty()) CompareStores(find, twins)
        if (!item.isProduct) {
            // Intel or a results page: what it is, and a way to read it.
            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(T.cyan.copy(alpha = 0.08f)).padding(10.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(if (item.isIntel) Icons.Outlined.Newspaper else Icons.AutoMirrored.Filled.ListAlt, null, tint = T.ink, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Txt(if (item.isIntel) "Intel from ${item.source}: worth knowing, not a product to buy" else "A page of listings on ${item.source}, not a single item",
                        size = T.footnote)
                }
                item.url?.takeIf { it.startsWith("https://") }?.let { url ->
                    Chip(Icons.Filled.ArrowOutward, if (item.isIntel) "Read it" else "See listings") { openUrl(context, url) }
                }
            }
        }
        if (item.isProduct) DealVerdict.of(item)?.let { v ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Txt(v.emoji); Spacer(Modifier.width(6.dp))
                Txt(v.title, weight = FontWeight.Bold, color = when (v.level) { DealVerdict.Level.GREAT -> T.green; DealVerdict.Level.FAIR -> T.warn; DealVerdict.Level.WAIT -> T.hot; else -> T.accent })
                Spacer(Modifier.width(6.dp))
                Txt(v.detail, size = T.footnote)
            }
        }
        if (item.isProduct) item.offers?.takeIf { it.isNotEmpty() }?.let { offers ->
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
        if (item.isProduct) item.localPriceLabel?.let { local ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Public, null, tint = T.muted, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(6.dp))
                Txt("$local. Ships from outside the US, so duties or import fees may apply.", size = T.caption, color = T.muted)
            }
        }
        if (item.isProduct) {
            Hairline()
            Row {
                Stat("Price", if (known) item.priceLabel else "See store", modifier = Modifier.weight(1f))
                Stat("Market", if (known && item.market > 0) Fmt.money(item.market) else "—", modifier = Modifier.weight(1f))
                Stat("Spread", if (known && item.market > 0) "${if (diff > 0) "+" else ""}$pct%" else "—", if (diff > 0) T.green else if (diff < 0) T.hot else null, Modifier.weight(1f))
            }
            Hairline()
        }
        val traits = item.traits + listOfNotNull(item.creator)
        if (traits.isNotEmpty()) Txt(traits.joinToString(" · "), size = T.caption, color = T.muted, italic = true)
        if (agent != null) {
            if (find.why.size > 1) Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Txt("WHY YOUR SCOUT PICKED IT", size = 9.sp, weight = FontWeight.SemiBold, tracking = 1.sp, color = T.muted)
                find.why.drop(1).forEach { w ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(5.dp).clip(CircleShape).background(T.accent)); Spacer(Modifier.width(7.dp)); Txt(w, size = T.footnote)
                    }
                }
            }
            if (find.status == FindStatus.OPEN) {
                val take = store.take(agent, item)
                val tint = if (take.caution) T.warn else T.accent
                Text(buildAnnotatedString {
                    withStyle(SpanStyle(color = tint, fontWeight = FontWeight.Bold)) { append("${agent.name}: ") }
                    withStyle(SpanStyle(color = T.ink)) { append(take.text) }
                }, fontSize = T.footnote, modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(tint.copy(alpha = 0.10f)).padding(10.dp))
            }
        }
    }
}

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
fun Chip(icon: ImageVector, text: String, primary: Boolean = false, tint: Color? = null, onClick: () -> Unit) {
    Row(Modifier.height(34.dp).clip(CircleShape).then(if (primary) Modifier.background(T.gradient) else Modifier.background(T.glass).border(1.dp, T.line, CircleShape))
        .clickable(onClick = onClick).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        val c = if (primary) T.accentInk else tint ?: T.ink
        Icon(icon, null, tint = c, modifier = Modifier.size(15.dp))
        Spacer(Modifier.width(5.dp))
        Txt(text, size = T.footnote, weight = FontWeight.Bold, color = c, maxLines = 1)
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
            soldOut -> "Sold out right now. ${a?.name ?: "Your scout"} will watch for a restock and tell you the moment it's back."
            !live -> "This isn't available yet. Your scout will hold your spot and ask again at release."
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
                    Stat("Price", if (item.priceKnown) item.priceLabel else "Not listed", modifier = Modifier.weight(1f))
                    Stat("Scout", a?.name ?: "—", modifier = Modifier.weight(1f))
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
                    "You buy it at ${item.source}; Baget never charges you. Tap \"I bought it\" afterwards so your scout learns from it.", color = T.muted)
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
                        Router.say(if (soldOut) "Restock watch on" else "Got it. Your scout will ping you at release.")
                        Router.close()
                    }
                    cloud -> {
                        val typed = amountText.replace(",", "").toDoubleOrNull() ?: 0.0
                        GhostButton("I bought it", Modifier.weight(1f), enabled = item.priceKnown || typed > 0) {
                            val amount = if (item.priceKnown) item.price else typed
                            store.confirmPurchase(findID, amount)
                            Analytics.track(AnalyticsEvent.PURCHASE_CONFIRMED, mapOf("amount" to amount, "category" to item.category.raw, "score" to f.score))
                            Router.say("Logged and off your list. ${a?.name ?: "Your scout"} will learn from it.")
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

/** "Also at 3 more stores": the same product is also at other stores (compare them on its page). */
@Composable
fun StoresBadge(count: Int) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Outlined.Storefront, null, tint = T.cyan, modifier = Modifier.size(12.dp))
        Spacer(Modifier.width(4.dp))
        Txt(if (count == 1) "Also at 1 more store" else "Also at $count more stores", size = T.caption2, weight = FontWeight.SemiBold, color = T.cyan, maxLines = 1)
    }
}

/** Every store your scouts found this same product at, cheapest first, each one tap to its page. */
@Composable
private fun CompareStores(find: Find, twins: List<Find>) {
    val context = LocalContext.current
    fun p(i: Item) = if (i.priceKnown && i.price > 0) i.price else Double.POSITIVE_INFINITY
    val rows = (listOf(find) + twins).mapNotNull { f -> Catalog.item(f.itemID)?.let { f to it } }.sortedBy { p(it.second) }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Txt("AT ${rows.size} STORES", size = 9.sp, weight = FontWeight.SemiBold, tracking = 1.sp, color = T.muted)
        rows.forEachIndexed { i, (f, it) ->
            val known = it.priceKnown && it.price > 0
            Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(T.glass)
                .clickable { (BuyLink.tracked(it, "compare") ?: BuyLink.url(it))?.let { url -> openUrl(context, url) } }
                .padding(horizontal = 10.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Txt(it.source, size = T.footnote, weight = if (f.id == find.id) FontWeight.Bold else FontWeight.Normal, maxLines = 1)
                if (i == 0 && rows.size > 1 && known) {
                    Spacer(Modifier.width(8.dp))
                    Txt("LOWEST", size = 9.sp, weight = FontWeight.Black, color = T.green,
                        modifier = Modifier.clip(CircleShape).background(T.green.copy(alpha = 0.15f)).padding(horizontal = 5.dp, vertical = 2.dp))
                }
                Spacer(Modifier.weight(1f))
                Txt(if (known) it.priceLabel else "See store", size = T.footnote, weight = FontWeight.SemiBold, mono = true, color = if (i == 0) T.green else T.ink)
                Spacer(Modifier.width(8.dp))
                Icon(Icons.Filled.ArrowOutward, null, tint = T.cyan, modifier = Modifier.size(12.dp))
            }
        }
    }
}

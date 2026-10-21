package app.baget.ui.screens

import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.Icon
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.baget.engine.*
import app.baget.model.*
import app.baget.ui.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/** Talk to an agent. It learns from the conversation, searches the web, and can flag finds or line up checkout. */
@Composable
fun ChatSheet(agentID: String, aboutFindID: String?) {
    val store = AppStore
    val s = store.observe()
    val a = store.agent(agentID)
    val turns = s.chats[agentID] ?: emptyList()
    val busy = store.chatBusy == agentID
    var draft by remember { mutableStateOf("") }
    var sentContext by remember { mutableStateOf(false) }
    val list = rememberLazyListState()
    val aboutItem = aboutFindID?.let { id -> s.finds.firstOrNull { it.id == id } }?.let { Catalog.item(it.itemID) }
    LaunchedEffect(turns.size, busy) { if (turns.isNotEmpty()) runCatching { list.animateScrollToItem(turns.size + 2) } }

    fun greeting(): String {
        a ?: return "Hi."
        if (Sizes.required(a) && !Sizes.has(a))
            return "Hey, I'm ${a.name}. First thing: what size are you? I only hunt ${if (a.mission.category == Category.SNEAKERS) "pairs" else "pieces"} that are in stock in your size."
        return "Hey, I'm ${a.name}. Tell me what you've been into lately, what you can't stand, or what you're hunting for, and I'll remember it."
    }

    fun send(text: String) {
        var t = text.trim()
        if (t.isEmpty() || store.chatBusy != null) return
        draft = ""
        if (aboutItem != null && !sentContext) {
            // The first question carries the item, so the agent knows exactly what we're talking about.
            val price = if (aboutItem.priceKnown && aboutItem.price > 0) Fmt.money(aboutItem.price) else "price not listed"
            t = "About the ${aboutItem.title} ($price at ${aboutItem.source}${aboutItem.url?.let { ", $it" } ?: ""}): $t"
            sentContext = true
            Analytics.track(AnalyticsEvent.ASK_ABOUT, mapOf("category" to aboutItem.category.raw))
        }
        val message = t
        store.scope.launch { store.sendChat(agentID, message) }
    }

    SheetFrame(a?.name ?: "Agent") {
        LazyColumn(Modifier.weight(1f), state = list, contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (aboutItem != null) item {
                Row(Modifier.glass(RoundedCornerShape(14.dp)).padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
                    ProductThumb(aboutItem, 48.dp); Spacer(Modifier.width(10.dp))
                    Column { Txt("Asking about", size = T.caption2, weight = FontWeight.Bold, color = T.muted); Txt(aboutItem.title, size = T.footnote, weight = FontWeight.SemiBold, maxLines = 2) }
                }
            }
            item { Bubble(if (aboutItem != null) "What do you want to know about it?" else greeting(), false) }
            items(turns.size) { i ->
                val t = turns[i]
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Bubble(t.text, t.role == "user")
                    t.actions.forEach { act ->
                        when (act.type) {
                            "profile_updated" -> Txt("✓ Updated your profile", size = T.caption, color = T.muted)
                            "find" -> Txt("✦ Flagged ${act.title ?: "a find"} in your Finds", size = T.caption, color = T.green)
                            "checkout" -> act.findID?.let { fid -> GhostButton("Review ${act.title ?: "checkout"}", Modifier.widthIn(max = 280.dp), icon = Icons.Filled.ShoppingCart) { Router.open(Sheet.Checkout(fid)) } }
                        }
                    }
                }
            }
            if (busy) item { Row(verticalAlignment = Alignment.CenterVertically) { Spinner(16.dp); Spacer(Modifier.width(8.dp)); Txt("Thinking…", color = T.muted) } }
        }
        if (turns.isEmpty() || (aboutItem != null && !sentContext)) {
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                (if (aboutItem != null) listOf("Is this a good price?", "Find it cheaper", "Will it restock in my size?", "Show me similar")
                 else listOf("Find me something new", "What have you learned about me?", "Anything worth buying this week?")).forEach { q -> Pill(q) { send(q) } }
            }
        }
        Row(Modifier.fillMaxWidth().background(T.panel.copy(alpha = 0.9f)).padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Field(draft, { draft = it }, "Tell me what you're into, or ask me to find something", Modifier.weight(1f), singleLine = false, maxLines = 4)
            Spacer(Modifier.width(8.dp))
            PrimaryButton("", Modifier.width(54.dp), icon = Icons.Filled.ArrowUpward, enabled = !busy && draft.isNotBlank()) { send(draft) }
        }
    }
}

@Composable
private fun Bubble(text: String, mine: Boolean) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start) {
        if (mine) Spacer(Modifier.width(40.dp))
        SelectionContainer(Modifier.weight(1f, fill = false)) {
            Box(Modifier.clip(RoundedCornerShape(16.dp)).then(if (mine) Modifier.background(T.gradient) else Modifier.background(T.glass.copy(alpha = 0.1f)))
                .padding(horizontal = 13.dp, vertical = 10.dp)) {
                Txt(text, color = if (mine) T.accentInk else T.ink)
            }
        }
        if (!mine) Spacer(Modifier.width(40.dp))
    }
}

/** Finds as a card stack: right to like, left to pass, up to buy. */
@Composable
fun SwipeSheet() {
    val store = AppStore
    val s = store.observe()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val ids = remember { store.swipeQueue.map { it.id } }
    var index by remember { mutableIntStateOf(0) }
    var liked by remember { mutableIntStateOf(0) }
    var passed by remember { mutableIntStateOf(0) }
    val dx = remember { Animatable(0f) }
    val dy = remember { Animatable(0f) }

    SheetFrame("Swipe") {
        Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            val f = ids.getOrNull(index)?.let { id -> s.finds.firstOrNull { it.id == id } }
            val item = f?.let { Catalog.item(it.itemID) }
            if (f != null && item != null) {
                fun act(action: String) {
                    val outX = when (action) { "like" -> 1400f; "pass" -> -1400f; else -> 0f }
                    val outY = if (action == "buy") -1800f else dy.value
                    when (action) {
                        "like" -> { store.like(f.id); liked++ }
                        "pass" -> { store.pass(f.id, PassReason.STYLE); passed++ }
                        "buy" -> BuyLink.url(item)?.let { link ->
                            Analytics.track(AnalyticsEvent.CHECKOUT_OPENED, mapOf("category" to item.category.raw, "toStore" to true, "from" to "swipe"))
                            Router.buyOpened = f.id
                            openUrl(context, BuyLink.tracked(item, "swipe") ?: link)
                        }
                    }
                    Analytics.track(AnalyticsEvent.SWIPE, mapOf("action" to action, "category" to item.category.raw, "score" to f.score))
                    scope.launch {
                        launch { dx.animateTo(outX) }; dy.animateTo(outY)
                        delay(30)
                        dx.snapTo(0f); dy.snapTo(0f); index++
                    }
                }
                Txt("${index + 1} of ${ids.size}", size = T.caption, color = T.muted, mono = true)
                Box(Modifier.weight(1f).fillMaxWidth()) {
                    ids.getOrNull(index + 1)?.let { nid -> s.finds.firstOrNull { it.id == nid } }?.let { nf ->
                        Catalog.item(nf.itemID)?.let { ni -> Box(Modifier.scale(0.95f).offset(y = 14.dp).alpha(0.6f)) { SwipeCard(nf, ni) } }
                    }
                    Box(Modifier
                        .offset { IntOffset(dx.value.roundToInt(), dy.value.roundToInt()) }
                        .rotate(dx.value / 22f / 3f)
                        .pointerInput(f.id) {
                            detectDragGestures(onDragEnd = {
                                when {
                                    dx.value > 300 -> act("like")
                                    dx.value < -300 -> act("pass")
                                    dy.value < -350 && BuyLink.url(item) != null -> act("buy")
                                    else -> scope.launch { launch { dx.animateTo(0f) }; dy.animateTo(0f) }
                                }
                            }) { change, amount ->
                                change.consume()
                                scope.launch { dx.snapTo(dx.value + amount.x); dy.snapTo(dy.value + amount.y) }
                            }
                        }) {
                        SwipeCard(f, item)
                        val stamp = when {
                            dx.value > 100 -> Triple("LIKE", T.green, dx.value / 300f)
                            dx.value < -100 -> Triple("PASS", T.hot, -dx.value / 300f)
                            dy.value < -130 -> Triple("BUY", T.accent, -dy.value / 350f)
                            else -> null
                        }
                        stamp?.let { (t, c, o) ->
                            Box(Modifier.align(Alignment.TopCenter).padding(top = 24.dp).alpha(o.coerceIn(0f, 1f)).rotate(-10f)
                                .border(3.dp, c, RoundedCornerShape(10.dp)).padding(horizontal = 14.dp, vertical = 6.dp)) {
                                Txt(t, size = 28.sp, weight = FontWeight.Black, color = c, tracking = 2.sp)
                            }
                        }
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(18.dp), verticalAlignment = Alignment.CenterVertically) {
                    RoundButton(Icons.Filled.Close, T.hot, "Pass") { act("pass") }
                    if (BuyLink.url(item) != null) RoundButton(Icons.Filled.ArrowOutward, T.accent, "Buy") { act("buy") }
                    RoundButton(if (f.watching) Icons.Filled.Visibility else Icons.Filled.VisibilityOff, T.warn, if (f.watching) "Watching" else "Watch") { store.toggleWatch(f.id) }
                    RoundButton(Icons.Filled.Favorite, T.green, "Like", big = true) { act("like") }
                }
            } else {
                Spacer(Modifier.height(40.dp))
                Icon(Icons.Filled.Verified, null, tint = T.green, modifier = Modifier.size(54.dp))
                Txt(if (ids.isEmpty()) "No new finds right now" else "All caught up", size = T.title2, weight = FontWeight.Black)
                Txt(if (ids.isEmpty()) "Your squad keeps hunting in the background and will text you."
                    else "$liked liked, $passed passed. Your squad just got sharper; their next search uses it.", color = T.muted,
                    align = androidx.compose.ui.text.style.TextAlign.Center)
                PrimaryButton("Back to Today", Modifier.widthIn(max = 240.dp)) { Router.close() }
            }
        }
    }
}

@Composable
private fun SwipeCard(f: Find, item: Item) {
    val store = AppStore
    val agent = store.agent(f.agentID)
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(T.panel).border(1.dp, T.line, RoundedCornerShape(24.dp))
        .verticalScroll(rememberScrollState()).padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Plate(item, store.whenLabel(item), height = 280.dp, live = store.isLive(item))
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (agent != null) { AgentAvatar(agent, 22.dp); Spacer(Modifier.width(6.dp)); Txt(agent.name, size = T.caption, weight = FontWeight.SemiBold, color = T.muted) }
            Spacer(Modifier.weight(1f))
            Txt("${f.score}% match", size = T.caption, weight = FontWeight.Bold, mono = true, color = if (f.score >= 80) T.green else T.accent)
        }
        Txt(item.title, size = T.title3, weight = FontWeight.Black, maxLines = 3)
        Txt(listOf(item.source, if (item.priceKnown && item.price > 0) Fmt.money(item.price) else "Price at store").joinToString(" · "), color = T.muted)
        if (hasAbout(item)) AboutBlock(item, lines = 3)
        DealVerdict.of(item)?.let { VerdictChip(it, showDetail = true) }
        f.why.firstOrNull()?.let { Txt(it, size = T.footnote, color = T.green.copy(alpha = 0.9f), maxLines = 3) }
    }
}

@Composable
private fun RoundButton(icon: androidx.compose.ui.graphics.vector.ImageVector, tint: Color, name: String, big: Boolean = false, onClick: () -> Unit) {
    val size = if (big) 66.dp else 54.dp
    Box(Modifier.size(size).clip(CircleShape).background(T.glass).border(1.dp, tint.copy(alpha = 0.5f), CircleShape).clickable(onClick = onClick),
        contentAlignment = Alignment.Center) { Icon(icon, name, tint = tint, modifier = Modifier.size(if (big) 28.dp else 22.dp)) }
}

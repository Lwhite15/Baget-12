package app.baget.ui.screens

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowOutward
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material3.Icon
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
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

/** How many of today's finds the deck holds. */
const val TODAY_DECK_SIZE = 12

/**
 * Today's finds as a swipe deck, right on Today: right to like, left to pass, or use the buttons. Tap a card for details.
 * Only sideways drags move a card, so scrolling the page over it still works.
 */
@Composable
fun TodayDeck(ids: List<String>, index: Int, onIndex: (Int) -> Unit) {
    val store = AppStore
    val s = store.observe()
    val context = LocalContext.current
    val haptic = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    val dx = remember { Animatable(0f) }
    var liked by remember { mutableIntStateOf(0) }
    var busy by remember { mutableStateOf(false) }

    fun find(i: Int): Pair<Find, Item>? {
        val id = ids.getOrNull(i) ?: return null
        val f = s.finds.firstOrNull { it.id == id } ?: return null
        val item = Catalog.item(f.itemID) ?: return null
        return f to item
    }

    val cur = find(index)
    if (cur == null) { DeckDone(ids.isEmpty(), liked); return }
    val (f, item) = cur

    fun act(a: String) {
        if (busy) return
        if (a == "buy") {
            BuyLink.url(item)?.let { link ->
                Analytics.track(AnalyticsEvent.CHECKOUT_OPENED, mapOf("category" to item.category.raw, "toStore" to true, "from" to "today_deck"))
                Router.buyOpened = f.id
                openUrl(context, BuyLink.tracked(item, "today_deck") ?: link)
            }
            return
        }
        busy = true
        if (a == "like") {
            if (f.status != FindStatus.LIKED) store.like(f.id)
            liked++
            haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
        } else store.pass(f.id, PassReason.PRODUCT)
        Analytics.track(AnalyticsEvent.SWIPE, mapOf("action" to a, "category" to item.category.raw, "score" to f.score, "from" to "today"))
        scope.launch {
            dx.animateTo(if (a == "like") 1400f else -1400f, tween(200))
            dx.snapTo(0f)
            onIndex(index + 1)
            busy = false
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.fillMaxWidth()) {
            find(index + 1)?.let { (nf, ni) ->
                Box(Modifier.scale(0.95f).offset(y = 12.dp).alpha(0.55f)) { DeckCard(nf, ni, index + 1, ids.size) }
            }
            Box(Modifier
                .offset { IntOffset(dx.value.roundToInt(), 0) }
                .rotate(dx.value / 24f / 3f)
                .pointerInput(f.id) {
                    detectHorizontalDragGestures(onDragEnd = {
                        when {
                            dx.value > 280 -> act("like")
                            dx.value < -280 -> act("pass")
                            else -> scope.launch { dx.animateTo(0f, spring()) }
                        }
                    }, onDragCancel = { scope.launch { dx.animateTo(0f) } }) { change, amount ->
                        if (busy) return@detectHorizontalDragGestures
                        change.consume()
                        scope.launch { dx.snapTo(dx.value + amount) }
                    }
                }
                .clickable { Router.focusFind = f.id; Router.tab = AppTab.FINDS }) {
                DeckCard(f, item, index, ids.size)
                val stamp = when {
                    dx.value > 80 -> Triple("LIKE", T.green, dx.value / 280f)
                    dx.value < -80 -> Triple("PASS", T.hot, -dx.value / 280f)
                    else -> null
                }
                stamp?.let { (t, c, o) ->
                    Box(Modifier.align(Alignment.TopStart).padding(top = 34.dp, start = 18.dp).alpha(o.coerceIn(0f, 1f)).rotate(-12f)
                        .clip(RoundedCornerShape(10.dp)).background(T.bg.copy(alpha = 0.35f))
                        .border(3.dp, c, RoundedCornerShape(10.dp)).padding(horizontal = 12.dp, vertical = 5.dp)) {
                        Txt(t, size = 26.sp, weight = FontWeight.Black, color = c, tracking = 2.sp)
                    }
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
            DeckRound(Icons.Filled.Close, T.ink, "Pass", filled = false) { act("pass") }
            DeckRound(Icons.Filled.Favorite, T.accentInk, "Like", filled = true, big = true) { act("like") }
            if (BuyLink.url(item) != null) {
                Row(Modifier.height(52.dp).clip(CircleShape).background(T.glass).border(1.dp, T.line, CircleShape)
                    .clickable { act("buy") }.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.ArrowOutward, null, tint = T.cyan, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Txt("Buy", weight = FontWeight.Bold, color = T.cyan)
                }
            }
        }
        Txt("Swipe right to like, left to pass. Tap for details.", size = T.caption, color = T.muted)
    }
}

@Composable
private fun DeckCard(f: Find, item: Item, index: Int, total: Int) {
    val agent = AppStore.agent(f.agentID)
    val shape = RoundedCornerShape(24.dp)
    Column(Modifier.fillMaxWidth().shadow(16.dp, shape).clip(shape).background(T.panel).border(1.dp, T.line, shape)) {
        Box {
            Plate(item, item.brand.ifEmpty { item.category.info.label }, height = 300.dp, lead = true)
            Box(Modifier.align(Alignment.TopEnd).padding(10.dp).clip(CircleShape).background(T.bg.copy(alpha = 0.85f))
                .padding(horizontal = 9.dp, vertical = 5.dp)) {
                Txt("${f.score}% match", size = T.caption, weight = FontWeight.Black, mono = true, color = if (f.score >= 80) T.green else T.accent)
            }
        }
        Column(Modifier.padding(horizontal = 14.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row {
                Txt("${index + 1} of $total", size = T.caption2, weight = FontWeight.Bold, mono = true, color = T.muted)
                Spacer(Modifier.weight(1f))
                agent?.let { Txt("from ${it.name}", size = T.caption2, weight = FontWeight.SemiBold, color = T.muted, maxLines = 1) }
            }
            Txt(item.title, size = T.body, weight = FontWeight.Bold, maxLines = 2)
            Txt(listOfNotNull(if (item.priceKnown && item.price > 0) item.priceLabel else null, item.source).joinToString(" · "),
                color = T.muted, maxLines = 1)
            (f.why.firstOrNull { !it.startsWith("Discovery") && it.isNotEmpty() } ?: f.why.firstOrNull())?.let { why ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Favorite, null, tint = T.green.copy(alpha = 0.9f), modifier = Modifier.size(11.dp))
                    Spacer(Modifier.width(5.dp))
                    Txt(why, size = T.caption, color = T.green.copy(alpha = 0.9f), maxLines = 1)
                }
            }
        }
    }
}

@Composable
private fun DeckRound(icon: ImageVector, tint: Color, name: String, filled: Boolean, big: Boolean = false, onClick: () -> Unit) {
    val size = if (big) 60.dp else 52.dp
    Box(Modifier.size(size).clip(CircleShape)
        .then(if (filled) Modifier.background(T.gradient) else Modifier.background(T.glass).border(1.dp, T.line, CircleShape))
        .clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, name, tint = tint, modifier = Modifier.size(if (big) 24.dp else 19.dp))
    }
}

@Composable
private fun DeckDone(empty: Boolean, liked: Int) {
    val shape = RoundedCornerShape(18.dp)
    Row(Modifier.fillMaxWidth().clip(shape).background(T.green.copy(alpha = 0.08f)).border(1.dp, T.green.copy(alpha = 0.3f), shape).padding(14.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Filled.Verified, null, tint = T.green, modifier = Modifier.size(26.dp))
        Spacer(Modifier.width(12.dp))
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Txt(if (empty) "No new finds right now" else "That's today's finds", weight = FontWeight.Bold)
            Txt(if (liked > 0) "$liked liked. Your scouts just got sharper. More for you below." else "Your scouts keep hunting. More for you below.",
                size = T.caption, color = T.muted)
        }
    }
}

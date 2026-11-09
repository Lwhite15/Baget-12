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
    var watchStamp by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }

    SheetFrame("Swipe") {
        Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            val f = ids.getOrNull(index)?.let { id -> s.finds.firstOrNull { it.id == id } }
            val item = f?.let { Catalog.item(it.itemID) }
            if (f != null && item != null) {
                fun act(action: String) {
                    if (busy) return
                    if (action == "watch") {
                        // Already watching: stop, and stay on this card.
                        if (f.watching) { store.toggleWatch(f.id); Router.say("Stopped watching"); return }
                        store.toggleWatch(f.id)
                        Analytics.track(AnalyticsEvent.SWIPE, mapOf("action" to "watch", "category" to item.category.raw, "score" to f.score))
                        busy = true
                        watchStamp = true
                        scope.launch {
                            delay(900)
                            dy.animateTo(2400f)
                            watchStamp = false
                            dx.snapTo(0f); dy.snapTo(0f); index++
                            busy = false
                        }
                        return
                    }
                    val outX = when (action) { "like" -> 1400f; "pass" -> -1400f; else -> 0f }
                    val outY = if (action == "buy") -1800f else dy.value
                    when (action) {
                        "like" -> { store.like(f.id); liked++ }
                        "pass" -> { store.pass(f.id, PassReason.PRODUCT); passed++ }
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
                            detectDragGestures(onDragEnd = end@{
                                if (busy) return@end
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
                        if (watchStamp) Column(Modifier.align(Alignment.TopCenter).padding(top = 24.dp),
                            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Box(Modifier.rotate(-10f).border(3.dp, T.warn, RoundedCornerShape(10.dp)).padding(horizontal = 14.dp, vertical = 6.dp)) {
                                Txt("NOW WATCHING", size = 28.sp, weight = FontWeight.Black, color = T.warn, tracking = 2.sp, maxLines = 1)
                            }
                            Box(Modifier.clip(CircleShape).background(T.bg.copy(alpha = 0.85f)).padding(horizontal = 12.dp, vertical = 7.dp)) {
                                Txt("We'll text you if the price drops or it restocks.", size = T.footnote, weight = FontWeight.SemiBold)
                            }
                        }
                        val stamp = if (watchStamp) null else when {
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
                    RoundButton(if (f.watching) Icons.Filled.Visibility else Icons.Filled.VisibilityOff, T.warn, if (f.watching) "Watching" else "Watch") { act("watch") }
                    RoundButton(Icons.Filled.Favorite, T.green, "Like", big = true) { act("like") }
                }
            } else {
                Spacer(Modifier.height(40.dp))
                Icon(Icons.Filled.Verified, null, tint = T.green, modifier = Modifier.size(54.dp))
                Txt(if (ids.isEmpty()) "No new finds right now" else "All caught up", size = T.title2, weight = FontWeight.Black)
                Txt(if (ids.isEmpty()) "Your scouts keep hunting in the background and will text you."
                    else "$liked liked, $passed passed. Your scouts just got sharper; their next search uses it.", color = T.muted,
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
        Txt(listOf(item.source, if (item.priceKnown && item.price > 0) item.priceLabel else "Price at store").joinToString(" · "), color = T.muted)
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

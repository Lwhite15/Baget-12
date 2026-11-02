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

    SheetFrame(a?.name ?: "Scout") {
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

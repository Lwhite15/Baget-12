package app.baget.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.baget.engine.*
import app.baget.model.*
import app.baget.ui.*

@Composable
fun SquadScreen() {
    val store = AppStore
    val s = store.observe()
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        SectionTitle("Your squad")
        HuntBox()
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            GhostButton("What Baget knows", Modifier.weight(1f), icon = Icons.Filled.Psychology) { Router.open(Sheet.Taste) }
            GhostButton("Detailed setup", Modifier.weight(1f), icon = Icons.Filled.Tune) { Router.deployPrefill = null; Router.open(Sheet.Deploy) }
        }
        if (s.agents.isEmpty()) EmptyCard("No agents yet. Tell Baget what you're hunting above.")
        s.agents.toList().forEach { a -> key(a.id) { AgentCard(a) } }
        Column(Modifier.fillMaxWidth().glassCard(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Kick("Squad activity")
            if (s.log.isEmpty()) Txt("No activity yet.", size = T.footnote, color = T.muted)
            s.log.take(6).forEach { l ->
                Row {
                    Txt(Fmt.ago(l.date), size = T.caption2, color = T.muted, mono = true, modifier = Modifier.width(64.dp))
                    Txt(l.text, size = T.footnote, maxLines = 2)
                }
            }
        }
    }
}

@Composable
private fun AgentCard(agent: Agent) {
    val store = AppStore
    val s = store.observe()
    var confirmRetire by remember { mutableStateOf(false) }
    val k = Matcher.intel(agent)
    val finds = s.finds.count { it.agentID == agent.id }
    val learned = agent.learned.filter { it.value != 0 }.entries.sortedByDescending { kotlin.math.abs(it.value) }.take(8)
    val styleTags = agent.style.traits + agent.style.makers + agent.style.creators

    fun change(name: String, edit: (Agent) -> Unit) {
        val a = agent.deepCopy(); edit(a); store.update(a)
        Analytics.track(AnalyticsEvent.AGENT_SETTING_CHANGED, mapOf("setting" to name))
    }

    Column(Modifier.fillMaxWidth().alpha(if (agent.isOff) 0.75f else 1f).glassCard(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.Top) {
            Box(Modifier.clickable { Router.open(Sheet.AgentIcon(agent.id)) }) { AgentAvatar(agent, 46.dp) }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Txt(agent.name, size = T.title3, weight = FontWeight.Black)
                Txt("${agent.mission.label} · $finds find${if (finds == 1) "" else "s"}", size = T.caption, color = T.muted, mono = true)
            }
            Column(horizontalAlignment = Alignment.End) {
                Switch(checked = !agent.isOff, onCheckedChange = { on ->
                    store.setOff(agent.id, !on)
                    Analytics.track(AnalyticsEvent.AGENT_SETTING_CHANGED, mapOf("setting" to "on"))
                    Router.say(if (on) "${agent.name} is back on the hunt" else "${agent.name} is off. No searching, no texts.")
                }, colors = SwitchDefaults.colors(checkedTrackColor = T.green, checkedThumbColor = Color.White))
                Txt(if (agent.isOff) "OFF" else "ON", size = 9.sp, weight = FontWeight.Bold, tracking = 1.sp, color = if (agent.isOff) T.muted else T.green)
            }
        }
        // Over the Free limit: the server only sends the first scouts (oldest first, among those switched on), the rest wait.
        val resting = store.isCloud && !store.isPro && store.plan != null && !agent.isOff &&
            s.agents.filter { !it.isOff }.indexOfFirst { it.id == agent.id }.let { it >= 0 && it >= store.scoutLimit }
        if (resting) Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(T.warn.copy(alpha = 0.10f))
            .clickable { Router.open(Sheet.Pro) }.padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Hotel, null, tint = T.warn, modifier = Modifier.size(16.dp)); Spacer(Modifier.width(8.dp))
            Column {
                Txt("Resting on Free, which includes ${store.scoutLimit} scouts.", size = T.footnote)
                Txt(Billing.proTrial?.let { "Try Pro free for ${Billing.spoken(it)} to wake it" } ?: "Go Pro to wake it", size = T.footnote, weight = FontWeight.Bold, color = T.accent)
            }
        }
        if (agent.isOff) Row(Modifier.fillMaxWidth().glass(RoundedCornerShape(12.dp)).padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Bedtime, null, tint = T.muted, modifier = Modifier.size(16.dp)); Spacer(Modifier.width(6.dp))
            Txt("Off. Not searching or texting until you switch it back on.", size = T.footnote, color = T.muted)
        }
        if (agent.keywords.isNotEmpty()) Flow { agent.keywords.forEach { Tag(it) } }
        if (styleTags.isNotEmpty()) Flow { styleTags.forEach { Tag(it, T.green) } }
        TasteBoardRow(agent)
        PrimaryButton("Talk to ${agent.name}", Modifier.fillMaxWidth(), icon = Icons.Filled.Forum) {
            if (store.isCloud) Router.open(Sheet.Chat(agent.id)) else Router.say("Sign in to talk to your agents. They need the internet to search.")
        }
        if (Sizes.required(agent) && !Sizes.has(agent)) Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(T.warn.copy(alpha = 0.1f)).padding(10.dp)) {
            Txt("Needs your size. ", size = T.footnote, weight = FontWeight.Bold, color = T.warn)
            Txt("I won't flag anything until I know it, so you only see things that fit.", size = T.footnote)
        }
        Row {
            Stat(if (agent.mission.info.sizeRequired) agent.mission.info.sizeLabel ?: "Size" else "Mission",
                if (agent.mission.info.sizeRequired) agent.size.ifEmpty { "Any" } else agent.mission.label, modifier = Modifier.weight(1f))
            Stat("When it finds something", agent.mode.short, modifier = Modifier.weight(1f))
        }
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Txt("Taste profile $k% complete${if (k < 70) " · rate finds so I learn faster" else ""}", size = T.caption, color = T.muted)
            Meter(k / 100.0)
        }
        if (learned.isEmpty() && agent.priceNote == 0.0) {
            Txt("Nothing learned yet. Buy, watch or pass on finds and I'll pick up your taste.", size = T.footnote, color = T.muted)
        } else Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Txt("What I've learned about you", size = T.caption, color = T.muted)
            Flow {
                learned.forEach { (key, w) -> LearnedChip("${if (w > 0) "Likes" else "Not into"} $key", w > 0) { store.unlearn(agent.id, key) } }
                if (agent.priceNote > 0) LearnedChip("Prefers under ${Fmt.money(agent.priceNote)}", null) { store.unlearn(agent.id, "__price") }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            MenuButton(agent.voice.label, Icons.Filled.Message, Modifier.weight(1f), Voice.entries.map { it.label to it.blurb }) { i -> change("voice") { it.voice = Voice.entries[i] } }
            MenuButton(agent.mode.short, Icons.Filled.ShoppingCart, Modifier.weight(1f), BuyMode.entries.map { it.label to null }) { i -> change("mode") { it.mode = BuyMode.entries[i] } }
            MenuButton(agent.alerts.short, if (agent.alerts == AgentAlerts.OFF) Icons.Filled.NotificationsOff else Icons.Filled.Notifications, Modifier.weight(1f),
                AgentAlerts.entries.map { it.label to it.blurb }) { i -> change("alerts") { it.alerts = AgentAlerts.entries[i] } }
        }
        Row(Modifier.fillMaxWidth().clickable { confirmRetire = true }.padding(top = 2.dp, bottom = 2.dp), horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Delete, null, tint = T.hot, modifier = Modifier.size(16.dp)); Spacer(Modifier.width(6.dp))
            Txt("Delete ${agent.name}", size = T.footnote, weight = FontWeight.SemiBold, color = T.hot)
        }
    }
    if (confirmRetire) AlertDialog(onDismissRequest = { confirmRetire = false }, containerColor = T.panel,
        title = { Txt("Delete ${agent.name}?", size = T.body, weight = FontWeight.Bold) },
        text = { Txt("It stops hunting for good and what it learned is lost. Its finds stay in your Finds.", color = T.muted) },
        confirmButton = { TextButton(onClick = {
            confirmRetire = false
            store.retire(agent.id)
            Analytics.track(AnalyticsEvent.AGENT_RETIRED, mapOf("mission" to agent.mission.label))
            Router.say("${agent.name} deleted")
        }) { Txt("Delete", color = T.hot, weight = FontWeight.Bold) } },
        dismissButton = {
            Row {
                if (!agent.isOff) TextButton(onClick = { confirmRetire = false; store.setOff(agent.id, true); Router.say("${agent.name} is off") }) {
                    Txt("Just turn it off", color = T.accent)
                }
                TextButton(onClick = { confirmRetire = false }) { Txt("Cancel", color = T.muted) }
            }
        })
}

@Composable
private fun LearnedChip(text: String, like: Boolean?, forget: () -> Unit) {
    val tint = when (like) { null -> T.muted; true -> T.green; false -> T.hot }
    Row(Modifier.clip(CircleShape).background(tint.copy(alpha = 0.14f)).padding(horizontal = 9.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Txt(text, size = T.caption, weight = FontWeight.Medium, color = tint)
        Spacer(Modifier.width(4.dp))
        Icon(Icons.Filled.Close, "Forget $text", tint = tint, modifier = Modifier.size(12.dp).clickable(onClick = forget))
    }
}

@Composable
fun MenuButton(label: String, icon: ImageVector, modifier: Modifier, options: List<Pair<String, String?>>, onPick: (Int) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box(modifier) {
        Row(Modifier.fillMaxWidth().glass(RoundedCornerShape(13.dp)).clickable { open = true }.padding(vertical = 10.dp, horizontal = 6.dp),
            horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, tint = T.ink, modifier = Modifier.size(14.dp)); Spacer(Modifier.width(5.dp))
            Txt(label, size = T.footnote, weight = FontWeight.SemiBold, maxLines = 1)
        }
        DropdownMenu(open, onDismissRequest = { open = false }, containerColor = T.panel) {
            options.forEachIndexed { i, (title, blurb) ->
                DropdownMenuItem(text = {
                    Column { Txt(title); if (blurb != null) Txt(blurb, size = T.caption, color = T.muted) }
                }, onClick = { open = false; onPick(i) })
            }
        }
    }
}

/** The taste board on an agent's card. */
@Composable
fun TasteBoardRow(agent: Agent) {
    val store = AppStore
    store.observe()
    store.photoVersion
    Column(Modifier.fillMaxWidth().glass(RoundedCornerShape(14.dp)).padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Kick("Taste board${if (agent.tasteBoard.isEmpty()) "" else " · ${agent.tasteBoard.size}"}", modifier = Modifier.weight(1f))
            val full = agent.tasteBoard.size >= AppStore.maxTastePhotos
            Row(Modifier.clickable(enabled = !full) { Router.open(Sheet.TastePhoto(agent.id)) }, verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Add, null, tint = if (full) T.muted else T.accent, modifier = Modifier.size(14.dp))
                Txt("Add a photo", size = T.caption, weight = FontWeight.SemiBold, color = if (full) T.muted else T.accent)
            }
        }
        if (agent.tasteBoard.isEmpty()) Txt("Show me photos of things you love, like a fit, a shelf, a car or a room. I'll pick up the style and hunt for more of it.",
            size = T.footnote, color = T.muted)
        else Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            agent.tasteBoard.chunked(3).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    row.forEach { p ->
                        Box(Modifier.weight(1f).aspectRatio(1f).clip(RoundedCornerShape(12.dp)).background(T.glass)) {
                            store.image(p)?.let { BitmapImage(it, Modifier.fillMaxSize()) }
                            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Transparent, T.bg.copy(alpha = 0.85f)), startY = 80f)))
                            Txt(p.tags.take(3).joinToString(" · "), size = 10.sp, weight = FontWeight.SemiBold, color = Color.White, maxLines = 1,
                                modifier = Modifier.align(Alignment.BottomStart).padding(6.dp))
                            Box(Modifier.align(Alignment.TopEnd).padding(4.dp).size(22.dp).clip(CircleShape).background(T.bg.copy(alpha = 0.75f))
                                .clickable { store.removeTastePhoto(agent.id, p.id); Router.say("Photo removed") }, contentAlignment = Alignment.Center) {
                                Icon(Icons.Filled.Close, "Remove this photo", tint = Color.White, modifier = Modifier.size(12.dp))
                            }
                        }
                    }
                    repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
    }
}

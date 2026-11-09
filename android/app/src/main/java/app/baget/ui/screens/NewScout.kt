package app.baget.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.baget.engine.*
import app.baget.model.*
import app.baget.ui.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** "Send a new scout": a button (not a search box), so nobody mistakes it for search. Tapping it opens a short sheet
 *  that explains a scout hunts in the background for days. After sending, the card becomes the scout's confirmation. */
@Composable
fun NewScoutCard(compact: Boolean = false) {
    val store = AppStore
    store.observe()
    val sent = Router.scoutSent
    val a = sent?.let { store.agent(it.agentID) }
    if (!compact && sent != null && a != null) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            ScoutConfirmation(a, sent.intro)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                Row(Modifier.clickable { Router.open(Sheet.NewScout) }.padding(4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Add, null, tint = T.cyan, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(4.dp))
                    Txt("Send another scout", weight = FontWeight.SemiBold, color = T.cyan)
                }
            }
        }
    } else {
        val shape = RoundedCornerShape(18.dp)
        Row(Modifier.fillMaxWidth().clip(shape)
            .background(Brush.linearGradient(listOf(T.blue.copy(alpha = 0.22f), T.green.copy(alpha = 0.14f))))
            .border(1.dp, Color.White.copy(alpha = 0.16f), shape)
            .clickable {
                Router.open(Sheet.NewScout)
                Analytics.track(AnalyticsEvent.HUNT_STARTED, mapOf("from" to if (compact) "squad" else "today", "step" to "open"))
            }
            .padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(42.dp).clip(RoundedCornerShape(13.dp)).background(T.gradient), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Add, null, tint = T.accentInk, modifier = Modifier.size(24.dp))
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Txt(if (compact) "New scout" else "Send a new scout", size = T.body, weight = FontWeight.SemiBold)
                if (!compact) Txt("Tell a scout what you're into. It keeps hunting for weeks and texts you what it finds.",
                    size = T.caption, color = T.ink.copy(alpha = 0.75f))
            }
            Icon(Icons.Filled.ChevronRight, null, tint = T.cyan)
        }
    }
}

@Composable
private fun ScoutConfirmation(a: Agent, intro: String) {
    val store = AppStore
    val shape = RoundedCornerShape(18.dp)
    Column(Modifier.fillMaxWidth().clip(shape)
        .background(Brush.linearGradient(listOf(T.green.copy(alpha = 0.14f), T.blue.copy(alpha = 0.12f))))
        .border(1.dp, T.green.copy(alpha = 0.35f), shape).padding(14.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.Top) {
            AgentAvatar(a, 42.dp)
            Spacer(Modifier.width(11.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Txt("${a.name} is on it", size = T.body, weight = FontWeight.SemiBold, maxLines = 1, modifier = Modifier.weight(1f, fill = false))
                    Spacer(Modifier.width(6.dp))
                    FocusTag(a.isSpecific)
                }
                Txt(intro, size = T.footnote, color = T.ink.copy(alpha = 0.8f))
                Txt("Tell it more", size = T.footnote, weight = FontWeight.SemiBold, color = T.cyan,
                    modifier = Modifier.clickable { Router.open(Sheet.Chat(a.id)) })
            }
            Icon(Icons.Filled.Close, "Dismiss", tint = T.muted, modifier = Modifier.size(16.dp).clickable { Router.scoutSent = null })
        }
        if (!a.isSpecific && ScoutLanesData.lanes(a).isNotEmpty()) {
            ScoutLanes(a)
        } else if (store.isCloud) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Step(Icons.Filled.Check, T.green, "READY", "Your scout knows what to look for", Modifier.weight(1f))
                Step(Icons.Filled.Circle, T.warn, "HUNTING", "First finds in a few minutes", Modifier.weight(1f))
                Step(Icons.AutoMirrored.Filled.ArrowForward, T.cyan, "ONGOING", "Keeps hunting every few hours", Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun Step(icon: ImageVector, tint: Color, title: String, text: String, modifier: Modifier) {
    Column(modifier.clip(RoundedCornerShape(11.dp)).background(Color.Black.copy(alpha = 0.2f)).padding(8.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, tint = tint, modifier = Modifier.size(10.dp))
            Spacer(Modifier.width(4.dp))
            Txt(title, size = 10.sp, weight = FontWeight.Black, color = tint, maxLines = 1)
        }
        Txt(text, size = T.caption2, color = T.ink.copy(alpha = 0.8f))
    }
}

/** The short sheet behind "Send a new scout". Starts from what you're into (the scout hunts that whole world for weeks);
 *  "Hunting one specific thing?" switches to a tight hunt for one item. */
@Composable
fun NewScoutSheet() {
    val store = AppStore
    store.observe()
    val focus = LocalFocusManager.current
    var text by remember { mutableStateOf("") }
    var specific by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    val starters = remember { NewScoutData.interests.shuffled().take(12) }
    val ready = text.trim().length >= 2
    LaunchedEffect(Unit) { store.syncProblem = null }

    fun send() {
        val t = text.trim()
        if (t.length < 2 || working) return
        focus.clearFocus()
        working = true
        store.scope.launch {
            val r = store.hunt(t, specific)
            working = false
            if (r == null) return@launch   // the reason shows under the button
            Router.scoutSent = ScoutSent(r.agentID, r.intro)
            Router.tab = AppTab.LIVE
            Router.sheets.remove(Sheet.NewScout)
            if (r.needsSize) {   // its first question will be your size
                delay(450)
                Router.open(Sheet.Chat(r.agentID))
            }
        }
    }

    SheetFrame(if (specific) "Specific hunt" else "New scout", leading = if (specific) "Back" else null,
        onLeading = { specific = false; text = "" }, trailing = "Close") {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Txt(if (specific) "What are you hunting?" else "What are you into?", size = 24.sp, weight = FontWeight.Black)
            Txt(if (specific) "One specific thing: a grail, a size, a price. Your scout tracks just that, across stores, resale and boutiques."
                else "Describe your taste, not one item. Your scout keeps hunting for weeks and brings you things you didn't know to look for.",
                color = T.muted)
            Field(text, { v -> if (v.contains("\n")) { text = v.replace("\n", " ").trim(); send() } else text = v },
                if (specific) "e.g. black Dior men's sunglasses, under \$500" else "Describe your taste: brands, sizes, budget, what you don't like…",
                Modifier.fillMaxWidth(), singleLine = false, minLines = 3, maxLines = 5, enabled = !working,
                keyboard = KeyboardOptions(imeAction = ImeAction.Send), actions = KeyboardActions(onSend = { send() }))
            DetailsMatterCard(compact = true)
            if (specific) {
                Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                    Kick("For example", modifier = Modifier.padding(top = 2.dp))
                    NewScoutData.examples.forEach { (icon, ex) ->
                        Row(Modifier.fillMaxWidth().glass(RoundedCornerShape(12.dp)).clickable { text = ex }
                            .padding(horizontal = 12.dp, vertical = 11.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(icon, null, tint = T.cyan, modifier = Modifier.size(20.dp))
                            Spacer(Modifier.width(10.dp))
                            Txt(ex)
                        }
                    }
                }
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Kick("Or start from one of these", modifier = Modifier.padding(top = 2.dp))
                    Flow(8.dp) {
                        starters.forEach { s ->
                            val on = text.trim().equals(s, ignoreCase = true)
                            Box(Modifier.clip(CircleShape).background(if (on) T.cyan.copy(alpha = 0.16f) else T.glass)
                                .border(1.dp, if (on) T.cyan.copy(alpha = 0.6f) else T.line, CircleShape)
                                .clickable { text = if (on) "" else s }.padding(horizontal = 11.dp, vertical = 8.dp)) {
                                Txt(s, size = T.footnote, weight = if (on) FontWeight.Bold else FontWeight.Normal, maxLines = 1)
                            }
                        }
                    }
                }
            }
            PrimaryButton(if (working) "Sending…" else "Send scout", Modifier.fillMaxWidth(), enabled = ready && !working, busy = working) { send() }
            val p = store.syncProblem
            if (p != null && p.isNotEmpty() && !working) Txt(p, size = T.footnote, color = T.hot)
            ChangeAnyTimeNote()
            if (!specific) {
                val stroke = T.line
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Color.Black.copy(alpha = 0.25f))
                    .drawBehind {
                        drawRoundRect(stroke, style = Stroke(width = 1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx()))),
                            cornerRadius = androidx.compose.ui.geometry.CornerRadius(14.dp.toPx()))
                    }
                    .clickable { specific = true; text = "" }.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.GpsFixed, null, tint = T.hot, modifier = Modifier.size(22.dp))
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                        Txt("Hunting one specific thing?", weight = FontWeight.SemiBold)
                        Txt("A grail, a size, a price. Your scout tracks just that.", size = T.caption, color = T.muted)
                    }
                    Icon(Icons.Filled.ChevronRight, null, tint = T.cyan)
                }
            }
        }
    }
}

object NewScoutData {
    /** Interests to start from, well beyond fashion. A fresh mix each time the sheet opens. */
    val interests = listOf(
        "Retro Jordans", "Vintage workwear", "Indie perfume houses", "Fly fishing gear", "Road bike gear", "Mid-century lamps",
        "Tool watches", "Vinyl records", "Camping gear", "Golf clubs", "Mechanical keyboards", "Film cameras",
        "Trading cards", "Japanese kitchen knives", "Trail running shoes", "Quiet luxury basics", "Bass fishing lures", "Mountain bike parts",
        "Streetwear drops", "Coffee gear", "Home gym equipment", "Vintage denim", "Board games", "Ski and snowboard gear",
    )

    val examples: List<Pair<ImageVector, String>> = listOf(
        Icons.Filled.Visibility to "Black Dior men's sunglasses",
        Icons.Filled.Watch to "A vintage Rolex Explorer, any year",
        Icons.Filled.DirectionsRun to "Jordan 1 Lows in my size, under \$200",
        Icons.Filled.PedalBike to "A used Specialized Tarmac, 56cm",
    )
}

/** Brand names saved in lowercase ("seiko", "audio-technica") shown as names ("Seiko", "Audio-Technica"); mixed case is kept. */
val String.brandCased: String
    get() = if (this == lowercase()) split(" ").joinToString(" ") { w -> w.split("-").joinToString("-") { it.capitalizedFirst() } } else this

object ScoutLanesData {
    /** What an interest scout will hunt, in up to four short boxes: makers, styles, what it's after, what it skips. */
    fun lanes(a: Agent): List<Pair<String, String>> {
        val fragrance = a.mission.category == Category.FRAGRANCE
        val skips = a.learned.filter { it.value < 0 }.entries.sortedBy { it.value }.map { it.key }
        return listOf(
            (if (fragrance) "HOUSES" else "BRANDS") to (a.style.makers + a.style.creators).take(4).joinToString(", ") { it.brandCased },
            (if (fragrance) "NOTES" else "STYLE") to a.style.traits.take(4).joinToString(", "),
            "LOOKING FOR" to a.keywords.take(4).joinToString(", "),
            "SKIPS" to skips.take(4).joinToString(", "),
        ).filter { it.second.isNotEmpty() }
    }
}

/** What an interest scout will hunt, in four short boxes. Tap one to tell the scout what to change. */
@Composable
fun ScoutLanes(agent: Agent) {
    val store = AppStore
    val lanes = ScoutLanesData.lanes(agent)
    if (lanes.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Grid(lanes.size) { i ->
            val (title, value) = lanes[i]
            Column(Modifier.fillMaxWidth().heightIn(min = 44.dp).clip(RoundedCornerShape(11.dp)).background(Color.Black.copy(alpha = 0.22f))
                .clickable { if (store.isCloud) Router.open(Sheet.Chat(agent.id)) }.padding(8.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Txt(title, size = 10.sp, weight = FontWeight.Black, tracking = 0.6.sp, color = T.cyan, maxLines = 1)
                Txt(value.capitalizedFirst(), size = T.caption, color = T.ink.copy(alpha = 0.85f), maxLines = 2)
            }
        }
        Txt("Tap a box to tell your scout what to change. Liking and passing finds sharpens it too.", size = T.caption2, color = T.muted)
    }
}

/** A small label: what you're into, or one specific hunt. */
@Composable
fun FocusTag(specific: Boolean) {
    val tint = if (specific) T.warn else T.green
    Box(Modifier.clip(RoundedCornerShape(5.dp)).background(tint.copy(alpha = 0.16f)).padding(horizontal = 6.dp, vertical = 3.dp)) {
        Txt(if (specific) "SPECIFIC" else "INTEREST", size = 9.sp, weight = FontWeight.Black, tracking = 0.6.sp, color = tint, maxLines = 1)
    }
}

/** A specific hunt that's done (you bought it): keep the scout going on what you're into, or retire it. */
@Composable
fun HuntDoneCard() {
    val store = AppStore
    val s = store.observe()
    val prefs = remember { store.context.getSharedPreferences("baget.ui", 0) }
    var dismissedRaw by remember { mutableStateOf(prefs.getString("huntsDone", "") ?: "") }
    var working by remember { mutableStateOf<String?>(null) }
    var confirmRetire by remember { mutableStateOf<Agent?>(null) }
    val dismissed = dismissedRaw.split(",").filter { it.isNotEmpty() }.toSet()
    val done = s.agents.mapNotNull { a ->
        if (!a.isSpecific || a.id in dismissed) return@mapNotNull null
        val p = s.purchases.filter { it.agentID == a.id }.maxByOrNull { it.date } ?: return@mapNotNull null
        a to p
    }

    fun dismiss(id: String) {
        val xs = dismissedRaw.split(",").filter { it.isNotEmpty() }.toMutableList()
        if (id !in xs) xs.add(id)
        dismissedRaw = xs.takeLast(30).joinToString(",")
        prefs.edit().putString("huntsDone", dismissedRaw).apply()
    }

    done.forEach { (a, p) ->
        key(a.id) {
            val shape = RoundedCornerShape(18.dp)
            Column(Modifier.fillMaxWidth().clip(shape)
                .background(Brush.linearGradient(listOf(T.warn.copy(alpha = 0.14f), T.blue.copy(alpha = 0.10f))))
                .border(1.dp, T.warn.copy(alpha = 0.4f), shape).padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.GpsFixed, null, tint = T.warn, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Txt("${a.name} found your grail", size = T.body, weight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                    Icon(Icons.Filled.Close, "Dismiss", tint = T.muted, modifier = Modifier.size(16.dp).clickable { dismiss(a.id) })
                }
                Txt("You bought ${p.title}. Want this scout to keep going on what you're into instead?", size = T.footnote, color = T.ink.copy(alpha = 0.8f))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PrimaryButton("Keep hunting this kind of thing", Modifier.weight(1f), enabled = working == null, busy = working == a.id) {
                        working = a.id
                        store.scope.launch {
                            val name = store.broaden(a.id)
                            working = null
                            if (name != null) {
                                dismiss(a.id)
                                Router.say("$name is hunting the wider world of it now")
                            }
                        }
                    }
                    GhostButton("Retire scout", Modifier.weight(1f), enabled = working == null) { confirmRetire = a }
                }
            }
        }
    }
    confirmRetire?.let { a ->
        AlertDialog(onDismissRequest = { confirmRetire = null }, containerColor = T.panel,
            title = { Txt("Retire ${a.name}?", size = T.body, weight = FontWeight.Bold) },
            text = { Txt("It stops hunting. Your finds and what it learned about your taste stay.", color = T.muted) },
            confirmButton = { TextButton(onClick = {
                confirmRetire = null
                store.retire(a.id)
                Router.say("${a.name} retired")
            }) { Txt("Retire", color = T.hot, weight = FontWeight.Bold) } },
            dismissButton = { TextButton(onClick = { confirmRetire = null }) { Txt("Cancel", color = T.muted) } })
    }
}

/** "See all" from Today's For You: the full ranked grid, with category filters. */
@Composable
fun ForYouFullSheet() {
    SheetFrame("For You") {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 24.dp)) {
            ForYouSection(ForYouMode.FULL)
        }
    }
}

/** "Ask about this" when the scout that found it is gone and there's no other scout to ask. */
@Composable
fun NoScoutSheet() {
    SheetFrame("Ask about this", trailing = "Close") {
        Column(Modifier.fillMaxSize().padding(28.dp), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically)) {
            Icon(Icons.Filled.PersonSearch, null, tint = T.muted, modifier = Modifier.size(40.dp))
            Txt("Set up a scout to ask about this", size = T.body, weight = FontWeight.SemiBold)
            Txt("The scout that found it is gone. Add a scout and you can ask it anything about your finds.", color = T.muted,
                align = androidx.compose.ui.text.style.TextAlign.Center)
            PrimaryButton("Set up a scout") { Router.close(); Router.deployPrefill = null; Router.open(Sheet.Deploy) }
        }
    }
}

/** Setup and new scouts: why details matter, with a vague vs. specific example and what to mention. */
@Composable
fun DetailsMatterCard(compact: Boolean = false) {
    val shape = RoundedCornerShape(16.dp)
    Column(Modifier.fillMaxWidth().clip(shape)
        .background(Brush.linearGradient(listOf(T.blue.copy(alpha = 0.20f), T.green.copy(alpha = 0.12f))))
        .border(1.dp, T.cyan.copy(alpha = 0.4f), shape).padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.AutoAwesome, null, tint = T.ink, modifier = Modifier.size(15.dp))
            Spacer(Modifier.width(6.dp))
            Txt("The more you tell your scouts, the better they hunt", weight = FontWeight.Bold)
        }
        Txt("Scouts only know what you share. A few details turn generic results into things you'd actually buy.",
            size = T.caption, color = T.ink.copy(alpha = 0.8f))
        if (!compact) Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            DetailsExample("TOO VAGUE", T.hot, "“Fragrance”", Modifier.weight(1f))
            DetailsExample("SPOT ON", T.green, "“Fresh citrus scents like Le Labo, under \$200, nothing sweet”", Modifier.weight(1f))
        }
        Flow {
            listOf("Brands you love", "Brands to skip", "Sizes", "Budget", "Colors & styles", "What it's for").forEach { t ->
                Box(Modifier.clip(CircleShape).background(Color.Black.copy(alpha = 0.25f)).padding(horizontal = 8.dp, vertical = 4.dp)) {
                    Txt(t, size = T.caption2, color = T.ink.copy(alpha = 0.9f))
                }
            }
        }
    }
}

@Composable
private fun DetailsExample(title: String, tint: Color, text: String, modifier: Modifier) {
    Column(modifier.clip(RoundedCornerShape(10.dp)).background(Color.Black.copy(alpha = 0.25f)).padding(8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Txt(title, size = 9.5.sp, weight = FontWeight.Black, tracking = 0.7.sp, color = tint)
        Txt(text, size = T.caption, color = T.ink.copy(alpha = 0.9f))
    }
}

/** "Nothing's locked in": scouts can be changed any time. */
@Composable
fun ChangeAnyTimeNote() {
    Row(Modifier.fillMaxWidth().glass(RoundedCornerShape(12.dp)).padding(10.dp)) {
        Icon(Icons.Filled.Edit, null, tint = T.cyan, modifier = Modifier.size(13.dp).padding(top = 2.dp))
        Spacer(Modifier.width(8.dp))
        Txt("Nothing's locked in. Change what any scout hunts any time: Scouts, then ••• on the scout, or just text it.",
            size = T.caption, color = T.ink.copy(alpha = 0.8f))
    }
}

package app.baget.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.baget.engine.*
import app.baget.model.*
import app.baget.ui.*

/** The stories feed (section bar, lead story, rows, trending), embedded in Today. */
@Composable
fun LiveFeed() {
    val store = AppStore
    val s = store.observe()
    var selected by remember { mutableStateOf("foryou") }
    var shown by remember { mutableIntStateOf(10) }
    val tabs = s.liveTabs
    val tab = tabs.firstOrNull { it.id == selected } ?: tabs.firstOrNull()
    val list = tab?.let { store.stories(it) } ?: emptyList()
    val forYouCount = store.stories().count { it.forYou }

    Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Row(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            tabs.forEach { t ->
                Pill(if (t.kind == LiveTabKind.ForYou && forYouCount > 0) "For you · $forYouCount" else t.label, selected = t.id == tab?.id) {
                    selected = t.id; shown = 10
                    Analytics.track(AnalyticsEvent.LIVE_SECTION_VIEWED, mapOf("section" to t.label))
                }
            }
            Row(Modifier.clip(CircleShape).border(1.dp, T.accent.copy(alpha = 0.5f), CircleShape).clickable { Router.open(Sheet.CustomizeBar) }
                .padding(horizontal = 14.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Tune, null, tint = T.accent, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Txt("Customize", weight = FontWeight.SemiBold, color = T.accent)
            }
        }
        s.awayReport?.let { AwayCard(it) }
        when {
            tab == null -> Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                EmptyCard("Your bar is empty.")
                PrimaryButton("Add sections", Modifier.fillMaxWidth()) { Router.open(Sheet.CustomizeBar) }
            }
            list.isEmpty() -> when (val k = tab.kind) {
                is LiveTabKind.Custom -> Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    EmptyCard("Nothing in today's stories matches “${k.query}” yet.")
                    PrimaryButton("Deploy an agent to hunt ${tab.label}", Modifier.fillMaxWidth()) {
                        Router.deployPrefill = Mission.Custom(k.query); Router.open(Sheet.Deploy)
                    }
                }
                LiveTabKind.ForYou -> EmptyCard("Your squad hasn't picked anything yet. Brief an agent or rate a few finds and this fills up.")
                else -> EmptyCard("No stories here yet.")
            }
            else -> {
                LeadStory(list.first())
                list.drop(1).take(shown).forEach { st ->
                    StoryRow(st)
                    Hairline()
                }
                if (list.size - 1 > shown) GhostButton("Load more stories", Modifier.fillMaxWidth()) { shown += 10 }
            }
        }
        Trending()
        if (!store.isCloud) Txt("Sample data. Sign in to have your squad search the real web.", size = T.caption, color = T.muted)
    }
}

@Composable
private fun Kicker(story: Story) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        val st = 10.5.sp
        Txt(story.item.category.info.label.uppercase(), size = st, weight = FontWeight.Bold, color = T.cyan, tracking = 0.8.sp, maxLines = 1)
        Txt(story.kind.uppercase(), size = st, weight = FontWeight.Bold, tracking = 0.8.sp, maxLines = 1,
            color = if (story.kind == "Release" || story.kind == "Market") T.hot else T.muted)
        Txt("${if (story.minutesAgo < 60) "${story.minutesAgo} MIN" else "${story.minutesAgo / 60} HR"} AGO", size = st, weight = FontWeight.Bold,
            color = T.muted, tracking = 0.8.sp, maxLines = 1)
        if (story.forYou) Box(Modifier.clip(CircleShape).background(T.gradient).padding(horizontal = 7.dp, vertical = 2.dp)) {
            Txt("FOR YOU · ${story.score}%", size = st, weight = FontWeight.Bold, color = T.accentInk, maxLines = 1)
        }
    }
}

@Composable
private fun StoryActions(story: Story) {
    val store = AppStore
    val s = store.observe()
    val tracked = s.finds.any { it.itemID == story.item.id }
    val agent = store.agent(story.agentID)
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (agent != null && story.match?.notInSize != true) {
            if (tracked) GhostButton("View in Finds", Modifier.weight(1f), tint = T.green) { Router.openInFinds(story) }
            else PrimaryButton("Send to ${agent.name}", Modifier.weight(1f)) {
                store.ensureFind(agent.id, story.item.id)
                store.log("You sent ${story.item.title} to ${agent.name}")
                Analytics.track(AnalyticsEvent.STORY_SENT_TO_AGENT, mapOf("category" to story.item.category.raw))
                Router.say("Sent to ${agent.name}. It's in your Finds.")
            }
        } else if (story.agentID == null) {
            GhostButton("Deploy a ${story.item.category.info.label.lowercase()} agent", Modifier.weight(1f)) {
                Router.deployPrefill = Mission.Cat(story.item.category); Router.open(Sheet.Deploy)
            }
        }
        GhostButton("", Modifier.width(54.dp), icon = Icons.Filled.Share) { Router.open(Sheet.ShareItem(story.item.id, null, false)) }
    }
}

@Composable
private fun LeadStory(story: Story) {
    val store = AppStore
    Column(Modifier.padding(bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.clickable { Router.openInFinds(story) }, verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Plate(story.item, if (story.isLive) "AVAILABLE NOW" else store.whenLabel(story.item), height = 230.dp, lead = true)
            Kicker(story)
            Txt(story.headline, size = 28.sp, weight = FontWeight.Black, tracking = (-0.8).sp)
            Txt(story.dek, size = T.body, color = T.muted)
        }
        val why = story.match?.why?.firstOrNull()
        if (story.forYou && why != null) Row {
            Txt("Why it's here: ", size = T.footnote, color = T.muted)
            Txt(why, size = T.footnote, weight = FontWeight.Bold)
        }
        StoryActions(story)
    }
}

@Composable
private fun StoryRow(story: Story) {
    val store = AppStore
    Row(Modifier.padding(vertical = 4.dp)) {
        Box(Modifier.width(104.dp).clickable { Router.openInFinds(story) }) {
            Plate(story.item, if (story.isLive) "NOW" else store.whenLabel(story.item), height = 104.dp, live = story.isLive)
        }
        Spacer(Modifier.width(14.dp))
        Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
            Column(Modifier.clickable { Router.openInFinds(story) }, verticalArrangement = Arrangement.spacedBy(7.dp)) {
                Kicker(story)
                Txt(story.headline, size = T.body, weight = FontWeight.SemiBold)
                Txt(story.dek, size = T.footnote, color = T.muted, maxLines = 3)
                val why = story.match?.why?.firstOrNull()
                if (story.forYou && why != null) Txt(why, size = T.caption, weight = FontWeight.SemiBold, color = T.green, maxLines = 2)
            }
            StoryActions(story)
        }
    }
}

@Composable
private fun Trending() {
    val store = AppStore
    store.observe()
    val trending = Catalog.all.filter { !store.isSoldOut(it) && it.priceKnown && it.price > 0 && it.market > it.price }
        .sortedByDescending { it.market / it.price }.take(5)
    Column(Modifier.fillMaxWidth().glassCard(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Kick("Trending by market heat")
        trending.forEachIndexed { i, item ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                GradientText("${i + 1}", 24.sp, modifier = Modifier.width(24.dp))
                Spacer(Modifier.width(12.dp))
                Column {
                    Txt(item.title, weight = FontWeight.SemiBold)
                    Txt("+${safeRound((item.market / item.price - 1) * 100)}% vs asking · ${item.category.info.label}", size = T.caption, color = T.muted, mono = true)
                }
            }
        }
    }
}

@Composable
private fun AwayCard(r: AwayReport) {
    val store = AppStore
    Column(Modifier.fillMaxWidth().glassCard(highlighted = true), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        GradientText("WHILE YOU WERE AWAY · ${if (r.minutes >= 90) "${safeRound(r.minutes / 60.0)} HOURS" else "${r.minutes} MINUTES"}", T.caption, FontWeight.Bold)
        Txt(if (r.sweeps > 0)
            "Your squad ran ${r.sweeps} sweep${if (r.sweeps == 1) "" else "s"}, checked about ${r.checked} listings and found ${r.found} new thing${if (r.found == 1) "" else "s"} for you." +
                (if (r.restocks > 0) " One of your watched items restocked." else "") + (if (r.bought > 0) " Auto-buy landed ${r.bought}." else "")
        else "Your squad kept searching the web and found ${r.found} new thing${if (r.found == 1) "" else "s"} for you." +
            (if (r.restocks > 0) " Something you're watching restocked." else ""))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            PrimaryButton("${r.notes} notification${if (r.notes == 1) "" else "s"}", Modifier.weight(1f)) { Router.open(Sheet.Inbox) }
            GhostButton("Dismiss", Modifier.weight(1f)) { store.state.awayReport = null; store.save() }
        }
    }
}

/** Reorder, remove and add sections of the Live bar. */
@Composable
fun CustomizeBarSheet() {
    val store = AppStore
    val s = store.observe()
    var newSection by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    val hidden = LiveTab.presets.filter { p -> s.liveTabs.none { it.id == p.id } }

    fun describe(t: LiveTab) = when (val k = t.kind) {
        LiveTabKind.ForYou -> "Ranked by what your squad knows you like"
        LiveTabKind.Latest -> "Everything, newest first"
        is LiveTabKind.Cat -> "Category"
        is LiveTabKind.Custom -> "Your section · matches “${k.query}”"
    }

    fun add() {
        val q = newSection.trim()
        if (TextMatch.words(q).isEmpty()) { error = "Type what this section should show, like “vinyl” or “Porsche”."; return }
        if (s.liveTabs.any { TextMatch.norm(it.label) == TextMatch.norm(q) }) { error = "You already have that section."; return }
        error = null
        val label = q.split(" ").joinToString(" ") { it.capitalizedFirst() }
        s.liveTabs.add(LiveTab("c" + uuid().take(6), LiveTabKind.Custom(q), label))
        store.save()
        Analytics.track(AnalyticsEvent.CUSTOM_SECTION_ADDED, mapOf("words" to TextMatch.words(q).size))
        val n = Catalog.all.count { TextMatch.matches(it, q) }
        Router.say(if (n > 0) "Added $label · $n stor${if (n == 1) "y" else "ies"} today" else "Added $label. Deploy an agent to hunt it.")
        newSection = ""
    }

    SheetFrame("Customize your bar") {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
            FormSection("Your sections, in your order", "Use the arrows to reorder. Tap ✕ to remove. Don't care about shoes or clothes? Remove them.") {
                s.liveTabs.toList().forEachIndexed { i, t ->
                    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Txt(t.label, size = T.body, weight = FontWeight.SemiBold)
                            Txt(describe(t), size = T.caption, color = T.muted, maxLines = 1)
                        }
                        IconButton(onClick = { if (i > 0) { s.liveTabs.add(i - 1, s.liveTabs.removeAt(i)); store.save() } }, enabled = i > 0) {
                            Icon(Icons.Filled.KeyboardArrowUp, "Move up", tint = if (i > 0) T.ink else T.muted)
                        }
                        IconButton(onClick = { if (i < s.liveTabs.lastIndex) { s.liveTabs.add(i + 1, s.liveTabs.removeAt(i)); store.save() } }, enabled = i < s.liveTabs.lastIndex) {
                            Icon(Icons.Filled.KeyboardArrowDown, "Move down", tint = if (i < s.liveTabs.lastIndex) T.ink else T.muted)
                        }
                        IconButton(onClick = { if (s.liveTabs.size > 1) { s.liveTabs.removeAt(i); store.save() } }) {
                            Icon(Icons.Filled.Close, "Remove", tint = T.hot)
                        }
                    }
                }
            }
            FormSection("Add your own section", "It shows every story that matches, with your agents' picks first.") {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Field(newSection, { newSection = it }, "Anything: vinyl, Porsche, Chrome Hearts", Modifier.weight(1f))
                    Spacer(Modifier.width(8.dp))
                    GhostButton("Add") { add() }
                }
                error?.let { Txt(it, size = T.footnote, color = T.hot) }
            }
            if (hidden.isNotEmpty()) FormSection("Add back") {
                hidden.forEach { p -> RowButton(p.label, Icons.Filled.AddCircle) { s.liveTabs.add(p); store.save() } }
            }
            FormSection { RowButton("Restore the default bar") { store.state.liveTabs = LiveTab.presets.toMutableList(); store.save() } }
        }
    }
}

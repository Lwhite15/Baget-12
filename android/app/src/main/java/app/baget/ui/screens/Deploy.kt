package app.baget.ui.screens

import android.graphics.Bitmap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import app.baget.engine.*
import app.baget.model.*
import app.baget.ui.*
import kotlinx.coroutines.launch
import java.io.File

/** Brief a new agent in detail: mission, size, voice, icon and style profile. */
@Composable
fun DeploySheet(prefill: Mission?) {
    val store = AppStore
    store.observe()
    var category by remember { mutableStateOf<Category?>(Category.FRAGRANCE) }
    var customText by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var shoeSystem by remember { mutableStateOf("US M") }
    var shoeSize by remember { mutableStateOf<Double?>(null) }
    var topSize by remember { mutableStateOf("") }
    var pants by remember { mutableStateOf("") }
    var sizeText by remember { mutableStateOf("") }
    var keywords by remember { mutableStateOf("") }
    var traits by remember { mutableStateOf("") }
    var makers by remember { mutableStateOf("") }
    var creators by remember { mutableStateOf("") }
    var voice by remember { mutableStateOf(Voice.CHILL) }
    var mode by remember { mutableStateOf(BuyMode.ASK) }
    var error by remember { mutableStateOf<String?>(null) }
    var icon by remember { mutableStateOf(Avatar()) }
    var iconPhoto by remember { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(Unit) {
        when (prefill) {
            is Mission.Cat -> category = prefill.category
            is Mission.Custom -> { category = null; customText = prefill.text }
            null -> {}
        }
    }
    val info = category?.info ?: customMissionInfo
    val mission: Mission = category?.let { Mission.Cat(it) } ?: Mission.Custom(customText.trim())
    val sizeString = when (category) {
        Category.SNEAKERS -> shoeSize?.let { "$shoeSystem ${Sizes.display(it)}" } ?: ""
        Category.APPAREL -> listOf(topSize, pants.trim()).filter { it.isNotEmpty() }.joinToString(" · ")
        else -> sizeText.trim()
    }
    fun draft() = Agent(uuid(), name.trim(), mission, TextMatch.list(keywords).map { it.lowercase() }.toMutableList(),
        StyleProfile(TextMatch.list(traits).map { it.lowercase() }.toMutableList(), TextMatch.list(makers).toMutableList(), TextMatch.list(creators).toMutableList()),
        sizeString, mode, voice)
    val previewName = name.trim().ifEmpty { "${mission.label.capitalizedFirst()} Hunter".take(40) }
    val shoeOptions: List<Double> = when (shoeSystem) {
        "EU" -> Sizes.euToUSMen.keys.sorted()
        "UK" -> (6..28).map { it / 2.0 }
        "US W" -> (10..33).map { it / 2.0 }
        else -> (8..30).map { it / 2.0 }
    }

    fun deploy() {
        val a = draft()
        if (a.mission is Mission.Custom && (a.mission as Mission.Custom).text.isEmpty()) { error = "Tell the agent what to hunt."; return }
        if (Sizes.required(a) && !Sizes.has(a)) { error = "Pick your ${if (category == Category.SNEAKERS) "shoe size" else "size"}. This agent only hunts things in stock in your size."; return }
        if (a.name.isEmpty()) a.name = previewName
        if (store.squadFull) {
            error = store.scoutLimitMessage
            if (!store.isPro && store.isCloud) Router.open(Sheet.Pro)
            return
        }
        // The icon: a photo is kept on the phone now and uploaded once the agent exists.
        var upload: Pair<String, ByteArray>? = null
        if (icon.style == Avatar.Style.PHOTO) {
            iconPhoto?.let { p -> val stored = store.storeIconPhoto(p); upload = stored; a.icon = icon.copy(photoID = stored.first) }
        } else if (icon != Avatar()) a.icon = icon.copy(photoID = null)
        store.deploy(a)
        if (store.isCloud) {
            store.scope.launch {
                val msg = store.cloudDeploy(a)
                upload?.let { (id, jpeg) -> if (store.agent(a.id) != null) store.uploadIconPhoto(id, jpeg) }
                Router.say(msg)
            }
        }
        Analytics.track(AnalyticsEvent.AGENT_DEPLOYED, mapOf("mission" to (a.mission.category?.raw ?: "custom"), "intel" to Matcher.intel(a),
            "mode" to a.mode.raw, "voice" to a.voice.raw, "hasSize" to a.size.isNotEmpty()))
        Router.deployPrefill = null
        Router.tab = AppTab.SQUAD
        Router.say(if (store.isCloud) "${a.name} deployed. Searching the web now…" else "${a.name} deployed and sweeping")
        Router.close()
    }

    SheetFrame("Brief a new agent", leading = "Cancel", trailing = "Deploy", onTrailing = ::deploy) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
            FormSection("Mission") {
                Box(Modifier.padding(vertical = 6.dp)) {
                    Flow {
                        Category.all.forEach { c -> Pill(c.info.label, category == c) { category = c } }
                        Pill("Something else…", category == null) { category = null }
                    }
                }
                if (category == null) Field(customText, { customText = it }, "What should it hunt? Vinyl, vintage Levi's, Pokémon cards…", Modifier.fillMaxWidth().padding(bottom = 6.dp))
            }
            FormSection("Agent") {
                Field(name, { name = it }, "Name (optional), e.g. Grail Hunter", Modifier.fillMaxWidth().padding(vertical = 6.dp))
                Choice("How it texts you", Voice.entries.map { it.label }, Voice.entries.indexOf(voice)) { voice = Voice.entries[it] }
                Txt(voice.blurb, size = T.caption, color = T.muted)
                Choice("When it finds something", BuyMode.entries.map { it.label }, BuyMode.entries.indexOf(mode)) { mode = BuyMode.entries[it] }
            }
            FormSection("Icon", "Optional. Use a photo, an emoji, or let it pick an emoji that fits. You can change it later by tapping the icon on its card.") {
                Row(Modifier.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    AgentAvatar(null, 56.dp, preview = icon, previewPhoto = iconPhoto, nameOverride = previewName, mission = mission)
                    Spacer(Modifier.width(14.dp))
                    Column {
                        Txt(previewName, size = T.body, weight = FontWeight.SemiBold)
                        Txt("Shows on its card and on every text it sends you.", size = T.caption, color = T.muted)
                    }
                }
                IconPicker(icon, { icon = it }, iconPhoto, { iconPhoto = it })
            }
            when (category) {
                Category.SNEAKERS -> FormSection("Shoe size (required)", "Your agent only flags pairs in stock in this size.") {
                    Segmented(listOf("US M", "US W", "UK", "EU"), shoeSystem) { shoeSystem = it; shoeSize = null }
                    Choice("Size", listOf("Pick a size") + shoeOptions.map { Sizes.display(it) }, shoeSize?.let { shoeOptions.indexOf(it) + 1 } ?: 0) {
                        shoeSize = if (it == 0) null else shoeOptions[it - 1]
                    }
                }
                Category.APPAREL -> FormSection("Clothing size (required)", "Your agent only flags pieces in stock in this size.") {
                    Choice("Top size", listOf("Pick a size") + Sizes.tops, if (topSize.isEmpty()) 0 else Sizes.tops.indexOf(topSize) + 1) {
                        topSize = if (it == 0) "" else Sizes.tops[it - 1]
                    }
                    Field(pants, { pants = it }, "Pants, e.g. 32x32 (optional)", Modifier.fillMaxWidth().padding(vertical = 6.dp))
                }
                else -> info.sizeLabel?.let { label -> FormSection(label) { Field(sizeText, { sizeText = it }, label, Modifier.fillMaxWidth().padding(vertical = 6.dp)) } }
            }
            FormSection("Must-have keywords", "Separate with commas.") {
                Field(keywords, { keywords = it }, "Exact names, models or drops", Modifier.fillMaxWidth().padding(vertical = 6.dp))
            }
            FormSection("${if (category == null) "" else info.label + " "}style profile",
                "Teach it your taste, not just names. It surfaces things that share these traits, even ones you've never heard of.") {
                Labeled(info.traitsLabel, info.traitsPlaceholder, traits) { traits = it }
                Labeled(info.makersLabel, info.makersPlaceholder, makers) { makers = it }
                Labeled(info.creatorsLabel, info.creatorsPlaceholder, creators) { creators = it }
            }
            Column(Modifier.fillMaxWidth().glass().padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                val a = draft()
                when {
                    Sizes.required(a) && !Sizes.has(a) -> Txt("Pick your ${if (category == Category.SNEAKERS) "shoe size" else "size"} first. Your agent only hunts what's in stock in it.",
                        size = T.footnote, color = T.warn)
                    category == null && customText.isBlank() -> Txt("Tell this agent what to hunt. Anything works.", size = T.footnote, color = T.muted)
                    else -> {
                        val k = Matcher.intel(a)
                        val reach = Catalog.all.count { (Matcher.match(a, it)?.score ?: 0) >= 45 }
                        val detail = if (store.isCloud) "it starts searching the web as soon as you deploy it"
                            else if (reach > 0) "would pick up about $reach of today's ${Catalog.all.size} sample listings" else "no sample listings fit yet"
                        Txt("Taste profile $k% complete · $detail", size = T.footnote)
                        Meter(k / 100.0)
                    }
                }
                error?.let { Txt(it, size = T.footnote, color = T.hot) }
            }
            PrimaryButton("Deploy", Modifier.fillMaxWidth()) { deploy() }
        }
    }
}

@Composable
private fun Labeled(label: String, placeholder: String, value: String, onChange: (String) -> Unit) {
    Column(Modifier.padding(vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Txt(label, size = T.caption, color = T.muted)
        Field(value, onChange, placeholder, Modifier.fillMaxWidth())
    }
}

/** A row that shows the current choice and opens a menu of options. */
@Composable
fun Choice(title: String, options: List<String>, selected: Int, onPick: (Int) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Row(Modifier.fillMaxWidth().clickable { open = true }.padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Txt(title, modifier = Modifier.weight(1f))
            Txt(options.getOrNull(selected) ?: "", color = T.muted, maxLines = 1)
            Icon(Icons.Filled.UnfoldMore, null, tint = T.muted, modifier = Modifier.size(16.dp))
        }
        DropdownMenu(open, onDismissRequest = { open = false }, containerColor = T.panel, modifier = Modifier.heightIn(max = 360.dp)) {
            options.forEachIndexed { i, o ->
                DropdownMenuItem(text = { Txt(o, color = if (i == selected) T.accent else T.ink) }, onClick = { open = false; onPick(i) })
            }
        }
    }
}

@Composable
fun Segmented(options: List<String>, selected: String, onPick: (String) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp).glass(RoundedCornerShape(12.dp)).padding(3.dp)) {
        options.forEach { o ->
            Box(Modifier.weight(1f).clip(RoundedCornerShape(10.dp)).background(if (o == selected) T.accent.copy(alpha = 0.22f) else Color.Transparent)
                .clickable { onPick(o) }.padding(vertical = 8.dp), contentAlignment = Alignment.Center) {
                Txt(o, size = T.footnote, weight = FontWeight.SemiBold, color = if (o == selected) T.ink else T.muted, maxLines = 1)
            }
        }
    }
}

/** Style, emoji, color and photo controls for an icon. */
@Composable
fun IconPicker(icon: Avatar, setIcon: (Avatar) -> Unit, photo: Bitmap?, setPhoto: (Bitmap?) -> Unit, hasSavedPhoto: Boolean = false) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var custom by remember { mutableStateOf("") }
    var failed by remember { mutableStateOf(false) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) scope.launch {
            val b = Images.load(context, uri, 1024)
            failed = b == null
            if (b != null) setPhoto(b)
        }
    }
    Segmented(listOf("Auto", "Emoji", "Photo"), when (icon.style) { Avatar.Style.INITIALS -> "Auto"; Avatar.Style.EMOJI -> "Emoji"; Avatar.Style.PHOTO -> "Photo" }) {
        setIcon(icon.copy(style = when (it) { "Emoji" -> Avatar.Style.EMOJI; "Photo" -> Avatar.Style.PHOTO; else -> Avatar.Style.INITIALS }))
    }
    when (icon.style) {
        Avatar.Style.INITIALS -> ColorRow(icon.color) { setIcon(icon.copy(color = it)) }
        Avatar.Style.EMOJI -> {
            EmojiGrid(icon.emoji) { setIcon(icon.copy(emoji = it)) }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Field(custom, { custom = it }, "Or type any emoji", Modifier.weight(1f))
                AvatarPalette.firstEmoji(custom)?.let { e -> TextButton(onClick = { setIcon(icon.copy(emoji = e)); custom = "" }) { Txt("Use", color = T.accent, weight = FontWeight.Bold) } }
            }
            ColorRow(icon.color) { setIcon(icon.copy(color = it)) }
        }
        Avatar.Style.PHOTO -> {
            RowButton(if (photo != null || hasSavedPhoto) "Change photo" else "Choose a photo", Icons.Filled.PhotoLibrary) {
                picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            }
            if (failed) Txt("Couldn't open that photo. Try another.", size = T.footnote, color = T.hot)
            if (photo == null && !hasSavedPhoto) Txt("Pick a photo, or this agent keeps its auto emoji.", size = T.caption, color = T.muted)
        }
    }
}

@Composable
fun EmojiGrid(selected: String?, onPick: (String) -> Unit) {
    Column(Modifier.padding(vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        AvatarPalette.emojis.chunked(8).forEach { row ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                row.forEach { e ->
                    Box(Modifier.size(36.dp).clip(RoundedCornerShape(9.dp)).background(if (selected == e) T.accent.copy(alpha = 0.25f) else Color.Transparent)
                        .clickable { onPick(e) }, contentAlignment = Alignment.Center) { Txt(e, size = 22.sp) }
                }
            }
        }
    }
}

@Composable
fun ColorRow(selected: Int, onPick: (Int) -> Unit) {
    Row(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        AvatarPalette.all.indices.forEach { i ->
            Box(Modifier.size(38.dp).then(if (selected == i) Modifier.border(2.5.dp, T.ink, CircleShape) else Modifier).padding(4.dp)
                .clip(CircleShape).background(AvatarPalette.gradient(i)).clickable { onPick(i) })
        }
    }
}

/** Change an agent's icon after it's deployed. */
@Composable
fun AgentIconSheet(agentID: String) {
    val store = AppStore
    store.observe()
    val agent = store.agent(agentID)
    var icon by remember { mutableStateOf(agent?.icon ?: Avatar()) }
    var photo by remember { mutableStateOf<Bitmap?>(null) }
    SheetFrame("Agent icon", leading = "Cancel", trailing = "Save", onTrailing = {
        // Photo style with no photo at all falls back to auto.
        var chosen = icon
        if (chosen.style == Avatar.Style.PHOTO && photo == null && agent?.icon?.photoID == null) chosen = chosen.copy(style = Avatar.Style.INITIALS)
        store.setAgentIcon(agentID, chosen, if (chosen.style == Avatar.Style.PHOTO) photo else null)
        Router.close()
    }) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { AgentAvatar(agent, 96.dp, preview = icon, previewPhoto = photo) }
            FormSection("${agent?.name ?: "Agent"}'s icon", "Shows on its card and on every text it sends you.") {
                IconPicker(icon, { icon = it }, photo, { photo = it }, hasSavedPhoto = agent?.icon?.photoID != null)
            }
            if (agent?.icon != null) FormSection {
                RowButton("Use the default icon", tint = T.hot) { store.setAgentIcon(agentID, null, null); Router.close() }
            }
        }
    }
}

/** A camera capture target for "Take a photo". */
fun cameraUri(context: android.content.Context): android.net.Uri {
    val dir = File(context.cacheDir, "camera").also { it.mkdirs() }
    val f = File(dir, "shot-${System.currentTimeMillis()}.jpg")
    return FileProvider.getUriForFile(context, context.packageName + ".files", f)
}

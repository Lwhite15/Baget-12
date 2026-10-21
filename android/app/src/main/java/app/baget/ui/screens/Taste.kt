package app.baget.ui.screens

import android.graphics.Bitmap
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.Icon
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.baget.engine.*
import app.baget.model.*
import app.baget.ui.*
import kotlinx.coroutines.launch

/** "What Baget knows about you": everything each agent has been told or has learned, as chips you can remove. */
@Composable
fun TasteSheet() {
    val store = AppStore
    val s = store.observe()
    SheetFrame("What Baget knows") {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Txt("Tap ✕ on anything that isn't you. Agents stop using it on their next search. Like, pass and chat to teach them more.",
                size = T.footnote, color = T.muted)
            if (s.agents.isEmpty()) EmptyCard("No agents yet. Tell Baget what you're hunting on Today.")
            s.agents.toList().forEach { a ->
                val seen = mutableSetOf<String>()
                val likes = (a.style.makers + a.style.creators + a.keywords + a.style.traits +
                    a.learned.filter { it.value >= 2 }.entries.sortedByDescending { it.value }.map { it.key })
                    .filter { seen.add(TextMatch.norm(it)) }.take(24)
                val dislikes = a.learned.filter { it.value < 0 }.entries.sortedBy { it.value }.map { it.key }
                Column(Modifier.fillMaxWidth().glassCard(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        AgentAvatar(a, 36.dp)
                        Spacer(Modifier.width(10.dp))
                        Column(Modifier.weight(1f)) {
                            Txt(a.name, size = T.body, weight = FontWeight.SemiBold)
                            Txt(a.mission.label.capitalizedFirst(), size = T.caption, color = T.muted, maxLines = 1)
                        }
                        Txt("Teach more", size = T.caption, weight = FontWeight.SemiBold, color = T.accent,
                            modifier = Modifier.clickable { Router.open(Sheet.Chat(a.id)) })
                    }
                    if (a.size.isNotEmpty()) Group("Size", listOf(a.size), a.id, T.accent)
                    if (a.priceNote > 0) Group("Price", listOf("Prefers under ${Fmt.money(a.priceNote)}"), a.id, T.warn, listOf("__price"))
                    if (likes.isNotEmpty()) Group("Into", likes, a.id, T.green)
                    if (dislikes.isNotEmpty()) Group("Not into", dislikes, a.id, T.hot)
                    if (likes.isEmpty() && dislikes.isEmpty() && a.size.isEmpty())
                        Txt("Nothing yet. Like or pass a few finds, or tell it what you love.", size = T.caption, color = T.muted)
                }
            }
        }
    }
}

@Composable
private fun Group(title: String, values: List<String>, agentID: String, tint: Color, keys: List<String>? = null) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Txt(title.uppercase(), size = 9.sp, weight = FontWeight.Bold, tracking = 1.sp, color = T.muted)
        Flow {
            values.forEachIndexed { i, v ->
                Row(Modifier.clip(CircleShape).background(tint.copy(alpha = 0.14f)).clickable { AppStore.removeTaste(agentID, keys?.getOrNull(i) ?: v) }
                    .padding(horizontal = 9.dp, vertical = 5.dp), verticalAlignment = Alignment.CenterVertically) {
                    Txt(v, size = T.caption, weight = FontWeight.SemiBold)
                    Spacer(Modifier.width(5.dp))
                    Icon(Icons.Filled.Close, "Remove $v", tint = T.muted, modifier = Modifier.size(10.dp))
                }
            }
        }
    }
}

/** Pick a photo, see what the agent picks up from it, keep what's right, teach the agent. */
@Composable
fun TastePhotoSheet(agentID: String) {
    val store = AppStore
    store.observe()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var image by remember { mutableStateOf<Bitmap?>(null) }
    var reading by remember { mutableStateOf<PhotoReading?>(null) }
    val kept = remember { mutableStateListOf<String>() }
    val extra = remember { mutableStateListOf<String>() }
    var own by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    var shotUri by remember { mutableStateOf<Uri?>(null) }
    val brandTags = (reading?.makers ?: emptyList()) + (reading?.creators ?: emptyList())
    val allTags = (reading?.traits ?: emptyList()) + brandTags + extra

    fun analyze(uri: Uri) = scope.launch {
        loading = true; failed = false; reading = null; kept.clear(); extra.clear()
        val a = store.agent(agentID)
        val b = Images.load(context, uri, 1400)
        if (b == null || a == null) { failed = true; loading = false; return@launch }
        image = b
        // Signed in, Claude reads the photo; otherwise the phone reads its palette.
        val cloud = store.readPhotoCloud(a.id, b)
        val r = if (cloud != null && !(cloud.traits.isEmpty() && cloud.makers.isEmpty())) cloud else {
            val colors = Images.dominantColors(b)
            PhotoReading(if (colors.isEmpty()) "I couldn't make much out of that one. Tell me what you love about it and I'll remember."
                else "Love the palette: ${colors.joinToString(" and ")}. I'll look for ${a.mission.label.lowercase()} in those tones.", colors)
        }
        val traits = r.traits.toMutableList()
        for (c in Images.dominantColors(b)) if (traits.none { it.contains(c) }) traits.add(c)
        reading = r.copy(traits = traits.take(8))
        kept.addAll(reading!!.traits + reading!!.makers + reading!!.creators)
        loading = false
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> if (uri != null) analyze(uri) }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok -> if (ok) shotUri?.let { analyze(it) } }

    fun addOwn() {
        for (t in TextMatch.list(own).map { it.lowercase() }) if (t !in allTags) { extra.add(t); kept.add(t) }
        own = ""
    }

    SheetFrame("Teach with a photo", leading = "Cancel", trailing = if (kept.isEmpty()) "Teach" else "Teach ${kept.size}",
        trailingEnabled = kept.isNotEmpty() && image != null, onTrailing = {
            val img = image; val a = store.agent(agentID)
            if (img != null && a != null) {
                val makers = (reading?.makers ?: emptyList()).filter { it in kept }
                val creators = (reading?.creators ?: emptyList()).filter { it in kept }
                val tags = allTags.filter { it in kept && it !in makers && it !in creators }
                store.addTastePhoto(agentID, img, tags, makers, creators, reading?.summary ?: "")
                Router.say("${a.name} learned from your photo")
                Router.close()
            }
        }) {
        val a = store.agent(agentID) ?: return@SheetFrame
        Column(Modifier.verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            image?.let { BitmapImage(it, Modifier.fillMaxWidth().heightIn(max = 340.dp).clip(RoundedCornerShape(18.dp)), crop = false) }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                val first = image == null
                if (first) PrimaryButton("Take a photo", Modifier.weight(1f), icon = Icons.Filled.PhotoCamera) {
                    shotUri = cameraUri(context); camera.launch(shotUri!!)
                } else GhostButton("Take a photo", Modifier.weight(1f), icon = Icons.Filled.PhotoCamera) { shotUri = cameraUri(context); camera.launch(shotUri!!) }
                GhostButton(if (first) "Choose a photo" else "Choose another", Modifier.weight(1f), icon = Icons.Filled.PhotoLibrary) {
                    picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                }
            }
            if (image == null) Txt("Show ${a.name} something you love, like a fit, a shelf, a car or a room. It reads the style and hunts for more of it. " +
                if (store.isCloud) "The photo is saved privately to your account." else "The photo stays on your phone.", size = T.footnote, color = T.muted)
            if (loading) Row(verticalAlignment = Alignment.CenterVertically) { Spinner(); Spacer(Modifier.width(10.dp)); Txt("Taking a look…", color = T.muted) }
            if (failed) Txt("That image couldn't be opened. Try another one.", size = T.footnote, color = T.hot)
            reading?.let { r ->
                Box(Modifier.fillMaxWidth().glass(RoundedCornerShape(14.dp)).padding(12.dp)) { Txt(r.summary) }
                if (allTags.isNotEmpty()) {
                    Kick("What I picked up · tap to drop")
                    Flow { allTags.forEach { t -> Pill(t, t in kept) { if (t in kept) kept.remove(t) else kept.add(t) } } }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Field(own, { own = it }, if (allTags.isEmpty()) "What do you love about it? e.g. suede, earth tones" else "Anything it missed", Modifier.weight(1f))
                    Spacer(Modifier.width(8.dp))
                    GhostButton("Add", Modifier.width(80.dp)) { addOwn() }
                }
            }
        }
    }
}

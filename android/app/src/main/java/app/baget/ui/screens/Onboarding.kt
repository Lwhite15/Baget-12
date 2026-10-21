package app.baget.ui.screens

import android.Manifest
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.baget.engine.*
import app.baget.model.*
import app.baget.ui.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private val moreInterests = listOf("Tech & gadgets", "Home decor", "Bags", "Jewelry", "Beauty & skincare", "Vinyl & music",
    "Art & prints", "Outdoor gear", "Toys & games", "Books", "Vintage", "Gifts")

/** First run: what you're into, your taste, a quick taste check, optional photos, and your squad is built and hunting. */
@Composable
fun OnboardingScreen(onDone: () -> Unit) {
    val store = AppStore
    val s = store.observe()
    val context = LocalContext.current
    var step by remember { mutableIntStateOf(0) }
    val picked = remember { mutableStateListOf<Category>() }
    val extras = remember { mutableStateListOf<String>() }
    var text by remember { mutableStateOf("") }
    val photos = remember { mutableStateListOf<Bitmap>() }
    var working by remember { mutableStateOf(false) }
    var made by remember { mutableIntStateOf(0) }
    var quiz by remember { mutableStateOf<List<Item>>(emptyList()) }
    var quizIndex by remember { mutableIntStateOf(0) }
    var quizLoading by remember { mutableStateOf(false) }
    val liked = remember { mutableStateListOf<String>() }
    val passed = remember { mutableStateListOf<String>() }
    val vibes = remember { mutableStateMapOf<Category, Set<String>>() }
    var budget by remember { mutableStateOf<Int?>(null) }
    val brands = remember { mutableStateMapOf<Category, Set<String>>() }
    var pushOn by remember { mutableStateOf(Notifier.allowed(context)) }
    var shotUri by remember { mutableStateOf<Uri?>(null) }
    val pickedCount = picked.size + extras.size
    val full = pickedCount >= store.scoutLimit

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(3)) { uris ->
        store.scope.launch { for (u in uris) if (photos.size < 3) Images.load(context, u, 1400)?.let { photos.add(it) } }
    }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok ->
        if (ok) shotUri?.let { u -> store.scope.launch { Images.load(context, u, 1400)?.let { if (photos.size < 3) photos.add(it) } } }
    }
    val askPush = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        store.scope.launch { if (granted) store.registerForPushIfAllowed(); pushOn = Notifier.allowed(context) }
    }

    fun startQuiz() {
        step = 2
        quizLoading = true
        store.scope.launch {
            quiz = store.tasteQuiz(picked.toList())
            quizIndex = 0
            quizLoading = false
            if (quiz.isEmpty()) step = 3     // nothing to rate yet: go straight on
        }
    }

    fun build() {
        working = true
        store.scope.launch {
            val ids = store.onboard(picked.toList(), text.trim(), photos.toList(), liked.toList(), passed.toList(),
                vibes.mapValues { it.value.toList() }, budget?.takeIf { it > 0 }, brands.mapValues { it.value.toList() }, extras.toList())
            working = false
            made = ids.size
            pushOn = Notifier.allowed(context)
            step = 4
            store.loadForYou()
            Billing.loadProducts()
            // Watch for the first finds every few seconds while this screen is up (up to 3 minutes).
            if (store.isCloud) for (i in 0 until 22) {
                delay(8000)
                if (step != 4) break
                store.pull()
                if (store.state.finds.any { it.status == FindStatus.OPEN } && store.state.agents.all { a -> store.state.finds.any { it.agentID == a.id } }) break
            }
        }
    }

    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding().padding(24.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            repeat(5) { i -> Box(Modifier.weight(1f).height(4.dp).clip(CircleShape).background(if (i <= step) T.gradient else androidx.compose.ui.graphics.SolidColor(T.glass.copy(alpha = 0.2f)))) }
        }
        when (step) {
            0 -> Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Txt("What are you into?", size = 30.sp, weight = FontWeight.Black)
                Txt(if (store.scoutLimit >= 5) "Pick a few. You'll get a personal scout for each, hunting drops, restocks and deals."
                    else "Pick up to ${store.scoutLimit}. You'll get a personal scout for each, hunting drops, restocks and deals.", color = T.muted)
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Flow {
                        Category.all.forEach { c ->
                            val on = c in picked
                            Box(Modifier.alpha(if (!on && full) 0.4f else 1f)) { Pill(c.info.label, on) { if (on) picked.remove(c) else if (!full) picked.add(c) } }
                        }
                        moreInterests.forEach { i ->
                            val on = i in extras
                            Box(Modifier.alpha(if (!on && full) 0.4f else 1f)) { Pill(i, on) { if (on) extras.remove(i) else if (!full) extras.add(i) } }
                        }
                    }
                    if (full && store.isCloud && !store.isPro) Txt("Free includes 2 scouts. You can go Pro any time for up to 5, hunting around the clock.", size = T.caption, color = T.muted)
                    Txt("Don't see it? Describe anything", weight = FontWeight.SemiBold)
                    Txt("A first-edition book, a vintage Rolex, a gift for your mom. Say it in your own words and your scouts will find it.", size = T.caption, color = T.muted)
                    Field(text, { text = it }, "Describe what you're looking for", Modifier.fillMaxWidth(), singleLine = false, maxLines = 4)
                }
                PrimaryButton("Next", Modifier.fillMaxWidth(), enabled = pickedCount > 0 || text.isNotBlank()) { if (picked.isEmpty()) startQuiz() else step = 1 }
                TextButton(onClick = onDone, modifier = Modifier.fillMaxWidth()) { Txt("Skip setup", size = T.footnote, color = T.muted) }
            }
            1 -> Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Txt("Your taste", size = 30.sp, weight = FontWeight.Black)
                Txt("Tap the brands you love and the vibe you're after. New to a brand? Your scouts will tell you about every one they find.", color = T.muted)
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(18.dp)) {
                    Category.all.filter { it in picked }.forEach { c ->
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(categoryIcon(c.info.symbol), null, tint = T.ink, modifier = Modifier.size(18.dp)); Spacer(Modifier.width(6.dp))
                                Txt(c.info.label, size = T.body, weight = FontWeight.SemiBold)
                            }
                            Txt("Brands you like", size = T.caption, weight = FontWeight.SemiBold, color = T.muted)
                            Flow { Vibes.brands(c).forEach { b -> val on = b in (brands[c] ?: emptySet()); Pill(b, on) { brands[c] = (brands[c] ?: emptySet()).let { if (on) it - b else it + b } } } }
                            Txt(Vibes.question(c), size = T.caption, weight = FontWeight.SemiBold, color = T.muted)
                            Flow { Vibes.options(c).forEach { v -> val on = v in (vibes[c] ?: emptySet()); Pill(v, on) { vibes[c] = (vibes[c] ?: emptySet()).let { if (on) it - v else it + v } } } }
                        }
                    }
                    if (picked.any { it != Category.CARS }) Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Txt("How much do you usually spend on one thing?", size = T.body, weight = FontWeight.SemiBold)
                        Flow { Vibes.budgets.forEach { (label, cap) -> Pill(label, budget == cap) { budget = if (budget == cap) null else cap } } }
                    }
                }
                val empty = vibes.values.all { it.isEmpty() } && brands.values.all { it.isEmpty() } && budget == null
                PrimaryButton(if (empty) "Skip" else "Next", Modifier.fillMaxWidth()) { startQuiz() }
                TextButton(onClick = { step = 0 }, modifier = Modifier.fillMaxWidth()) { Txt("Back", size = T.footnote, color = T.muted) }
            }
            2 -> Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Txt("Quick taste check", size = 30.sp, weight = FontWeight.Black)
                Txt("Heart what you'd wear or buy, ✕ what you wouldn't. Your scouts start from your answers.", color = T.muted)
                if (quizLoading) Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) { Spinner() }
                else if (quizIndex < quiz.size) {
                    val item = quiz[quizIndex]
                    fun answer(like: Boolean) {
                        store.rateInQuiz(item, like)
                        val name = listOf(item.brand, if (item.title.startsWith(item.brand)) item.title.drop(item.brand.length).trim() else item.title)
                            .filter { it.isNotEmpty() }.joinToString(" ")
                        if (like) liked.add(name) else passed.add(name)
                        quizIndex++
                        if (quizIndex >= quiz.size) step = 3
                    }
                    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        key(item.id) { Plate(item, item.brand.ifEmpty { item.category.info.label }, height = 300.dp, lead = true) }
                        Txt(item.title, size = T.body, weight = FontWeight.SemiBold, maxLines = 2)
                        Txt(listOfNotNull(if (item.priceKnown && item.price > 0) Fmt.money(item.price) else null, item.source).joinToString(" · "), size = T.caption, color = T.muted)
                        if (hasAbout(item)) AboutBlock(item, lines = 3)
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                        Box(Modifier.weight(1f).height(60.dp).clip(CircleShape).background(T.glass).border(1.dp, T.hot.copy(alpha = 0.5f), CircleShape)
                            .clickable { answer(false) }, contentAlignment = Alignment.Center) { Icon(Icons.Filled.Close, "Not for me", tint = T.hot, modifier = Modifier.size(28.dp)) }
                        Box(Modifier.weight(1f).height(60.dp).clip(CircleShape).background(T.gradient)
                            .clickable { answer(true) }, contentAlignment = Alignment.Center) { Icon(Icons.Filled.Favorite, "Love it", tint = T.accentInk, modifier = Modifier.size(28.dp)) }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Txt("${quizIndex + 1} of ${quiz.size}", size = T.caption, color = T.muted, mono = true, modifier = Modifier.weight(1f))
                        Txt("Done", size = T.footnote, weight = FontWeight.SemiBold, color = T.accent, modifier = Modifier.clickable { step = 3 })
                    }
                } else {
                    Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                        Txt(if (liked.isEmpty()) "Got it." else "Nice taste. ${liked.size} noted.", size = T.title3, weight = FontWeight.Bold)
                    }
                    PrimaryButton("Next", Modifier.fillMaxWidth()) { step = 3 }
                }
            }
            3 -> Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Txt("Got photos of things you love?", size = 30.sp, weight = FontWeight.Black)
                Tag("Optional", T.muted)
                Txt("Add up to 3 screenshots or photos of pieces you own or want and your scouts read your taste from them. No photos? Skip it.", color = T.muted)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    for (i in 0 until 3) {
                        var menu by remember { mutableStateOf(false) }
                        Box(Modifier.weight(1f).height(110.dp).clip(RoundedCornerShape(16.dp)).background(T.glass)
                            .border(1.dp, if (i == photos.size) T.accent.copy(alpha = 0.5f) else T.line, RoundedCornerShape(16.dp))
                            .clickable { menu = true }, contentAlignment = Alignment.Center) {
                            if (i < photos.size) BitmapImage(photos[i], Modifier.fillMaxSize())
                            else Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                Icon(if (i == photos.size) Icons.Filled.PhotoCamera else Icons.Filled.Add, null, tint = if (i == photos.size) T.accent else T.muted)
                                if (i == photos.size) Txt("Add", size = T.caption2, weight = FontWeight.SemiBold, color = T.accent)
                            }
                            DropdownMenu(menu, onDismissRequest = { menu = false }, containerColor = T.panel) {
                                DropdownMenuItem(text = { Txt("Take a photo") }, onClick = { menu = false; shotUri = cameraUri(context); camera.launch(shotUri!!) })
                                DropdownMenuItem(text = { Txt("Choose from library") }, onClick = { menu = false; picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) })
                                if (i < photos.size) DropdownMenuItem(text = { Txt("Remove", color = T.hot) }, onClick = { menu = false; photos.removeAt(i) })
                            }
                        }
                    }
                }
                Spacer(Modifier.weight(1f))
                if (working) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                    Spinner(); Spacer(Modifier.width(10.dp)); Txt("Building your squad…", color = T.muted)
                } else {
                    PrimaryButton(if (photos.isEmpty()) "Skip and build my squad" else "Build my squad with these", Modifier.fillMaxWidth()) { build() }
                    if (photos.isNotEmpty()) TextButton(onClick = { photos.clear(); build() }, modifier = Modifier.fillMaxWidth()) {
                        Txt("Build without photos", size = T.footnote, weight = FontWeight.SemiBold, color = T.accent)
                    }
                    TextButton(onClick = { step = 0 }, modifier = Modifier.fillMaxWidth()) { Txt("Back", size = T.footnote, color = T.muted) }
                }
            }
            else -> {
                val newest = s.finds.filter { it.status == FindStatus.OPEN }.sortedByDescending { it.foundAt }.take(3)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Txt(if (newest.isEmpty()) "Your squad is hunting" else "First finds are in", size = 30.sp, weight = FontWeight.Black)
                    Txt(if (made > 0) "They're searching stores, release calendars and resale sites for you right now."
                        else "Tell Baget what you're hunting on Today and a scout starts right away.", color = T.muted)
                    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        s.agents.forEach { a ->
                            val n = s.finds.count { it.agentID == a.id }
                            Row(Modifier.fillMaxWidth().glass(RoundedCornerShape(14.dp)).padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
                                AgentAvatar(a, 32.dp); Spacer(Modifier.width(10.dp))
                                Column(Modifier.weight(1f)) {
                                    Txt(a.name, weight = FontWeight.SemiBold)
                                    Row {
                                        Txt(if (n > 0) "Found $n" else "Searching", size = T.caption, color = if (n > 0) T.green else T.cyan)
                                        Txt(" · ${a.mission.label.lowercase()}", size = T.caption, color = T.muted, maxLines = 1)
                                    }
                                }
                                if (n > 0) Icon(Icons.Filled.CheckCircle, null, tint = T.green) else Spinner(16.dp)
                            }
                        }
                        if (made > 0) Column(Modifier.fillMaxWidth().glass(RoundedCornerShape(14.dp)).padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Kick("What happens next")
                            Txt("⏱  First finds land in a few minutes, right in Finds", size = T.footnote)
                            Txt("↻  " + if (store.isPro) "Then they hunt every 6 hours, around the clock" else "Then they hunt every day and keep your finds fresh", size = T.footnote)
                            Txt("♡  Like or pass what they bring, and they learn your taste fast", size = T.footnote)
                        }
                        val trial = Billing.proTrial
                        if (made > 0 && store.isCloud && !store.isPro && trial != null)
                            Row(Modifier.fillMaxWidth().glass(RoundedCornerShape(14.dp), T.accent.copy(alpha = 0.10f), T.accent.copy(alpha = 0.4f))
                                .clickable { Router.open(Sheet.Pro) }.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                                Box(Modifier.size(34.dp).clip(CircleShape).background(T.gradient), contentAlignment = Alignment.Center) {
                                    Icon(Icons.Filled.Bolt, null, tint = T.accentInk, modifier = Modifier.size(18.dp))
                                }
                                Spacer(Modifier.width(12.dp))
                                Column(Modifier.weight(1f)) {
                                    Txt("Try Pro free for ${Billing.spoken(trial)}", weight = FontWeight.Bold)
                                    Txt("Up to 5 scouts, hunting every 6 hours and twice as deep", size = T.caption, color = T.muted)
                                }
                                Icon(Icons.Filled.ChevronRight, null, tint = T.accent)
                            }
                        if (newest.isNotEmpty()) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            newest.forEach { f -> Catalog.item(f.itemID)?.let { ProductThumb(it, 70.dp) } }
                        }
                    }
                    if (store.isCloud && !pushOn) {
                        PrimaryButton("Text me when they find something", Modifier.fillMaxWidth(), icon = Icons.Filled.NotificationsActive) {
                            if (Build.VERSION.SDK_INT >= 33 && Notifier.needsPrompt(context)) askPush.launch(Manifest.permission.POST_NOTIFICATIONS)
                            else store.scope.launch { store.registerForPushIfAllowed(); pushOn = Notifier.allowed(context) }
                        }
                        Txt("Like a friend texting you a photo of the thing. You choose how often in Settings.", size = T.caption, color = T.muted,
                            align = TextAlign.Center, modifier = Modifier.fillMaxWidth())
                        TextButton(onClick = onDone, modifier = Modifier.fillMaxWidth()) {
                            Txt(if (newest.isEmpty()) "Not now, show me Today" else "Not now, see my finds", size = T.footnote, color = T.muted)
                        }
                    } else {
                        if (pushOn) Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Filled.CheckCircle, null, tint = T.green, modifier = Modifier.size(16.dp)); Spacer(Modifier.width(6.dp))
                            Txt("Texts are on", size = T.footnote, color = T.green)
                        }
                        PrimaryButton(if (newest.isEmpty()) "Show me Today" else "See my finds", Modifier.fillMaxWidth()) {
                            if (newest.isNotEmpty()) Router.tab = AppTab.FINDS
                            onDone()
                        }
                    }
                }
            }
        }
    }
}

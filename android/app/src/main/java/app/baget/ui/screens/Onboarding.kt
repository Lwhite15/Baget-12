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
import androidx.compose.ui.focus.focusRequester
import androidx.compose.foundation.horizontalScroll
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

/**
 * Interests beyond the built-in categories. Each becomes its own scout with a custom mission.
 * Grouped so it's clear Baget hunts far beyond fashion: style, hobbies and gear, home and more.
 */
private class InterestGroup(val title: String, val categories: List<Category>, val extras: List<String>)

private val interestGroups = listOf(
    InterestGroup("STYLE", listOf(Category.SNEAKERS, Category.APPAREL, Category.FRAGRANCE, Category.WATCHES, Category.ACCESSORIES),
        listOf("Bags", "Jewelry", "Beauty & skincare", "Vintage")),
    InterestGroup("HOBBIES & GEAR", listOf(Category.COLLECTIBLES),
        listOf("Fishing", "Bike gear", "Golf", "Camping & outdoor", "Fitness", "Cameras", "Trading cards", "Vinyl & music", "Toys & games")),
    InterestGroup("HOME & MORE", listOf(Category.FURNITURE, Category.CARS),
        listOf("Home decor", "Kitchen & coffee", "Tech & gadgets", "Art & prints", "Books", "Gifts")),
)

/** Setup's own-words box takes up to this many characters. */
private const val OWN_WORDS_MAX = 1200

/** What a scout hunts, in a few words: its brands, then its style ("Orvis, Sage · fly rods, waders"). */
fun scoutHunting(a: Agent): String {
    val makers = a.style.makers.take(3).joinToString(", ") { it.brandCased }
    val style = (if (a.style.traits.isEmpty()) a.keywords else a.style.traits).take(2).joinToString(", ")
    val line = listOf(makers, style).filter { it.isNotEmpty() }.joinToString(" · ")
    return line.ifEmpty { a.mission.label.lowercase() }
}

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
    val sizes = remember { mutableStateMapOf<Category, String>() }
    val womens = remember { mutableStateListOf<Category>() }
    // Who they shop for, from the size step: Women's picked anywhere means women's; a size picked on Men's means men's.
    val department: String? = if (womens.isNotEmpty()) "women" else if (sizes.isEmpty()) null else "men"
    var editingWords by remember { mutableStateOf(false) }
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
            quiz = store.tasteQuiz(picked.toList(), brands.values.flatten(), department)
            quizIndex = 0
            quizLoading = false
            if (quiz.isEmpty()) step = 3     // nothing to rate yet: go straight on
        }
    }

    fun build() {
        working = true
        store.scope.launch {
            val ids = store.onboard(picked.toList(), text.trim(), photos.toList(), liked.toList(), passed.toList(),
                vibes.mapValues { it.value.toList() }, budget?.takeIf { it > 0 }, brands.mapValues { it.value.toList() }, extras.toList(),
                sizes = sizes.mapValues { (c, z) -> Vibes.sizeValue(c, z, c in womens) }, department = department)
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
                Txt(if (store.scoutLimit >= 5) "Pick a few. Each becomes a scout that hunts that whole world for you, for weeks, and learns your taste."
                    else "Pick up to ${store.scoutLimit}. Each becomes a scout that hunts that whole world for you, for weeks, and learns your taste.", color = T.muted)
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    interestGroups.forEach { g ->
                        Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                            Txt(g.title, size = T.caption, weight = FontWeight.Black, color = T.muted, tracking = 1.1.sp)
                            Flow {
                                g.categories.forEach { c ->
                                    val on = c in picked
                                    Box(Modifier.alpha(if (!on && full) 0.4f else 1f)) { Pill(c.info.label, on) { if (on) picked.remove(c) else if (!full) picked.add(c) } }
                                }
                                g.extras.forEach { i ->
                                    val on = i in extras
                                    Box(Modifier.alpha(if (!on && full) 0.4f else 1f)) { Pill(i, on) { if (on) extras.remove(i) else if (!full) extras.add(i) } }
                                }
                            }
                        }
                    }
                    if (full && store.isCloud && !store.isPro) Txt("Free includes 2 scouts. You can go Pro any time for up to 5, hunting around the clock.", size = T.caption, color = T.muted)
                    Column(Modifier.padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        DetailsMatterCard()
                        // Opens a full-height editor, so what you write stays readable while you type.
                        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(T.bg.copy(alpha = 0.6f))
                            .border(1.dp, T.line, RoundedCornerShape(14.dp)).clickable { editingWords = true }.padding(12.dp),
                            horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Txt(text.ifEmpty { "Describe your taste in your own words" }, size = T.body, color = if (text.isEmpty()) T.muted else T.ink,
                                maxLines = 6, modifier = Modifier.weight(1f).heightIn(min = 66.dp))
                            Icon(if (text.isEmpty()) Icons.Filled.EditNote else Icons.Filled.Edit, null, tint = T.accent)
                        }
                        ChangeAnyTimeNote()
                    }
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
                            val women = c in womens
                            Vibes.sizes(c, women)?.let { options ->
                                // Sneaker and clothing scouts only flag what's in stock in your size, so ask here.
                                Row(Modifier.fillMaxWidth().padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                                    Txt(if (c == Category.SNEAKERS) "Your shoe size (US)" else "Your size", size = T.caption, weight = FontWeight.SemiBold,
                                        color = T.muted, modifier = Modifier.weight(1f))
                                    Row(Modifier.glass(CircleShape).padding(2.dp)) {
                                        listOf(false to "Men's", true to "Women's").forEach { (w, label) ->
                                            val sel = women == w
                                            Box(Modifier.clip(CircleShape).background(if (sel) T.ink.copy(alpha = 0.18f) else androidx.compose.ui.graphics.Color.Transparent)
                                                .clickable {
                                                    if (w != women) {
                                                        if (w) womens.add(c) else womens.remove(c)
                                                        sizes.remove(c)   // a men's 10 isn't a women's 10
                                                    }
                                                }.padding(horizontal = 14.dp, vertical = 6.dp)) {
                                                Txt(label, size = T.footnote, weight = if (sel) FontWeight.SemiBold else FontWeight.Normal, color = if (sel) T.ink else T.muted)
                                            }
                                        }
                                    }
                                }
                                Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    options.forEach { z ->
                                        val on = sizes[c] == z
                                        Pill(z, on) { if (on) sizes.remove(c) else sizes[c] = z }
                                    }
                                }
                                if (sizes[c] == null)
                                    Txt(if (c == Category.SNEAKERS) "EU or UK sizing? Put it in your own words on the first screen."
                                        else "Pants or a specific fit? Put it in your own words on the first screen.", size = T.caption2, color = T.muted)
                            }
                            Txt(Vibes.question(c), size = T.caption, weight = FontWeight.SemiBold, color = T.muted, modifier = Modifier.padding(top = 4.dp))
                            Flow { Vibes.options(c).forEach { v -> val on = v in (vibes[c] ?: emptySet()); Pill(v, on) { vibes[c] = (vibes[c] ?: emptySet()).let { if (on) it - v else it + v } } } }
                        }
                    }
                    if (picked.any { it != Category.CARS }) Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Txt("How much do you usually spend on one thing?", size = T.body, weight = FontWeight.SemiBold)
                        Flow { Vibes.budgets.forEach { (label, cap) -> Pill(label, budget == cap) { budget = if (budget == cap) null else cap } } }
                    }
                }
                val empty = vibes.values.all { it.isEmpty() } && brands.values.all { it.isEmpty() } && budget == null && sizes.isEmpty()
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
                        Txt(listOfNotNull(if (item.priceKnown && item.price > 0) item.priceLabel else null, item.source).joinToString(" · "), size = T.caption, color = T.muted)
                        if (hasAbout(item)) AboutBlock(item, lines = 3)
                    }
                    // Heart first, then ✕.
                    Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                        Box(Modifier.weight(1f).height(60.dp).clip(CircleShape).background(T.gradient)
                            .clickable { answer(true) }, contentAlignment = Alignment.Center) { Icon(Icons.Filled.Favorite, "Love it", tint = T.accentInk, modifier = Modifier.size(28.dp)) }
                        Box(Modifier.weight(1f).height(60.dp).clip(CircleShape).background(T.glass).border(1.dp, T.hot.copy(alpha = 0.5f), CircleShape)
                            .clickable { answer(false) }, contentAlignment = Alignment.Center) { Icon(Icons.Filled.Close, "Not for me", tint = T.hot, modifier = Modifier.size(28.dp)) }
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
                    Spinner(); Spacer(Modifier.width(10.dp)); Txt("Building your scouts…", color = T.muted)
                } else {
                    PrimaryButton(if (photos.isEmpty()) "Skip and build my scouts" else "Build my scouts with these", Modifier.fillMaxWidth()) { build() }
                    if (photos.isNotEmpty()) TextButton(onClick = { photos.clear(); build() }, modifier = Modifier.fillMaxWidth()) {
                        Txt("Build without photos", size = T.footnote, weight = FontWeight.SemiBold, color = T.accent)
                    }
                    TextButton(onClick = { step = if (picked.isEmpty()) 0 else 1 }, modifier = Modifier.fillMaxWidth()) { Txt("Back", size = T.footnote, color = T.muted) }
                }
            }
            else -> {
                val newest = s.finds.filter { it.status == FindStatus.OPEN }.sortedByDescending { it.foundAt }.take(3)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Txt(if (newest.isEmpty()) "Your scouts are hunting" else "First finds are in", size = 30.sp, weight = FontWeight.Black)
                    Txt(if (made > 0) "They're searching stores, resale sites and small shops for you right now."
                        else "Tell Baget what you're hunting on Today and a scout starts right away.", color = T.muted)
                    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        s.agents.forEach { a ->
                            val n = s.finds.count { it.agentID == a.id }
                            Row(Modifier.fillMaxWidth().glass(RoundedCornerShape(14.dp)).padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
                                AgentAvatar(a, 32.dp); Spacer(Modifier.width(10.dp))
                                Column(Modifier.weight(1f)) {
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                        Txt(a.name, weight = FontWeight.SemiBold, maxLines = 1, modifier = Modifier.weight(1f, fill = false))
                                        FocusTag(a.isSpecific)
                                    }
                                    Row {
                                        Txt(if (n > 0) "Found $n" else "Searching", size = T.caption, color = if (n > 0) T.green else T.cyan)
                                        Txt(" · ${scoutHunting(a)}", size = T.caption, color = T.muted, maxLines = 1)
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
                            Txt("✎  Change any scout any time: tell it more, add a brand or size, or start over. Scouts, then ••• on any scout", size = T.footnote)
                            Txt("◎  Hunting one specific thing? Send a specific scout from Today any time", size = T.footnote)
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
    if (editingWords) OwnWordsEditor(text, { text = it.take(OWN_WORDS_MAX) }) { editingWords = false }
}

/** Setup's "in your own words" box, full height so a long description stays readable while you type. */
@Composable
private fun OwnWordsEditor(text: String, onChange: (String) -> Unit, onDone: () -> Unit) {
    val focus = remember { androidx.compose.ui.focus.FocusRequester() }
    androidx.compose.ui.window.Dialog(onDismissRequest = onDone,
        properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Box(Modifier.fillMaxSize().background(T.panel)) {
            SheetFrame("In your own words", trailing = "Done", onTrailing = onDone) {
                Column(Modifier.weight(1f).fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Txt("Your taste: styles, brands, colors, materials, sizes, your budget, what you use it for and what you don't like.", color = T.muted)
                    Field(text, onChange, "e.g. Indie citrus perfumes, nothing too sweet. Also into fly fishing gear for trout, mostly Orvis and Simms.",
                        Modifier.fillMaxWidth().weight(1f).focusRequester(focus), singleLine = false, minLines = 6, maxLines = Int.MAX_VALUE)
                    Txt("${text.length}/$OWN_WORDS_MAX", size = T.caption2, color = T.muted, align = TextAlign.End, modifier = Modifier.fillMaxWidth())
                }
            }
        }
    }
    LaunchedEffect(Unit) { delay(150); runCatching { focus.requestFocus() } }
}

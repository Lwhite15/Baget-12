package app.baget.ui.screens

import android.app.Activity
import android.graphics.Bitmap
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.baget.BuildConfig
import app.baget.engine.*
import app.baget.model.*
import app.baget.ui.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.*

private enum class ProfilePage { MAIN, ALERTS, PRIVACY, STATS }

/** Opened from your icon at the top left: your icon, name, handle, settings and account. */
@Composable
fun ProfileSheet() {
    val store = AppStore
    val s = store.observe()
    var page by remember { mutableStateOf(ProfilePage.MAIN) }
    BackHandler(enabled = page != ProfilePage.MAIN) { page = ProfilePage.MAIN }
    LaunchedEffect(Unit) { Analytics.track(AnalyticsEvent.PROFILE_OPENED) }
    when (page) {
        ProfilePage.ALERTS -> SheetFrame("Notifications", leading = "‹ You", onLeading = { page = ProfilePage.MAIN }) { AlertSettings() }
        ProfilePage.PRIVACY -> SheetFrame("Friends and privacy", leading = "‹ You", onLeading = { page = ProfilePage.MAIN }) {
            Column(Modifier.padding(16.dp)) {
                FormSection("What friends can see", s.profile?.handle?.takeIf { store.isCloud }?.let { "Friends add you by your handle, @$it." }) { PrivacySwitches() }
            }
        }
        ProfilePage.STATS -> SheetFrame("Stats", leading = "‹ You", onLeading = { page = ProfilePage.MAIN }) { StatsPage() }
        ProfilePage.MAIN -> SheetFrame("You") {
            Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    AvatarView(96.dp)
                    val n = s.profile?.displayName?.trim().orEmpty()
                    val h = s.profile?.handle.orEmpty()
                    Txt(if (n.isNotEmpty()) n else if (h.isNotEmpty()) "@$h" else "You", size = T.title3, weight = FontWeight.Bold)
                    if (h.isNotEmpty() && store.isCloud) Txt("@$h", color = T.muted) else if (!store.isCloud) Txt("Sample tour", color = T.muted)
                }
                IconSection()
                if (store.isCloud) NameSection()
                AccountSection()
                FormSection("Settings") {
                    RowButton("Send feedback", Icons.Filled.Feedback) { Router.open(Sheet.Feedback) }
                    val context = LocalContext.current
                    RowButton("Contact support", Icons.Filled.Email) { open(context, "mailto:bagetsupport@gmail.com?subject=Baget%20support") }
                    PlanRows()
                    RowButton("What Baget knows about you", Icons.Filled.Psychology) { Router.open(Sheet.Taste) }
                    RowButton("Notifications and background", Icons.Filled.NotificationsActive) { page = ProfilePage.ALERTS }
                    RowButton("Friends and privacy", Icons.Filled.PanTool) { page = ProfilePage.PRIVACY }
                    RowButton("Customize the Live bar", Icons.Filled.Tune) { Router.open(Sheet.CustomizeBar) }
                    if (store.isAdmin) RowButton("Stats", Icons.Filled.BarChart) { page = ProfilePage.STATS }
                }
                Txt("Baget ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}) for Android", size = T.caption, color = T.muted,
                    align = TextAlign.Center, modifier = Modifier.fillMaxWidth())
            }
        }
    }
}

@Composable
private fun IconSection() {
    val store = AppStore
    val s = store.observe()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var editing by remember { mutableStateOf(s.avatar.style) }
    var custom by remember { mutableStateOf("") }
    var failed by remember { mutableStateOf(false) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) scope.launch {
            val b = Images.load(context, uri, 1024)
            failed = b == null
            if (b != null) { store.setAvatarPhoto(b); editing = Avatar.Style.PHOTO }
        }
    }
    FormSection("Your icon", if (editing == Avatar.Style.PHOTO) "Cropped to a circle. It's kept private in your account, so it follows you to a new phone."
        else "Shows at the top left of every screen.") {
        Segmented(listOf("Initials", "Emoji", "Photo"), when (editing) { Avatar.Style.INITIALS -> "Initials"; Avatar.Style.EMOJI -> "Emoji"; else -> "Photo" }) {
            editing = when (it) { "Emoji" -> Avatar.Style.EMOJI; "Photo" -> Avatar.Style.PHOTO; else -> Avatar.Style.INITIALS }
            // Photo only takes effect once there's a photo.
            if (editing != Avatar.Style.PHOTO || s.avatar.photoID != null) {
                store.setAvatarStyle(editing)
                Analytics.track(AnalyticsEvent.AVATAR_CHANGED, mapOf("style" to editing.raw))
            }
        }
        when (editing) {
            Avatar.Style.INITIALS -> ColorRow(s.avatar.color) { store.setAvatarColor(it) }
            Avatar.Style.EMOJI -> {
                EmojiGrid(if (s.avatar.style == Avatar.Style.EMOJI) s.avatar.emoji else null) { store.setAvatarEmoji(it) }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Field(custom, { custom = it }, "Or type any emoji", Modifier.weight(1f))
                    AvatarPalette.firstEmoji(custom)?.let { e -> TextButton(onClick = { store.setAvatarEmoji(e); custom = "" }) { Txt("Use", color = T.accent, weight = FontWeight.Bold) } }
                }
                ColorRow(s.avatar.color) { store.setAvatarColor(it); store.setAvatarStyle(Avatar.Style.EMOJI) }
            }
            Avatar.Style.PHOTO -> {
                RowButton(if (s.avatar.photoID == null) "Choose a photo" else "Change photo", Icons.Filled.PhotoLibrary) {
                    picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                }
                if (failed) Txt("Couldn't open that photo. Try another.", size = T.footnote, color = T.hot)
                if (s.avatar.photoID != null) RowButton("Remove photo", tint = T.hot) { store.removeAvatarPhoto(); editing = Avatar.Style.INITIALS }
            }
        }
    }
}

@Composable
private fun NameSection() {
    val store = AppStore
    val s = store.observe()
    var name by remember { mutableStateOf(s.profile?.displayName ?: "") }
    var error by remember { mutableStateOf<String?>(null) }
    var saved by remember { mutableStateOf(false) }
    val dirty = name != (s.profile?.displayName ?: "")
    FormSection("Name", "What friends see next to your handle.") {
        Row(Modifier.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Field(name, { name = it; saved = false }, "Your name", Modifier.weight(1f))
            if (dirty) TextButton(onClick = {
                store.scope.launch {
                    error = store.updateDisplayName(name)
                    if (error == null) { saved = true; delay(2500); saved = false }
                }
            }) { Txt("Save", color = T.accent, weight = FontWeight.Bold) }
            else if (saved) Txt("✓ Saved", size = T.footnote, weight = FontWeight.SemiBold, color = T.green)
        }
        error?.let { Txt(it, size = T.footnote, color = T.hot) }
    }
}

/** Handle, sign out and account deletion. */
@Composable
private fun AccountSection() {
    val store = AppStore
    val s = store.observe()
    var handle by remember { mutableStateOf(s.profile?.handle ?: "") }
    var handleError by remember { mutableStateOf<String?>(null) }
    var saved by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    if (store.isCloud) {
        FormSection("Account", "Friends add you by your handle. Deleting your account permanently removes your agents, finds, purchases, photos and friends.") {
            Row(Modifier.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Txt("@", color = T.muted); Spacer(Modifier.width(6.dp))
                // Handles are lowercase letters, numbers, dots and underscores: show exactly what will be saved.
                Field(handle, { v -> handle = v.lowercase().filter { (it.isLetter() && it.code < 128) || it.isDigit() || it == '.' || it == '_' }.take(24); saved = false },
                    "handle", Modifier.weight(1f))
                if (handle != s.profile?.handle && handle.isNotEmpty()) TextButton(onClick = {
                    store.scope.launch {
                        handleError = store.updateHandle(handle)
                        if (handleError == null) { handle = store.state.profile?.handle ?: handle; saved = true; delay(2500); saved = false }
                    }
                }) { Txt("Save", color = T.accent, weight = FontWeight.Bold) }
                else if (saved) Txt("✓ Saved", size = T.footnote, weight = FontWeight.SemiBold, color = T.green)
            }
            handleError?.let { Txt(it, size = T.footnote, color = T.hot) }
            RowButton("Sign out") { store.scope.launch { Router.closeAll(); store.signOut() } }
            RowButton(if (deleting) "Deleting…" else "Delete my account", tint = T.hot, enabled = !deleting) { confirmDelete = true }
        }
        if (confirmDelete) AlertDialog(onDismissRequest = { confirmDelete = false }, containerColor = T.panel,
            title = { Txt("Delete your Baget account?", size = T.body, weight = FontWeight.Bold) },
            text = { Txt("This can't be undone.", color = T.muted) },
            confirmButton = { TextButton(onClick = {
                confirmDelete = false; deleting = true
                store.scope.launch {
                    try { store.deleteAccount(); Router.closeAll() } catch (e: Exception) {
                        Router.say((e as? BackendError)?.message ?: "Couldn't delete your account. Try again.")
                    }
                    deleting = false
                }
            }) { Txt("Delete everything", color = T.hot, weight = FontWeight.Bold) } },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Txt("Cancel", color = T.muted) } })
    } else if (Backend.isConfigured) {
        FormSection("Account", "You're looking at sample data. Signing in lets your agents search the real web, sync across your devices and connect with friends.") {
            RowButton("Sign in to start hunting for real") { Router.closeAll(); store.resetToWelcome() }
        }
    }
}

/** Settings: your plan, and for Free, when the daily window runs. */
@Composable
private fun PlanRows() {
    val store = AppStore
    store.observe()
    val context = LocalContext.current
    if (!store.isCloud) return
    RowButton(if (store.isPro) "Baget Pro" else "Go Pro: hunt around the clock", Icons.Filled.Bolt, trailing = if (store.isPro) "Active" else null,
        enabled = !(store.isPro && store.plan?.plan == "comp")) { Router.open(Sheet.Pro) }
    if (store.isPro && store.plan?.plan != "comp") RowButton("Manage subscription", Icons.Filled.CreditCard) {
        open(context, "https://play.google.com/store/account/subscriptions?package=${context.packageName}")
    }
    if (!store.isPro) {
        val start = store.plan?.huntStart ?: store.state.settings.huntStart ?: 9
        Choice("Hunting window", (0 until 24).map { "${PlanInfo.hourLabel(it)} to ${PlanInfo.hourLabel((it + 4) % 24)}" }, start) { store.setHuntStart(it) }
    }
}

// MARK: Baget Pro

@Composable
fun PaywallSheet() {
    val store = AppStore
    store.observe()
    val context = LocalContext.current
    val products = Billing.products
    var selected by remember { mutableStateOf("baget.pro.yearly") }
    var message by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { Billing.loadProducts() }
    LaunchedEffect(store.isPro) { if (store.isPro) { Router.say("You're Pro. Your scouts hunt around the clock now."); Router.close() } }

    data class Option(val id: String, val title: String, val price: String, val note: String?)
    val monthly = products.firstOrNull { it.productId == "baget.pro.monthly" }
    val yearly = products.firstOrNull { it.productId == "baget.pro.yearly" }
    fun priceOf(p: com.android.billingclient.api.ProductDetails) = p.subscriptionOfferDetails?.firstOrNull()?.pricingPhases?.pricingPhaseList?.lastOrNull()
    val options = buildList {
        yearly?.let { y ->
            val yp = priceOf(y); val mp = monthly?.let { priceOf(it) }
            val save = if (yp != null && mp != null && mp.priceAmountMicros > 0) {
                val pct = Math.round((1 - yp.priceAmountMicros.toDouble() / (mp.priceAmountMicros * 12.0)) * 100).toInt()
                if (pct > 0) "Save $pct%" else null
            } else null
            add(Option(y.productId, "Yearly", "${yp?.formattedPrice ?: ""} / year", save))
        }
        monthly?.let { add(Option(it.productId, "Monthly", "${priceOf(it)?.formattedPrice ?: ""} / month", null)) }
    }

    SheetFrame("", leading = "Close", trailing = null) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Row { Txt("Baget ", size = 36.sp, weight = FontWeight.Black); GradientText("Pro", 36.sp) }
            Billing.proTrial?.let { Txt("Try it free for ${Billing.spoken(it)}.", size = T.body, weight = FontWeight.SemiBold, color = T.green) }
            Txt("Your scouts never clock out and dig twice as deep: more searches, more stores and more angles on every hunt.", color = T.muted)
            Column(Modifier.fillMaxWidth().glass()) {
                listOf(Triple("", "Free", "Pro"), Triple("Scouts", "2", "Up to 5"), Triple("Hunting", "4 hours a day", "Around the clock"),
                    Triple("Hunts", "1 a day each", "Every 6 hours"), Triple("Search depth", "Checks product pages", "Twice as deep: 12 searches, more stores"),
                    Triple("Everything else", "Included", "Included")).forEachIndexed { i, (l, f, p) ->
                    Row(Modifier.padding(horizontal = 12.dp, vertical = 9.dp)) {
                        Txt(l, size = T.caption, color = T.muted, modifier = Modifier.weight(1f))
                        Txt(f, size = T.caption, color = if (i == 0) T.muted else T.ink, weight = if (i == 0) FontWeight.Bold else FontWeight.Normal, modifier = Modifier.width(92.dp))
                        Txt(p, size = T.caption, color = T.green, weight = FontWeight.Bold, modifier = Modifier.width(96.dp))
                    }
                }
            }
            if (options.isEmpty()) Row(verticalAlignment = Alignment.CenterVertically) {
                Spinner(16.dp); Spacer(Modifier.width(8.dp)); Txt("Loading plans…", size = T.footnote, color = T.muted)
            } else options.forEach { o ->
                val on = selected == o.id
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(if (on) T.green.copy(alpha = 0.10f) else T.glass)
                    .border(1.dp, if (on) T.green.copy(alpha = 0.6f) else T.line, RoundedCornerShape(16.dp)).clickable { selected = o.id }.padding(14.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Icon(if (on) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked, null, tint = if (on) T.green else T.muted)
                    Spacer(Modifier.width(8.dp))
                    Txt(o.title, size = T.body, weight = FontWeight.SemiBold)
                    o.note?.let { Spacer(Modifier.width(8.dp)); Tag(it, T.green) }
                    Spacer(Modifier.weight(1f))
                    Txt(o.price, weight = FontWeight.SemiBold)
                }
            }
            message?.let { Txt(it, size = T.footnote, color = T.warn) }
            val chosen = products.firstOrNull { it.productId == selected } ?: products.firstOrNull()
            val trial = Billing.trial(chosen)
            PrimaryButton(trial?.let { "Start $it free trial" } ?: "Go Pro", Modifier.fillMaxWidth(), enabled = !store.isPro, busy = store.purchasing) {
                val p = products.firstOrNull { it.productId == selected } ?: products.firstOrNull()
                if (p == null) { message = "Plans aren't available right now. Try again in a minute."; return@PrimaryButton }
                store.scope.launch { message = Billing.buy(context as Activity, p) }
            }
            if (trial != null && chosen != null) {
                val price = chosen.subscriptionOfferDetails?.firstOrNull()?.pricingPhases?.pricingPhaseList?.lastOrNull()?.formattedPrice ?: ""
                Txt("Free for ${Billing.spoken(trial)}, then $price/${if (chosen.productId.endsWith("yearly")) "year" else "month"}. Cancel any time before the trial ends and you won't be charged.",
                    size = T.caption, color = T.muted, align = TextAlign.Center, modifier = Modifier.fillMaxWidth())
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Txt("Restore purchases", size = T.footnote, weight = FontWeight.SemiBold, color = T.accent,
                    modifier = Modifier.clickable { store.scope.launch { message = Billing.restore() } })
                Spacer(Modifier.weight(1f))
                Txt("Terms", size = T.footnote, weight = FontWeight.SemiBold, color = T.accent, modifier = Modifier.clickable { open(context, TERMS_URL) })
                Txt(" · ", size = T.footnote, color = T.muted)
                Txt("Privacy", size = T.footnote, weight = FontWeight.SemiBold, color = T.accent, modifier = Modifier.clickable { open(context, PRIVACY_URL) })
            }
            Txt("Subscriptions renew automatically until canceled. Cancel any time in Google Play → Payments & subscriptions. Payment is charged to your Google account.",
                size = T.caption2, color = T.muted)
        }
    }
}

// MARK: Feedback

@Composable
fun FeedbackSheet() {
    val store = AppStore
    store.observe()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var kind by remember { mutableStateOf("bug") }
    var text by remember { mutableStateOf("") }
    var photo by remember { mutableStateOf<Bitmap?>(null) }
    var sending by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) scope.launch { photo = Images.load(context, uri, 1600) }
    }
    val device = "${Build.MANUFACTURER} ${Build.MODEL}"
    val version = "Baget ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}) Android"
    SheetFrame("Feedback", leading = "Cancel", trailing = null) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Segmented(listOf("🐞 Bug", "💡 Idea", "❤️ Love it"), when (kind) { "bug" -> "🐞 Bug"; "idea" -> "💡 Idea"; else -> "❤️ Love it" }) {
                kind = when (it) { "🐞 Bug" -> "bug"; "💡 Idea" -> "idea"; else -> "love" }
            }
            Field(text, { text = it }, when (kind) { "bug" -> "What happened, and what did you expect?"; "idea" -> "What would make Baget better for you?"; else -> "What do you love about it?" },
                Modifier.fillMaxWidth(), singleLine = false, minLines = 4, maxLines = 10)
            Txt("Sends with $version · $device · Android ${Build.VERSION.RELEASE}", size = T.caption, color = T.muted)
            FormSection("Screenshot") {
                photo?.let { p ->
                    Row(Modifier.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        BitmapImage(p, Modifier.height(140.dp).width(80.dp).clip(RoundedCornerShape(10.dp)), crop = false)
                        Spacer(Modifier.weight(1f))
                        TextButton(onClick = { photo = null }) { Txt("Remove", color = T.hot) }
                    }
                }
                RowButton(if (photo == null) "Add a screenshot" else "Use a different one", Icons.Filled.Image) {
                    picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                }
            }
            error?.let { Txt(it, size = T.footnote, color = T.hot) }
            PrimaryButton("Send", Modifier.fillMaxWidth(), enabled = text.isNotBlank(), busy = sending) {
                val uid = Backend.userID
                if (!store.isCloud || uid == null) { error = "Sign in to send feedback."; return@PrimaryButton }
                sending = true
                store.scope.launch {
                    try {
                        val row = mutableMapOf<String, Any?>("kind" to kind, "body" to text.trim().take(2000), "app_version" to version, "device" to device,
                            "screen" to Router.tab.name.lowercase())
                        photo?.let { p ->
                            val path = "${uid.lowercase()}/${uuid()}.jpg"
                            Backend.upload("feedback", path, Images.jpeg(Images.scaled(p, 1600), 70))
                            row["photo_path"] = path
                        }
                        Backend.insert("feedback", toJson(row))
                        Router.say("Thanks! Sent straight to the Baget team.")
                        Router.close()
                    } catch (e: Exception) {
                        error = (e as? BackendError)?.message ?: "Couldn't send. Try again."
                    }
                    sending = false
                }
            }
        }
    }
}

// MARK: Stats (owner accounts only; the server decides)

@Composable
private fun StatsPage() {
    var stats by remember { mutableStateOf<JsonObject?>(null) }
    var road by remember { mutableStateOf<JsonObject?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        try {
            stats = Backend.rpc("admin_stats").jsonObject
            road = runCatching { Backend.rpc("road_to_100").jsonObject }.getOrNull()
        } catch (e: Exception) { error = "Couldn't load stats. ${(e as? BackendError)?.message ?: ""}" }
    }
    fun JsonObject.o(k: String) = this[k] as? JsonObject
    fun JsonObject.i(k: String) = this[k]?.jsonPrimitive?.intOrNull ?: 0
    fun JsonObject.d(k: String) = this[k]?.jsonPrimitive?.doubleOrNull ?: 0.0
    fun pct(n: Int, d: Int) = if (d == 0) "–" else "${Math.round(n * 100.0 / d)}%"
    fun money(v: Double) = if (v < 10) String.format("$%.2f", v) else String.format("$%.0f", v)

    Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        val s = stats
        when {
            s != null -> {
                road?.let { r ->
                    Section("Road to 100") {
                        Row(verticalAlignment = Alignment.Bottom) {
                            Txt("${r.i("users")}", size = 40.sp, weight = FontWeight.Black)
                            Txt(" / ${r.i("goal")} people", color = T.muted)
                        }
                        LinearProgressIndicator(progress = { (r.i("users").toFloat() / maxOf(1, r.i("goal"))).coerceAtMost(1f) }, color = T.cyan, trackColor = T.glass,
                            modifier = Modifier.fillMaxWidth())
                        Cells(listOf("Still here after 4 weeks" to pct(r.i("week4"), r.i("week4_base")), "Paying for Pro" to pct(r.i("pro"), r.i("paid_base")),
                            "Connected to a friend" to pct(r.i("with_friends"), r.i("users")), "Feedback notes" to "${r.i("feedback")}"))
                    }
                }
                val u = s.o("users"); val a = s.o("active"); val ret = s.o("retention")
                Section("People") {
                    Cells(listOf("Users" to "${u?.i("total")}", "New today" to "${u?.i("today")}", "New this week" to "${u?.i("week")}", "New this month" to "${u?.i("month")}"))
                    Cells(listOf("Active today" to "${a?.i("day")}", "Active this week" to "${a?.i("week")}",
                        "Came back next day" to pct(ret?.i("day1") ?: 0, ret?.i("day1_base") ?: 0), "Still here after a week" to pct(ret?.i("day7") ?: 0, ret?.i("day7_base") ?: 0)))
                }
                val ag = s.o("agents"); val f = s.o("finds"); val sh = s.o("shopping"); val en = s.o("engagement")
                Section("Agents and finds") {
                    Cells(listOf("Agents" to "${ag?.i("total")}", "People with agents" to "${ag?.i("with_agents")}", "Finds" to "${f?.i("total")}",
                        "Like rate" to pct(f?.i("liked") ?: 0, (f?.i("liked") ?: 0) + (f?.i("passed") ?: 0))))
                    Cells(listOf("Buy taps (week)" to "${sh?.i("buy_taps_week")}", "Purchases" to "${sh?.i("purchases")}",
                        "Chats (week)" to "${en?.i("chats_week")}", "Likes and passes (week)" to "${en?.i("swipes_week")}"))
                }
                val c = s.o("claude")
                Section("Claude spend") {
                    Cells(listOf("Today" to money(c?.d("today") ?: 0.0), "This week" to money(c?.d("week") ?: 0.0),
                        "Last 30 days" to money(c?.d("month") ?: 0.0), "Saved by caching" to money(c?.d("cache_saved_week") ?: 0.0)))
                }
            }
            error != null -> Txt(error!!, size = T.footnote, color = T.hot)
            else -> Box(Modifier.fillMaxWidth().padding(top = 60.dp), contentAlignment = Alignment.Center) { Spinner() }
        }
    }
}

@Composable
private fun Section(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().glassCard(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Txt(title, size = T.body, weight = FontWeight.SemiBold)
        content()
    }
}

@Composable
private fun Cells(cells: List<Pair<String, String>>) {
    Grid(cells.size) { i ->
        Column {
            Txt(cells[i].first.uppercase(), size = 9.sp, weight = FontWeight.SemiBold, tracking = 1.sp, color = T.muted, maxLines = 1)
            Txt(cells[i].second, size = T.title2, weight = FontWeight.Black)
        }
    }
}

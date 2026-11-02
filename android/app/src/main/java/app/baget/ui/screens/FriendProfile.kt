package app.baget.ui.screens

import android.content.Context
import android.content.Intent
import androidx.compose.foundation.Canvas
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
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import app.baget.engine.*
import app.baget.model.*
import app.baget.ui.*
import kotlinx.coroutines.launch
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter

private val themOrange = Color(1f, 0.54f, 0.36f)
private val themGradient: Brush get() = Brush.linearGradient(listOf(themOrange, T.hot))

/** A store page inside Baget (Back brings you right back). */
fun storePage(context: Context, url: String) {
    runCatching {
        androidx.browser.customtabs.CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(context, android.net.Uri.parse(url))
    }.onFailure { open(context, url) }
}

private fun firstName(name: String) = name.split(" ").firstOrNull { it.isNotEmpty() } ?: name

/** "Oct 25" from a server date or timestamp. */
private fun shortDate(s: String?): String? {
    if (s.isNullOrBlank()) return null
    val ms = parseDate(s) ?: runCatching { LocalDate.parse(s.take(10)).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli() }.getOrNull() ?: return null
    return DateTimeFormatter.ofPattern("MMM d").format(Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()))
}

// MARK: Friend profile

/** A friend's profile: taste match, taste DNA, what you both love, their world, grails, twin finds and gift radar. */
@Composable
fun FriendProfileSheet(friend: Friend, onClose: () -> Unit) {
    val store = AppStore
    store.observe()
    val context = LocalContext.current
    val first = firstName(friend.name)
    var profile by remember { mutableStateOf<FriendProfile?>(null) }
    var loading by remember { mutableStateOf(true) }
    var confirmRemove by remember { mutableStateOf(false) }
    var showCards by remember { mutableStateOf(false) }
    var hunting by remember { mutableStateOf<String?>(null) }
    var reporting by remember { mutableStateOf<SafetyTarget?>(null) }
    var blocking by remember { mutableStateOf<SafetyTarget?>(null) }
    LaunchedEffect(friend.id) {
        if (!friend.isSample) profile = store.friendProfile(friend.id)
        loading = false
    }
    fun openItem(item: Item) { BuyLink.url(item)?.let { open(context, it) } }

    PopSheet(onClose) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 24.dp, bottom = 30.dp),
            verticalArrangement = Arrangement.spacedBy(22.dp)) {
            // Hero: their icon overlapping yours.
            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy((-14).dp)) {
                    RingFrame(Ring.of(store.friendRings[friend.id]), 76.dp) { s ->
                        val icon = store.friendIcons[friend.id]
                        if (icon != null) Box(Modifier.border(3.dp, T.bg, CircleShape)) { FriendIconView(friend.id, friend.name, icon, s) }
                        else Box(Modifier.size(s).clip(CircleShape).background(themGradient).border(3.dp, T.bg, CircleShape), contentAlignment = Alignment.Center) {
                            Txt((friend.name.firstOrNull() ?: '?').uppercase(), size = (s.value * 0.4f).sp, weight = FontWeight.Black)
                        }
                    }
                    Box(Modifier.border(3.dp, T.bg, CircleShape)) { AvatarView(76.dp) }
                }
                Txt(friend.name, size = 26.sp, weight = FontWeight.Bold, modifier = Modifier.padding(top = 4.dp))
                val since = shortDate(profile?.since)
                Txt(if (since != null) "${friend.handle} · friends since $since" else friend.handle, color = T.muted)
                profile?.card?.archetype?.takeIf { it.isNotEmpty() }?.let { a ->
                    Box(Modifier.clip(CircleShape).background(T.hot.copy(alpha = 0.12f)).padding(horizontal = 12.dp, vertical = 6.dp)) {
                        Txt("✦ $a", size = T.footnote, weight = FontWeight.Bold, color = Color(1f, 0.62f, 0.69f))
                    }
                }
            }

            val p = profile
            when {
                loading -> Box(Modifier.fillMaxWidth().padding(vertical = 30.dp), contentAlignment = Alignment.Center) { Spinner() }
                p != null && p.shares -> {
                    p.match?.let { MatchCard(it, p, first) }
                    p.dna?.takeIf { it.isNotEmpty() }?.let { DnaCard(it, first) }
                    p.bothLove?.takeIf { it.isNotEmpty() }?.let { Chips("You both love", it, T.green) }
                    p.theirWorld?.takeIf { it.isNotEmpty() }?.let { Chips("From $first's world", it, T.cyan, trailing = "Tap one to hunt it") { t -> hunting = t } }
                    p.grails?.takeIf { it.isNotEmpty() }?.let { g ->
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            Header("$first's grails")
                            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                g.forEach { x -> Tile(x.listing.item, when (x.tag) { "watching" -> "WATCHING"; "got" -> "GOT IT"; else -> "LIKED" }) { openItem(it) } }
                            }
                        }
                    }
                    p.twins?.takeIf { it.isNotEmpty() }?.let { t ->
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            Header("Twin finds")
                            t.forEach { l ->
                                val item = l.item
                                Row(Modifier.fillMaxWidth().glass(RoundedCornerShape(18.dp)).clickable { openItem(item) }.padding(12.dp),
                                    verticalAlignment = Alignment.CenterVertically) {
                                    ProductThumb(item, 64.dp); Spacer(Modifier.width(12.dp))
                                    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                        Txt(l.title, weight = FontWeight.SemiBold, maxLines = 2)
                                        Txt(listOfNotNull(if (item.priceKnown) item.priceLabel else null, l.source.ifEmpty { null }).joinToString(" · "),
                                            size = T.caption, color = T.muted)
                                        Row(verticalAlignment = Alignment.CenterVertically) {
                                            Box(Modifier.size(6.dp).clip(CircleShape).background(T.green)); Spacer(Modifier.width(5.dp))
                                            Txt("Both your scouts found this", size = T.caption2, weight = FontWeight.SemiBold, color = T.green)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    p.gifts?.takeIf { it.isNotEmpty() }?.let { GiftRadar(it.map { l -> l.item }, p.birthday, first) { i -> openItem(i) } }
                }
                else -> Column(Modifier.fillMaxWidth().glass(RoundedCornerShape(18.dp)).padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.Lock, null, tint = T.ink, modifier = Modifier.size(18.dp)); Spacer(Modifier.width(8.dp))
                        Txt("Taste match is waiting", size = T.body, weight = FontWeight.SemiBold)
                    }
                    Txt(if (p?.theyShare == false)
                            "$first keeps their taste private. When you both share taste, you'll see your match, their grails, gift ideas and swap Taste Cards."
                        else "Turn on sharing your taste (Friends, then What friends can see) to see your match, $first's grails, gift ideas and swap Taste Cards.",
                        size = T.footnote, color = T.muted)
                }
            }

            // Recently sent you
            val sent = store.state.suggestions.filter { it.friendID == friend.id }.sortedByDescending { it.date }.mapNotNull { Catalog.item(it.itemID) }.take(6)
            if (sent.isNotEmpty()) Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Header("Recently sent you")
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    sent.forEach { Tile(it, null) { i -> openItem(i) } }
                }
            }

            // Actions
            Column(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (profile?.shares == true) PrimaryButton("Swap Taste Cards", Modifier.fillMaxWidth(), icon = Icons.Filled.Style) { showCards = true }
                GhostButton("Suggest something for $first", Modifier.fillMaxWidth().height(52.dp)) { onClose(); Router.open(Sheet.SuggestFor(friend.id)) }
                Txt("Remove friend", size = T.footnote, color = T.muted, modifier = Modifier.clickable { confirmRemove = true }.padding(4.dp))
                if (store.isCloud && !friend.isSample) {
                    Hairline()
                    Row(horizontalArrangement = Arrangement.spacedBy(26.dp)) {
                        IconLabel("Report", Icons.Filled.Flag, T.warn) { reporting = SafetyTarget(friend) }
                        IconLabel("Block ${friend.handle}", Icons.Filled.Block, T.hot) { blocking = SafetyTarget(friend) }
                    }
                }
            }
        }
        Box(Modifier.align(Alignment.TopEnd).padding(top = 14.dp, end = 16.dp)) { RoundClose(onClose) }
    }

    SafetyDialogs(reporting, blocking, onDone = { reporting = null; blocking = null }, onBlocked = onClose)
    if (showCards) TasteCardSwap(friend.name, profile?.card, profile?.myCard, profile?.match) { showCards = false }
    if (confirmRemove) AlertDialog(onDismissRequest = { confirmRemove = false }, containerColor = T.panel,
        title = { Txt("Remove ${friend.name}?", size = T.body, weight = FontWeight.Bold) },
        confirmButton = { TextButton(onClick = {
            confirmRemove = false; store.removeFriend(friend.id); Router.say("Removed ${friend.name}"); onClose()
        }) { Txt("Remove", color = T.hot, weight = FontWeight.Bold) } },
        dismissButton = { TextButton(onClick = { confirmRemove = false }) { Txt("Cancel", color = T.muted) } })
    hunting?.let { h ->
        AlertDialog(onDismissRequest = { hunting = null }, containerColor = T.panel,
            title = { Txt("Start a scout for $h?", size = T.body, weight = FontWeight.Bold) },
            text = { Txt("A new scout hunts it for you, the way $first loves it.", color = T.muted) },
            confirmButton = { TextButton(onClick = {
                hunting = null
                store.scope.launch {
                    val r = store.hunt(h)
                    if (r != null) Router.say(r.intro) else store.syncProblem?.let { Router.say(it) }
                }
            }) { Txt("Start hunting", color = T.accent, weight = FontWeight.Bold) } },
            dismissButton = { TextButton(onClick = { hunting = null }) { Txt("Cancel", color = T.muted) } })
    }
}

@Composable
private fun IconLabel(text: String, icon: androidx.compose.ui.graphics.vector.ImageVector, tint: Color, onClick: () -> Unit) {
    Row(Modifier.clickable(onClick = onClick).padding(4.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(15.dp)); Spacer(Modifier.width(5.dp))
        Txt(text, size = T.footnote, weight = FontWeight.SemiBold, color = tint)
    }
}

@Composable
private fun Header(t: String, trailing: String? = null) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Txt(t.uppercase(), size = T.caption, weight = FontWeight.SemiBold, tracking = 1.6.sp, color = T.muted, modifier = Modifier.weight(1f))
        if (trailing != null) Txt(trailing, size = T.caption, color = T.cyan)
    }
}

@Composable
private fun MatchCard(m: Int, p: FriendProfile, first: String) {
    val title = when {
        m >= 80 -> "Taste match: twins"; m >= 60 -> "Taste match: really close"
        m >= 40 -> "Taste match: some overlap"; else -> "Taste match: different worlds"
    }
    val both = (p.bothLove ?: emptyList()).take(2).joinToString(", ")
    val theirs = (p.dna ?: emptyList()).firstOrNull { it.who == "them" }?.label
    val line = when {
        both.isNotEmpty() && theirs != null -> "You both go for $both. $first leans more $theirs than you."
        both.isNotEmpty() -> "You both go for $both."
        theirs != null -> "$first is into $theirs. A good way to find something new."
        else -> "Like and pass a few more finds and this gets sharper."
    }
    Row(Modifier.fillMaxWidth().glass(RoundedCornerShape(18.dp)).padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(80.dp), contentAlignment = Alignment.Center) {
            Canvas(Modifier.fillMaxSize().padding(5.dp)) {
                drawCircle(Color.White.copy(alpha = 0.08f), style = Stroke(9.dp.toPx()))
                drawArc(T.gradient, -90f, 360f * m / 100f, false, style = Stroke(9.dp.toPx(), cap = StrokeCap.Round))
            }
            Txt("$m%", size = 21.sp, weight = FontWeight.Black)
        }
        Spacer(Modifier.width(16.dp))
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Txt(title, size = T.body, weight = FontWeight.SemiBold)
            Txt(line, size = T.footnote, color = T.muted)
        }
    }
}

@Composable
private fun DnaCard(dna: List<FriendProfile.DNA>, first: String) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Header("Taste DNA")
        Column(Modifier.fillMaxWidth().glass(RoundedCornerShape(18.dp)).padding(14.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) {
            dna.forEach { d ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Txt(d.label, maxLines = 1, modifier = Modifier.width(110.dp))
                    Spacer(Modifier.width(10.dp))
                    BoxWithConstraints(Modifier.weight(1f).height(8.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.08f))) {
                        val frac = d.strength.coerceIn(0.12, 1.0).toFloat()
                        Box(Modifier.fillMaxHeight().width(maxOf(10.dp, maxWidth * frac)).clip(CircleShape).background(when (d.who) {
                            "both" -> T.gradient; "them" -> themGradient; else -> Brush.linearGradient(listOf(T.blue, T.blue))
                        }))
                    }
                    Spacer(Modifier.width(10.dp))
                    Txt(when (d.who) { "both" -> "both"; "them" -> first; else -> "you" }, size = T.caption, color = T.muted,
                        align = TextAlign.End, maxLines = 1, modifier = Modifier.width(52.dp))
                }
            }
            Row(Modifier.padding(top = 2.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                listOf("You both" to T.green, "Mostly $first" to T.hot, "Mostly you" to T.blue).forEach { (t, c) ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(7.dp).clip(CircleShape).background(c)); Spacer(Modifier.width(5.dp))
                        Txt(t, size = T.caption2, color = T.muted)
                    }
                }
            }
        }
    }
}

@Composable
private fun Chips(title: String, items: List<String>, tint: Color, trailing: String? = null, action: ((String) -> Unit)? = null) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Header(title, trailing)
        Flow(8.dp) {
            items.forEach { t ->
                Box(Modifier.clip(CircleShape).background(tint.copy(alpha = 0.10f)).border(1.dp, tint.copy(alpha = 0.45f), CircleShape)
                    .then(if (action != null) Modifier.clickable { action(t) } else Modifier).padding(horizontal = 12.dp, vertical = 7.dp)) {
                    Txt(t, size = T.footnote, color = tint.copy(alpha = 0.95f))
                }
            }
        }
    }
}

/** A product tile: photo, title, brand and price; opens the store page. */
@Composable
private fun Tile(item: Item, tag: String?, width: Dp = 118.dp, onOpen: (Item) -> Unit) {
    Column(Modifier.width(width).clickable { onOpen(item) }, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box {
            ProductThumb(item, width)
            if (tag != null) Box(Modifier.padding(7.dp).clip(RoundedCornerShape(6.dp)).background(T.bg.copy(alpha = 0.85f)).padding(horizontal = 6.dp, vertical = 3.dp)) {
                Txt(tag, size = 9.sp, weight = FontWeight.Black, tracking = 0.6.sp, color = T.warn)
            }
        }
        Txt(item.title, size = T.caption, weight = FontWeight.SemiBold, maxLines = 2)
        Txt(listOfNotNull(item.brand.ifEmpty { null }, if (item.priceKnown) item.priceLabel else null).joinToString(" · "),
            size = T.caption2, color = T.muted, maxLines = 1)
    }
}

@Composable
private fun GiftRadar(gifts: List<Item>, birthday: String?, first: String, onOpen: (Item) -> Unit) {
    val shape = RoundedCornerShape(20.dp)
    Column(Modifier.fillMaxWidth().clip(shape).background(Brush.linearGradient(listOf(T.warn.copy(alpha = 0.12f), T.hot.copy(alpha = 0.10f))))
        .border(1.dp, T.warn.copy(alpha = 0.3f), shape).padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.CardGiftcard, null, tint = T.ink, modifier = Modifier.size(18.dp)); Spacer(Modifier.width(8.dp))
            Txt("Gift radar", size = T.body, weight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            Birthday.label(birthday)?.let { b ->
                Box(Modifier.clip(CircleShape).background(T.warn.copy(alpha = 0.14f)).padding(horizontal = 9.dp, vertical = 5.dp)) {
                    Txt("Birthday · $b", size = T.caption, weight = FontWeight.SemiBold, color = Color(1f, 0.85f, 0.54f))
                }
            }
        }
        Txt("Picked for $first's taste by your scouts, under $150.", size = T.footnote, color = T.muted)
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            gifts.forEach { Tile(it, null, onOpen = onOpen) }
        }
    }
}

// MARK: Taste Cards

/** One collectible card. Used in the swap sheet, the Friends collection and the shared image. */
@Composable
fun TasteCardView(card: TasteCard, name: String, match: Int? = null, width: Dp = 310.dp) {
    val s = width.value / 310f
    val base = listOf(themOrange, T.hot, Color(0.48f, 0.24f, 1f))
    val p = card.palette.mapNotNull { hexColor(it) }
    // The card's own palette tints the gradient's top so every card looks like its owner.
    val colors = if (p.size >= 2) listOf(lerp(p[0], base[0], 0.55f), base[1], base[2]) else base
    val shape = RoundedCornerShape((26 * s).dp)
    Column(Modifier.width(width).height(width * 1.5f).clip(shape).background(Brush.linearGradient(colors))
        .border(1.5.dp, Color.White.copy(alpha = 0.35f), shape).padding((18 * s).dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Txt("BAGET · TASTE CARD", size = (10.5f * s).sp, weight = FontWeight.Black, tracking = 1.4.sp, color = Color.White.copy(alpha = 0.9f), modifier = Modifier.weight(1f), maxLines = 1)
            card.number?.let { Txt("No. ${"%04d".format(it)}", size = (10.5f * s).sp, weight = FontWeight.Black, tracking = 1.4.sp, color = Color.White.copy(alpha = 0.9f), maxLines = 1) }
        }
        Box(Modifier.padding(top = (20 * s).dp).size((62 * s).dp).clip(CircleShape).background(Color.White.copy(alpha = 0.22f))
            .border(2.dp, Color.White.copy(alpha = 0.6f), CircleShape), contentAlignment = Alignment.Center) {
            Txt((name.firstOrNull() ?: '?').uppercase(), size = (26 * s).sp, weight = FontWeight.Black, color = Color.White)
        }
        Txt(name, size = (27 * s).sp, weight = FontWeight.Black, color = Color.White, maxLines = 1, modifier = Modifier.padding(top = (10 * s).dp))
        Txt("✦ ${card.archetype}", size = (14.5f * s).sp, weight = FontWeight.Bold, color = Color.White, maxLines = 2, modifier = Modifier.padding(top = (4 * s).dp))
        Column(Modifier.padding(top = (16 * s).dp), verticalArrangement = Arrangement.spacedBy((9 * s).dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy((9 * s).dp)) {
                CardStat("SIGNATURE", card.signature.joinToString(", "), s, Modifier.weight(1f))
                CardStat("NOTES", card.notes.joinToString(", "), s, Modifier.weight(1f))
            }
            Row(horizontalArrangement = Arrangement.spacedBy((9 * s).dp)) {
                CardStat("HUNTS", card.hunts.joinToString(", "), s, Modifier.weight(1f))
                CardStat("GRAIL", card.grail ?: "—", s, Modifier.weight(1f))
            }
        }
        if (card.palette.isNotEmpty()) Column(Modifier.padding(top = (14 * s).dp), verticalArrangement = Arrangement.spacedBy((6 * s).dp)) {
            Txt("TASTE PALETTE", size = (9 * s).sp, weight = FontWeight.Black, tracking = 1.1.sp, color = Color.White.copy(alpha = 0.85f), maxLines = 1)
            Row(horizontalArrangement = Arrangement.spacedBy((6 * s).dp)) {
                card.palette.take(5).forEach { hex ->
                    val r = RoundedCornerShape((7 * s).dp)
                    Box(Modifier.weight(1f).height((20 * s).dp).clip(r).background(hexColor(hex) ?: Color.Gray).border(1.dp, Color.White.copy(alpha = 0.4f), r))
                }
            }
        }
        Spacer(Modifier.weight(1f))
        Row {
            if (match != null) Txt("$match% match with you", size = (11 * s).sp, weight = FontWeight.Bold, color = Color.White.copy(alpha = 0.9f), maxLines = 1)
            Spacer(Modifier.weight(1f))
            Txt(DateTimeFormatter.ofPattern("MMM yyyy").format(LocalDate.now()), size = (11 * s).sp, weight = FontWeight.Bold, color = Color.White.copy(alpha = 0.9f), maxLines = 1)
        }
    }
}

@Composable
private fun CardStat(label: String, value: String, s: Float, modifier: Modifier) {
    Column(modifier.heightIn(min = (58 * s).dp).clip(RoundedCornerShape((13 * s).dp)).background(Color.Black.copy(alpha = 0.18f)).padding((10 * s).dp),
        verticalArrangement = Arrangement.spacedBy((4 * s).dp)) {
        Txt(label, size = (9 * s).sp, weight = FontWeight.Black, tracking = 1.1.sp, color = Color.White.copy(alpha = 0.85f), maxLines = 1)
        Txt(value.ifEmpty { "—" }, size = (13.5f * s).sp, weight = FontWeight.Bold, color = Color.White, maxLines = 2)
    }
}

/** "Swap Taste Cards": their card and yours, flip between them, share either as an image. */
@Composable
fun TasteCardSwap(friendName: String, theirs: TasteCard?, mine: TasteCard?, match: Int?, onClose: () -> Unit) {
    val store = AppStore
    val context = LocalContext.current
    var showingMine by remember { mutableStateOf(false) }
    val layer = rememberGraphicsLayer()
    val card = if (showingMine) mine else theirs
    val shownName = if (showingMine) (store.state.profile?.displayName?.ifEmpty { null } ?: "You") else friendName
    PopSheet(onClose) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Txt(if (showingMine) "YOUR TASTE CARD" else "${friendName.uppercase()}'S TASTE CARD", size = T.caption, weight = FontWeight.Bold,
                tracking = 2.sp, color = T.muted, modifier = Modifier.padding(top = 28.dp))
            Box(Modifier.clickable { showingMine = !showingMine }) {
                if (card != null) Box(Modifier.drawWithContent { layer.record { this@drawWithContent.drawContent() }; drawLayer(layer) }) {
                    TasteCardView(card, shownName, if (showingMine) null else match)
                }
                else Column(Modifier.width(310.dp).height(465.dp).glass(RoundedCornerShape(26.dp)).padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterVertically)) {
                    Icon(Icons.Filled.Style, null, tint = T.cyan, modifier = Modifier.size(34.dp))
                    Txt("This card is being made", size = T.body, weight = FontWeight.SemiBold)
                    Txt("Baget writes a Taste Card from what someone likes and passes on. Check back after a few more likes.",
                        size = T.footnote, color = T.muted, align = TextAlign.Center)
                }
            }
            Row(Modifier.width(310.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                GhostButton(if (showingMine) "See ${firstName(friendName)}'s" else "See mine", Modifier.weight(1f).height(48.dp)) { showingMine = !showingMine }
                if (card != null) PrimaryButton("Share", Modifier.weight(1f).height(48.dp), icon = Icons.Filled.Share) {
                    store.scope.launch { runCatching { shareCardImage(context, layer.toImageBitmap().asAndroidBitmap()) } }
                }
            }
            Txt("Cards swap when you both share taste, and they update as your taste changes. Tap the card to flip.",
                size = T.caption, color = T.muted, align = TextAlign.Center, modifier = Modifier.width(290.dp))
        }
        Box(Modifier.align(Alignment.TopEnd).padding(top = 14.dp, end = 16.dp)) { RoundClose(onClose) }
    }
}

private fun shareCardImage(context: Context, bitmap: android.graphics.Bitmap) {
    val dir = File(context.cacheDir, "camera").also { it.mkdirs() }
    val f = File(dir, "taste-card.png")
    f.outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
    val uri = FileProvider.getUriForFile(context, context.packageName + ".files", f)
    val send = Intent(Intent.ACTION_SEND).setType("image/png").putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    context.startActivity(Intent.createChooser(send, "Taste Card").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}

/** Friends tab: your Taste Card and the ones your friends have swapped with you. */
@Composable
fun TasteCardsRow() {
    val store = AppStore
    var cards by remember { mutableStateOf<List<TasteCard>>(emptyList()) }
    var mine by remember { mutableStateOf<TasteCard?>(null) }
    var open by remember { mutableStateOf<TasteCard?>(null) }
    LaunchedEffect(Unit) { mine = store.myTasteCard(); cards = store.friendCards() }
    val myName = store.state.profile?.displayName?.ifEmpty { null } ?: "You"
    if (cards.isNotEmpty() || mine != null) Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Txt("TASTE CARDS", size = T.caption, weight = FontWeight.SemiBold, tracking = 1.6.sp, color = T.muted)
        Row(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            mine?.let { c -> MiniCard(c, myName, "You") { open = c } }
            cards.forEach { c -> MiniCard(c, c.name ?: c.handle ?: "", c.name ?: "") { open = c } }
        }
    }
    open?.let { c ->
        PopSheet({ open = null }) {
            Column(Modifier.fillMaxSize().padding(top = 40.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                TasteCardView(c, c.name ?: myName)
            }
            Box(Modifier.align(Alignment.TopEnd).padding(top = 14.dp, end = 16.dp)) { RoundClose { open = null } }
        }
    }
}

@Composable
private fun MiniCard(c: TasteCard, name: String, caption: String, onClick: () -> Unit) {
    Column(Modifier.clickable(onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        TasteCardView(c, name, width = 110.dp)
        Txt(caption, size = T.caption2, color = T.muted, maxLines = 1, align = TextAlign.Center, modifier = Modifier.width(110.dp))
    }
}

// MARK: Birthdays

/** A small menu picker (month, day). */
@Composable
private fun MenuPick(options: List<String>, selected: Int, onPick: (Int) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        Row(Modifier.clip(RoundedCornerShape(10.dp)).background(Color.White.copy(alpha = 0.06f)).clickable { expanded = true }
            .padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Txt(options.getOrElse(selected) { "" }, color = T.cyan)
            Icon(Icons.Filled.ArrowDropDown, null, tint = T.cyan)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }, containerColor = T.panel,
            modifier = Modifier.heightIn(max = 320.dp)) {
            options.forEachIndexed { i, o ->
                DropdownMenuItem(text = { Txt(o, weight = if (i == selected) FontWeight.Bold else FontWeight.Normal) }, onClick = { expanded = false; onPick(i) })
            }
        }
    }
}

/** Your birthday (month and day). Friends see it when it's coming up, with gift ideas for your taste if you both share taste. */
@Composable
fun BirthdayRow(showsCaption: Boolean = true) {
    val store = AppStore
    val today = LocalDate.now()
    var on by remember { mutableStateOf(false) }
    var month by remember { mutableIntStateOf(today.monthValue) }
    var day by remember { mutableIntStateOf(today.dayOfMonth) }
    var loaded by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        val b = store.myBirthday()
        val m = b?.takeIf { it.length == 5 }?.take(2)?.toIntOrNull(); val d = b?.takeIf { it.length == 5 }?.takeLast(2)?.toIntOrNull()
        if (m != null && d != null) { month = m; day = d; on = true }
        loaded = true
    }
    fun save() {
        if (!loaded) return
        val value = if (on) "%02d-%02d".format(month, minOf(day, Birthday.daysIn(month))) else null
        store.scope.launch { store.setBirthday(value) }
    }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SwitchRow("My birthday", if (showsCaption) "Month and day only. Friends get a heads-up when it's coming up, with gift ideas for your taste." else null, on) {
            if (loaded) { on = it; save() }
        }
        if (on) Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            MenuPick(Birthday.monthNames, month - 1) { month = it + 1; if (day > Birthday.daysIn(month)) day = Birthday.daysIn(month); save() }
            MenuPick((1..Birthday.daysIn(month)).map { "$it" }, day - 1) { day = it + 1; save() }
        }
    }
}

/** A friend's birthday coming up: when it is, gift picks for their taste, and a way to see their profile. */
@Composable
fun BirthdayCard(birthday: UpcomingBirthday, friend: Friend?, openProfile: () -> Unit) {
    val store = AppStore
    val context = LocalContext.current
    var gifts by remember { mutableStateOf<List<Item>>(emptyList()) }
    LaunchedEffect(birthday.friendId) {
        if (birthday.shares) store.friendProfile(birthday.friendId)?.let { p -> gifts = (p.gifts ?: emptyList()).take(6).map { it.item } }
    }
    val shape = RoundedCornerShape(20.dp)
    Column(Modifier.fillMaxWidth().clip(shape).background(Brush.linearGradient(listOf(T.warn.copy(alpha = 0.14f), T.hot.copy(alpha = 0.10f))))
        .border(1.dp, T.warn.copy(alpha = 0.32f), shape).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.Top) {
            Box(Modifier.size(46.dp).clip(RoundedCornerShape(14.dp)).background(T.warn.copy(alpha = 0.16f)), contentAlignment = Alignment.Center) {
                Txt(if (birthday.days == 0) "🎂" else "🎁", size = 24.sp)
            }
            Spacer(Modifier.width(12.dp))
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Txt(if (birthday.days == 0) "It's ${birthday.first}'s birthday!" else "${birthday.first}'s birthday is coming up", size = T.body, weight = FontWeight.SemiBold)
                Txt("${birthday.whenLabel} · ${Birthday.label(birthday.birthday) ?: ""}", size = T.footnote, weight = FontWeight.SemiBold, color = Color(1f, 0.85f, 0.54f))
            }
        }
        if (gifts.isNotEmpty()) {
            Txt("Picked for ${birthday.first}'s taste by your scouts:", size = T.footnote, color = T.muted)
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                gifts.forEach { Tile(it, null, width = 104.dp) { i -> BuyLink.url(i)?.let { u -> open(context, u) } } }
            }
        } else if (!birthday.shares) {
            Txt("When you both share taste, your scouts pick gift ideas for ${birthday.first} here.", size = T.footnote, color = T.muted)
        }
        if (friend != null) Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(13.dp)).background(T.warn).clickable(onClick = openProfile).padding(vertical = 11.dp),
            contentAlignment = Alignment.Center) {
            Txt(if (birthday.shares) "More gift ideas" else "See ${birthday.first}'s profile", weight = FontWeight.Black, color = Color(0.11f, 0.08f, 0.02f))
        }
    }
}

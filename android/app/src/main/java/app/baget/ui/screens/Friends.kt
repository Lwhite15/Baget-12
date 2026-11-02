package app.baget.ui.screens

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.baget.engine.*
import app.baget.model.*
import app.baget.ui.*
import kotlinx.coroutines.launch

private fun first(name: String) = name.split(" ").firstOrNull { it.isNotEmpty() } ?: name

/** Opens the share sheet with the invite (Messages, WhatsApp, Instagram...). */
private fun shareInvite(context: android.content.Context) {
    Analytics.track(AnalyticsEvent.FRIEND_INVITED, mapOf("via" to "share"))
    val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, AppStore.inviteMessage)
    runCatching { context.startActivity(Intent.createChooser(send, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
}

@Composable
private fun SectionHead(title: String, trailing: String? = null) {
    Row(Modifier.fillMaxWidth().padding(top = 6.dp), verticalAlignment = Alignment.Bottom) {
        Txt(title, size = 21.sp, weight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
        if (trailing != null) Txt(trailing, size = T.footnote, color = T.muted)
    }
}

/** A plain white pill: the one main action on a row. */
@Composable
private fun QuietPrimary(text: String, enabled: Boolean = true, onClick: () -> Unit) {
    Box(Modifier.clip(CircleShape).background(Color.White.copy(alpha = if (enabled) 0.95f else 0.4f)).clickable(enabled = enabled, onClick = onClick)
        .padding(horizontal = 18.dp, vertical = 10.dp)) {
        Txt(text, weight = FontWeight.SemiBold, color = T.bg, maxLines = 1)
    }
}

@Composable
fun FriendsScreen() {
    val store = AppStore
    val s = store.observe()
    val focus = LocalFocusManager.current
    var open by remember { mutableStateOf<Friend?>(null) }
    var adding by remember { mutableStateOf(false) }
    var privacy by remember { mutableStateOf(false) }
    var matches by remember { mutableStateOf<Map<String, Int>>(emptyMap()) }
    var birthdays by remember { mutableStateOf<List<UpcomingBirthday>>(emptyList()) }

    // Only suggestions you haven't acted on: adding saves it to Finds and passing dismisses it; either way it leaves.
    val suggestions = s.suggestions.filter { it.status == SuggestionStatus.NEW }.sortedByDescending { it.date }
    val circle = s.friends.filter { !it.isPending || !it.incoming }
    val requests = s.friends.filter { it.isPending && it.incoming }
    val shares = s.shares.filter { Catalog.item(it.itemID) != null }
    val accepted = circle.filter { !it.isPending }

    LaunchedEffect(accepted.size, s.settings.shareTasteWithFriends) {
        matches = store.friendMatches()
        birthdays = store.upcomingBirthdays()
    }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).tap { focus.clearFocus() }
        .padding(horizontal = 20.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Column(Modifier.padding(bottom = 4.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Txt("Friends", size = 36.sp, weight = FontWeight.Bold)
            Txt("Hunting's better with people who get your taste.", color = T.muted)
        }

        if (requests.isNotEmpty()) RequestList(requests)

        birthdays.forEach { b ->
            key(b.friendId) {
                val f = accepted.firstOrNull { it.id == b.friendId }
                BirthdayCard(b, f) { open = f }
            }
        }

        if (circle.isEmpty()) InviteHero { adding = true }
        else {
            SectionHead("Your circle", if (accepted.isEmpty()) null else if (accepted.size == 1) "1 friend" else "${accepted.size} friends")
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 2.dp), horizontalArrangement = Arrangement.spacedBy(16.dp),
                verticalAlignment = Alignment.Top) {
                circle.forEach { f ->
                    key(f.id) {
                        Box(Modifier.clickable { open = f }) {
                            CircleMember(f, hasNew = suggestions.any { it.friendID == f.id }, match = if (f.isPending) null else matches[f.id])
                        }
                    }
                }
                Column(Modifier.width(62.dp).clickable { adding = true }, horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(7.dp)) {
                    Box(Modifier.size(58.dp).drawBehind {
                        drawCircle(T.cyan.copy(alpha = 0.7f), radius = size.minDimension / 2 - 1.dp.toPx(),
                            style = Stroke(1.5.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx()))))
                    }, contentAlignment = Alignment.Center) {
                        Icon(Icons.Filled.PersonAdd, "Add a friend by username", tint = T.cyan)
                    }
                    Txt("Add", size = T.caption, weight = FontWeight.SemiBold, color = T.cyan)
                }
            }
            if (accepted.size < 8) InviteBanner()
        }

        if (store.isCloud) Box(Modifier.padding(top = 6.dp)) { TasteCardsRow() }

        SectionHead("Sent to you", if (suggestions.isEmpty()) null else "${suggestions.size} new")
        if (suggestions.isEmpty()) {
            Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(T.glass).border(1.dp, T.line, RoundedCornerShape(18.dp)).padding(14.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(40.dp).clip(RoundedCornerShape(12.dp)).background(T.warn.copy(alpha = 0.14f)), contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.MoveToInbox, null, tint = T.warn)
                }
                Spacer(Modifier.width(12.dp))
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Txt(if (s.friends.isEmpty()) "Nothing here yet" else "Nothing new right now", weight = FontWeight.SemiBold)
                    Txt("Friends' finds and picks for you land here.", size = T.footnote, color = T.muted)
                }
            }
        }
        suggestions.forEach { key(it.id) { SuggestionCard(it) } }

        if (shares.isNotEmpty()) {
            Box(Modifier.padding(top = 8.dp)) { SectionHead("You sent") }
            shares.forEach { sh -> key(sh.id) { SentRow(sh) } }
        }

        Box(Modifier.padding(top = 8.dp)) { SharingCard { privacy = true } }

        if (!store.isCloud) Txt("Sample data: Dre, Maya and Sam are sample friends, and their replies are simulated.", size = T.caption, color = T.muted)
    }

    open?.let { f ->
        if (f.isPending || f.isSample) FriendSheet(f) { open = null } else FriendProfileSheet(f) { open = null }
    }
    if (adding) AddFriendSheet { adding = false }
    if (privacy) FriendsPrivacySheet { privacy = false }
}

/** The big invite card for someone with no friends on Baget yet. */
@Composable
private fun InviteHero(onAdd: () -> Unit) {
    val store = AppStore
    val context = LocalContext.current
    val shape = RoundedCornerShape(24.dp)
    Column(Modifier.padding(top = 6.dp).fillMaxWidth().clip(shape)
        .background(Brush.linearGradient(listOf(T.blue.copy(alpha = 0.30f), T.cyan.copy(alpha = 0.16f), T.hot.copy(alpha = 0.18f))))
        .drawBehind {
            drawCircle(Brush.radialGradient(listOf(T.green.copy(alpha = 0.35f), Color.Transparent), center = Offset(size.width - 40.dp.toPx(), 30.dp.toPx()),
                radius = 110.dp.toPx()), radius = 110.dp.toPx(), center = Offset(size.width - 40.dp.toPx(), 30.dp.toPx()))
        }
        .border(1.dp, Color.White.copy(alpha = 0.14f), shape).padding(20.dp)) {
        Row(Modifier.padding(bottom = 14.dp), horizontalArrangement = Arrangement.spacedBy((-12).dp)) {
            Box(Modifier.border(3.dp, T.panel, CircleShape)) { AvatarView(46.dp) }
            repeat(3) {
                Box(Modifier.size(46.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.1f)).drawBehind {
                    drawCircle(Color.White.copy(alpha = 0.45f), radius = size.minDimension / 2 - 1.dp.toPx(),
                        style = Stroke(1.5.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx()))))
                }, contentAlignment = Alignment.Center) { Icon(Icons.Filled.Add, null, tint = Color.White) }
            }
        }
        Txt("Bring your crew.\nSee who shares your taste.", size = 24.sp, weight = FontWeight.Black)
        Txt("When a friend joins, Baget compares your taste and unlocks:", color = T.ink.copy(alpha = 0.75f), modifier = Modifier.padding(top = 6.dp))
        Column(Modifier.padding(top = 14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Perk(Icons.Filled.Percent, T.green, "Your taste match", "how close your styles are")
            Perk(Icons.Filled.Style, T.hot, "Taste Cards", "swap your style ID")
            Perk(Icons.Filled.CardGiftcard, T.warn, "Gift radar", "picks for their birthday")
            Perk(Icons.AutoMirrored.Filled.Send, T.cyan, "Send finds", "\"saw this and thought of you\"")
        }
        Row(Modifier.padding(top = 16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.weight(1f).clip(RoundedCornerShape(15.dp)).background(T.gradient).clickable { shareInvite(context) }.padding(vertical = 13.dp),
                contentAlignment = Alignment.Center) { Txt("Invite friends", weight = FontWeight.Black, color = T.accentInk) }
            Box(Modifier.weight(1f).clip(RoundedCornerShape(15.dp)).background(Color.White.copy(alpha = 0.08f))
                .border(1.dp, Color.White.copy(alpha = 0.16f), RoundedCornerShape(15.dp)).clickable(onClick = onAdd).padding(vertical = 13.dp),
                contentAlignment = Alignment.Center) { Txt("Add by username", weight = FontWeight.Black) }
        }
        val h = store.state.profile?.handle
        if (!h.isNullOrEmpty()) Row(Modifier.fillMaxWidth().padding(top = 12.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
            Txt("Your username", size = T.footnote, color = T.muted)
            Spacer(Modifier.width(8.dp))
            Box(Modifier.clip(CircleShape).background(Color.Black.copy(alpha = 0.25f)).padding(horizontal = 10.dp, vertical = 5.dp)) {
                Txt("@$h", size = T.footnote, weight = FontWeight.Bold)
            }
            Spacer(Modifier.width(8.dp))
            Txt("Copy", size = T.footnote, weight = FontWeight.Bold, color = T.cyan, modifier = Modifier.clickable {
                runCatching { context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("username", "@$h")) }
                Router.say("Username copied")
            })
        }
    }
}

@Composable
private fun Perk(icon: ImageVector, tint: Color, title: String, detail: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(30.dp).clip(RoundedCornerShape(10.dp)).background(tint.copy(alpha = 0.16f)), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = tint, modifier = Modifier.size(15.dp))
        }
        Spacer(Modifier.width(11.dp))
        Row {
            Txt("$title ", weight = FontWeight.Bold)
            Txt(detail, color = T.ink.copy(alpha = 0.65f))
        }
    }
}

/** A slim nudge to invite more people, once you have a few friends. */
@Composable
private fun InviteBanner() {
    val context = LocalContext.current
    val shape = RoundedCornerShape(18.dp)
    Row(Modifier.fillMaxWidth().clip(shape).background(Brush.horizontalGradient(listOf(T.blue.copy(alpha = 0.22f), T.green.copy(alpha = 0.14f))))
        .border(1.dp, Color.White.copy(alpha = 0.14f), shape).padding(horizontal = 16.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Txt("Who else hunts like you?", weight = FontWeight.Bold)
            Txt("Invite a friend and see your match.", size = T.caption, color = T.ink.copy(alpha = 0.7f))
        }
        Spacer(Modifier.width(8.dp))
        Box(Modifier.clip(CircleShape).background(T.gradient).clickable { shareInvite(context) }.padding(horizontal = 16.dp, vertical = 9.dp)) {
            Txt("Invite", weight = FontWeight.Black, color = T.accentInk)
        }
    }
}

/** What friends can see, at a glance, with a nudge to share taste (it's what unlocks match % and Taste Cards). */
@Composable
private fun SharingCard(edit: () -> Unit) {
    val store = AppStore
    val s = store.observe()
    val taste = s.settings.shareTasteWithFriends
    val buys = s.settings.sharePurchasesWithFriends
    val shape = RoundedCornerShape(20.dp)
    Column(Modifier.fillMaxWidth().clip(shape).background(T.glass).border(1.dp, T.line, shape).clickable(onClick = edit).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Txt("What friends see", size = T.body, weight = FontWeight.Bold, modifier = Modifier.weight(1f))
            Txt("Edit", weight = FontWeight.Bold, color = T.cyan, modifier = Modifier.clickable(onClick = edit))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            SharePill(Icons.Filled.AutoAwesome, "Taste", if (taste) "Shared" else "Hidden", taste, Modifier.weight(1f))
            SharePill(if (buys) Icons.Filled.ShoppingBag else Icons.Filled.Lock, "Purchases", if (buys) "Shared" else "Private", buys, Modifier.weight(1f))
        }
        if (!taste) {
            val r = RoundedCornerShape(14.dp)
            Row(Modifier.fillMaxWidth().clip(r).background(T.warn.copy(alpha = 0.10f)).border(1.dp, T.warn.copy(alpha = 0.28f), r).padding(12.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Txt("Share your taste to see match % and swap Taste Cards.", size = T.footnote, color = Color(1f, 0.89f, 0.64f), modifier = Modifier.weight(1f))
                Spacer(Modifier.width(4.dp))
                Box(Modifier.clip(CircleShape).background(T.warn).clickable { s.settings.shareTasteWithFriends = true; store.save() }
                    .padding(horizontal = 12.dp, vertical = 7.dp)) {
                    Txt("Turn on", size = T.footnote, weight = FontWeight.Black, color = Color(0.11f, 0.08f, 0.02f))
                }
            }
        }
    }
}

@Composable
private fun SharePill(icon: ImageVector, title: String, state: String, on: Boolean, modifier: Modifier) {
    val r = RoundedCornerShape(14.dp)
    Row(modifier.clip(r).background(if (on) T.green.copy(alpha = 0.08f) else Color.Black.copy(alpha = 0.18f))
        .border(1.dp, if (on) T.green.copy(alpha = 0.4f) else T.line, r).padding(horizontal = 12.dp, vertical = 11.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = if (on) T.green else T.muted, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(10.dp))
        Column {
            Txt(title, weight = FontWeight.Bold)
            Txt(state, size = T.caption, color = if (on) T.green.copy(alpha = 0.9f) else T.muted)
        }
    }
}

private val circleColors = listOf(
    listOf(Color(1f, 0.54f, 0.36f), T.hot), listOf(Color(0.48f, 0.24f, 1f), T.cyan),
    listOf(T.warn, Color(1f, 0.54f, 0.36f)), listOf(T.blue, T.green), listOf(T.hot, Color(0.48f, 0.24f, 1f)),
)

@Composable
private fun CircleMember(friend: Friend, hasNew: Boolean, match: Int?) {
    val store = AppStore
    val icon = store.friendIcons[friend.id]
    val colors = circleColors[Math.abs(friend.id.sumOf { it.code }) % circleColors.size]
    Column(Modifier.width(62.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Box {
            RingFrame(if (friend.isPending) null else Ring.of(store.friendRings[friend.id]), 58.dp) { s ->
                if (icon != null && !friend.isPending) FriendIconView(friend.id, friend.name, icon, s)
                else Box(Modifier.size(s).clip(CircleShape)
                    .background(if (friend.isPending) Brush.linearGradient(listOf(T.glass, T.glass)) else Brush.linearGradient(colors))
                    .then(if (friend.isPending) Modifier.drawBehind {
                        drawCircle(Color.White.copy(alpha = 0.3f), radius = size.minDimension / 2 - 0.5.dp.toPx(),
                            style = Stroke(1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx()))))
                    } else Modifier), contentAlignment = Alignment.Center) {
                    Txt(nameInitials(friend.name), size = (s.value * 0.38f).sp, weight = FontWeight.Black,
                        color = if (friend.isPending) T.ink.copy(alpha = 0.75f) else Color.White, maxLines = 1)
                }
            }
            if (hasNew) Box(Modifier.align(Alignment.TopEnd).size(12.dp).clip(CircleShape).background(T.warn).border(2.dp, T.bg, CircleShape))
        }
        Txt(if (friend.isPending) friend.handle else first(friend.name), size = T.caption, color = T.ink.copy(alpha = if (friend.isPending) 0.75f else 0.9f), maxLines = 1)
        if (friend.isPending) {
            Box(Modifier.clip(CircleShape).border(1.dp, T.line, CircleShape).padding(horizontal = 6.dp, vertical = 1.dp)) {
                Txt(if (friend.incoming) "Wants to connect" else "Pending", size = 10.5.sp, weight = FontWeight.SemiBold, color = T.muted, maxLines = 1)
            }
        } else if (match != null) {
            Box(Modifier.clip(CircleShape).background(if (match >= 85) T.cyan else T.green).padding(horizontal = 6.dp, vertical = 1.dp)) {
                Txt("$match%", size = 10.5.sp, weight = FontWeight.Black, color = T.accentInk)
            }
        }
    }
}

/** A "…" menu with Report and Block. */
@Composable
private fun MoreMenu(friend: Friend, reportLabel: String, onReport: () -> Unit, onBlock: () -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        Box(Modifier.size(30.dp).clickable { expanded = true }, contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.MoreHoriz, "More options for ${friend.name}", tint = T.muted)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }, containerColor = T.panel) {
            DropdownMenuItem(text = { Txt(reportLabel) }, leadingIcon = { Icon(Icons.Filled.Flag, null, tint = T.ink) },
                onClick = { expanded = false; onReport() })
            DropdownMenuItem(text = { Txt("Block ${friend.handle}", color = T.hot) }, leadingIcon = { Icon(Icons.Filled.Block, null, tint = T.hot) },
                onClick = { expanded = false; onBlock() })
        }
    }
}

@Composable
private fun RequestRow(friend: Friend) {
    val store = AppStore
    var reporting by remember { mutableStateOf<SafetyTarget?>(null) }
    var blocking by remember { mutableStateOf<SafetyTarget?>(null) }
    val showsHandle = friend.handle.isNotEmpty() && friend.handle != friend.name
    val shape = RoundedCornerShape(20.dp)
    Column(Modifier.fillMaxWidth().clip(shape).background(Brush.linearGradient(listOf(T.blue.copy(alpha = 0.18f), T.green.copy(alpha = 0.10f))))
        .border(1.dp, T.cyan.copy(alpha = 0.35f), shape).padding(14.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.border(2.dp, T.cyan.copy(alpha = 0.55f), CircleShape).padding(3.dp)) { FriendAvatar(friend, 50.dp) }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Txt("FRIEND REQUEST", size = 10.sp, weight = FontWeight.Black, tracking = 0.8.sp, color = T.cyan)
                Txt(friend.name, size = T.body, weight = FontWeight.SemiBold, maxLines = 1)
                Txt(if (showsHandle) "${friend.handle} wants to join your circle" else "Wants to join your circle", size = T.caption, color = T.muted, maxLines = 2)
            }
            if (store.isCloud && !friend.isSample) MoreMenu(friend, "Report", { reporting = SafetyTarget(friend) }, { blocking = SafetyTarget(friend) })
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.weight(1f).height(42.dp).clip(RoundedCornerShape(13.dp)).background(T.gradient).clickable {
                store.respondToFriend(friend, true); Router.say("You and ${friend.name} are now friends")
            }, contentAlignment = Alignment.Center) { Txt("Accept", weight = FontWeight.Black, color = T.accentInk) }
            Box(Modifier.weight(1f).height(42.dp).clip(RoundedCornerShape(13.dp)).background(T.glass).border(1.dp, T.line, RoundedCornerShape(13.dp))
                .clickable { store.respondToFriend(friend, false) }, contentAlignment = Alignment.Center) {
                Txt("Decline", weight = FontWeight.Bold, color = T.ink.copy(alpha = 0.85f))
            }
        }
    }
    SafetyDialogs(reporting, blocking, onDone = { reporting = null; blocking = null })
}

/** Friend requests: the two newest as cards, the rest behind "Show N more requests". */
@Composable
private fun RequestList(requests: List<Friend>) {
    var showAll by remember { mutableStateOf(false) }
    val shown = if (showAll) requests else requests.take(2)
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        shown.forEach { f -> key(f.id) { RequestRow(f) } }
        if (requests.size > 2) Row(Modifier.fillMaxWidth().clickable { showAll = !showAll }.padding(top = 2.dp), horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically) {
            Icon(if (showAll) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown, null, tint = T.cyan, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(4.dp))
            Txt(if (showAll) "Show fewer" else "Show ${requests.size - 2} more requests", size = T.footnote, weight = FontWeight.SemiBold, color = T.cyan)
        }
    }
}

@Composable
private fun SuggestionCard(sug: Suggestion) {
    val store = AppStore
    store.observe()
    val context = LocalContext.current
    val f = store.friend(sug.friendID) ?: return
    val item = Catalog.item(sug.itemID) ?: return
    val best = store.best(item)
    val notInSize = best?.second?.notInSize ?: false
    val note = sug.note.trim()
    var reply by remember { mutableStateOf("") }
    var replying by remember { mutableStateOf(false) }
    var replied by remember { mutableStateOf(false) }
    var reporting by remember { mutableStateOf<SafetyTarget?>(null) }
    var blocking by remember { mutableStateOf<SafetyTarget?>(null) }
    fun send() {
        val t = reply.trim()
        if (t.isEmpty()) return
        store.replyToSuggestion(sug, t)
        reply = ""; replied = true; replying = false
    }
    Column(Modifier.fillMaxWidth()) {
        Hairline()
        Column(Modifier.padding(vertical = 18.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                FriendAvatar(f, 24.dp); Spacer(Modifier.width(9.dp))
                Txt(f.name, size = T.footnote, weight = FontWeight.Bold, maxLines = 1)
                Txt(" · ${Fmt.ago(sug.date)}", size = T.footnote, color = T.muted, maxLines = 1, modifier = Modifier.weight(1f))
                if (store.isCloud && !f.isSample) MoreMenu(f, "Report this", { reporting = SafetyTarget(f, sug.id) }, { blocking = SafetyTarget(f) })
            }
            // Tap the product to see the store's page in Baget before deciding.
            val link = BuyLink.tracked(item, "suggestion")
            Row(Modifier.fillMaxWidth().clickable(enabled = link != null) { link?.let { storePage(context, it) } }, verticalAlignment = Alignment.CenterVertically) {
                ProductThumb(item, 104.dp)
                Spacer(Modifier.width(16.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    if (item.brand.isNotEmpty()) Txt(item.brand, size = 16.sp, weight = FontWeight.SemiBold)
                    Txt(item.title, weight = FontWeight.SemiBold, maxLines = 3)
                    Txt(listOfNotNull(if (item.priceKnown && item.price > 0) item.priceLabel else null, item.source.ifEmpty { null },
                        if (notInSize) "not in your size" else null).joinToString(" · "), size = T.footnote, color = T.muted, modifier = Modifier.padding(top = 2.dp))
                    if (link != null) Row(Modifier.padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.AutoMirrored.Filled.OpenInNew, null, tint = T.cyan, modifier = Modifier.size(14.dp)); Spacer(Modifier.width(5.dp))
                        Txt("View it at ${item.source}", size = T.footnote, weight = FontWeight.SemiBold, color = T.cyan, maxLines = 1)
                    }
                }
            }
            if (note.isNotEmpty()) Row(Modifier.height(IntrinsicSize.Min)) {
                Box(Modifier.width(2.dp).fillMaxHeight().background(Color.White.copy(alpha = 0.25f)))
                Spacer(Modifier.width(12.dp))
                Txt(note, size = 16.sp, italic = true, color = T.ink.copy(alpha = 0.9f))
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                QuietPrimary("Add to Finds") {
                    store.acceptSuggestion(sug.id)
                    Analytics.track(AnalyticsEvent.SUGGESTION_ACCEPTED, mapOf("category" to item.category.raw))
                    Router.say(if (best != null && !notInSize) "Saved to Finds. ${best.first.name} learned from it." else "Saved to your Finds")
                }
                Txt("Not for me", color = T.ink.copy(alpha = 0.8f), modifier = Modifier.clickable {
                    store.passSuggestion(sug.id)
                    Router.say("Passed")
                    Analytics.track(AnalyticsEvent.SUGGESTION_PASSED, mapOf("category" to item.category.raw))
                })
                Spacer(Modifier.weight(1f))
                if (store.isCloud && sug.shareID != null && !replied) {
                    Txt(if (replying) "Cancel" else "Reply", color = T.muted, modifier = Modifier.clickable { replying = !replying })
                }
            }
            if (replied) Txt("Reply sent to ${f.name}", size = T.caption, color = T.muted)
            else if (replying) Row(verticalAlignment = Alignment.CenterVertically) {
                Field(reply, { reply = it }, "Reply to ${first(f.name)}", Modifier.weight(1f),
                    keyboard = KeyboardOptions(imeAction = ImeAction.Send), actions = KeyboardActions(onSend = { send() }))
                Spacer(Modifier.width(8.dp))
                Txt("Send", weight = FontWeight.SemiBold, color = if (reply.isBlank()) T.muted else T.ink,
                    modifier = Modifier.clickable(enabled = reply.isNotBlank()) { send() })
            }
        }
    }
    SafetyDialogs(reporting, blocking, onDone = { reporting = null; blocking = null })
}

/** Something you sent, with your friends' replies underneath. */
@Composable
private fun SentRow(share: Share) {
    val store = AppStore
    val item = Catalog.item(share.itemID) ?: return
    val recipients = share.to.mapNotNull { store.friend(it)?.name }.joinToString(", ") { first(it) }
    Column {
        Hairline()
        Row(Modifier.padding(vertical = 12.dp), verticalAlignment = Alignment.Top) {
            ProductThumb(item, 50.dp)
            Spacer(Modifier.width(12.dp))
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row {
                    Txt(item.title, maxLines = 2, modifier = Modifier.weight(1f, fill = false))
                    Txt(" to $recipients · ${Fmt.ago(share.date)}", color = T.muted, maxLines = 2)
                }
                share.replies.forEach { r ->
                    store.friend(r.friendID)?.let { f ->
                        Box(Modifier.clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.05f)).padding(horizontal = 10.dp, vertical = 7.dp)) {
                            Row {
                                Txt(first(f.name), size = T.footnote, weight = FontWeight.Bold)
                                Txt("  ${r.text}", size = T.footnote)
                            }
                        }
                    }
                }
            }
        }
    }
}

/** A pending or sample friend's page: what you share in taste, what they hunt, what they've sent you, and suggesting something back. */
@Composable
private fun FriendSheet(friend: Friend, onClose: () -> Unit) {
    val store = AppStore
    store.observe()
    var reporting by remember { mutableStateOf<SafetyTarget?>(null) }
    var blocking by remember { mutableStateOf<SafetyTarget?>(null) }
    var confirmRemove by remember { mutableStateOf(false) }
    val firstName = first(friend.name)
    val both = store.sharedTaste(friend)
    val sent = store.state.suggestions.filter { it.friendID == friend.id }.sortedByDescending { it.date }.mapNotNull { Catalog.item(it.itemID) }.take(4)
    PopSheet(onClose) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(top = 50.dp, bottom = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally) {
            FriendAvatar(friend, 84.dp)
            Txt(if (friend.isPending) friend.handle else friend.name, size = 26.sp, weight = FontWeight.SemiBold, modifier = Modifier.padding(top = 12.dp))
            Txt(if (friend.isPending) "Request sent · waiting for them to accept" else friend.handle, color = T.muted, modifier = Modifier.padding(top = 4.dp))
            Column(Modifier.fillMaxWidth().padding(top = 24.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
                if (both.isNotEmpty()) LabeledChips("You both like", both.take(6))
                if (friend.hunts.isNotEmpty()) LabeledChips("$firstName hunts", friend.hunts.map { it.info.label })
                if (sent.isNotEmpty()) Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Txt("RECENTLY SENT YOU", size = T.caption, weight = FontWeight.SemiBold, tracking = 1.6.sp, color = T.muted)
                    sent.chunked(2).forEach { pair ->
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) { pair.forEach { ProductThumb(it, 150.dp) } }
                    }
                }
            }
            if (friend.isPending) Txt("Cancel request", color = T.muted, modifier = Modifier.padding(top = 28.dp).clickable { store.removeFriend(friend.id); onClose() })
            else {
                Box(Modifier.padding(top = 28.dp)) { QuietPrimary("Suggest something for $firstName") { onClose(); Router.open(Sheet.SuggestFor(friend.id)) } }
                Txt("Remove friend", size = T.footnote, color = T.muted, modifier = Modifier.padding(top = 16.dp).clickable { confirmRemove = true })
            }
            if (store.isCloud && !friend.isSample) Row(Modifier.padding(top = 18.dp), horizontalArrangement = Arrangement.spacedBy(26.dp)) {
                Txt("Report", size = T.footnote, weight = FontWeight.SemiBold, color = T.warn, modifier = Modifier.clickable { reporting = SafetyTarget(friend) })
                Txt("Block ${friend.handle}", size = T.footnote, weight = FontWeight.SemiBold, color = T.hot, modifier = Modifier.clickable { blocking = SafetyTarget(friend) })
            }
        }
        Box(Modifier.align(Alignment.TopEnd).padding(top = 14.dp, end = 16.dp)) { RoundClose(onClose) }
    }
    SafetyDialogs(reporting, blocking, onDone = { reporting = null; blocking = null }, onBlocked = onClose)
    if (confirmRemove) AlertDialog(onDismissRequest = { confirmRemove = false }, containerColor = T.panel,
        title = { Txt("Remove ${friend.name}?", size = T.body, weight = FontWeight.Bold) },
        confirmButton = { TextButton(onClick = {
            confirmRemove = false; store.removeFriend(friend.id); Router.say("Removed ${friend.name}"); onClose()
        }) { Txt("Remove", color = T.hot, weight = FontWeight.Bold) } },
        dismissButton = { TextButton(onClick = { confirmRemove = false }) { Txt("Cancel", color = T.muted) } })
}

@Composable
private fun LabeledChips(title: String, items: List<String>) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Txt(title.uppercase(), size = T.caption, weight = FontWeight.SemiBold, tracking = 1.6.sp, color = T.muted)
        Flow(8.dp) {
            items.forEach { t ->
                Box(Modifier.clip(CircleShape).border(1.dp, Color.White.copy(alpha = 0.18f), CircleShape).padding(horizontal = 12.dp, vertical = 6.dp)) {
                    Txt(t, size = T.footnote)
                }
            }
        }
    }
}

@Composable
private fun AddFriendSheet(onClose: () -> Unit) {
    val store = AppStore
    var handle by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var working by remember { mutableStateOf(false) }
    fun add() {
        if (handle.isEmpty()) return
        if (store.isCloud) {
            working = true
            store.scope.launch {
                val (ok, msg) = store.addFriendCloud(handle)
                working = false
                if (ok) { Router.say(msg); onClose() } else error = msg
            }
        } else {
            error = store.addFriend(handle)
            if (error == null) { Analytics.track(AnalyticsEvent.FRIEND_INVITED); Router.say("Invite sent"); onClose() }
        }
    }
    PopSheet(onClose) {
        Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Txt("Add a friend", size = 24.sp, weight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                RoundClose(onClose)
            }
            Txt("Type their username. Yours is @${store.state.profile?.handle ?: "you"}, and you can change it in Settings.", size = T.footnote, color = T.muted)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Field(handle, { handle = it }, if (store.isCloud) "@username" else "@username or email", Modifier.weight(1f),
                    keyboard = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, imeAction = ImeAction.Go),
                    actions = KeyboardActions(onGo = { add() }))
                Spacer(Modifier.width(8.dp))
                QuietPrimary(if (working) "…" else "Add", enabled = !working && handle.isNotEmpty()) { add() }
            }
            error?.let { Txt(it, size = T.footnote, color = T.hot) }
        }
    }
}

@Composable
private fun FriendsPrivacySheet(onClose: () -> Unit) {
    val store = AppStore
    val s = store.observe()
    PopSheet(onClose) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Txt("What friends can see", size = 24.sp, weight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                RoundClose(onClose)
            }
            SwitchRow("My taste", "The styles, brands and creators your scouts hunt, so what friends send you lands better.", s.settings.shareTasteWithFriends) {
                s.settings.shareTasteWithFriends = it; store.save()
            }
            if (store.isCloud) BirthdayRow()
            SwitchRow("What I buy", "Off by default. Purchases and prices stay private unless you turn this on.", s.settings.sharePurchasesWithFriends) {
                s.settings.sharePurchasesWithFriends = it; store.save()
            }
        }
    }
}

/** Settings > Friends and privacy. */
@Composable
fun PrivacySwitches() {
    val store = AppStore
    val s = store.observe()
    SwitchRow("My taste profile", "The styles, makers and creators your scouts hunt, so suggestions land better.", s.settings.shareTasteWithFriends) {
        s.settings.shareTasteWithFriends = it; store.save()
    }
    SwitchRow("What I buy", "Off by default. Purchases and prices stay private unless you turn this on.", s.settings.sharePurchasesWithFriends) {
        s.settings.sharePurchasesWithFriends = it; store.save()
    }
}

@Composable
fun ShareSheet(itemID: String, preselect: String?, isSuggestion: Boolean) {
    val store = AppStore
    val s = store.observe()
    val friends = s.friends.filter { !it.isPending }
    val picked = remember { mutableStateListOf<String>().apply { if (preselect != null) add(preselect) else if (friends.size == 1) add(friends[0].id) } }
    var note by remember { mutableStateOf("") }
    SheetFrame(if (isSuggestion) "Suggest" else "Share", leading = "Cancel", trailing = "Send", trailingEnabled = picked.isNotEmpty(), onTrailing = {
        store.share(itemID, picked.toList(), note.trim(), isSuggestion)
        Analytics.track(if (isSuggestion) AnalyticsEvent.SUGGESTION_SENT else AnalyticsEvent.ITEM_SHARED, mapOf("friends" to picked.size, "hasNote" to note.isNotEmpty()))
        Router.say("Sent")
        Router.close()
    }) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
            Catalog.item(itemID)?.let { item ->
                FormSection {
                    Txt(item.title, size = T.body, weight = FontWeight.SemiBold, modifier = Modifier.padding(top = 6.dp))
                    Txt("${item.category.info.label} · ${item.priceLabel} at ${item.source}", size = T.caption, color = T.muted, modifier = Modifier.padding(bottom = 6.dp))
                }
            }
            FormSection("Send to") {
                if (friends.isEmpty()) Txt("Add a friend first, on the Friends tab.", color = T.muted, modifier = Modifier.padding(vertical = 10.dp))
                friends.forEach { f ->
                    Row(Modifier.fillMaxWidth().clickable { if (f.id in picked) picked.remove(f.id) else picked.add(f.id) }.padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        FriendAvatar(f, 28.dp); Spacer(Modifier.width(10.dp))
                        Column(Modifier.weight(1f)) { Txt(f.name); Txt(f.handle, size = T.caption, color = T.muted) }
                        Icon(if (f.id in picked) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked, null, tint = T.accent)
                    }
                }
            }
            FormSection("Add a note") {
                Field(note, { note = it }, if (isSuggestion) "Why it's perfect for them" else "What do you think?", Modifier.fillMaxWidth().padding(vertical = 6.dp))
            }
        }
    }
}

@Composable
fun SuggestForSheet(friendID: String) {
    val store = AppStore
    store.observe()
    SheetFrame("Suggest something", leading = "Cancel", trailing = null) {
        val f = store.friend(friendID) ?: return@SheetFrame
        Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Txt("Picked from today's listings that match what ${first(f.name)} hunts${if (f.likes.isEmpty()) "" else ": ${f.likes.joinToString(", ")}"}.",
                size = T.footnote, color = T.muted)
            val picks = store.friendPicks(f)
            if (picks.isEmpty()) Txt("Nothing matches their taste right now.", color = T.muted)
            picks.forEach { item ->
                Column(Modifier.fillMaxWidth().glass().clickable { Router.close(); Router.open(Sheet.ShareItem(item.id, f.id, true)) }.padding(14.dp)) {
                    Txt(item.title)
                    Txt("${item.category.info.label} · ${item.priceLabel}", size = T.caption, color = T.muted)
                }
            }
        }
    }
}

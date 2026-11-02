package app.baget.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.baget.engine.*
import app.baget.model.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Which sheet is open. One place, so any screen can open any sheet. */
sealed class Sheet {
    data object Inbox : Sheet()
    data object Deploy : Sheet()
    data object CustomizeBar : Sheet()
    data object Profile : Sheet()
    data class Checkout(val findID: String) : Sheet()
    data class ShareItem(val itemID: String, val friendID: String?, val suggestion: Boolean) : Sheet()
    data class SuggestFor(val friendID: String) : Sheet()
    data class TastePhoto(val agentID: String) : Sheet()
    data class Chat(val agentID: String, val aboutFindID: String? = null) : Sheet()
    data class AgentIcon(val agentID: String) : Sheet()
    data object Swipe : Sheet()
    data object Taste : Sheet()
    data object Pro : Sheet()
    data object Feedback : Sheet()
    data object HowTo : Sheet()
    data class Reminder(val itemID: String, val findID: String?) : Sheet()
    data object NewScout : Sheet()
    data object ForYou : Sheet()
}

/** The scout you just sent from "Send a new scout" (its confirmation card shows on Today). */
data class ScoutSent(val agentID: String, val intro: String)

enum class AppTab { LIVE, FINDS, SQUAD, FRIENDS }

object Router {
    var tab by mutableStateOf(AppTab.LIVE)
    /** A stack, so a sheet can open another (Swipe → Checkout) and Back closes the top one. */
    val sheets = mutableStateListOf<Sheet>()
    var deployPrefill by mutableStateOf<Mission?>(null)
    var toast by mutableStateOf<String?>(null)
    /** Set when Buy opens a store; when you come back, Baget asks whether you bought it. */
    var buyOpened: String? = null
    var askBought by mutableStateOf<String?>(null)
    /** A find to scroll to and highlight on the Finds tab. */
    var focusFind by mutableStateOf<String?>(null)
    var scoutSent by mutableStateOf<ScoutSent?>(null)

    val sheet: Sheet? get() = sheets.lastOrNull()
    fun open(s: Sheet) { sheets.add(s) }
    fun close() { if (sheets.isNotEmpty()) sheets.removeAt(sheets.lastIndex) }
    fun closeAll() { sheets.clear() }

    /** Opens an item in Finds. If it isn't there yet, its agent adds it first. */
    fun openInFinds(story: Story) {
        val store = AppStore
        var find = store.state.finds.firstOrNull { it.itemID == story.item.id }
        if (find == null && story.agentID != null && story.match?.notInSize != true) {
            find = store.ensureFind(story.agentID, story.item.id)
            if (find != null) Analytics.track(AnalyticsEvent.STORY_SENT_TO_AGENT, mapOf("category" to story.item.category.raw, "from" to "tap"))
        }
        val f = find ?: run {
            say(if (story.agentID == null) "Set up a ${story.item.category.info.label.lowercase()} scout to track this" else "Not in your size, so it isn't in Finds")
            return
        }
        when (f.status) {
            FindStatus.PASSED -> store.undoPass(f.id)            // you went looking for it, so bring it back
            FindStatus.REMOVED -> store.restoreFind(f.id)
            FindStatus.ACQUIRED -> { say("You bought this one"); return }
            else -> {}
        }
        focusFind = f.id
        tab = AppTab.FINDS
        closeAll()
    }

    fun say(text: String) {
        toast = text
        AppStore.scope.launch {
            delay(2600)
            if (toast == text) toast = null
        }
    }
}

// MARK: Icons

/** Tile colors for initials and emoji icons. */
object AvatarPalette {
    val all: List<Brush> = listOf(
        Brush.linearGradient(listOf(T.blue, T.cyan, T.green)),
        Brush.linearGradient(listOf(Color(0.23f, 0.51f, 1.0f), Color(0.55f, 0.36f, 1.0f))),
        Brush.linearGradient(listOf(Color(1.0f, 0.36f, 0.49f), Color(1.0f, 0.62f, 0.30f))),
        Brush.linearGradient(listOf(Color(1.0f, 0.78f, 0.34f), Color(0.98f, 0.52f, 0.20f))),
        Brush.linearGradient(listOf(Color(0.20f, 0.90f, 0.65f), Color(0.05f, 0.55f, 0.45f))),
        Brush.linearGradient(listOf(Color(0.86f, 0.40f, 0.95f), Color(0.45f, 0.25f, 0.85f))),
        Brush.linearGradient(listOf(Color(0.40f, 0.45f, 0.55f), Color(0.16f, 0.19f, 0.26f))),
        Brush.linearGradient(listOf(Color(0.96f, 0.96f, 0.98f), Color(0.72f, 0.78f, 0.86f))),
    )
    /** Dark text on the light tiles, white on the rest. */
    fun ink(i: Int): Color = if (i in listOf(0, 3, 4, 7)) T.accentInk else Color.White
    fun gradient(i: Int): Brush = all[((i % all.size) + all.size) % all.size]

    val emojis = listOf("🔥", "👟", "🧢", "🕶️", "⌚️", "💎", "🖤", "🌊", "🌿", "🍸", "🏎️", "🛋️", "🎧", "📸", "🎨", "🧸",
        "🐉", "🦍", "👑", "⚡️", "🌙", "🍀", "🎯", "🕵️")

    /** The first emoji in the text, so typing a word doesn't become an icon. */
    fun firstEmoji(text: String): String? {
        val it = java.text.BreakIterator.getCharacterInstance()
        it.setText(text)
        var start = it.first()
        var end = it.next()
        while (end != java.text.BreakIterator.DONE) {
            val g = text.substring(start, end)
            val cp = g.codePointAt(0)
            if (cp >= 0x2190 && !Character.isLetterOrDigit(cp)) return g
            start = end; end = it.next()
        }
        return null
    }
}

/** An agent's icon: its photo, emoji, or an emoji that fits what it hunts, on a colored tile. */
@Composable
fun AgentAvatar(agent: Agent?, size: Dp = 36.dp, preview: Avatar? = null, previewPhoto: android.graphics.Bitmap? = null,
                nameOverride: String? = null, mission: Mission? = null) {
    val store = AppStore
    val icon = preview ?: agent?.icon
    val name = nameOverride ?: agent?.name ?: "Scout"
    val shape = RoundedCornerShape(size * 0.3f)
    val photo = if (icon?.style == Avatar.Style.PHOTO) previewPhoto ?: store.iconImage(icon.photoID) else null
    Box(Modifier.size(size).clip(shape).background(AvatarPalette.gradient(icon?.color ?: 0)).border(1.dp, T.line, shape), contentAlignment = Alignment.Center) {
        if (photo != null) BitmapImage(photo, Modifier.fillMaxSize())
        else {
            val auto = if (agent != null && nameOverride == null) AgentEmoji.pick(agent)
                       else AgentEmoji.pick(name, agent?.mission ?: mission, agent?.keywords ?: emptyList())
            Txt(if (icon?.style == Avatar.Style.EMOJI) icon.emoji.ifEmpty { auto } else auto, size = (size.value * 0.5f).sp, maxLines = 1)
        }
    }
}

/** Your icon: a photo, an emoji, a Baget icon or your initials, inside the ring you wear. */
@Composable
fun AvatarView(size: Dp = 32.dp, showRing: Boolean = true, preview: Avatar? = null) {
    val store = AppStore
    val a = preview ?: store.observe().avatar
    val photo = store.avatarImage
    val ring = if (showRing) Ring.of(store.rings?.wearing) else null
    // A ring you just earned: say so once.
    val earned = FriendsState.ringEarned
    LaunchedEffect(earned) {
        Ring.of(earned)?.let { Router.say("Ring earned: ${it.title}. Wear it from your icon in Settings.") }
        if (earned != null) FriendsState.ringEarned = null
    }
    RingFrame(ring, size) { s ->
        Box(Modifier.size(s).clip(CircleShape).background(AvatarFill.brush(a.color, store.myPalette)).border(1.dp, T.line, CircleShape),
            contentAlignment = Alignment.Center) {
            when {
                a.style == Avatar.Style.PHOTO && photo != null -> BitmapImage(photo, Modifier.fillMaxSize())
                a.style == Avatar.Style.EMOJI -> Txt(a.emoji, size = (s.value * 0.5f).sp, maxLines = 1)
                a.style == Avatar.Style.BAGET -> androidx.compose.material3.Icon(BagetGlyph.icon(a.glyph), null, tint = AvatarFill.ink(a.color),
                    modifier = Modifier.size(s * 0.5f))
                else -> Txt(store.initials, size = (s.value * 0.38f).sp, weight = FontWeight.Black, color = AvatarFill.ink(a.color), maxLines = 1)
            }
        }
    }
}

/** Initials for someone's name: first and last word, or the first letter. */
fun nameInitials(name: String): String {
    val words = name.trim('@', ' ').split(" ").filter { it.isNotEmpty() }
    if (words.size >= 2) return (words.first().take(1) + words.last().take(1)).uppercase()
    return (words.firstOrNull() ?: "?").take(1).uppercase()
}

/** Someone's chosen icon, drawn the same way as your own (AvatarView). No ring: wrap it in RingFrame for that. */
@Composable
fun FriendIconView(friendID: String, name: String, icon: Avatar, size: Dp) {
    val store = AppStore
    val photo = if (icon.style == Avatar.Style.PHOTO) store.friendIconImage(friendID, icon.photoID) else null
    Box(Modifier.size(size).clip(CircleShape).background(if (photo != null) Brush.linearGradient(listOf(T.panel, T.panel)) else AvatarFill.brush(icon.color, store.friendPalettes[friendID])),
        contentAlignment = Alignment.Center) {
        when {
            photo != null -> BitmapImage(photo, Modifier.fillMaxSize())
            icon.style == Avatar.Style.EMOJI -> Txt(icon.emoji, size = (size.value * 0.5f).sp, maxLines = 1)
            icon.style == Avatar.Style.BAGET -> androidx.compose.material3.Icon(BagetGlyph.icon(icon.glyph), null, tint = AvatarFill.ink(icon.color),
                modifier = Modifier.size(size * 0.5f))
            else -> Txt(nameInitials(name), size = (size.value * 0.38f).sp, weight = FontWeight.Black, color = AvatarFill.ink(icon.color), maxLines = 1)
        }
    }
}

/** A friend's icon: what they picked in Settings, inside the ring they wear; an initial in a thin ring until they pick one. */
@Composable
fun FriendAvatar(friend: Friend, size: Dp = 32.dp) {
    val store = AppStore
    val hidden = friend.isPending && !friend.incoming
    val icon = if (hidden) null else store.friendIcons[friend.id]
    RingFrame(if (hidden) null else Ring.of(store.friendRings[friend.id]), size) { s ->
        if (icon != null) FriendIconView(friend.id, friend.name, icon, s)
        else Box(Modifier.size(s).clip(CircleShape).background(Color.White.copy(alpha = 0.04f)).border(1.dp, Color.White.copy(alpha = 0.22f), CircleShape),
            contentAlignment = Alignment.Center) {
            Txt(nameInitials(friend.name), size = (s.value * 0.4f).sp, weight = FontWeight.SemiBold, maxLines = 1)
        }
    }
}

/** The sender's icon on a notification: the agent's own icon, or Baget's. */
@Composable
fun NoteIcon(note: AppNote) {
    val a = if (note.friendID == null) AppStore.agent(note.agentID) else null
    if (a != null) AgentAvatar(a, 36.dp) else AppIcon(36.dp)
}

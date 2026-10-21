package app.baget.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.Icon
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.baget.engine.*
import app.baget.model.*
import app.baget.ui.*
import kotlinx.coroutines.launch

@Composable
fun FriendsScreen() {
    val store = AppStore
    val s = store.observe()
    var handle by remember { mutableStateOf("") }
    var addError by remember { mutableStateOf<String?>(null) }
    var adding by remember { mutableStateOf(false) }
    val suggestions = s.suggestions.sortedWith(compareBy<Suggestion> { if (it.status == SuggestionStatus.NEW) 0 else 1 }.thenByDescending { it.date })

    fun invite() {
        if (store.isCloud) {
            adding = true
            store.scope.launch {
                val (ok, msg) = store.addFriendCloud(handle)
                adding = false
                if (ok) { addError = null; handle = ""; Router.say(msg) } else addError = msg
            }
        } else {
            addError = store.addFriend(handle)
            if (addError == null) { Analytics.track(AnalyticsEvent.FRIEND_INVITED); Router.say("Invite sent"); handle = "" }
        }
    }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)) {
        SectionTitle("Suggested by friends")
        if (suggestions.isEmpty()) EmptyCard("No suggestions yet. When friends spot something for you, it shows up here.")
        suggestions.forEach { key(it.id) { SuggestionCard(it) } }

        SectionTitle("Your friends")
        if (s.friends.isEmpty()) EmptyCard("No friends yet. Add someone by their Baget handle.")
        s.friends.toList().forEach { key(it.id) { FriendCard(it) } }

        Column(Modifier.fillMaxWidth().glassCard(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Kick("Add a friend")
            Row(verticalAlignment = Alignment.CenterVertically) {
                Field(handle, { handle = it }, if (store.isCloud) "@handle" else "@handle or email", Modifier.weight(1f))
                Spacer(Modifier.width(8.dp))
                PrimaryButton("Add", Modifier.width(96.dp), busy = adding) { invite() }
            }
            addError?.let { Txt(it, size = T.footnote, color = T.hot) }
            Txt("Your handle is @${s.profile?.handle ?: "you"}. Friends on Baget can suggest things for you and see what you share.", size = T.caption, color = T.muted)
        }

        SectionTitle("Shared with friends")
        if (s.shares.isEmpty()) EmptyCard("Nothing shared yet. Use Share on any find or story.")
        s.shares.forEach { sh -> key(sh.id) { ShareCard(sh) } }

        Column(Modifier.fillMaxWidth().glassCard(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Kick("What friends can see")
            PrivacySwitches()
        }
        if (!store.isCloud) Txt("Sample data: Dre, Maya and Sam are sample friends, and their replies are simulated.", size = T.caption, color = T.muted)
    }
}

@Composable
fun PrivacySwitches() {
    val store = AppStore
    val s = store.observe()
    SwitchRow("My taste profile", "The styles, makers and creators your agents hunt, so suggestions land better.", s.settings.shareTasteWithFriends) {
        s.settings.shareTasteWithFriends = it; store.save()
    }
    SwitchRow("What I buy", "Off by default. Purchases and prices stay private unless you turn this on.", s.settings.sharePurchasesWithFriends) {
        s.settings.sharePurchasesWithFriends = it; store.save()
    }
}

@Composable
private fun SuggestionCard(sug: Suggestion) {
    val store = AppStore
    store.observe()
    val f = store.friend(sug.friendID) ?: return
    val item = Catalog.item(sug.itemID) ?: return
    val best = store.best(item)
    val notInSize = best?.second?.notInSize ?: false
    var reply by remember { mutableStateOf("") }
    var replied by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().glassCard(highlighted = sug.status == SuggestionStatus.NEW), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            FriendAvatar(f); Spacer(Modifier.width(10.dp))
            Txt(f.name, size = T.footnote, weight = FontWeight.Bold)
            Txt(" suggested for you · ${Fmt.ago(sug.date)}", size = T.footnote, color = T.muted, maxLines = 1)
        }
        Txt("“${sug.note}”", size = T.body, italic = true)
        Column(Modifier.fillMaxWidth().glass(RoundedCornerShape(12.dp)).padding(10.dp)) {
            Txt(item.title, weight = FontWeight.SemiBold)
            Txt("${item.category.info.label} · ${Fmt.money(item.price)} at ${item.source}${if (notInSize) " · not in your size" else ""}", size = T.caption, color = T.muted)
        }
        when (sug.status) {
            SuggestionStatus.NEW -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PrimaryButton(if (best != null && !notInSize) "Send to ${best.first.name}" else "Save to my Finds", Modifier.weight(1f)) {
                    store.acceptSuggestion(sug.id)
                    Analytics.track(AnalyticsEvent.SUGGESTION_ACCEPTED, mapOf("category" to item.category.raw))
                    Router.say("Saved to your Finds. Your agent learned from it.")
                }
                GhostButton("Not for me", Modifier.weight(1f)) {
                    store.passSuggestion(sug.id)
                    Analytics.track(AnalyticsEvent.SUGGESTION_PASSED, mapOf("category" to item.category.raw))
                }
            }
            SuggestionStatus.SENT -> Txt("Saved to your Finds. Your agent learned from it.", size = T.footnote, color = T.green)
            SuggestionStatus.PASSED -> Txt("You passed. Your agent won't count it.", size = T.footnote, color = T.muted)
        }
        if (store.isCloud && sug.shareID != null) {
            if (replied) Txt("Reply sent to ${f.name}", size = T.caption, color = T.muted)
            else Row(verticalAlignment = Alignment.CenterVertically) {
                Field(reply, { reply = it }, "Reply to ${f.name.split(" ").first()}", Modifier.weight(1f))
                Spacer(Modifier.width(8.dp))
                GhostButton("Send", Modifier.width(80.dp), enabled = reply.isNotBlank()) {
                    store.replyToSuggestion(sug, reply.trim()); reply = ""; replied = true
                }
            }
        }
    }
}

@Composable
private fun FriendCard(friend: Friend) {
    val store = AppStore
    Column(Modifier.fillMaxWidth().glassCard(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            FriendAvatar(friend, 42.dp); Spacer(Modifier.width(12.dp))
            Column {
                Txt(if (friend.isPending && !friend.incoming) friend.handle else friend.name, size = T.body, weight = FontWeight.SemiBold)
                Txt(if (friend.isPending) (if (friend.incoming) "${friend.handle} wants to be friends" else "Request sent · waiting for them to accept")
                    else "${friend.handle}${if (friend.isSample) " · sample friend" else ""}", size = T.caption, color = T.muted)
            }
        }
        if (friend.isPending && friend.incoming) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            PrimaryButton("Accept", Modifier.weight(1f)) { store.respondToFriend(friend, true); Router.say("You and ${friend.name} are now friends") }
            GhostButton("Decline", Modifier.weight(1f)) { store.respondToFriend(friend, false) }
        } else if (friend.isPending && !friend.isSample) GhostButton("Cancel request", Modifier.fillMaxWidth()) { store.removeFriend(friend.id) }
        if (!friend.isPending) {
            if (friend.hunts.isNotEmpty()) Flow { friend.hunts.forEach { Tag(it.info.label) } }
            val both = store.sharedTaste(friend)
            if (both.isNotEmpty()) Row {
                Txt("You both like ", size = T.footnote, color = T.muted)
                Txt(both.take(3).joinToString(", "), size = T.footnote, weight = FontWeight.Bold)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PrimaryButton("Suggest something", Modifier.weight(1f)) { Router.open(Sheet.SuggestFor(friend.id)) }
                GhostButton("Remove", Modifier.weight(1f)) { store.removeFriend(friend.id); Router.say("Removed ${friend.name}") }
            }
        }
    }
}

@Composable
private fun ShareCard(share: Share) {
    val store = AppStore
    val item = Catalog.item(share.itemID) ?: return
    Column(Modifier.fillMaxWidth().glassCard(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Txt("${if (share.isSuggestion) "You suggested" else "You shared"} ${item.title}", weight = FontWeight.SemiBold)
        Txt("to ${share.to.mapNotNull { store.friend(it)?.name }.joinToString(", ")} · ${Fmt.ago(share.date)}", size = T.caption, color = T.muted)
        if (share.note.isNotEmpty()) Txt("“${share.note}”", size = T.footnote, italic = true)
        share.replies.forEach { r ->
            store.friend(r.friendID)?.let { f ->
                Row(verticalAlignment = Alignment.Top) {
                    FriendAvatar(f, 26.dp); Spacer(Modifier.width(8.dp))
                    Box(Modifier.glass(RoundedCornerShape(12.dp)).padding(horizontal = 10.dp, vertical = 7.dp)) { Txt("${f.name} ${r.text}", size = T.footnote) }
                }
            }
        }
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
                    Txt("${item.category.info.label} · ${Fmt.money(item.price)} at ${item.source}", size = T.caption, color = T.muted, modifier = Modifier.padding(bottom = 6.dp))
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
            Txt("Picked from today's listings that match what ${f.name.split(" ").first()} hunts${if (f.likes.isEmpty()) "" else ": ${f.likes.joinToString(", ")}"}.",
                size = T.footnote, color = T.muted)
            val picks = store.friendPicks(f)
            if (picks.isEmpty()) Txt("Nothing matches their taste right now.", color = T.muted)
            picks.forEach { item ->
                Column(Modifier.fillMaxWidth().glass().clickable { Router.close(); Router.open(Sheet.ShareItem(item.id, f.id, true)) }.padding(14.dp)) {
                    Txt(item.title)
                    Txt("${item.category.info.label} · ${Fmt.money(item.price)}", size = T.caption, color = T.muted)
                }
            }
        }
    }
}

package app.baget.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import app.baget.engine.*
import app.baget.model.*
import app.baget.ui.*
import kotlinx.coroutines.launch

/** A full-screen sheet opened from inside a screen or another sheet (Back or ✕ closes it). */
@Composable
fun PopSheet(onDismiss: () -> Unit, content: @Composable BoxScope.() -> Unit) {
    Dialog(onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false, dismissOnClickOutside = false)) {
        Box(Modifier.fillMaxSize().litBackground().statusBarsPadding().navigationBarsPadding().imePadding()) {
            content()
            val t = Router.toast
            AnimatedVisibility(t != null, modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 24.dp),
                enter = slideInVertically { it } + fadeIn(), exit = fadeOut()) {
                Box(Modifier.padding(horizontal = 20.dp).clip(CircleShape).background(T.panel).border(1.dp, T.line, CircleShape)
                    .padding(horizontal = 16.dp, vertical = 11.dp)) { Txt(t ?: "", weight = FontWeight.SemiBold) }
            }
        }
    }
}

/** The round ✕ in the top corner of a sheet. */
@Composable
fun RoundClose(onClick: () -> Unit) {
    Box(Modifier.size(34.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.10f)).border(1.dp, Color.White.copy(alpha = 0.12f), CircleShape)
        .clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(Icons.Filled.Close, "Close", tint = T.ink, modifier = Modifier.size(16.dp))
    }
}

/** Who's being reported or blocked. */
data class SafetyTarget(val userID: String, val name: String, val handle: String, val suggestionID: String? = null) {
    val label: String get() = handle.ifEmpty { name }
    constructor(f: Friend, suggestionID: String? = null) : this(f.id, f.name, f.handle, suggestionID)
}

/** Report and Block, wherever someone appears: confirms a block before doing it. */
@Composable
fun SafetyDialogs(reporting: SafetyTarget?, blocking: SafetyTarget?, onDone: () -> Unit, onBlocked: () -> Unit = {}) {
    val store = AppStore
    if (reporting != null) ReportSheet(reporting, onClose = onDone, onBlocked = onBlocked)
    if (blocking != null) AlertDialog(onDismissRequest = onDone, containerColor = T.panel,
        title = { Txt("Block ${blocking.label}?", size = T.body, weight = FontWeight.Bold) },
        text = { Txt("They won't be able to find you, add you or send you anything, and you won't see them. They aren't told. Unblock any time in Settings.", color = T.muted) },
        confirmButton = { TextButton(onClick = {
            val t = blocking
            onDone()
            store.scope.launch {
                if (store.blockUser(t.userID)) { Router.say("Blocked ${t.label}"); onBlocked() }
                else store.syncProblem?.let { Router.say(it) }
            }
        }) { Txt("Block", color = T.hot, weight = FontWeight.Bold) } },
        dismissButton = { TextButton(onClick = onDone) { Txt("Cancel", color = T.muted) } })
}

/** "Report @name": pick a reason, optionally block too. */
@Composable
private fun ReportSheet(target: SafetyTarget, onClose: () -> Unit, onBlocked: () -> Unit) {
    val store = AppStore
    var reason by remember { mutableStateOf<ReportReason?>(null) }
    var detail by remember { mutableStateOf("") }
    var alsoBlock by remember { mutableStateOf(true) }
    var sending by remember { mutableStateOf(false) }
    PopSheet(onClose) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Txt("Report ${target.label}", size = T.title3, weight = FontWeight.Black, modifier = Modifier.weight(1f))
                RoundClose(onClose)
            }
            Txt("The Baget team reviews every report within 24 hours. They won't know you reported them.", size = T.footnote, color = T.muted)
            ReportReason.entries.forEach { r ->
                val on = reason == r
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(13.dp)).background(T.glass)
                    .border(1.dp, if (on) T.cyan.copy(alpha = 0.6f) else T.line, RoundedCornerShape(13.dp)).clickable { reason = r }.padding(13.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Txt(r.label, modifier = Modifier.weight(1f))
                    Icon(if (on) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked, null, tint = if (on) T.cyan else T.muted)
                }
            }
            Field(detail, { detail = it }, "Anything to add? (optional)", Modifier.fillMaxWidth(), singleLine = false, minLines = 2, maxLines = 4)
            SwitchRow("Also block ${target.label}", null, alsoBlock) { alsoBlock = it }
            Box(Modifier.fillMaxWidth().height(52.dp).clip(RoundedCornerShape(16.dp))
                .background(Brush.horizontalGradient(listOf(Color(1f, 0.54f, 0.36f), T.hot)))
                .then(if (reason == null) Modifier.background(T.bg.copy(alpha = 0.5f)) else Modifier)
                .clickable(enabled = reason != null && !sending) {
                    val r = reason ?: return@clickable
                    sending = true
                    store.scope.launch {
                        val ok = store.reportUser(target.userID, r, detail, target.suggestionID)
                        if (!ok) { sending = false; store.syncProblem?.let { Router.say(it) }; return@launch }
                        val blocked = if (alsoBlock) store.blockUser(target.userID) else false
                        sending = false
                        Router.say(if (blocked) "Reported and blocked. Thanks for telling us." else "Reported. Thanks for telling us.")
                        onClose()
                        if (blocked) onBlocked()
                    }
                }, contentAlignment = Alignment.Center) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (sending) { Spinner(16.dp, Color.White); Spacer(Modifier.width(8.dp)) }
                    Txt("Send report", size = T.body, weight = FontWeight.Black, color = Color.White)
                }
            }
        }
    }
}

/** Settings > Blocked people: everyone you've blocked, with Unblock. */
@Composable
fun BlockedPeoplePage() {
    val store = AppStore
    var people by remember { mutableStateOf<List<BlockedPerson>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    LaunchedEffect(Unit) { people = store.blockedPeople(); loading = false }
    Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        when {
            loading -> Box(Modifier.fillMaxWidth().padding(top = 40.dp), contentAlignment = Alignment.Center) { Spinner() }
            people.isEmpty() -> Txt("You haven't blocked anyone.", color = T.muted)
            else -> FormSection(null, "Blocked people can't find you, add you or send you anything. Unblocking doesn't make you friends again.") {
                people.forEach { p ->
                    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Txt(p.displayName.ifEmpty { "@${p.handle}" })
                            Txt("@${p.handle}", size = T.caption, color = T.muted)
                        }
                        TextButton(onClick = {
                            store.scope.launch { store.unblockUser(p.userId); people = people.filter { it.userId != p.userId } }
                        }) { Txt("Unblock", color = T.cyan, weight = FontWeight.SemiBold) }
                    }
                }
            }
        }
    }
}

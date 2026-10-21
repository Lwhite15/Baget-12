package app.baget.ui.screens

import android.Manifest
import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.baget.engine.*
import app.baget.model.*
import app.baget.ui.*
import kotlinx.coroutines.launch

@Composable
fun InboxSheet() {
    val store = AppStore
    val s = store.observe()
    var tab by remember { mutableIntStateOf(0) }
    SheetFrame("Notifications", leading = if (tab == 0 && store.unreadCount > 0) "Mark all read" else null,
        onLeading = { store.markRead(s.notes.filter { !it.read }.map { it.id }) }) {
        Box(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) { Segmented(listOf("Inbox", "Background and alerts"), if (tab == 0) "Inbox" else "Background and alerts") { tab = if (it == "Inbox") 0 else 1 } }
        if (tab == 0) LazyColumn(contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (s.notes.isEmpty()) item { EmptyCard("Nothing yet. When your squad finds something, it'll text you here.") }
            items(s.notes.toList(), key = { it.id }) { n ->
                val shape = RoundedCornerShape(16.dp)
                Row(Modifier.fillMaxWidth().clip(shape).background(if (n.read) T.glass else T.accent.copy(alpha = 0.10f))
                    .border(1.dp, if (n.read) T.line else T.accent.copy(alpha = 0.45f), shape).clickable { openNote(n.id) }.padding(12.dp)) {
                    NoteIcon(n)
                    Spacer(Modifier.width(11.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Row {
                            Txt(store.noteSender(n), size = T.footnote, weight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                            Txt("${Fmt.ago(n.date)}${if (n.heldForMorning) " · held for morning" else ""}", size = T.caption2, color = T.muted)
                        }
                        Txt(n.body)
                    }
                }
            }
        } else AlertSettings(onSimulate = { tab = 0 })
    }
}

/** How often agents search, quiet hours, what they text you about, and metrics. */
@Composable
fun AlertSettings(onSimulate: () -> Unit = {}) {
    val store = AppStore
    val s = store.observe()
    val context = LocalContext.current
    var allowed by remember { mutableStateOf(Notifier.allowed(context)) }
    var metricsOn by remember { mutableStateOf(Analytics.enabled) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        allowed = Notifier.allowed(context)
        if (allowed) store.scope.launch { store.registerForPushIfAllowed() }
    }
    Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        if (!allowed) FormSection {
            Txt("Notifications are off for Baget. Turn them on so your squad can text you.", size = T.footnote, modifier = Modifier.padding(vertical = 6.dp))
            RowButton("Turn on notifications") {
                if (Build.VERSION.SDK_INT >= 33 && Notifier.needsPrompt(context)) ask.launch(Manifest.permission.POST_NOTIFICATIONS)
                else context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName))
            }
        }
        FormSection(footer = if (store.isCloud) "Your squad searches on our servers even when your phone is off. Each search costs a little, so less often is cheaper. You can always pull down on Today to check now."
            else "In the sample tour, sweeps are simulated each time you come back to the app.") {
            val opts = listOf(60 to "Every hour", 180 to "Every 3 hours", 360 to "Every 6 hours", 720 to "Twice a day", 1440 to "Once a day")
            Choice("Each agent searches the web", opts.map { it.second }, opts.indexOfFirst { it.first == s.settings.sweepMinutes }.coerceAtLeast(0)) {
                s.settings.sweepMinutes = opts[it].first; store.save()
            }
        }
        FormSection("How often Baget texts you", ((s.settings.pushLevel ?: PushLevel.BEST).blurb) + " Everything else still shows up in your inbox.") {
            PushLevel.entries.forEach { l ->
                Row(Modifier.fillMaxWidth().clickable { s.settings.pushLevel = l; store.save() }.padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    RadioButton(selected = (s.settings.pushLevel ?: PushLevel.BEST) == l, onClick = { s.settings.pushLevel = l; store.save() },
                        colors = RadioButtonDefaults.colors(selectedColor = T.cyan))
                    Txt(l.label)
                }
            }
        }
        FormSection {
            SwitchRow("Quiet hours, 10pm to 8am", "Non-urgent texts wait for morning. Restocks, purchases and drops starting within 90 minutes still come through.",
                s.settings.quietHours) { s.settings.quietHours = it; store.save() }
        }
        FormSection("Text me about") {
            NoteGroup.entries.forEach { g ->
                SwitchRow(g.label, checked = g in s.settings.groups) { on ->
                    if (on) s.settings.groups.add(g) else s.settings.groups.remove(g); store.save()
                }
            }
        }
        FormSection("Privacy") {
            SwitchRow("Share anonymous usage metrics", if (Analytics.configured) "Sent with a random install ID, never your name or email."
                else "No backend set up yet, so metrics stay on this phone.", metricsOn) { metricsOn = it; Analytics.enabled = it }
        }
        if (!store.isCloud) FormSection("Try it", "Fast-forwards three hours of background sweeps so you can see what your squad does while you're gone.") {
            RowButton("Simulate 3 hours away") {
                store.catchUp(180.0)
                Analytics.track(AnalyticsEvent.BACKGROUND_SIMULATED)
                onSimulate()
            }
        }
    }
}

package app.baget.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.baget.engine.*
import app.baget.model.*
import app.baget.ui.*
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

object ReminderFmt {
    fun long(ms: Long): String = SimpleDateFormat("EEE, MMM d, h:mm a", Locale.US).format(Date(ms))
    fun short(ms: Long): String {
        val c = Calendar.getInstance(); val d = Calendar.getInstance().apply { timeInMillis = ms }
        val today = c.get(Calendar.YEAR) == d.get(Calendar.YEAR) && c.get(Calendar.DAY_OF_YEAR) == d.get(Calendar.DAY_OF_YEAR)
        return SimpleDateFormat(if (today) "h:mm a" else "MMM d, h:mm a", Locale.US).format(Date(ms))
    }
}

/** "Remind me" on something that hasn't released yet: pick when the text should come. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReminderSheet(itemID: String, findID: String?) {
    val store = AppStore
    store.observe()
    val context = LocalContext.current
    val item = Catalog.item(itemID) ?: run { SheetFrame("Remind me") {}; return }
    val drop = item.dropAt ?: now()
    val current = store.reminder(item)
    var picking by remember { mutableStateOf(false) }
    val choices = listOf("When it drops" to 0, "15 minutes before" to 15, "1 hour before" to 60, "1 day before" to 1440, "3 days before" to 4320)

    fun set(offset: Int? = null, at: Long? = null) {
        if (store.setReminder(item, findID, offset, at)) {
            Router.say("I'll text you ${ReminderFmt.short(offset?.let { drop - it * 60_000L } ?: at ?: now())}")
            Router.close()
        } else Router.say("That time has already passed")
    }

    SheetFrame("Remind me", leading = "Close", trailing = null) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Txt(item.title, size = T.body, weight = FontWeight.SemiBold)
                Row {
                    Txt("Releases ${ReminderFmt.long(drop)} at ${item.source}", size = T.footnote, color = T.muted)
                    if ("limited" in item.tags) { Spacer(Modifier.width(6.dp)); MonoBadge("LIMITED", T.hot) }
                }
            }
            if (current != null) Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Notifications, null, tint = T.blue, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Txt("You'll get a text ${ReminderFmt.long(current.remindAt)}", size = T.footnote, weight = FontWeight.SemiBold)
            }
            Kick("When should I text you?")
            choices.filter { drop - it.second * 60_000L > now() }.forEach { (label, mins) ->
                val on = current?.offsetMinutes == mins
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(if (on) T.blue.copy(alpha = 0.16f) else T.glass)
                    .clickable { set(offset = mins) }.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Txt(label, weight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                    Txt(ReminderFmt.short(drop - mins * 60_000L), size = T.caption, color = T.muted)
                    if (on) { Spacer(Modifier.width(6.dp)); Icon(Icons.Filled.Check, null, tint = T.blue) }
                }
            }
            Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(T.glass).clickable { picking = true }.padding(12.dp)) {
                Txt("Pick a time", weight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                if (current != null && current.offsetMinutes == null) Icon(Icons.Filled.Check, null, tint = T.blue)
            }
            if (current != null) TextButton(onClick = { store.removeReminder(item); Router.say("Reminder removed"); Router.close() }, modifier = Modifier.fillMaxWidth()) {
                Txt("Remove reminder", weight = FontWeight.SemiBold, color = T.hot)
            }
            item.url?.let { u -> Txt("See the release page ↗", size = T.footnote, weight = FontWeight.SemiBold, color = T.accent, modifier = Modifier.clickable { openUrl(context, u) }) }
        }
    }

    if (picking) {
        val dateState = rememberDatePickerState(initialSelectedDateMillis = maxOf(now() + 3_600_000L, drop - 3_600_000L).coerceAtMost(drop))
        var pickedDay by remember { mutableStateOf<Long?>(null) }
        if (pickedDay == null) DatePickerDialog(onDismissRequest = { picking = false },
            confirmButton = { TextButton(onClick = { pickedDay = dateState.selectedDateMillis ?: now() }) { Txt("Next", color = T.accent) } },
            dismissButton = { TextButton(onClick = { picking = false }) { Txt("Cancel", color = T.muted) } }) {
            DatePicker(dateState)
        } else {
            val timeState = rememberTimePickerState(initialHour = 10, initialMinute = 0)
            AlertDialog(onDismissRequest = { picking = false }, containerColor = T.panel,
                confirmButton = { TextButton(onClick = {
                    // The date picker returns UTC midnight; combine its calendar day with the local time picked.
                    val utc = Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC")).apply { timeInMillis = pickedDay!! }
                    val at = Calendar.getInstance().apply {
                        set(utc.get(Calendar.YEAR), utc.get(Calendar.MONTH), utc.get(Calendar.DAY_OF_MONTH), timeState.hour, timeState.minute, 0)
                    }.timeInMillis
                    picking = false
                    set(at = at)
                }) { Txt("Remind me", color = T.accent, weight = FontWeight.Bold) } },
                dismissButton = { TextButton(onClick = { picking = false }) { Txt("Cancel", color = T.muted) } },
                text = { TimePicker(timeState) })
        }
    }
}

package app.baget.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.Icon
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.baget.engine.Analytics
import app.baget.engine.AnalyticsEvent
import app.baget.ui.*
import kotlinx.coroutines.launch

private class HowToPage(val icon: ImageVector, val tint: Color, val title: String, val body: String, val tips: List<String>)

private val howToPages = listOf(
    HowToPage(Icons.Filled.WbSunny, T.warn, "Today is your daily feed",
        "Every day your scouts' best finds land at the top, with more picks for you below.",
        listOf("Tap ♥ on what you love, ✕ on what you don't", "Every tap teaches your scouts your taste", "Pull down any time to check for new finds")),
    HowToPage(Icons.Filled.AutoAwesome, T.cyan, "Finds is everything they found",
        "Each find shows the price, the store and why your scout picked it.",
        listOf("Like it, or Pass and say why", "Watch it and get a text when the price drops or it restocks", "Buy takes you straight to the store's page")),
    HowToPage(Icons.Filled.Groups, T.green, "Your scouts do the hunting",
        "Each scout hunts one thing for you, and every one is yours to shape. Change what it hunts, its brands, styles, size and budget, or how often it texts you, any time.",
        listOf("Talk to a scout or open Detailed hunt setup to fine-tune it", "Pause a scout, or delete it from its card in Scouts",
            "Send a new scout any time from Today, and it starts hunting right away", "Tap Hunt now in Finds when you can't wait")),
    HowToPage(Icons.Filled.NotificationsActive, T.hot, "They text you like a friend",
        "When something great turns up, your scout texts you a photo and why it's worth a look.",
        listOf("Only the best ones, a few a day at most", "Change how often in Settings, under Notifications", "Your icon at the top left opens Settings")),
    HowToPage(Icons.Filled.Favorite, T.accent, "Hunt with friends",
        "Add friends and see how your taste compares.",
        listOf("Tap Add in Your circle and type their @username. Set yours in Settings", "Share your taste to see your taste match and swap Taste Cards",
            "Add your birthday in Settings, and friends get gift ideas for your taste", "Send a friend a find, and tap what they send you to see it at the store")),
)

/** "How Baget works": a short swipe-through shown once, right after setup and before Today. Also in Settings. */
@Composable
fun HowToSheet(onDone: () -> Unit = { Router.close() }) {
    val pager = rememberPagerState { howToPages.size }
    val scope = rememberCoroutineScope()
    val last = pager.currentPage == howToPages.size - 1
    fun finish() {
        Analytics.track(AnalyticsEvent.HOW_TO_DONE, mapOf("page" to pager.currentPage))
        onDone()
    }
    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(24.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Row(Modifier.fillMaxWidth().height(40.dp), verticalAlignment = Alignment.CenterVertically) {
            Txt("How Baget works", size = T.footnote, color = T.muted, weight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            if (!last) TextButton(onClick = { finish() }) { Txt("Skip", size = T.footnote, color = T.muted, weight = FontWeight.SemiBold) }
        }
        HorizontalPager(pager, Modifier.weight(1f).fillMaxWidth()) { i -> HowToCard(howToPages[i]) }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally)) {
            howToPages.indices.forEach { i ->
                val on = i == pager.currentPage
                Box(Modifier.width(if (on) 18.dp else 6.dp).height(6.dp).clip(CircleShape)
                    .let { if (on) it.background(T.gradient) else it.background(T.line) })
            }
        }
        PrimaryButton(if (last) "Start exploring" else "Next", Modifier.fillMaxWidth()) {
            if (last) finish() else scope.launch { pager.animateScrollToPage(pager.currentPage + 1) }
        }
    }
}

@Composable
private fun HowToCard(p: HowToPage) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 2.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically)) {
        Box(Modifier.size(72.dp).clip(RoundedCornerShape(20.dp)).background(p.tint.copy(alpha = 0.15f)), contentAlignment = Alignment.Center) {
            Icon(p.icon, null, tint = p.tint, modifier = Modifier.size(34.dp))
        }
        Txt(p.title, size = 30.sp, weight = FontWeight.Black)
        Txt(p.body, size = T.body, color = T.muted)
        Column(Modifier.fillMaxWidth().glass(RoundedCornerShape(18.dp)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            p.tips.forEach { tip ->
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Icon(Icons.Filled.CheckCircle, null, tint = p.tint, modifier = Modifier.size(18.dp).padding(top = 1.dp))
                    Txt(tip, size = T.subhead)
                }
            }
        }
    }
}

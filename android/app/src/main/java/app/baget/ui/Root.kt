package app.baget.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import app.baget.engine.*
import app.baget.model.*
import app.baget.ui.screens.*
import kotlinx.coroutines.launch

@Composable
fun RootScreen() {
    val store = AppStore
    val s = store.observe()
    val router = Router
    val scope = rememberCoroutineScope()
    val prefs = remember { store.context.getSharedPreferences("baget.ui", 0) }
    var onboarded by remember { mutableStateOf(prefs.getBoolean("onboarded", false)) }

    // A tapped system notification: open what it's about.
    LaunchedEffect(store.openNoteFromSystem) {
        val id = store.openNoteFromSystem ?: return@LaunchedEffect
        store.openNoteFromSystem = null
        if (store.isCloud && s.notes.none { it.id == id }) store.pull()
        openNote(id)
    }
    LaunchedEffect(store.syncProblem) {
        val p = store.syncProblem ?: return@LaunchedEffect
        store.syncProblem = null
        router.say(p)
    }

    Box(Modifier.fillMaxSize().litBackground()) {
        when {
            store.needsWelcome -> WelcomeScreen()
            store.isCloud && s.agents.isEmpty() && !onboarded && s.lastSynced != null ->
                OnboardingScreen(onDone = { onboarded = true; prefs.edit().putBoolean("onboarded", true).apply() })
            else -> MainTabs()
        }
        // Sheets, newest on top. Back closes the top one.
        for (sheet in router.sheets.toList()) key(sheet) { SheetDialog(sheet) }

        Banner(Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(top = 8.dp))
        Toast(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 92.dp))
    }

    // Back from a store after tapping Buy: did you buy it? A yes is logged and teaches the agent.
    val askID = router.askBought
    if (askID != null) {
        val f = s.finds.firstOrNull { it.id == askID }
        val item = f?.let { Catalog.item(it.itemID) }
        AlertDialog(onDismissRequest = { router.askBought = null },
            containerColor = T.panel,
            title = { Txt(item?.let { "Did you buy the ${it.title}?" } ?: "Did you buy it?", size = T.body, weight = FontWeight.Bold) },
            text = { Txt("Your agent learns the most from what you actually buy.", color = T.muted) },
            confirmButton = {
                TextButton(onClick = {
                    if (f != null && item != null) {
                        val amount = if (item.priceKnown) item.price else 0.0
                        store.confirmPurchase(askID, amount)
                        Analytics.track(AnalyticsEvent.PURCHASE_CONFIRMED, mapOf("amount" to amount, "category" to item.category.raw, "score" to f.score, "from" to "buy"))
                        router.say("Nice. It's off your list, and ${store.agent(f.agentID)?.name ?: "your agent"} will find more like it.")
                    }
                    router.askBought = null
                }) { Txt("Yes, I bought it", color = T.accent, weight = FontWeight.Bold) }
            },
            dismissButton = { TextButton(onClick = { router.askBought = null }) { Txt("Not yet", color = T.muted) } })
    }
}

fun openNote(noteID: String) {
    val store = AppStore
    val n = store.state.notes.firstOrNull { it.id == noteID } ?: return
    store.markRead(listOf(noteID))
    Analytics.track(AnalyticsEvent.NOTIFICATION_OPENED, mapOf("kind" to n.kind.raw))
    Router.closeAll()
    if (n.friendID != null) { Router.tab = AppTab.FRIENDS; return }
    if (n.kind == NoteKind.DIGEST) { Router.tab = AppTab.LIVE; return }
    val fid = n.findID
    if (fid != null && store.state.finds.any { it.id == fid }) {
        Router.focusFind = fid
        Router.tab = AppTab.FINDS
    } else Router.tab = if (n.kind == NoteKind.LEARNED) AppTab.SQUAD else AppTab.FINDS
}

@Composable
private fun MainTabs() {
    val store = AppStore
    val s = store.observe()
    val router = Router
    Scaffold(
        containerColor = Color.Transparent,
        topBar = { TopBar() },
        bottomBar = {
            NavigationBar(containerColor = T.panel.copy(alpha = 0.96f), tonalElevation = 0.dp) {
                tabItem(AppTab.LIVE, "Today", Icons.Filled.WbSunny, 0)
                tabItem(AppTab.FINDS, "Finds", Icons.Filled.AutoAwesome, s.finds.count { it.status == FindStatus.OPEN && Catalog.item(it.itemID)?.showable == true })
                tabItem(AppTab.SQUAD, "Squad", Icons.Filled.Groups, 0)
                tabItem(AppTab.FRIENDS, "Friends", Icons.Filled.Favorite, s.suggestions.count { it.status == SuggestionStatus.NEW })
            }
        },
    ) { pad ->
        Box(Modifier.padding(pad).fillMaxSize()) {
            when (router.tab) {
                AppTab.LIVE -> TodayScreen()
                AppTab.FINDS -> FindsScreen()
                AppTab.SQUAD -> SquadScreen()
                AppTab.FRIENDS -> FriendsScreen()
            }
        }
    }
    BackHandler(enabled = router.tab != AppTab.LIVE && router.sheets.isEmpty()) { router.tab = AppTab.LIVE }
}

@Composable
private fun RowScope.tabItem(tab: AppTab, label: String, icon: ImageVector, badge: Int) {
    NavigationBarItem(
        selected = Router.tab == tab,
        onClick = { Router.tab = tab },
        icon = {
            BadgedBox(badge = { if (badge > 0) Badge(containerColor = T.hot) { Text(if (badge > 99) "99+" else "$badge", fontSize = 10.sp) } }) {
                Icon(icon, label)
            }
        },
        label = { Text(label, fontSize = 11.sp) },
        colors = NavigationBarItemDefaults.colors(selectedIconColor = T.accent, selectedTextColor = T.accent, indicatorColor = T.accent.copy(alpha = 0.14f),
            unselectedIconColor = T.muted, unselectedTextColor = T.muted),
    )
}

@Composable
private fun TopBar() {
    val store = AppStore
    store.observe()
    val unread = store.unreadCount
    Row(Modifier.fillMaxWidth().background(T.bg.copy(alpha = 0.85f)).statusBarsPadding().height(54.dp).padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.clip(CircleShape).clickable { Router.open(Sheet.Profile) }) { AvatarView(30.dp) }
        Spacer(Modifier.weight(1f))
        Row(verticalAlignment = Alignment.CenterVertically) {
            AppIcon(26.dp)
            Spacer(Modifier.width(8.dp))
            BagetWordmark(22.sp)
        }
        Spacer(Modifier.weight(1f))
        Box(Modifier.size(36.dp).clip(CircleShape).clickable { Router.open(Sheet.Inbox) }, contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Notifications, "Notifications, $unread unread", tint = T.ink)
            if (unread > 0) Box(Modifier.align(Alignment.TopEnd).padding(top = 2.dp, end = 2.dp).clip(CircleShape).background(T.hot).padding(horizontal = 4.dp, vertical = 1.dp)) {
                Txt(if (unread > 9) "9+" else "$unread", size = 9.sp, weight = FontWeight.Bold, color = Color.White)
            }
        }
    }
}

@Composable
private fun Banner(modifier: Modifier) {
    val store = AppStore
    val n = store.banner
    AnimatedVisibility(n != null, modifier = modifier, enter = slideInVertically { -it } + fadeIn(), exit = slideOutVertically { -it } + fadeOut()) {
        if (n == null) return@AnimatedVisibility
        Row(Modifier.padding(horizontal = 12.dp).fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(T.panel.copy(alpha = 0.97f))
            .border(1.dp, T.line, RoundedCornerShape(20.dp))
            .clickable { store.banner = null; Router.open(Sheet.Inbox) }.padding(12.dp), verticalAlignment = Alignment.Top) {
            NoteIcon(n)
            Spacer(Modifier.width(11.dp))
            Column(Modifier.weight(1f)) {
                Row {
                    Txt(store.noteSender(n), size = T.footnote, weight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                    Txt("now", size = T.caption2, color = T.muted)
                }
                Txt(n.body, maxLines = 3)
            }
        }
    }
}

@Composable
private fun Toast(modifier: Modifier) {
    val t = Router.toast
    AnimatedVisibility(t != null, modifier = modifier, enter = slideInVertically { it } + fadeIn(), exit = fadeOut()) {
        Box(Modifier.padding(horizontal = 20.dp).clip(CircleShape).background(T.panel).border(1.dp, T.line, CircleShape).padding(horizontal = 16.dp, vertical = 11.dp)) {
            Txt(t ?: "", weight = FontWeight.SemiBold)
        }
    }
}

// MARK: Sheets

@Composable
private fun SheetDialog(sheet: Sheet) {
    Dialog(onDismissRequest = { Router.sheets.remove(sheet) },
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false, dismissOnClickOutside = false)) {
        Box(Modifier.fillMaxSize().litBackground()) {
            when (sheet) {
                Sheet.Inbox -> InboxSheet()
                Sheet.Deploy -> DeploySheet(Router.deployPrefill)
                Sheet.CustomizeBar -> CustomizeBarSheet()
                Sheet.Profile -> ProfileSheet()
                is Sheet.Checkout -> CheckoutSheet(sheet.findID)
                is Sheet.ShareItem -> ShareSheet(sheet.itemID, sheet.friendID, sheet.suggestion)
                is Sheet.SuggestFor -> SuggestForSheet(sheet.friendID)
                is Sheet.TastePhoto -> TastePhotoSheet(sheet.agentID)
                is Sheet.Chat -> ChatSheet(sheet.agentID, sheet.aboutFindID)
                is Sheet.AgentIcon -> AgentIconSheet(sheet.agentID)
                Sheet.Swipe -> SwipeSheet()
                Sheet.Taste -> TasteSheet()
                Sheet.Pro -> PaywallSheet()
                Sheet.Feedback -> FeedbackSheet()
                is Sheet.Reminder -> ReminderSheet(sheet.itemID, sheet.findID)
            }
            Toast(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 24.dp))
        }
    }
}

/** A sheet's frame: a title bar with Cancel/Done, then the content. */
@Composable
fun SheetFrame(title: String, leading: String? = null, onLeading: (() -> Unit)? = null, trailing: String? = "Done",
               trailingEnabled: Boolean = true, onTrailing: (() -> Unit)? = null, bold: Boolean = true,
               content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding()) {
        Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f)) {
                if (leading != null) TextButton(onClick = { (onLeading ?: Router::close)() }) { Txt(leading, color = T.accent) }
            }
            Txt(title, size = T.body, weight = FontWeight.SemiBold, maxLines = 1)
            Box(Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
                if (trailing != null) TextButton(onClick = { (onTrailing ?: Router::close)() }, enabled = trailingEnabled) {
                    Txt(trailing, color = if (trailingEnabled) T.accent else T.muted, weight = if (bold) FontWeight.Bold else FontWeight.Normal)
                }
            }
        }
        content()
    }
}

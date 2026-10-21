package app.baget

import android.app.Application
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.LaunchedEffect
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import app.baget.engine.*
import app.baget.model.now
import app.baget.ui.BagetTheme
import app.baget.ui.RootScreen
import app.baget.ui.Router
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class BagetApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        Analytics.init(this)
        AppStore.init(this)
        Notifier.createChannels(this)
        // Coming back to the app, and leaving it.
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) {
                val store = AppStore
                val gone = (now() - store.state.lastSeen) / 60000.0
                store.scope.launch {
                    store.cameBack(gone)
                    store.state.lastSeen = now()
                    store.save()
                }
                Analytics.track(AnalyticsEvent.APP_OPENED, mapOf("minutesAway" to gone.toInt(), "signedIn" to store.isCloud))
                Analytics.flush()
                // Back from a store after tapping Buy: ask whether they bought it.
                Router.buyOpened?.let { id ->
                    Router.buyOpened = null
                    store.scope.launch {
                        delay(700)
                        if (store.state.finds.any { it.id == id && it.status != app.baget.model.FindStatus.ACQUIRED }) Router.askBought = id
                    }
                }
            }

            override fun onStop(owner: LifecycleOwner) {
                AppStore.state.lastSeen = now()
                AppStore.saveNow()
                Analytics.flush()
            }
        })
    }
}

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT))
        super.onCreate(savedInstanceState)
        handle(intent)
        setContent {
            BagetTheme {
                RootScreen()
                LaunchedEffect(Unit) {
                    val store = AppStore
                    if (store.isCloud) store.registerForPushIfAllowed()
                    Billing.sync()
                    Billing.loadProducts()
                    store.loadPlan()
                    // While the app is open, keep everything fresh in the background, every 3 minutes.
                    while (true) {
                        delay(180_000)
                        store.refreshQuietly()
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    /** A tapped notification carries the note it's about. */
    private fun handle(intent: Intent?) {
        intent?.getStringExtra("noteID")?.let { AppStore.openNoteFromSystem = it }
        intent?.getStringExtra("go")?.let { go(it) }
    }

    /** Navigation for the cloud launch test (adb shell am start ... --es go finds). It only moves between screens. */
    private fun go(to: String) {
        val store = AppStore
        when (to) {
            "tour" -> if (!store.isCloud) store.exploreSamples()
            "live" -> { Router.closeAll(); Router.tab = app.baget.ui.AppTab.LIVE }
            "finds" -> { Router.closeAll(); Router.tab = app.baget.ui.AppTab.FINDS }
            "squad" -> { Router.closeAll(); Router.tab = app.baget.ui.AppTab.SQUAD }
            "friends" -> { Router.closeAll(); Router.tab = app.baget.ui.AppTab.FRIENDS }
            "close" -> Router.closeAll()
            else -> if (to.startsWith("sheet:")) {
                val s = when (to.removePrefix("sheet:")) {
                    "profile" -> app.baget.ui.Sheet.Profile
                    "inbox" -> app.baget.ui.Sheet.Inbox
                    "swipe" -> app.baget.ui.Sheet.Swipe
                    "deploy" -> app.baget.ui.Sheet.Deploy
                    "taste" -> app.baget.ui.Sheet.Taste
                    "pro" -> app.baget.ui.Sheet.Pro
                    "customize" -> app.baget.ui.Sheet.CustomizeBar
                    "feedback" -> app.baget.ui.Sheet.Feedback
                    "chat" -> store.state.agents.firstOrNull()?.let { app.baget.ui.Sheet.Chat(it.id) }
                    "checkout" -> store.state.finds.firstOrNull()?.let { app.baget.ui.Sheet.Checkout(it.id) }
                    else -> null
                }
                s?.let { Router.closeAll(); Router.open(it) }
            }
        }
    }
}

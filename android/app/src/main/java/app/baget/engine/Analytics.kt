package app.baget.engine

import android.content.Context
import app.baget.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.time.Instant
import java.util.UUID
import java.util.concurrent.TimeUnit

/** Product events. Names match the backend's metric views. */
enum class AnalyticsEvent(val raw: String) {
    APP_OPENED("app_opened"), LIVE_SECTION_VIEWED("live_section_viewed"), CUSTOM_SECTION_ADDED("custom_section_added"),
    BACKGROUND_SIMULATED("background_simulated"),
    AGENT_DEPLOYED("agent_deployed"), AGENT_RETIRED("agent_retired"), AGENT_SETTING_CHANGED("agent_setting_changed"),
    AGENT_LEARNED("agent_learned"), TASTE_PHOTO_ADDED("taste_photo_added"), SIGNED_IN("signed_in"), AVATAR_CHANGED("avatar_changed"),
    PROFILE_OPENED("profile_opened"), CHAT_SENT("chat_sent"), SWEEP_RUN("sweep_run"),
    FIND_CREATED("find_created"), STORY_SENT_TO_AGENT("story_sent_to_agent"), CHECKOUT_OPENED("checkout_opened"),
    PURCHASE_CONFIRMED("purchase_confirmed"), AUTO_PURCHASED("auto_purchased"), FIND_WATCHED("find_watched"), HUNT_STARTED("hunt_started"),
    ONBOARDING_DONE("onboarding_done"), SWIPE("swipe"), ASK_ABOUT("ask_about"), TASTE_REMOVED("taste_removed"), TODAY_VIEWED("today_viewed"),
    FIND_PASSED("find_passed"), FIND_LIKED("find_liked"), REMINDER_SET("reminder_set"), FIND_UNLIKED("find_unliked"),
    NOTIFICATION_SENT("notification_sent"), NOTIFICATION_OPENED("notification_opened"),
    FRIEND_INVITED("friend_invited"), ITEM_SHARED("item_shared"), SUGGESTION_SENT("suggestion_sent"),
    SUGGESTION_ACCEPTED("suggestion_accepted"), SUGGESTION_PASSED("suggestion_passed"),
}

/**
 * Batches events on the device and sends them to the backend.
 *  - Identity: a random install ID. No name, email, handle or device identifier is ever sent.
 *  - Delivery: events queue on disk and go out in batches of 100.
 *  - Opt-out: Analytics.enabled = false stops collection and clears the queue.
 */
object Analytics {
    private lateinit var appContext: Context
    private val lock = Any()
    private var buffer = mutableListOf<JsonObject>()
    private val sessionID = UUID.randomUUID().toString()
    private const val MAX_QUEUED = 2000
    private val http = OkHttpClient.Builder().callTimeout(20, TimeUnit.SECONDS).build()

    private val prefs get() = appContext.getSharedPreferences("baget.analytics", Context.MODE_PRIVATE)
    private val file: File get() = File(appContext.filesDir, "baget-analytics-queue.json")

    fun init(context: Context) {
        appContext = context.applicationContext
        buffer = runCatching {
            (plainJson.parseToJsonElement(file.readText()) as JsonArray).map { it.jsonObject }.toMutableList()
        }.getOrDefault(mutableListOf())
    }

    val installID: String
        get() = prefs.getString("installID", null) ?: UUID.randomUUID().toString().also { prefs.edit().putString("installID", it).apply() }

    var enabled: Boolean
        get() = prefs.getBoolean("enabled", true)
        set(v) {
            prefs.edit().putBoolean("enabled", v).apply()
            if (!v) synchronized(lock) { buffer.clear(); persist() }
        }

    val configured: Boolean get() = Backend.isConfigured

    private val version: String get() = "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}) android"

    fun track(event: AnalyticsEvent, props: Map<String, Any?> = emptyMap()) {
        if (!::appContext.isInitialized || !enabled) return
        val row = jobj("id" to UUID.randomUUID().toString(), "install_id" to installID, "session_id" to sessionID, "name" to event.raw,
            "occurred_at" to Instant.now().toString(), "app_version" to version, "props" to toJson(props + ("platform" to "android")))
        synchronized(lock) {
            buffer.add(row)
            while (buffer.size > MAX_QUEUED) buffer.removeAt(0)
            persist()
        }
    }

    fun flush() { AppStore.scope.launch { flushNow() } }

    /** Sends queued events. Safe to call often; does nothing without a configured backend. */
    suspend fun flushNow() = withContext(Dispatchers.IO) {
        val base = Backend.baseURL ?: return@withContext
        if (!enabled) return@withContext
        dropStale()
        repeat(20) {
            val batch = synchronized(lock) { buffer.take(100) }
            if (batch.isEmpty()) return@withContext
            val req = Request.Builder().url("$base/rest/v1/events")
                .header("apikey", Backend.apiKey).header("Authorization", "Bearer ${Backend.apiKey}")
                .header("Prefer", "return=minimal,resolution=ignore-duplicates")
                .post(JsonArray(batch).toString().toRequestBody("application/json".toMediaType())).build()
            val code = runCatching { http.newCall(req).execute().use { it.code } }.getOrNull() ?: return@withContext   // offline: keep the queue
            val ok = code in 200..299
            // A batch the server rejects (4xx other than auth or rate limit) would fail forever; drop it.
            val poison = code in 400..499 && code != 401 && code != 429
            if (!ok && !poison) return@withContext
            val sent = batch.mapNotNull { it["id"]?.jsonPrimitive?.content }.toSet()
            synchronized(lock) {
                buffer.removeAll { it["id"]?.jsonPrimitive?.content in sent }
                persist()
            }
        }
    }

    val queuedCount: Int get() = synchronized(lock) { buffer.size }

    /** The backend only accepts events from the last 30 days. */
    private fun dropStale() {
        val cutoff = System.currentTimeMillis() - 29L * 24 * 3600 * 1000
        synchronized(lock) {
            buffer.removeAll { row ->
                val t = row["occurred_at"]?.jsonPrimitive?.content?.let { runCatching { Instant.parse(it).toEpochMilli() }.getOrNull() }
                t == null || t < cutoff
            }
            persist()
        }
    }

    private fun persist() { runCatching { file.writeText(JsonArray(buffer).toString()) } }
}

@Suppress("unused") private fun JsonElement.asObj() = this as? JsonObject

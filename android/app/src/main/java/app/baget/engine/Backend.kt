package app.baget.engine

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import app.baget.BuildConfig
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.OffsetDateTime
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Errors shown to people. Messages are written for the screen. */
class BackendError(override val message: String, val status: Int = 0) : Exception(message) {
    companion object {
        val notSignedIn = BackendError("Sign in to use this.")
        val offline = BackendError("You're offline. Check your connection and try again.")
    }
}

/** Server rows use snake_case; Kotlin properties are camelCase. */
@OptIn(ExperimentalSerializationApi::class)
val rowJson = Json {
    namingStrategy = JsonNamingStrategy.SnakeCase
    ignoreUnknownKeys = true
    explicitNulls = false
    coerceInputValues = true
    isLenient = true
}

/** Local saves and anything already camelCase. */
val plainJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    coerceInputValues = true
    encodeDefaults = true
}

/** Turns Kotlin values into JSON: strings, numbers, booleans, null, lists, maps and JSON elements. */
fun toJson(v: Any?): JsonElement = when (v) {
    null -> JsonNull
    is JsonElement -> v
    is String -> JsonPrimitive(v)
    is Number -> JsonPrimitive(v)
    is Boolean -> JsonPrimitive(v)
    is Map<*, *> -> JsonObject(v.entries.associate { (k, x) -> k.toString() to toJson(x) })
    is Iterable<*> -> JsonArray(v.map { toJson(it) })
    is Array<*> -> JsonArray(v.map { toJson(it) })
    else -> JsonPrimitive(v.toString())
}

fun jobj(vararg pairs: Pair<String, Any?>): JsonObject = JsonObject(pairs.associate { (k, v) -> k to toJson(v) })

/** Postgres timestamps: "2026-10-07T15:00:00.123456+00:00", "2026-10-07 15:00:00+00" and friends. */
fun parseDate(s: String?): Long? {
    if (s.isNullOrBlank()) return null
    var t = s.trim().replace(' ', 'T')
    if (Regex("[+-]\\d{2}$").containsMatchIn(t)) t += ":00"
    if (t.endsWith("Z").not() && !Regex("[+-]\\d{2}:\\d{2}$").containsMatchIn(t)) t += "Z"
    return runCatching { OffsetDateTime.parse(t).toInstant().toEpochMilli() }.getOrNull()
}

fun isoDate(ms: Long): String = java.time.Instant.ofEpochMilli(ms).toString()

/**
 * A minimal Supabase client: sign-in (Google, email), database (PostgREST), RPC, edge functions and storage.
 * The session is encrypted with a key that never leaves this phone's Android Keystore.
 */
object Backend {
    @Serializable
    data class Session(val accessToken: String, val refreshToken: String, val expiresAt: Long, val userID: String)

    val baseURL: String? = BuildConfig.SUPABASE_URL.takeIf { it.startsWith("https://") }?.trimEnd('/')
    val apiKey: String = BuildConfig.SUPABASE_ANON_KEY
    var session: Session? = null
        private set
    private val refreshLock = Mutex()
    private lateinit var store: SecureStore

    val isConfigured: Boolean get() = baseURL != null && apiKey.isNotEmpty()
    val isSignedIn: Boolean get() = session != null
    val userID: String? get() = session?.userID

    private val http = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .build()

    fun init(context: Context) {
        store = SecureStore(context.applicationContext)
        session = store.load()?.let { runCatching { plainJson.decodeFromString<Session>(it) }.getOrNull() }
    }

    // MARK: Auth

    /** A random nonce. Google gets its SHA-256; Supabase gets the original to check against it. */
    fun makeNonce(): String {
        val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
        return bytes.joinToString("") { "%02x".format(it) }
    }

    fun sha256(s: String): String = MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }

    suspend fun signInWithIdToken(provider: String, idToken: String, nonce: String?) {
        val body = buildMap<String, Any?> { put("provider", provider); put("id_token", idToken); if (nonce != null) put("nonce", nonce) }
        val data = raw("POST", "/auth/v1/token", query = listOf("grant_type" to "id_token"), json = toJson(body), authorized = false)
        storeSession(data)
    }

    suspend fun signInWithEmail(email: String, password: String) {
        val data = raw("POST", "/auth/v1/token", query = listOf("grant_type" to "password"),
            json = jobj("email" to email, "password" to password), authorized = false)
        storeSession(data)
    }

    /** New account with email and password. The server confirms it straight away, so this signs in too. */
    suspend fun signUpWithEmail(email: String, password: String, name: String?) {
        val body = mutableMapOf<String, Any?>("email" to email, "password" to password)
        if (!name.isNullOrEmpty()) body["data"] = mapOf("full_name" to name)
        val data = raw("POST", "/auth/v1/signup", json = toJson(body), authorized = false)
        val obj = runCatching { rowJson.parseToJsonElement(String(data)).jsonObject }.getOrNull()
        if (obj?.get("access_token") != null) storeSession(data) else signInWithEmail(email, password)
    }

    suspend fun signOut() {
        if (session != null) runCatching { raw("POST", "/auth/v1/logout", json = JsonObject(emptyMap())) }
        forgetSession()
    }

    fun forgetSession() {
        session = null
        store.clear()
    }

    private fun storeSession(data: ByteArray) {
        val obj = runCatching { rowJson.parseToJsonElement(String(data)).jsonObject }.getOrNull()
        val access = obj?.get("access_token")?.jsonPrimitive?.contentOrNull
        val refresh = obj?.get("refresh_token")?.jsonPrimitive?.contentOrNull
        val uid = obj?.get("user")?.jsonObject?.get("id")?.jsonPrimitive?.contentOrNull
        if (access == null || refresh == null || uid == null) throw BackendError("Sign-in didn't complete. Try again.")
        val expiresIn = obj["expires_in"]?.jsonPrimitive?.doubleOrNull ?: 3600.0
        val s = Session(access, refresh, System.currentTimeMillis() + ((expiresIn - 60) * 1000).toLong(), uid)
        session = s
        store.save(plainJson.encodeToString(Session.serializer(), s))
    }

    private suspend fun refreshIfNeeded() {
        val s = session ?: throw BackendError.notSignedIn
        if (s.expiresAt > System.currentTimeMillis()) return
        refreshLock.withLock {
            val current = session ?: throw BackendError.notSignedIn
            if (current.expiresAt > System.currentTimeMillis()) return   // someone else refreshed it
            try {
                val data = raw("POST", "/auth/v1/token", query = listOf("grant_type" to "refresh_token"),
                    json = jobj("refresh_token" to current.refreshToken), authorized = false)
                storeSession(data)
            } catch (e: BackendError) {
                if (e.status == 400 || e.status == 401) {
                    forgetSession()
                    throw BackendError("Your session expired. Sign in again.", 401)
                }
                throw e
            }
        }
    }

    // MARK: Requests

    suspend fun raw(method: String, path: String, query: List<Pair<String, String>> = emptyList(), json: JsonElement? = null,
                    body: ByteArray? = null, contentType: String? = null, prefer: String? = null, authorized: Boolean = true): ByteArray {
        val base = baseURL ?: throw BackendError("Baget isn't connected to a server yet.")
        if (authorized) refreshIfNeeded()
        val qs = if (query.isEmpty()) "" else "?" + query.joinToString("&") { (k, v) -> "$k=${pgrstEncode(v)}" }
        val builder = Request.Builder().url(base + path + qs).header("apikey", apiKey)
        if (authorized) session?.accessToken?.let { builder.header("Authorization", "Bearer $it") }
        prefer?.let { builder.header("Prefer", it) }
        val reqBody = when {
            json != null -> json.toString().toRequestBody("application/json".toMediaType())
            body != null -> body.toRequestBody((contentType ?: "application/octet-stream").toMediaType())
            method == "GET" || method == "DELETE" -> null
            else -> ByteArray(0).toRequestBody(null)
        }
        builder.method(method, reqBody)
        val callTimeout = if (path.startsWith("/functions/")) 120L else 30L
        val client = http.newBuilder().callTimeout(callTimeout, TimeUnit.SECONDS).build()
        return withContext(Dispatchers.IO) {
            val resp = try { client.newCall(builder.build()).execute() } catch (e: Exception) { throw BackendError.offline }
            resp.use { r ->
                val data = r.body?.bytes() ?: ByteArray(0)
                if (r.code !in 200..299) {
                    if (r.code == 401 && authorized) forgetSession()
                    throw BackendError(message(data, r.code), r.code)
                }
                data
            }
        }
    }

    private fun message(data: ByteArray, status: Int): String {
        val obj = runCatching { rowJson.parseToJsonElement(String(data)).jsonObject }.getOrNull()
        if (obj != null) {
            for (key in listOf("error", "message", "msg", "error_description")) {
                val m = (obj[key] as? JsonPrimitive)?.contentOrNull
                if (!m.isNullOrEmpty() && !m.contains("violates") && m.length < 200) return m
            }
        }
        return when (status) {
            401 -> "Your session expired. Sign in again."
            409 -> "That's already taken."
            429, 503 -> "Busy right now. Try again in a minute."
            else -> "Something went wrong ($status). Try again."
        }
    }

    /** Keeps PostgREST's filter syntax intact while encoding everything else. */
    private fun pgrstEncode(v: String): String {
        val allowed = "-._~*,():!\""
        val sb = StringBuilder()
        for (b in v.toByteArray(Charsets.UTF_8)) {
            val c = b.toInt() and 0xff
            val ch = c.toChar()
            if ((ch in 'a'..'z') || (ch in 'A'..'Z') || (ch in '0'..'9') || (c < 128 && allowed.indexOf(ch) >= 0)) sb.append(ch)
            else sb.append('%').append("%02X".format(c))
        }
        return sb.toString()
    }

    /** "select=*&user_id=eq.x" -> query pairs, keeping PostgREST's syntax intact. */
    private fun items(q: String): List<Pair<String, String>> = q.split('&').filter { it.isNotEmpty() }.map { part ->
        val i = part.indexOf('=')
        if (i < 0) part to "" else part.substring(0, i) to part.substring(i + 1)
    }

    suspend fun <T> select(table: String, query: String, de: DeserializationStrategy<List<T>>): List<T> {
        val data = raw("GET", "/rest/v1/$table", query = items(query))
        return rowJson.decodeFromString(de, String(data))
    }

    suspend fun selectRaw(table: String, query: String): JsonElement =
        rowJson.parseToJsonElement(String(raw("GET", "/rest/v1/$table", query = items(query))))

    suspend fun insert(table: String, rows: JsonElement, prefer: String = "return=minimal") {
        raw("POST", "/rest/v1/$table", json = rows, prefer = prefer)
    }

    suspend fun update(table: String, filter: String, patch: JsonObject) {
        raw("PATCH", "/rest/v1/$table", query = items(filter), json = patch, prefer = "return=minimal")
    }

    suspend fun delete(table: String, filter: String) {
        raw("DELETE", "/rest/v1/$table", query = items(filter), prefer = "return=minimal")
    }

    suspend fun rpc(fn: String, args: JsonObject = JsonObject(emptyMap())): JsonElement {
        val data = raw("POST", "/rest/v1/rpc/$fn", json = args)
        return if (data.isEmpty()) JsonNull else rowJson.parseToJsonElement(String(data))
    }

    suspend fun <T> rpc(fn: String, args: JsonObject, de: DeserializationStrategy<T>): T =
        rowJson.decodeFromJsonElement(de, rpc(fn, args))

    suspend fun function(name: String, body: JsonElement): JsonElement {
        val data = raw("POST", "/functions/v1/$name", json = body)
        return if (data.isEmpty()) JsonNull else rowJson.parseToJsonElement(String(data))
    }

    suspend fun upload(bucket: String, path: String, jpeg: ByteArray) {
        raw("POST", "/storage/v1/object/$bucket/$path", body = jpeg, contentType = "image/jpeg")
    }

    suspend fun download(bucket: String, path: String): ByteArray = raw("GET", "/storage/v1/object/authenticated/$bucket/$path")

    suspend fun removeFile(bucket: String, path: String) {
        raw("DELETE", "/storage/v1/object/$bucket", json = jobj("prefixes" to listOf(path)))
    }
}

/** Runs several requests at once, like Swift's async let. */
suspend fun <A, B> both(a: suspend () -> A, b: suspend () -> B): Pair<A, B> = coroutineScope {
    val x: Deferred<A> = async { a() }
    val y: Deferred<B> = async { b() }
    x.await() to y.await()
}

/** Stores a small secret (the session) encrypted with an AES key kept in the Android Keystore. */
class SecureStore(context: Context) {
    private val prefs = context.getSharedPreferences("baget.secure", Context.MODE_PRIVATE)
    private val alias = "baget.session"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build())
        return gen.generateKey()
    }

    fun save(text: String) {
        runCatching {
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.ENCRYPT_MODE, key())
            val out = c.doFinal(text.toByteArray())
            prefs.edit().putString("iv", Base64.encodeToString(c.iv, Base64.NO_WRAP))
                .putString("data", Base64.encodeToString(out, Base64.NO_WRAP)).apply()
        }
    }

    fun load(): String? = runCatching {
        val iv = Base64.decode(prefs.getString("iv", null) ?: return null, Base64.NO_WRAP)
        val data = Base64.decode(prefs.getString("data", null) ?: return null, Base64.NO_WRAP)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
        String(c.doFinal(data))
    }.getOrNull()

    fun clear() { prefs.edit().clear().apply() }
}

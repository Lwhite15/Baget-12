package app.baget.engine

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.exifinterface.media.ExifInterface
import app.baget.BuildConfig
import app.baget.MainActivity
import app.baget.R
import app.baget.model.AppNote
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.net.URL
import java.util.Calendar
import kotlin.coroutines.resume
import kotlin.math.max
import kotlin.math.min

// MARK: Images

object Images {
    fun scaled(b: Bitmap, maxSide: Int): Bitmap {
        val scale = min(1f, maxSide.toFloat() / max(b.width, b.height))
        if (scale >= 1f) return b
        return Bitmap.createScaledBitmap(b, max(1, (b.width * scale).toInt()), max(1, (b.height * scale).toInt()), true)
    }

    fun jpeg(b: Bitmap, quality: Int): ByteArray {
        val out = ByteArrayOutputStream()
        // JPEG has no alpha: draw onto white first so transparent pixels don't turn black.
        val opaque = if (b.hasAlpha()) Bitmap.createBitmap(b.width, b.height, Bitmap.Config.ARGB_8888).also {
            Canvas(it).apply { drawColor(Color.WHITE); drawBitmap(b, 0f, 0f, null) }
        } else b
        opaque.compress(Bitmap.CompressFormat.JPEG, quality, out)
        return out.toByteArray()
    }

    fun squareCrop(b: Bitmap): Bitmap {
        val side = min(b.width, b.height)
        return Bitmap.createBitmap(b, (b.width - side) / 2, (b.height - side) / 2, side, side)
    }

    /** Opens a photo the person picked, upright and no larger than maxSide. */
    suspend fun load(context: Context, uri: Uri, maxSide: Int = 1400): Bitmap? = withContext(Dispatchers.IO) {
        runCatching {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
            var sample = 1
            while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
            val raw = context.contentResolver.openInputStream(uri)?.use {
                BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
            } ?: return@runCatching null
            val rotation = context.contentResolver.openInputStream(uri)?.use {
                when (ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                    ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                    ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                    ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                    else -> 0f
                }
            } ?: 0f
            val upright = if (rotation != 0f) Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, Matrix().apply { postRotate(rotation) }, true) else raw
            scaled(upright, maxSide)
        }.getOrNull()
    }

    /** The two or three colors that cover most of the photo, by name. */
    fun dominantColors(b: Bitmap): List<String> {
        val small = Bitmap.createScaledBitmap(b, 32, 32, true)
        val counts = mutableMapOf<String, Int>()
        for (y in 0 until 32) for (x in 0 until 32) {
            val p = small.getPixel(x, y)
            val name = colorName(Color.red(p).toDouble(), Color.green(p).toDouble(), Color.blue(p).toDouble())
            counts[name] = (counts[name] ?: 0) + 1
        }
        return counts.entries.sortedByDescending { it.value }.filter { it.value / 1024.0 > 0.12 }.take(3).map { it.key }
    }

    fun colorName(r: Double, g: Double, b: Double): String {
        val R = r / 255; val G = g / 255; val B = b / 255
        val mx = maxOf(R, G, B); val mn = minOf(R, G, B); val l = (mx + mn) / 2; val d = mx - mn
        val s = if (d == 0.0) 0.0 else d / (1 - kotlin.math.abs(2 * l - 1))
        var hue = 0.0
        if (d > 0) {
            hue = when (mx) {
                R -> 60 * (((G - B) / d) % 6)
                G -> 60 * ((B - R) / d + 2)
                else -> 60 * ((R - G) / d + 4)
            }
            if (hue < 0) hue += 360
        }
        if (l < 0.13) return "black"
        if (l > 0.9 && s < 0.25) return "white"
        if (s < 0.14) return if (l > 0.6) "light grey" else "grey"
        return when {
            hue < 15 || hue >= 345 -> if (l < 0.35) "burgundy" else "red"
            hue < 40 -> if (l < 0.42) "brown" else if (s < 0.45 && l > 0.6) "beige" else "orange"
            hue < 65 -> if (l < 0.42) "olive" else if (s < 0.5 && l > 0.65) "cream" else "yellow"
            hue < 170 -> if (l < 0.3) "forest green" else "green"
            hue < 195 -> "teal"
            hue < 250 -> if (l < 0.3) "navy" else "blue"
            hue < 290 -> "purple"
            else -> "pink"
        }
    }
}

// MARK: Notifications on this phone

object Notifier {
    const val CHANNEL_FINDS = "finds"
    const val CHANNEL_FRIENDS = "friends"

    fun createChannels(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        nm.createNotificationChannel(NotificationChannel(CHANNEL_FINDS, "Finds and drops", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Texts from your scouts when they find something"
        })
        nm.createNotificationChannel(NotificationChannel(CHANNEL_FRIENDS, "Friends", NotificationManager.IMPORTANCE_DEFAULT).apply {
            description = "Suggestions and replies from friends"
        })
    }

    fun allowed(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false
        return NotificationManagerCompat.from(context).areNotificationsEnabled()
    }

    /** Whether Android would still show the permission prompt (Android 13+ only asks twice). */
    fun needsPrompt(context: Context): Boolean =
        Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED

    /** Delivers a friend-style text right away. */
    fun post(context: Context, note: AppNote, title: String, subtitle: String? = null, image: Bitmap? = null) {
        if (!allowed(context)) return
        show(context, note.id, title, note.body, subtitle, image, if (note.friendID != null) CHANNEL_FRIENDS else CHANNEL_FINDS)
    }

    fun show(context: Context, noteID: String, title: String, body: String, subtitle: String?, image: Bitmap?, channel: String) {
        if (!allowed(context)) return
        val open = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("noteID", noteID)
        }
        val pi = PendingIntent.getActivity(context, noteID.hashCode(), open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val b = NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(0xFF2B3BFF.toInt())
            .setContentTitle(title)
            .setContentText(body)
            .setSubText(subtitle?.takeIf { it.isNotEmpty() })
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
        if (image != null) b.setLargeIcon(image).setStyle(NotificationCompat.BigPictureStyle().bigPicture(image).setSummaryText(body))
        else b.setStyle(NotificationCompat.BigTextStyle().bigText(body))
        try { NotificationManagerCompat.from(context).notify(noteID.hashCode(), b.build()) } catch (_: SecurityException) { }
    }

    /** Quiet hours: holds a non-urgent text until 8am. */
    fun postAtMorning(context: Context, note: AppNote, title: String) {
        val am = context.getSystemService(AlarmManager::class.java) ?: return
        val at = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 8); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0)
            if (timeInMillis <= System.currentTimeMillis()) add(Calendar.DAY_OF_YEAR, 1)
        }
        val i = Intent(context, MorningReceiver::class.java).apply {
            putExtra("noteID", note.id); putExtra("title", title); putExtra("body", note.body)
        }
        val pi = PendingIntent.getBroadcast(context, note.id.hashCode(), i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        am.set(AlarmManager.RTC_WAKEUP, at.timeInMillis, pi)
    }

    fun clear(context: Context, ids: List<String>) {
        val nm = NotificationManagerCompat.from(context)
        ids.forEach { nm.cancel(it.hashCode()) }
    }
}

class MorningReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("noteID") ?: return
        Notifier.show(context, id, intent.getStringExtra("title") ?: "Baget", intent.getStringExtra("body") ?: "", null, null, Notifier.CHANNEL_FINDS)
    }
}

// MARK: Push (Firebase Cloud Messaging)

object Push {
    private const val PREF = "baget.push"

    val available: Boolean get() = BuildConfig.HAS_FIREBASE

    suspend fun fetchToken(): String? {
        if (!available) return null
        return runCatching {
            suspendCancellableCoroutine { cont ->
                FirebaseMessaging.getInstance().token
                    .addOnSuccessListener { cont.resume(it) }
                    .addOnFailureListener { cont.resume(null) }
            }
        }.getOrNull()
    }

    fun saveToken(context: Context, token: String) {
        context.getSharedPreferences(PREF, Context.MODE_PRIVATE).edit().putString("token", token).apply()
    }

    fun currentToken(context: Context): String? = context.getSharedPreferences(PREF, Context.MODE_PRIVATE).getString("token", null)
}

/** Receives texts from the server. Data messages, so Baget draws them the same way whether it's open or not. */
class BagetMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        AppStore.scope.launch { AppStore.registerDevice(token) }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val d = message.data
        val noteID = d["noteID"] ?: d["note_id"] ?: java.util.UUID.randomUUID().toString()
        val title = d["title"] ?: message.notification?.title ?: "Baget"
        val body = d["body"] ?: message.notification?.body ?: return
        val subtitle = d["subtitle"]
        val image = d["image"]?.takeIf { it.startsWith("https://") }?.let { url ->
            runCatching { URL(url).openStream().use { BitmapFactory.decodeStream(it) } }.getOrNull()
        }
        Notifier.show(this, noteID, title, body, subtitle, image, if (d["thread"] == "friends") Notifier.CHANNEL_FRIENDS else Notifier.CHANNEL_FINDS)
        // Something new is waiting: sync so it's there when the person opens Baget.
        AppStore.scope.launch { runCatching { AppStore.pull() } }
    }
}

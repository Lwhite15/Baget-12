package app.baget.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.baget.engine.AppStore
import app.baget.model.Item
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/**
 * Product photos from store pages. Each photo is downloaded once, trimmed of plain white margins so the
 * product fills the tile, and kept on disk.
 */
object ProductPhotos {
    private val memory = LruCache<String, ImageBitmap>(150)
    private val failed = mutableSetOf<String>()
    private val inFlight = mutableMapOf<String, Deferred<ImageBitmap?>>()
    private val http = OkHttpClient.Builder().callTimeout(15, TimeUnit.SECONDS).build()
    private val dir: File get() = File(AppStore.context.cacheDir, "product-photos").also { it.mkdirs() }

    fun cached(url: String): ImageBitmap? = memory.get(url)

    suspend fun load(url: String): ImageBitmap? {
        memory.get(url)?.let { return it }
        if (url in failed) return null
        inFlight[url]?.let { return it.await() }
        val job = AppStore.scope.async { withContext(Dispatchers.IO) { fetch(url) } }
        inFlight[url] = job
        val img = job.await()
        inFlight.remove(url)
        if (img != null) memory.put(url, img) else failed.add(url)
        return img
    }

    private fun key(url: String) = MessageDigest.getInstance("SHA-256").digest(("v2:$url").toByteArray()).take(16).joinToString("") { "%02x".format(it) }

    private fun fetch(url: String): ImageBitmap? {
        val f = File(dir, "${key(url)}.jpg")
        if (f.exists()) BitmapFactory.decodeFile(f.path)?.let { return it.asImageBitmap() }
        val bytes = runCatching {
            http.newCall(Request.Builder().url(url).header("Accept", "image/jpeg,image/png,image/webp,image/*;q=0.8").build()).execute().use {
                if (it.isSuccessful) it.body?.bytes() else null
            }
        }.getOrNull() ?: return null
        val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
        if (opts.outWidth < 120 || opts.outHeight < 120) return null
        var sample = 1
        while (maxOf(opts.outWidth, opts.outHeight) / (sample * 2) >= 1000) sample *= 2
        val raw = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
        val trimmed = trimWhite(raw) ?: raw
        runCatching { f.outputStream().use { trimmed.compress(Bitmap.CompressFormat.JPEG, 85, it) } }
        return trimmed.asImageBitmap()
    }

    /** Crops away plain white or near-white margins so the product fills the tile. */
    private fun trimWhite(b: Bitmap): Bitmap? {
        val w = b.width; val h = b.height
        val px = IntArray(w * h)
        b.getPixels(px, 0, w, 0, 0, w, h)
        fun blank(x: Int, y: Int): Boolean {
            val p = px[y * w + x]
            val a = (p ushr 24) and 0xff
            if (a < 16) return true
            return ((p shr 16) and 0xff) > 242 && ((p shr 8) and 0xff) > 242 && (p and 0xff) > 242
        }
        var minX = w; var minY = h; var maxX = -1; var maxY = -1
        var y = 0
        while (y < h) { var x = 0; while (x < w) { if (!blank(x, y)) { if (x < minX) minX = x; if (x > maxX) maxX = x; if (y < minY) minY = y; if (y > maxY) maxY = y }; x += 2 }; y += 2 }
        if (maxX <= minX || maxY <= minY) return null
        val pad = (maxOf(maxX - minX, maxY - minY) * 0.04).toInt()
        val left = maxOf(0, minX - pad); val top = maxOf(0, minY - pad)
        val right = minOf(w, maxX + pad); val bottom = minOf(h, maxY + pad)
        if (right - left >= w * 0.98 && bottom - top >= h * 0.98) return null
        return Bitmap.createBitmap(b, left, top, right - left, bottom - top)
    }
}

@Composable
fun rememberProductPhoto(item: Item): ImageBitmap? {
    val url = item.imageURL?.takeIf { it.startsWith("https://") } ?: return null
    var img by remember(url) { mutableStateOf(ProductPhotos.cached(url)) }
    LaunchedEffect(url) { if (img == null) img = ProductPhotos.load(url) }
    return img
}

private fun brandInitials(brand: String, n: Int) = brand.split(" ").mapNotNull { it.firstOrNull()?.toString() }.take(n).joinToString("").uppercase()

/** Product photo on white (the way stores shoot products), or the maker's initials on a gradient tile. */
@Composable
fun Plate(item: Item, label: String, height: Dp = 120.dp, live: Boolean = false, lead: Boolean = false, modifier: Modifier = Modifier) {
    val photo = rememberProductPhoto(item)
    val radius = if (lead) 22.dp else 18.dp
    val shape = RoundedCornerShape(radius)
    Box(modifier.fillMaxWidth().height(height).clip(shape).then(
        when {
            photo != null -> Modifier.background(Color.White)
            lead -> Modifier.background(T.gradient)
            else -> Modifier.background(T.glass).background(Brush.linearGradient(listOf(T.blue.copy(alpha = 0.4f), Color.Transparent, T.green.copy(alpha = 0.28f))))
        })) {
        AnimatedContent(photo, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "plate") { p ->
            if (p != null) Image(p, item.title, contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxSize().padding(start = 10.dp, end = 10.dp, top = 30.dp, bottom = 24.dp))
        }
        Column(Modifier.fillMaxSize().padding(12.dp)) {
            Box(Modifier.clip(RoundedCornerShape(50)).background(
                if (live) T.hot else if (photo != null) T.bg.copy(alpha = 0.85f) else if (lead) Color.White.copy(alpha = 0.25f) else T.bg.copy(alpha = 0.6f))
                .padding(horizontal = 8.dp, vertical = 4.dp)) {
                Txt(label, size = 10.sp, weight = FontWeight.SemiBold, mono = true, maxLines = 1,
                    color = if (live) Color.White else if (photo != null) T.ink else if (lead) T.accentInk else T.ink)
            }
            Spacer(Modifier.weight(1f))
            if (photo == null) Txt(brandInitials(item.brand, 3), size = if (lead) 84.sp else 40.sp, weight = FontWeight.Black,
                color = if (lead) T.accentInk else T.ink, tracking = (-2).sp, maxLines = 1)
            Txt(if (item.sku.isEmpty()) item.source else "${item.sku} · ${item.source}", size = 10.sp, mono = true, maxLines = 1,
                color = if (photo != null) Color.Black.copy(alpha = 0.5f) else if (lead) T.accentInk.copy(alpha = 0.7f) else T.muted)
        }
    }
}

/** A product photo (or brand letters) in a small rounded square. */
@Composable
fun ProductThumb(item: Item, size: Dp = 76.dp) {
    val photo = rememberProductPhoto(item)
    val shape = RoundedCornerShape(14.dp)
    Box(Modifier.size(size).clip(shape).background(if (photo != null) Color.White else T.glass).border(1.dp, T.line, shape), contentAlignment = Alignment.Center) {
        if (photo != null) Image(photo, null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize().padding(4.dp))
        else {
            Box(Modifier.fillMaxSize().background(Brush.radialGradient(listOf(T.blue.copy(alpha = 0.35f), Color.Transparent))))
            Txt(brandInitials(item.brand, 2), size = (size.value * 0.3f).sp, weight = FontWeight.Black)
        }
    }
}

/** A local picture (taste photo or icon photo) filling its box. */
@Composable
fun BitmapImage(bitmap: Bitmap, modifier: Modifier = Modifier, crop: Boolean = true) {
    Image(remember(bitmap) { bitmap.asImageBitmap() }, null, modifier = modifier, contentScale = if (crop) ContentScale.Crop else ContentScale.Fit)
}

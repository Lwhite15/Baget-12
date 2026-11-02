package app.baget.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.baget.engine.AppStore
import app.baget.engine.myPalette

// MARK: Rings

/** A ring around someone's icon. Owned rings come from the server (my_rings / friend_icons); the app only draws them. */
enum class Ring(val raw: String, val title: String, val detail: String) {
    CREATOR("creator", "Creator · 1 of 1", "The one and only. Worn by Baget's creator."),
    FOUNDING("founding", "Founding tester", "Gold and silver, for Baget's founding testers. Given, never earned, so no one else can ever get it."),
    FIRST_LIKE("first_like", "First like", "Heart your first find."),
    CREW_3("crew_3", "Crew of 3", "Add three friends."),
    STREAK_7("streak_7", "7-day streak", "Like or pass finds 7 days in a row."),
    FIRST_BUY("first_buy", "First buy", "Buy something your scout found."),
    PRO_GLOW("pro_glow", "Pro glow", "A ring that shimmers. Pro members only.");

    val short: String get() = when (this) { CREATOR -> "Creator"; FOUNDING -> "Founding"; else -> title }

    /** The ring's colors. Gold and silver belong to Founding tester alone; black and gold to Creator alone. */
    val colors: List<Color> get() = when (this) {
        CREATOR -> listOf(Color(0.06f, 0.06f, 0.07f), Color(0.96f, 0.82f, 0.48f), Color(0.10f, 0.09f, 0.08f), Color(0.91f, 0.71f, 0.63f),
            Color(0.05f, 0.05f, 0.06f), Color(1.0f, 0.88f, 0.55f), Color(0.06f, 0.06f, 0.07f))
        FOUNDING -> listOf(Color(0.97f, 0.91f, 0.66f), Color(0.83f, 0.65f, 0.22f), Color(1.0f, 0.96f, 0.84f), Color(0.79f, 0.81f, 0.84f),
            Color(0.56f, 0.59f, 0.64f), Color(0.93f, 0.95f, 0.96f), Color(0.73f, 0.54f, 0.16f), Color(0.97f, 0.91f, 0.66f))
        FIRST_LIKE -> listOf(T.green, Color(0.62f, 0.96f, 0.81f), T.green)
        CREW_3 -> listOf(T.hot, Color(0.55f, 0.36f, 0.96f), T.hot)
        STREAK_7 -> listOf(Color(1f, 0.54f, 0.36f), T.hot, T.warn, Color(1f, 0.54f, 0.36f))
        FIRST_BUY -> listOf(T.blue, T.cyan, T.green, Color(0.55f, 0.36f, 0.96f), T.blue)
        PRO_GLOW -> listOf(T.blue, T.cyan, T.green, T.warn, T.hot, Color(0.55f, 0.36f, 0.96f), T.blue)
    }
    /** The little seal on the ring's edge (only the two rings that can't be earned have one). */
    val seal: ImageVector? get() = when (this) { CREATOR -> Icons.Filled.WorkspacePremium; FOUNDING -> Icons.Filled.Star; else -> null }
    val glow: Color? get() = when (this) {
        CREATOR -> Color(0.96f, 0.80f, 0.40f); FOUNDING -> Color(0.94f, 0.80f, 0.45f); PRO_GLOW -> T.cyan; else -> null
    }

    companion object {
        fun of(raw: String?): Ring? = entries.firstOrNull { it.raw == raw }
        /** The order rings are listed in. */
        val listed: List<Ring> = listOf(CREATOR, FOUNDING, FIRST_LIKE, CREW_3, STREAK_7, FIRST_BUY, PRO_GLOW)
        /** Rings anyone can earn by using Baget (creator and founding are given, never earned). */
        val earnable: List<Ring> = listOf(FIRST_LIKE, CREW_3, STREAK_7, FIRST_BUY)
    }
}

/** Draws an icon inside its ring, keeping the same overall size. No ring: just the icon. */
@Composable
fun RingFrame(ring: Ring?, size: Dp, content: @Composable (Dp) -> Unit) {
    if (ring == null) { content(size); return }
    val width = maxOf(2.dp, size * 0.075f)
    val angle = if (ring == Ring.PRO_GLOW) {
        val t = rememberInfiniteTransition(label = "ring")
        val a by t.animateFloat(0f, 360f, infiniteRepeatable(tween(6000, easing = LinearEasing), RepeatMode.Restart), label = "spin")
        a
    } else 0f
    Box(Modifier.size(size), contentAlignment = Alignment.Center) {
        content(size - width * 2.6f)
        Box(Modifier.fillMaxSize().rotate(angle).drawBehind {
            val w = width.toPx()
            ring.glow?.let { g -> drawCircle(g.copy(alpha = 0.25f), radius = this.size.minDimension / 2, style = Stroke(w * 2.2f)) }
            drawCircle(Brush.sweepGradient(ring.colors), radius = this.size.minDimension / 2 - w / 2, style = Stroke(w))
            if (ring == Ring.FOUNDING || ring == Ring.CREATOR) {
                // A sheen across the metal.
                drawCircle(Brush.linearGradient(listOf(Color.Transparent, Color.White.copy(alpha = 0.5f), Color.Transparent),
                    start = Offset(0.15f * this.size.width, 0.1f * this.size.height), end = Offset(0.85f * this.size.width, 0.9f * this.size.height)),
                    radius = this.size.minDimension / 2 - w / 2, style = Stroke(w * 0.6f))
            }
        })
        val seal = ring.seal
        if (seal != null && size >= 30.dp) {
            val creator = ring == Ring.CREATOR
            Box(Modifier.align(Alignment.Center).offset(x = size * 0.35f, y = size * 0.35f).size(size * 0.28f)
                .background(if (creator) Brush.linearGradient(listOf(Color(0.06f, 0.06f, 0.07f), Color(0.06f, 0.06f, 0.07f))) else Brush.sweepGradient(Ring.FOUNDING.colors), CircleShape)
                .border(maxOf(1.dp, size * 0.02f), if (creator) Color(1f, 0.86f, 0.5f) else T.bg, CircleShape),
                contentAlignment = Alignment.Center) {
                Icon(seal, null, tint = if (creator) Color(1f, 0.86f, 0.5f) else Color(0.23f, 0.16f, 0.02f), modifier = Modifier.size(size * 0.16f))
            }
        }
    }
}

// MARK: Baget icons

/** Icons drawn for Baget, stored by the iPhone's symbol names so both apps show the same pick. */
object BagetGlyph {
    val all: List<String> = listOf("shoe.fill", "tshirt.fill", "drop.fill", "watch.analog", "binoculars.fill", "bag.fill", "handbag.fill",
        "car.fill", "tag.fill", "crown.fill", "sunglasses.fill", "diamond.fill", "flame.fill", "headphones",
        "camera.fill", "skateboard.fill", "basketball.fill", "sofa.fill", "gift.fill", "sparkles")
    val available: List<String> get() = all

    fun icon(name: String?): ImageVector = when (name) {
        "shoe.fill" -> Icons.Filled.Hiking
        "tshirt.fill" -> Icons.Filled.Checkroom
        "drop.fill" -> Icons.Filled.WaterDrop
        "watch.analog" -> Icons.Filled.Watch
        "binoculars.fill" -> Icons.Filled.TravelExplore
        "bag.fill" -> Icons.Filled.ShoppingBag
        "handbag.fill" -> Icons.Filled.LocalMall
        "car.fill" -> Icons.Filled.DirectionsCar
        "tag.fill" -> Icons.Filled.LocalOffer
        "crown.fill" -> Icons.Filled.WorkspacePremium
        "sunglasses.fill" -> Icons.Filled.RemoveRedEye
        "diamond.fill" -> Icons.Filled.Diamond
        "flame.fill" -> Icons.Filled.LocalFireDepartment
        "headphones" -> Icons.Filled.Headphones
        "camera.fill" -> Icons.Filled.PhotoCamera
        "skateboard.fill" -> Icons.Filled.Skateboarding
        "basketball.fill" -> Icons.Filled.SportsBasketball
        "sofa.fill" -> Icons.Filled.Weekend
        "gift.fill" -> Icons.Filled.CardGiftcard
        else -> Icons.Filled.AutoAwesome
    }
}

/** "#335fa0" → a color. */
fun hexColor(hex: String): Color? {
    val h = hex.trim().removePrefix("#")
    if (h.length != 6) return null
    val v = h.toLongOrNull(16) ?: return null
    return Color(((v shr 16) and 0xff).toInt(), ((v shr 8) and 0xff).toInt(), (v and 0xff).toInt())
}

/** The fill behind an initials, emoji or Baget icon: a palette color, or your Taste Card's colors. */
object AvatarFill {
    /** The "taste palette" color index (your Taste Card's own colors). */
    const val TASTE = 100
    fun brush(color: Int, palette: List<String>?): Brush {
        if (color == TASTE) {
            val p = palette?.mapNotNull { hexColor(it) } ?: emptyList()
            if (p.size >= 2) return Brush.sweepGradient(p + p[0])
        }
        return AvatarPalette.gradient(if (color == TASTE) 0 else color)
    }
    fun ink(color: Int): Color = if (color == TASTE) Color.White else AvatarPalette.ink(color)
}

/** Your own taste palette, for the color row in Settings. */
val AppStore.tasteBrush: Brush get() = AvatarFill.brush(AvatarFill.TASTE, myPalette)

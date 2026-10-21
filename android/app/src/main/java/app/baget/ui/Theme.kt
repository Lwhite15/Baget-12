package app.baget.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Deep navy lit with blue, cyan and green, glass panels, gradient actions. Same look as the iPhone app. */
object T {
    val bg = Color(0.02f, 0.04f, 0.09f)
    val panel = Color(0.05f, 0.08f, 0.15f)
    val ink = Color(0.92f, 0.95f, 1.0f)
    val muted = Color(0.55f, 0.62f, 0.73f)
    val line = Color(0.58f, 0.75f, 1.0f, 0.14f)
    val glass = Color(0.58f, 0.75f, 1.0f, 0.06f)
    val blue = Color(0.23f, 0.51f, 1.0f)
    val cyan = Color(0.13f, 0.83f, 0.93f)
    val green = Color(0.20f, 0.90f, 0.65f)
    val accent = Color(0.31f, 0.76f, 1.0f)
    val accentInk = Color(0.01f, 0.07f, 0.11f)
    val warn = Color(1.0f, 0.78f, 0.34f)
    val hot = Color(1.0f, 0.36f, 0.49f)
    val ground = Color(0xFF2B3BFF)
    val visor = Color(0xFFFF6A1A)

    val gradient: Brush get() = Brush.linearGradient(listOf(blue, cyan, green))
    val barGradient: Brush get() = Brush.verticalGradient(listOf(green, cyan, blue))

    // Type, roughly matching iOS sizes
    val caption2 = 11.sp
    val caption = 12.sp
    val footnote = 13.sp
    val subhead = 15.sp
    val body = 17.sp
    val title3 = 20.sp
    val title2 = 22.sp
}

val BagetColors = darkColorScheme(
    primary = T.accent, onPrimary = T.accentInk, secondary = T.cyan, onSecondary = T.accentInk,
    background = T.bg, onBackground = T.ink, surface = T.panel, onSurface = T.ink, surfaceVariant = T.panel,
    onSurfaceVariant = T.muted, outline = T.line, error = T.hot, surfaceContainer = T.panel, surfaceContainerHigh = T.panel,
    surfaceContainerHighest = T.panel, surfaceContainerLow = T.bg,
)

@Composable
fun BagetTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = BagetColors, typography = Typography(), content = content)
}

/** The lit background behind every screen. */
fun Modifier.litBackground(): Modifier = this
    .background(T.bg)
    .drawBehind {
        val w = size.width; val h = size.height
        drawRect(Brush.radialGradient(listOf(T.blue.copy(alpha = 0.30f), Color.Transparent), center = Offset(-0.1f * w, 0.15f * h), radius = 520.dp.toPx()))
        drawRect(Brush.radialGradient(listOf(T.cyan.copy(alpha = 0.22f), Color.Transparent), center = Offset(0.95f * w, -0.05f * h), radius = 480.dp.toPx()))
        drawRect(Brush.radialGradient(listOf(T.green.copy(alpha = 0.16f), Color.Transparent), center = Offset(0.6f * w, 1.1f * h), radius = 520.dp.toPx()))
    }

fun Modifier.glassCard(highlighted: Boolean = false, padding: Dp = 16.dp): Modifier {
    val shape = RoundedCornerShape(20.dp)
    return this
        .clip(shape)
        .background(Brush.verticalGradient(listOf(T.glass.copy(alpha = 0.08f), T.glass.copy(alpha = 0.036f))), shape)
        .then(if (highlighted) Modifier.border(1.dp, T.gradient, shape) else Modifier.border(1.dp, T.line, shape))
        .padding(padding)
}

fun Modifier.glass(shape: Shape = RoundedCornerShape(16.dp), tint: Color = T.glass, stroke: Color = T.line): Modifier =
    this.clip(shape).background(tint, shape).border(1.dp, stroke, shape)

/** A tap target with no ripple artifacts on dark glass. */
@Composable
fun Modifier.tap(enabled: Boolean = true, onClick: () -> Unit): Modifier =
    this.clickable(enabled = enabled, interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onClick)

@Composable
fun Txt(text: String, size: TextUnit = T.subhead, color: Color = T.ink, weight: FontWeight = FontWeight.Normal, modifier: Modifier = Modifier,
        maxLines: Int = Int.MAX_VALUE, align: TextAlign? = null, mono: Boolean = false, tracking: TextUnit = TextUnit.Unspecified,
        italic: Boolean = false) {
    Text(text, modifier = modifier, color = color, fontSize = size, fontWeight = weight, maxLines = maxLines, overflow = TextOverflow.Ellipsis,
        textAlign = align, letterSpacing = tracking,
        style = TextStyle(fontFamily = if (mono) FontFamily.Monospace else FontFamily.Default,
            fontStyle = if (italic) androidx.compose.ui.text.font.FontStyle.Italic else androidx.compose.ui.text.font.FontStyle.Normal))
}

@Composable
fun GradientText(text: String, size: TextUnit, weight: FontWeight = FontWeight.Black, modifier: Modifier = Modifier) {
    Text(text, modifier = modifier, fontSize = size, fontWeight = weight, style = TextStyle(brush = T.gradient))
}

/** Uppercase small label, like iOS section captions. */
@Composable
fun Kick(text: String, color: Color = T.muted, modifier: Modifier = Modifier) {
    Txt(text.uppercase(), size = T.caption, color = color, weight = FontWeight.Bold, tracking = 1.sp, modifier = modifier)
}

@Composable
fun PrimaryButton(text: String, modifier: Modifier = Modifier, icon: ImageVector? = null, enabled: Boolean = true, busy: Boolean = false,
                  onClick: () -> Unit) {
    val shape = RoundedCornerShape(13.dp)
    Row(modifier
        .heightIn(min = 44.dp)
        .clip(shape)
        .background(if (enabled) T.gradient else Brush.linearGradient(listOf(T.muted.copy(alpha = 0.4f), T.muted.copy(alpha = 0.4f))), shape)
        .clickable(enabled = enabled && !busy, onClick = onClick)
        .padding(horizontal = 12.dp, vertical = 11.dp),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
        if (busy) CircularProgressIndicator(color = T.accentInk, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
        else {
            if (icon != null) { Icon(icon, null, tint = T.accentInk, modifier = Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)) }
            Txt(text, color = T.accentInk, weight = FontWeight.Bold, maxLines = 1)
        }
    }
}

@Composable
fun GhostButton(text: String, modifier: Modifier = Modifier, icon: ImageVector? = null, enabled: Boolean = true, tint: Color = T.ink,
                busy: Boolean = false, onClick: () -> Unit) {
    val shape = RoundedCornerShape(13.dp)
    Row(modifier
        .heightIn(min = 42.dp)
        .glass(shape)
        .clickable(enabled = enabled && !busy, onClick = onClick)
        .padding(horizontal = 10.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
        if (busy) CircularProgressIndicator(color = T.accent, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
        else {
            if (icon != null) { Icon(icon, null, tint = tint, modifier = Modifier.size(17.dp)); if (text.isNotEmpty()) Spacer(Modifier.width(6.dp)) }
            if (text.isNotEmpty()) Txt(text, color = if (enabled) tint else T.muted, weight = FontWeight.SemiBold, maxLines = 1)
        }
    }
}

@Composable
fun Pill(text: String, selected: Boolean = false, modifier: Modifier = Modifier, onClick: (() -> Unit)? = null) {
    val m = modifier.clip(CircleShape).let { if (selected) it.background(T.gradient) else it.background(T.glass).border(1.dp, T.line, CircleShape) }
        .let { if (onClick != null) it.clickable(onClick = onClick) else it }
        .padding(horizontal = 14.dp, vertical = 8.dp)
    Box(m) { Txt(text, color = if (selected) T.accentInk else T.ink, weight = FontWeight.SemiBold, maxLines = 1) }
}

@Composable
fun Tag(text: String, tint: Color? = null, modifier: Modifier = Modifier) {
    Box(modifier.clip(CircleShape).background((tint ?: T.accent).copy(alpha = if (tint == null) 0.10f else 0.14f)).padding(horizontal = 9.dp, vertical = 4.dp)) {
        Txt(text, size = T.caption, color = tint ?: T.ink, weight = FontWeight.Medium, maxLines = 1)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun Flow(spacing: Dp = 6.dp, content: @Composable () -> Unit) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(spacing), verticalArrangement = Arrangement.spacedBy(spacing)) { content() }
}

@Composable
fun Meter(value: Double, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().height(6.dp).clip(CircleShape).background(T.glass.copy(alpha = 0.1f))) {
        Box(Modifier.fillMaxHeight().fillMaxWidth(value.coerceIn(0.03, 1.0).toFloat()).clip(CircleShape).background(T.gradient))
    }
}

@Composable
fun SectionTitle(text: String) {
    Txt(text, size = T.title3, weight = FontWeight.Bold, modifier = Modifier.fillMaxWidth())
}

@Composable
fun EmptyCard(text: String) {
    val stroke = T.line
    Box(Modifier.fillMaxWidth().drawBehind {
        drawRoundRect(stroke, style = Stroke(width = 1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(5.dp.toPx(), 5.dp.toPx()))),
            cornerRadius = CornerRadius(18.dp.toPx()))
    }.padding(28.dp), contentAlignment = Alignment.Center) {
        Txt(text, color = T.muted, align = TextAlign.Center)
    }
}

/** Baget's logo, the "Agent b": a lowercase b whose bowl wears an orange visor. Same drawing as the home-screen icon. */
@Composable
fun AppIcon(size: Dp = 36.dp) {
    Canvas(Modifier.size(size).clip(RoundedCornerShape(size * 0.224f)).background(T.ground)) {
        val k = this.size.width / 100f
        fun r(x: Float, y: Float) = Offset(x * k, y * k)
        drawRoundRect(Color.White, topLeft = r(23f, 17f), size = Size(12 * k, 66 * k), cornerRadius = CornerRadius(6 * k))
        drawCircle(Color.White, radius = 26 * k, center = r(51f, 57f))
        drawCircle(T.ground, radius = 14 * k, center = r(51f, 57f))
        drawRoundRect(T.visor, topLeft = r(40f, 53f), size = Size(22 * k, 8 * k), cornerRadius = CornerRadius(4 * k))
    }
}

@Composable
fun BagetWordmark(size: TextUnit = 22.sp) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("Baget", color = T.ink, fontSize = size, fontWeight = FontWeight.Black, letterSpacing = (-0.8).sp)
        Text(".", fontSize = size, fontWeight = FontWeight.Black, style = TextStyle(brush = T.gradient))
    }
}

/** Small mono badge: "NEW", "SOLD OUT", "IN 3H 10M". */
@Composable
fun MonoBadge(text: String, tint: Color) {
    Box(Modifier.clip(CircleShape).background(tint.copy(alpha = 0.14f)).padding(horizontal = 6.dp, vertical = 2.dp)) {
        Txt(text, size = 9.sp, color = tint, weight = FontWeight.Bold, mono = true, maxLines = 1)
    }
}

/** A labelled value: "PRICE  $215". */
@Composable
fun Stat(label: String, value: String, tint: Color? = null, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Txt(label.uppercase(), size = 9.sp, color = T.muted, weight = FontWeight.SemiBold, tracking = 1.sp, maxLines = 1)
        Txt(value, color = tint ?: T.ink, weight = FontWeight.SemiBold, mono = true, maxLines = 1)
    }
}

/** A field with the glass look. */
@Composable
fun Field(value: String, onChange: (String) -> Unit, placeholder: String, modifier: Modifier = Modifier, singleLine: Boolean = true,
          minLines: Int = 1, maxLines: Int = if (singleLine) 1 else 4, keyboard: androidx.compose.foundation.text.KeyboardOptions = androidx.compose.foundation.text.KeyboardOptions.Default,
          actions: androidx.compose.foundation.text.KeyboardActions = androidx.compose.foundation.text.KeyboardActions.Default,
          password: Boolean = false, leading: (@Composable () -> Unit)? = null, trailing: (@Composable () -> Unit)? = null, enabled: Boolean = true) {
    OutlinedTextField(value = value, onValueChange = onChange, modifier = modifier,
        placeholder = { Txt(placeholder, color = T.muted, maxLines = maxLines) }, singleLine = singleLine, minLines = minLines, maxLines = maxLines,
        keyboardOptions = keyboard, keyboardActions = actions, enabled = enabled,
        visualTransformation = if (password) androidx.compose.ui.text.input.PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        leadingIcon = leading, trailingIcon = trailing,
        shape = RoundedCornerShape(14.dp),
        colors = OutlinedTextFieldDefaults.colors(
            focusedContainerColor = T.bg.copy(alpha = 0.6f), unfocusedContainerColor = T.bg.copy(alpha = 0.6f), disabledContainerColor = T.bg.copy(alpha = 0.4f),
            focusedBorderColor = T.accent.copy(alpha = 0.7f), unfocusedBorderColor = T.line, cursorColor = T.accent,
            focusedTextColor = T.ink, unfocusedTextColor = T.ink))
}

/** A settings row with a switch. */
@Composable
fun SwitchRow(title: String, detail: String? = null, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Txt(title)
            if (detail != null) Txt(detail, size = T.caption, color = T.muted)
        }
        Spacer(Modifier.width(10.dp))
        Switch(checked = checked, onCheckedChange = onChange,
            colors = SwitchDefaults.colors(checkedTrackColor = T.green, checkedThumbColor = Color.White, uncheckedTrackColor = T.glass.copy(alpha = 0.2f)))
    }
}

/** A grouped list section, like an iOS Form section. */
@Composable
fun FormSection(header: String? = null, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth()) {
        if (header != null) Kick(header, modifier = Modifier.padding(start = 4.dp, bottom = 6.dp))
        Column(Modifier.fillMaxWidth().glass(RoundedCornerShape(16.dp)).padding(horizontal = 14.dp, vertical = 8.dp), content = content)
        if (footer != null) Txt(footer, size = T.caption, color = T.muted, modifier = Modifier.padding(start = 4.dp, top = 6.dp, end = 4.dp))
    }
}

@Composable
fun RowButton(text: String, icon: ImageVector? = null, tint: Color = T.ink, trailing: String? = null, enabled: Boolean = true, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(enabled = enabled, onClick = onClick).padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        if (icon != null) { Icon(icon, null, tint = if (tint == T.ink) T.accent else tint, modifier = Modifier.size(20.dp)); Spacer(Modifier.width(12.dp)) }
        Txt(text, color = if (enabled) tint else T.muted, modifier = Modifier.weight(1f))
        if (trailing != null) Txt(trailing, size = T.footnote, color = T.green)
    }
}

@Composable
fun Hairline() { Box(Modifier.fillMaxWidth().height(1.dp).background(T.line)) }

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun Spinner(size: Dp = 20.dp, color: Color = T.cyan) {
    CircularProgressIndicator(color = color, strokeWidth = 2.dp, modifier = Modifier.size(size))
}

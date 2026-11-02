package app.baget.engine

/**
 * The app's language, sent to the server so scouts text and chat in it (iOS sends its per-app language).
 * The Android app is English-only for now, so this is always "en".
 */
object AppLanguage {
    val code: String get() = "en"
}

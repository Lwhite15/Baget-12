package app.baget.engine

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import app.baget.model.*
import kotlinx.coroutines.launch
import java.io.File
import java.util.Calendar

/** First-launch state for the sample tour: a sample squad, sample friends and a few months of sample purchases. */
fun AppStore.seed() {
    state.catalogStart = now()
    fun agent(id: String, name: String, c: Category, kw: List<String>, traits: List<String>, makers: List<String>, creators: List<String>,
              size: String, mode: BuyMode, voice: Voice) =
        Agent(id, name, Mission.Cat(c), kw.toMutableList(), StyleProfile(traits.toMutableList(), makers.toMutableList(), creators.toMutableList()),
            size, mode, voice)
    state.agents = mutableListOf(
        agent("a1", "Jumpman Scout", Category.SNEAKERS, listOf("aj1", "retro"), listOf("jordan 1", "suede", "low top"), listOf("Jordan"),
            listOf("Travis Scott"), "US M 10.5", BuyMode.ASK, Voice.HYPE),
        agent("a2", "Thursday Drop Desk", Category.APPAREL, listOf("box logo"), listOf("heavyweight fleece", "outerwear"), listOf("Supreme", "Stüssy"),
            listOf("The North Face"), "L", BuyMode.ALERT, Voice.HYPE),
        agent("a3", "Knightsbridge Nose", Category.FRAGRANCE, listOf("harrods exclusive"), listOf("oud", "rose", "saffron", "incense"),
            listOf("Frédéric Malle", "Maison Francis Kurkdjian"), listOf("Dominique Ropion"), "50ml or 100ml", BuyMode.ASK, Voice.CHILL),
        agent("a4", "Air-Cooled Desk", Category.CARS, listOf("911"), listOf("air-cooled", "manual", "coupe"), listOf("Porsche", "BMW M"),
            emptyList(), "", BuyMode.ALERT, Voice.STRAIGHT),
        agent("a5", "Studio Hunter", Category.FURNITURE, emptyList(), listOf("mid-century", "walnut", "teak", "cane"), listOf("Herman Miller"),
            listOf("Pierre Jeanneret", "Eames"), "", BuyMode.ASK, Voice.CHILL),
    )

    fun daysIntoMonth(monthsAgo: Int, day: Int): Long = Calendar.getInstance().apply {
        set(Calendar.DAY_OF_MONTH, 1); set(Calendar.HOUR_OF_DAY, 15); set(Calendar.MINUTE, 0)
        add(Calendar.MONTH, -monthsAgo); add(Calendar.DAY_OF_MONTH, day - 1)
    }.timeInMillis
    fun p(m: Int, d: Int, title: String, amt: Double, agent: String, cat: Category) =
        Purchase(uuid(), daysIntoMonth(m, d), title, amt, agent, cat, isSample = true)
    state.purchases = mutableListOf(
        p(3, 12, "New Balance 9060", 150.0, "a1", Category.SNEAKERS), p(3, 25, "Stüssy Basic Tee", 50.0, "a2", Category.APPAREL),
        p(3, 28, "Byredo Bal d'Afrique, 50ml", 205.0, "a3", Category.FRAGRANCE),
        p(2, 3, "Air Jordan 4 Retro", 215.0, "a1", Category.SNEAKERS), p(2, 14, "Le Labo Santal 33, 50ml", 220.0, "a3", Category.FRAGRANCE),
        p(2, 21, "Supreme Tee", 54.0, "a2", Category.APPAREL), p(2, 27, "Vitra Eames Elephant", 245.0, "a5", Category.FURNITURE),
        p(1, 9, "Maison Margiela Replica Jazz Club, 100ml", 160.0, "a3", Category.FRAGRANCE), p(1, 18, "Supreme Box Logo Crewneck", 168.0, "a2", Category.APPAREL),
        p(1, 22, "Nike Dunk Low", 115.0, "a1", Category.SNEAKERS), p(1, 27, "Herman Miller Eames Molded Plastic Side Chair", 495.0, "a5", Category.FURNITURE),
        p(0, 1, "Air Jordan 1 Retro Low OG", 185.0, "a1", Category.SNEAKERS),
    )

    state.friends = mutableListOf(
        Friend("u1", "Dre Johnson", "@dre.kicks", listOf(Category.SNEAKERS, Category.APPAREL), listOf("jordan 1", "suede", "fleece", "outerwear"),
            replies = listOf("W. Cop it before it's gone.", "Yo that's hard. What size you grabbing?", "Saw that this morning, it's even better in person.")),
        Friend("u2", "Maya Chen", "@mayac", listOf(Category.FRAGRANCE, Category.FURNITURE), listOf("rose", "oud", "mid-century", "walnut"),
            replies = listOf("Okay obsessed. Send me your thoughts after you try it.", "This is so you. Do it.", "Ooh, adding that to my list too.")),
        Friend("u3", "Sam Patel", "@samp", listOf(Category.WATCHES, Category.CARS), listOf("manual", "air-cooled", "steel", "integrated bracelet"),
            replies = listOf("That's a forever piece. Respect.", "Check the service history before you commit.", "Absolute grail. Keep me posted.")),
    )
    fun itemID(prefix: String) = Catalog.items.firstOrNull { it.title.startsWith(prefix) }?.id
    val hour = 3_600_000L
    state.suggestions = listOfNotNull(
        itemID("Travis Scott")?.let { Suggestion("s1", "u1", it, "Your size is still showing on SNKRS. Don't sleep on these.", now() - (1.5 * hour).toLong()) },
        itemID("Armani Privé Rose")?.let { Suggestion("s2", "u2", it, "Rose and oud together. Literally your whole thing.", now() - 5 * hour) },
        itemID("1995 Porsche 911")?.let { Suggestion("s3", "u3", it, "Air-cooled, manual, coupe. You know you want it.", now() - 20 * hour) },
    ).toMutableList()
    state.liveTabs = LiveTab.presets.toMutableList()
    state.lastSeen = now()
    sweep(quiet = true)
}

// MARK: Icons: yours and your agents', kept on this phone and in your account so they follow you to a new phone

private val AppStore.avatarDir: File get() = File(context.filesDir, "avatar").also { it.mkdirs() }
private fun AppStore.avatarFile(id: String) = File(avatarDir, "$id.jpg")
private fun avatarPath(id: String, uid: String) = "$uid/avatars/$id.jpg"

/** Initials for your icon: from your name, else your handle, else "B". */
val AppStore.initials: String get() {
    val words = (state.profile?.displayName?.trim() ?: "").split(" ").filter { it.isNotEmpty() }
    if (words.size >= 2) return (words.first().take(1) + words.last().take(1)).uppercase()
    words.firstOrNull()?.let { return it.take(2).uppercase() }
    state.profile?.handle?.takeIf { it.isNotEmpty() }?.let { return it.take(2).uppercase() }
    return "B"
}

val AppStore.avatarImage: Bitmap? get() = if (state.avatar.style == Avatar.Style.PHOTO) iconImage(state.avatar.photoID) else null

/** A cached icon photo, downloaded from your account the first time this phone needs it. */
fun AppStore.iconImage(photoID: String?): Bitmap? {
    avatarVersion
    val id = photoID ?: return null
    val f = avatarFile(id)
    if (f.exists()) BitmapFactory.decodeFile(f.path)?.let { return it }
    fetchAvatarIfNeeded(id)
    return null
}

/** Crops to a square and keeps a small copy on this phone. Returns its id and bytes for uploading. */
fun AppStore.storeIconPhoto(image: Bitmap): Pair<String, ByteArray> {
    val jpeg = Images.jpeg(Images.scaled(Images.squareCrop(Images.scaled(image, 1024)), 512), 82)
    val id = uuid()
    runCatching { avatarFile(id).writeBytes(jpeg) }
    avatarVersion++
    return id to jpeg
}

/** Uploads an icon photo, then runs `then` (so other devices only hear about photos that exist). */
fun AppStore.uploadIconPhoto(id: String, jpeg: ByteArray, replacing: String? = null, then: (suspend (Backend) -> Unit)? = null) {
    val uid = Backend.userID ?: return
    if (!isCloud) return
    val path = avatarPath(id, uid)
    val oldPath = replacing?.let { avatarPath(it, uid) }
    push {
        it.upload("taste-photos", path, jpeg)
        then?.invoke(it)
        if (oldPath != null) runCatching { it.removeFile("taste-photos", oldPath) }
    }
}

fun AppStore.deleteIconPhoto(id: String?) {
    id ?: return
    avatarFile(id).delete()
    avatarVersion++
    val uid = Backend.userID
    if (isCloud && uid != null) {
        val path = avatarPath(id, uid)
        push { runCatching { it.removeFile("taste-photos", path) } }
    }
}

fun AppStore.setAvatarStyle(style: Avatar.Style) {
    if (state.avatar.style == style) return
    state.avatar.style = style
    save()
}

fun AppStore.setAvatarEmoji(emoji: String) {
    state.avatar.emoji = emoji
    state.avatar.style = Avatar.Style.EMOJI
    save()
}

fun AppStore.setAvatarColor(index: Int) {
    state.avatar.color = index
    if (state.avatar.style == Avatar.Style.PHOTO) state.avatar.style = Avatar.Style.INITIALS
    save()
}

fun AppStore.setAvatarPhoto(image: Bitmap) {
    val (id, jpeg) = storeIconPhoto(image)
    val old = state.avatar.photoID
    if (old != null) avatarFile(old).delete()
    state.avatar.photoID = id
    state.avatar.style = Avatar.Style.PHOTO
    if (isCloud) uploadIconPhoto(id, jpeg, old) { save() } else save()
    tickNow()
    Analytics.track(AnalyticsEvent.AVATAR_CHANGED, mapOf("style" to "photo", "who" to "you"))
}

fun AppStore.removeAvatarPhoto() {
    val id = state.avatar.photoID ?: return
    state.avatar.photoID = null
    state.avatar.style = Avatar.Style.INITIALS
    save()
    deleteIconPhoto(id)
}

/** Sets an agent's icon. A new photo is kept on the phone, uploaded, then saved to the agent. */
fun AppStore.setAgentIcon(agentID: String, icon: Avatar?, photo: Bitmap?) {
    val a = agent(agentID) ?: return
    val oldPhoto = a.icon?.photoID
    var newIcon = icon?.copy()
    var upload: Pair<String, ByteArray>? = null
    if (photo != null) {
        val stored = storeIconPhoto(photo)
        upload = stored
        newIcon = (newIcon ?: Avatar()).copy(style = Avatar.Style.PHOTO, photoID = stored.first)
    }
    if (newIcon?.style != Avatar.Style.PHOTO) newIcon?.photoID = null
    a.icon = newIcon
    save()
    val keepsOld = newIcon?.photoID == oldPhoto
    if (!keepsOld && oldPhoto != null && upload == null) deleteIconPhoto(oldPhoto)
    val field = jobj("icon" to iconToJson(newIcon))
    if (upload != null) {
        uploadIconPhoto(upload.first, upload.second, if (keepsOld) null else oldPhoto) { it.update("agents", "id=eq.$agentID", field) }
        if (!isCloud && oldPhoto != null && !keepsOld) avatarFile(oldPhoto).delete()
    } else {
        push { it.update("agents", "id=eq.$agentID", field) }
    }
    Analytics.track(AnalyticsEvent.AVATAR_CHANGED, mapOf("style" to (newIcon?.style?.raw ?: "default"), "who" to "agent"))
}

private fun AppStore.fetchAvatarIfNeeded(id: String) {
    val uid = Backend.userID ?: return
    val key = "avatar-$id"
    if (!isCloud || key in downloading) return
    downloading.add(key)
    val path = avatarPath(id, uid)
    scope.launch {
        try {
            runCatching { Backend.download("taste-photos", path) }.getOrNull()?.let {
                runCatching { avatarFile(id).writeBytes(it) }
                avatarVersion++
            }
        } finally { downloading.remove(key) }
    }
}

/** Redraw without a save. */
fun AppStore.tickNow() { avatarVersion++ }

package app.baget.ui.screens

import android.app.Activity
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.NoCredentialException
import app.baget.BuildConfig
import app.baget.engine.*
import app.baget.ui.*
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import kotlinx.coroutines.launch

/** First screen when Baget is connected to a server: sign in, or look around with sample data. */
@Composable
fun WelcomeScreen() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var showEmail by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).statusBarsPadding().navigationBarsPadding().padding(horizontal = 24.dp, vertical = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally) {
        Spacer(Modifier.height(24.dp))
        AppIcon(84.dp)
        Spacer(Modifier.height(14.dp))
        BagetWordmark(48.sp)
        Spacer(Modifier.height(10.dp))
        Txt("Never miss what you'd love.", size = T.title2, weight = FontWeight.Bold, align = TextAlign.Center)
        Spacer(Modifier.height(10.dp))
        Txt("Baget gives you personal scouts that learn your taste, hunt the web and tell you when they find something worth buying.",
            size = T.body, color = T.muted, align = TextAlign.Center)
        Spacer(Modifier.height(28.dp))
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Feature(Icons.Filled.TravelExplore, "Whatever you're into, they find it",
                "Rare vinyl, a vintage chair, the perfect gift or your next car. Name it, and your scouts search stores, resale sites and small shops for you.")
            Feature(Icons.Filled.FavoriteBorder, "They learn your taste", "Every like and pass makes their next picks sharper.")
            Feature(Icons.Filled.NotificationsActive, "They tell you first", "A heads-up when something you'd love drops, restocks or goes on sale.")
        }
        Spacer(Modifier.height(28.dp))
        if (working) {
            Box(Modifier.height(52.dp), contentAlignment = Alignment.Center) { Spinner() }
        } else {
            if (BuildConfig.GOOGLE_WEB_CLIENT_ID.isNotEmpty()) {
                Row(Modifier.fillMaxWidth().height(52.dp).clip(RoundedCornerShape(14.dp)).background(Color.White)
                    .clickable {
                        error = null
                        scope.launch {
                            working = true
                            error = signInWithGoogle(context as Activity)
                            working = false
                        }
                    }, horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                    Txt("G", size = 20.sp, weight = FontWeight.Black, color = Color(0xFF4285F4))
                    Spacer(Modifier.width(10.dp))
                    Txt("Continue with Google", size = T.body, weight = FontWeight.SemiBold, color = Color.Black)
                }
                Spacer(Modifier.height(12.dp))
            }
            Row(Modifier.fillMaxWidth().height(52.dp).clip(RoundedCornerShape(14.dp)).border(1.dp, T.ink.copy(alpha = 0.35f), RoundedCornerShape(14.dp))
                .clickable { showEmail = true }, horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Email, null, tint = T.ink)
                Spacer(Modifier.width(8.dp))
                Txt("Continue with email", size = T.body, weight = FontWeight.SemiBold)
            }
        }
        error?.let { Spacer(Modifier.height(10.dp)); Txt(it, size = T.footnote, color = T.hot, align = TextAlign.Center) }
        Spacer(Modifier.height(12.dp))
        TextButton(onClick = { AppStore.exploreSamples() }) { Txt("Take a look first", weight = FontWeight.SemiBold, color = T.accent) }
        Row(horizontalArrangement = Arrangement.Center) {
            Txt("By continuing, you agree to the ", size = T.caption, color = T.muted)
        }
        Row(horizontalArrangement = Arrangement.Center) {
            Txt("Terms of Use", size = T.caption, color = T.accent, modifier = Modifier.clickable { open(context, TERMS_URL) })
            Txt(" and ", size = T.caption, color = T.muted)
            Txt("Privacy Policy", size = T.caption, color = T.accent, modifier = Modifier.clickable { open(context, PRIVACY_URL) })
            Txt(".", size = T.caption, color = T.muted)
        }
    }
    if (showEmail) EmailSignIn(onClose = { showEmail = false })
}

fun open(context: android.content.Context, url: String) {
    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
}

/** Sign in with Google through Android's account sheet. Returns an error to show, or null. */
suspend fun signInWithGoogle(activity: Activity): String? {
    val nonce = Backend.makeNonce()
    return try {
        val option = GetSignInWithGoogleOption.Builder(BuildConfig.GOOGLE_WEB_CLIENT_ID).setNonce(Backend.sha256(nonce)).build()
        val result = CredentialManager.create(activity).getCredential(activity, GetCredentialRequest.Builder().addCredentialOption(option).build())
        val cred = result.credential
        if (cred !is CustomCredential || cred.type != GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL) return "Google didn't send a sign-in token. Try again."
        val g = GoogleIdTokenCredential.createFrom(cred.data)
        Backend.signInWithIdToken("google", g.idToken, nonce)
        // The welcome screen goes away as soon as the account loads, so this runs on the app's own scope.
        val name = g.displayName
        AppStore.scope.launch { AppStore.didSignIn(name) }
        null
    } catch (e: GetCredentialCancellationException) {
        null
    } catch (e: NoCredentialException) {
        "No Google account on this phone. Add one in Settings, or continue with email."
    } catch (e: BackendError) {
        e.message
    } catch (e: Exception) {
        "Google sign-in didn't finish. Try again."
    }
}

@Composable
private fun Feature(icon: ImageVector, title: String, detail: String) {
    Row(Modifier.fillMaxWidth().glass().padding(14.dp), verticalAlignment = Alignment.Top) {
        Box(Modifier.size(36.dp).clip(RoundedCornerShape(10.dp)).background(T.cyan.copy(alpha = 0.12f)), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = T.cyan, modifier = Modifier.size(20.dp))
        }
        Spacer(Modifier.width(14.dp))
        Column {
            Txt(title, weight = FontWeight.SemiBold)
            Txt(detail, size = T.footnote, color = T.muted)
        }
    }
}

/** Sign in or create an account with an email address and password. */
@Composable
private fun EmailSignIn(onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    var creating by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val valid = email.contains("@") && email.contains(".") && password.length >= (if (creating) 8 else 1)

    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Box(Modifier.fillMaxSize().litBackground()) {
            SheetFrame(if (creating) "Create account" else "Sign in with email", leading = "Cancel", onLeading = onClose, trailing = null) {
                Column(Modifier.padding(16.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(Modifier.fillMaxWidth().glass(RoundedCornerShape(12.dp)).padding(3.dp)) {
                        listOf(false to "Sign in", true to "Create account").forEach { (v, label) ->
                            Box(Modifier.weight(1f).clip(RoundedCornerShape(10.dp)).background(if (creating == v) T.accent.copy(alpha = 0.22f) else Color.Transparent)
                                .clickable { creating = v; error = null }.padding(vertical = 9.dp), contentAlignment = Alignment.Center) {
                                Txt(label, weight = FontWeight.SemiBold, color = if (creating == v) T.ink else T.muted)
                            }
                        }
                    }
                    if (creating) Field(name, { name = it }, "Your name", Modifier.fillMaxWidth())
                    Field(email, { email = it }, "Email", Modifier.fillMaxWidth(), keyboard = KeyboardOptions(keyboardType = KeyboardType.Email))
                    Field(password, { password = it }, if (creating) "Password (8 or more characters)" else "Password", Modifier.fillMaxWidth(),
                        password = true, keyboard = KeyboardOptions(keyboardType = KeyboardType.Password))
                    error?.let { Txt(it, size = T.footnote, color = T.hot) }
                    PrimaryButton(if (creating) "Create account" else "Sign in", Modifier.fillMaxWidth(), enabled = valid, busy = working) {
                        scope.launch {
                            error = null; working = true
                            val address = email.trim().lowercase()
                            val fullName = name.trim()
                            try {
                                if (creating) Backend.signUpWithEmail(address, password, fullName) else Backend.signInWithEmail(address, password)
                                val n = if (creating && fullName.isNotEmpty()) fullName else null
                                AppStore.scope.launch { AppStore.didSignIn(n) }
                                onClose()
                            } catch (e: BackendError) {
                                val m = e.message
                                error = when {
                                    m.contains("invalid login", true) -> "That email and password don't match. Check them, or switch to Create account."
                                    m.contains("already registered", true) -> "There's already an account with that email. Switch to Sign in."
                                    else -> m
                                }
                            }
                            working = false
                        }
                    }
                }
            }
        }
    }
}

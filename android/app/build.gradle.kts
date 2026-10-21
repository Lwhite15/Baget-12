import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

// Push notifications need Firebase's config file. The cloud build writes it from a secret;
// without it the app builds and runs, just without push.
val hasFirebase = file("google-services.json").exists()
if (hasFirebase) apply(plugin = "com.google.gms.google-services")

/** Settings come from environment variables (the cloud build) or local.properties (a laptop). Never committed. */
val local = Properties().apply {
    val f = rootProject.file("local.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
fun setting(name: String, default: String = ""): String =
    System.getenv(name)?.takeIf { it.isNotBlank() } ?: local.getProperty(name)?.takeIf { it.isNotBlank() } ?: default

fun quoted(s: String) = "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

android {
    namespace = "app.baget"
    compileSdk = 36

    defaultConfig {
        applicationId = setting("BAGET_ANDROID_ID", "app.baget")
        minSdk = 26
        targetSdk = 36
        versionCode = setting("BAGET_BUILD_NUMBER", "1").toInt()
        versionName = setting("BAGET_VERSION", "1.0")

        val ref = setting("SUPABASE_PROJECT_REF")
        val url = setting("BAGET_SUPABASE_URL", if (ref.isNotEmpty()) "https://$ref.supabase.co" else "")
        buildConfigField("String", "SUPABASE_URL", quoted(url))
        buildConfigField("String", "SUPABASE_ANON_KEY", quoted(setting("SUPABASE_ANON_KEY")))
        buildConfigField("String", "GOOGLE_WEB_CLIENT_ID", quoted(setting("GOOGLE_WEB_CLIENT_ID")))
        buildConfigField("boolean", "HAS_FIREBASE", hasFirebase.toString())
    }

    signingConfigs {
        val ks = setting("ANDROID_KEYSTORE_FILE")
        if (ks.isNotEmpty() && file(ks).exists()) {
            create("release") {
                storeFile = file(ks)
                storePassword = setting("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = setting("ANDROID_KEY_ALIAS", "baget")
                keyPassword = setting("ANDROID_KEY_PASSWORD", setting("ANDROID_KEYSTORE_PASSWORD"))
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
        debug {
            // Same signing key as release when it's available, so Google sign-in works on test builds too.
            signingConfigs.findByName("release")?.let { signingConfig = it }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

    buildFeatures {
        compose = true
        buildConfig = true
    }
    packaging { resources { excludes += "/META-INF/{AL2.0,LGPL2.1}" } }
    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.09.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.lifecycle:lifecycle-process:2.9.4")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    implementation("androidx.work:work-runtime-ktx:2.10.5")
    implementation("androidx.exifinterface:exifinterface:1.4.1")
    implementation("androidx.browser:browser:1.9.0")

    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // Sign in with Google
    implementation("androidx.credentials:credentials:1.5.0")
    implementation("androidx.credentials:credentials-play-services-auth:1.5.0")
    implementation("com.google.android.libraries.identity.googleid:googleid:1.1.1")

    // Baget Pro through Google Play
    implementation("com.android.billingclient:billing-ktx:8.0.0")

    // Push notifications
    implementation(platform("com.google.firebase:firebase-bom:34.3.0"))
    implementation("com.google.firebase:firebase-messaging")

    debugImplementation("androidx.compose.ui:ui-tooling")
}

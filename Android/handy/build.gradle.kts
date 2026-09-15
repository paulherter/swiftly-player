import java.util.Properties

// Swiftly fuer Android-Telefone. Vorlage: Sources/Shared + Sources/iOS.
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

// **Signatur fuer den Play Store** — aus einer Datei ausserhalb aller Repos, die Paul selbst anlegt.
// Fehlt sie, baut `bundleRelease` unsigniert; Debug-Baue brauchen sie nie.
val signaturDatei = file(System.getProperty("user.home") + "/.swiftly-android/signatur.properties")
val signatur = Properties().apply { if (signaturDatei.exists()) signaturDatei.inputStream().use { load(it) } }

android {
    namespace = "de.paulherter.swiftly"
    signingConfigs {
        if (signaturDatei.exists()) create("play") {
            storeFile = file(signatur.getProperty("storeFile"))
            storePassword = signatur.getProperty("storePassword")
            keyAlias = signatur.getProperty("keyAlias")
            keyPassword = signatur.getProperty("keyPassword")
        }
    }
    buildTypes {
        getByName("release") {
            if (signaturDatei.exists()) signingConfig = signingConfigs.getByName("play")
            isMinifyEnabled = false
        }
    }
    compileSdk = 36
    defaultConfig {
        applicationId = "de.paulherter.swiftly"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.3"
        // **Nur arm64.** Der Swift-Kern wird nur fuer arm64-v8a gebaut; auf jeder anderen ABI
        // stuerzte die App beim Start. libVLC brachte vier ABIs mit — rund 135 MB, die nie liefen.
        ndk { abiFilters += listOf("arm64-v8a") }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }
    packaging {
        jniLibs {
            useLegacyPackaging = false
            // **Zweimal libc++_shared.so:** aus dem Kern (NDK r27, fuer die Swift-
            // Laufzeit) und aus libvlc-all. Die erste gewinnt — das Kernmodul steht
            // in den Abhaengigkeiten vorn, und die Swift-Laufzeit braucht die neuere.
            pickFirsts += "lib/**/libc++_shared.so"
        }
    }
}

dependencies {
    implementation(project(":kern"))
    implementation(project(":gemeinsam"))
    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)
    implementation(libs.androidx.material.icons.extended)
    implementation(libs.swiftkit.core)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.foundation)
    implementation(libs.androidx.material3)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.libvlc.all)
    implementation(libs.lottie.compose)
    implementation(libs.play.review.ktx)
}

// **Die Startanimation liegt einmal im Repo** (`Sources/Shared/Mittel`) und wird beim Bau
// hierher kopiert — eine zweite Datei liefe auseinander.
val startanimationKopieren by tasks.registering(Copy::class) {
    from(rootProject.file("../Sources/Shared/Mittel/startanimation.json"))
    into(layout.buildDirectory.dir("generated/startanimation"))
}
android.sourceSets.getByName("main").assets.srcDir(file("build/generated/startanimation"))
tasks.named("preBuild") { dependsOn(startanimationKopieren) }

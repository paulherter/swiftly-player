// Swiftly for Android phones. Mirrors Sources/Shared + Sources/iOS.
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

// **Signing for the Play Store.** The key lives outside all repos (`~/.swiftly-android/swiftly-upload.jks`),
// the password **in the macOS keychain** (entry `swiftly-android-signatur`), never in a file or the
// repo. The keychain is queried only for release builds; debug builds never need either.
val uploadKey = file(System.getProperty("user.home") + "/.swiftly-android/swiftly-upload.jks")
val releaseBuild = gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }
val signingPassword: String? = if (releaseBuild && uploadKey.exists()) runCatching {
    providers.exec { commandLine("security", "find-generic-password", "-s", "swiftly-android-signatur", "-w") }
        .standardOutput.asText.get().trim().ifEmpty { null }
}.getOrNull() else null

android {
    namespace = "de.paulherter.swiftly"
    signingConfigs {
        if (signingPassword != null) create("play") {
            storeFile = uploadKey
            storePassword = signingPassword
            keyAlias = "swiftly-upload"
            keyPassword = signingPassword
        }
    }
    buildTypes {
        getByName("release") {
            if (signingPassword != null) signingConfig = signingConfigs.getByName("play")
            isMinifyEnabled = false
        }
    }
    // **Two ways to say thanks, two builds** (`Notizen/Supporter/PLAN-APPS.md`), same applicationId,
    // same versionCode:
    // - `play`: Google Play and its Play-signed APK. Tips through Play Billing; no link to the
    //   website, no supporter key, and nothing of either in the binary.
    // - `direct`: the APK on GitHub signed with the upload key (`Werkzeuge/sideload-apk.sh`). No
    //   Billing library and no BILLING permission; "Support on the website" and the supporter key.
    // Flavor code lives in `src/play` and `src/direct`; `Werkzeuge/store-guard-android.py` proves
    // that the play build carries none of the direct-only strings.
    flavorDimensions += "distribution"
    productFlavors {
        create("play") { dimension = "distribution" }
        create("direct") { dimension = "distribution" }
    }
    compileSdk = 36
    defaultConfig {
        applicationId = "de.paulherter.swiftly"
        minSdk = 28
        targetSdk = 36
        versionCode = 26
        versionName = "1.0.8"
        // **Switch-to-Play-Store build for the current beta testers** (`-PbetaRedirect=true`, never set
        // permanently): the app shows only a notice page (`BetaRedirectPage`). Off by default.
        buildConfigField("boolean", "BETA_REDIRECT", (findProperty("betaRedirect") == "true").toString())
        // **Only the ABIs the Swift core is built for** (`core/build.gradle`); on any other the app
        // crashed at startup. libVLC shipped four ABIs, x86 never worked.
        // armeabi-v7a for TVs with 32-bit Android: without it the app was invisible in the store there.
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    // `buildConfig` for the version line: it reads `versionName` and `versionCode` from here
    // instead of maintaining them a second time by hand.
    buildFeatures { compose = true; buildConfig = true }
    packaging {
        jniLibs {
            useLegacyPackaging = false
            // **`libc++_shared.so` twice:** from the core (NDK r27, for the Swift runtime) and from
            // libvlc-all. The first wins, since the core module comes first in the dependencies, and the
            // Swift runtime needs the newer one.
            pickFirsts += "lib/**/libc++_shared.so"
        }
    }
}

dependencies {
    implementation(project(":core"))
    implementation(project(":shared"))
    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)
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
    implementation(libs.androidx.media3.exoplayer)
    implementation(libs.androidx.media3.ui)
    implementation(libs.lottie.compose)
    implementation(libs.play.review.ktx)
    implementation(libs.androidx.tvprovider)
    // Only the play flavor: the direct build must not even declare the BILLING permission
    // (the library's manifest adds it).
    "playImplementation"(libs.billing)
    // Only for the JVM tests (`StreamNextLeaderTest`).
    testImplementation("junit:junit:4.13.2")
    // Only for the device tests (`CertificatesTest`), on the emulator.
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}

// **The start animation lives once in the repo** (`Sources/Shared/Assets`) and is copied here at
// build time; a second file would drift.
val copyStartAnimation by tasks.registering(Copy::class) {
    from(rootProject.file("../Sources/Shared/Assets/startanimation.json"))
    into(layout.buildDirectory.dir("generated/startanimation"))
}
android.sourceSets.getByName("main").assets.srcDir(file("build/generated/startanimation"))
tasks.named("preBuild") { dependsOn(copyStartAnimation) }

// **The licence texts live once in the repo** (`LICENSES/`) and are shipped as assets under
// `licenses/` at build time; the "Open-source licences" page reads them from there.
val copyLicenses by tasks.registering(Copy::class) {
    from(rootProject.file("../LICENSES"))
    into(layout.buildDirectory.dir("generated/licenses/licenses"))
}
android.sourceSets.getByName("main").assets.srcDir(file("build/generated/licenses"))
tasks.named("preBuild") { dependsOn(copyLicenses) }

// **"What's new" lives once in the package** (`whatsnew/<version>.json`) and is shipped as an asset
// under `whatsnew/`; the sheet reads the entry for this version from there.
val copyWhatsNew by tasks.registering(Copy::class) {
    from(rootProject.file("../Packages/JellyfinKit/Sources/JellyfinKit/Resources/whatsnew"))
    into(layout.buildDirectory.dir("generated/whatsnew/whatsnew"))
}
android.sourceSets.getByName("main").assets.srcDir(file("build/generated/whatsnew"))
tasks.named("preBuild") { dependsOn(copyWhatsNew) }

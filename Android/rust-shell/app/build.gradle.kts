plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "app.swiftly.rustshell"
    compileSdk = 36

    defaultConfig {
        // Not the store app's id: this shell is a development build and installs next to it.
        applicationId = "app.swiftly.rustshell"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        // `cargo ndk -o app/src/main/jniLibs` fills these two (see xtask `android`).
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }

    buildTypes {
        debug { isJniDebuggable = false }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("androidx.media3:media3-exoplayer:1.9.4")
}

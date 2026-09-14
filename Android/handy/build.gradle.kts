// Swiftly fuer Android-Telefone. Vorlage: Sources/Shared + Sources/iOS.
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "de.paulherter.swiftly"
    compileSdk = 36
    defaultConfig {
        applicationId = "de.paulherter.swiftly"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.3"
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
}

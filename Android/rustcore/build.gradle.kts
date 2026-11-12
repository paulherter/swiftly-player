// The Rust core for Android (UniFFI Kotlin bindings + cdylib per ABI) and the Kotlin implementations of the
// traits the core asks the platform for. Replaces `:core` (Swift via swift-java) once nothing uses it.
// `Werkzeuge/rust-kern-android.sh` builds the .so files and generates the bindings into build/android-core.
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
}

val rustOut = rootProject.layout.projectDirectory.dir("../build/android-core")

android {
    namespace = "de.paulherter.swiftly.rustcore"
    compileSdk = 36
    defaultConfig { minSdk = 28; consumerProguardFiles("consumer-rules.pro") }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    // Same flavors as :phone, so each phone flavor takes its own core: Play without the direct-only supporter-key symbols.
    flavorDimensions += "distribution"
    productFlavors {
        create("play") { dimension = "distribution" }
        create("direct") { dimension = "distribution" }
    }
    sourceSets {
        for (flavor in listOf("play", "direct")) {
            getByName(flavor) {
                java.srcDir(rustOut.dir("$flavor/kotlin"))
                jniLibs.srcDir(rustOut.dir("$flavor/jniLibs"))
            }
        }
    }
    testOptions {
        unitTests.all {
            val flavor = if (it.name.contains("Play")) "play" else "direct"
            it.systemProperty("jna.library.path", rustOut.dir("$flavor/host").asFile.absolutePath)
        }
    }
}

dependencies {
    // JNA 5.17.0 is the first release whose libjnidispatch.so is aligned to 16 KB pages (jna#1647/#1654).
    api("net.java.dev.jna:jna:5.17.0@aar")
    implementation("androidx.annotation:annotation:1.9.1")
    implementation(libs.kotlinx.coroutines.android)
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    testImplementation("net.java.dev.jna:jna:5.17.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
}

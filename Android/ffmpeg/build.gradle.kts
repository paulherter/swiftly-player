// FFmpeg audio decoder extension for Media3 (androidx/media "decoder_ffmpeg", Apache-2.0), plus the LGPL FFmpeg
// shared libraries. Java sources and .so files come from Werkzeuge/media3-ffmpeg-bauen.sh; the .so files are not
// committed (src/main/jniLibs is ignored). Without them the module still builds and `FfmpegLibrary.isAvailable()`
// is false, so the app just falls back to what the device decodes itself.
plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "androidx.media3.decoder.ffmpeg"
    compileSdk = 36
    defaultConfig { minSdk = 28 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    api(libs.androidx.media3.decoder)
    implementation(libs.androidx.media3.exoplayer)
    implementation(libs.androidx.media3.common)
    implementation("androidx.annotation:annotation:1.9.1")
    compileOnly("org.checkerframework:checker-qual:3.49.0")
}

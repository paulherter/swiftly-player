# R8 for the release build. Everything that native code or reflection reaches by name stays.
# Swift core (swift-java / JNI): the Swift side looks Java classes and methods up by name.
-keep class de.paulherter.swiftly.core.** { *; }
-keepclasseswithmembernames class * { native <methods>; }
# libVLC and FFmpeg JNI glue.
-keep class org.videolan.** { *; }
-keep class de.paulherter.swiftly.ffmpeg.** { *; }
# Rust core (JNA + UniFFI) keeps come from :rustcore's consumer rules.
-dontwarn java.awt.**
-dontwarn javax.annotation.**

# Reported missing by R8 (annotation-only classes)
-dontwarn com.google.android.gms.common.annotation.NoNullnessRewrite
-dontwarn jdk.jfr.Description
-dontwarn jdk.jfr.Label

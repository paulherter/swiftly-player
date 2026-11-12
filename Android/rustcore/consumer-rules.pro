# JNA: the native dispatcher looks classes, fields and callbacks up by name; R8 must not rename or strip them.
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.** { public *; }
# The UniFFI bindings: every Structure, Callback and the generated interfaces the Rust side calls back into
# (host traits: HttpClient, SecretStore, PlayerEngine, DownloadHost, ...).
-keep class de.paulherter.swiftly.rustcore.** { *; }
-dontwarn java.awt.**

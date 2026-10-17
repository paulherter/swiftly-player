// Swiftly for Android.
pluginManagement {
    repositories {
        mavenLocal()
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        // `swiftkit-core` exists only locally: swift-java does not publish it to Maven Central yet.
        // Provide it once with JDK 25.
        mavenLocal()
        google()
        mavenCentral()
    }
}
rootProject.name = "Swiftly"
include(":core")
include(":phone")
include(":shared")

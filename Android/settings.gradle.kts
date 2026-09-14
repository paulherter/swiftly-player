// Swiftly fuer Android. Aufbau und Regeln: Notizen/Android/PLAN.md
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
        // `swiftkit-core` liegt nur lokal: swift-java veroeffentlicht es noch
        // nicht auf Maven Central. Einmalig mit JDK 25 bereitstellen, siehe PLAN.
        mavenLocal()
        google()
        mavenCentral()
    }
}
rootProject.name = "Swiftly"
include(":kern")
include(":handy")
include(":gemeinsam")

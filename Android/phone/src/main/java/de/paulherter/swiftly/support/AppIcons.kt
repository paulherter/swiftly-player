package de.paulherter.swiftly.support

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import de.paulherter.swiftly.R

/**
 * **Supporter app icons on the phone**: one `activity-alias` per icon in the manifest, all pointing
 * at `MainActivity`; exactly one carries the launcher entry at a time. Switching enables the new
 * alias first and only then disables the others, so the app is never without an icon.
 *
 * The alias names are strings in the manifest (`.icon.Standard`, `.icon.Heart` …).
 * `Werkzeuge/manifest-classes-check.py` checks that every alias points at a class in the DEX.
 * The resources come from `Assets/SupporterIcons/android` (`build-icons.py`).
 *
 * TV has no alternate icons (the banner stays), as on tvOS.
 */
object AppIcons {
    data class Icon(val name: String, val background: Int, val foreground: Int)

    /** Standard first, then the six from `Assets/SupporterIcons/README.md`, in its order. */
    val all = listOf(
        Icon("Standard", R.drawable.ic_launcher_background, R.drawable.ic_launcher_foreground),
        Icon("Heart", R.drawable.ic_launcher_heart_background, R.drawable.ic_launcher_heart_foreground),
        Icon("Aurora", R.drawable.ic_launcher_aurora_background, R.drawable.ic_launcher_aurora_foreground),
        Icon("Gold", R.drawable.ic_launcher_gold_background, R.drawable.ic_launcher_gold_foreground),
        Icon("Light", R.drawable.ic_launcher_light_background, R.drawable.ic_launcher_light_foreground),
        Icon("Night", R.drawable.ic_launcher_night_background, R.drawable.ic_launcher_night_foreground),
        Icon("Coffee", R.drawable.ic_launcher_coffee_background, R.drawable.ic_launcher_coffee_foreground),
    )

    private fun component(context: Context, name: String) =
        ComponentName(context.packageName, "de.paulherter.swiftly.icon.$name")

    /** The icon whose alias is enabled now; Standard when none is (fresh install: the manifest default). */
    fun current(context: Context): String {
        val pm = context.packageManager
        return all.firstOrNull { icon ->
            when (runCatching { pm.getComponentEnabledSetting(component(context, icon.name)) }.getOrNull()) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
                PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> icon.name == "Standard"
                else -> false
            }
        }?.name ?: "Standard"
    }

    /** Switch to `name`. The launcher may take a moment to show the new icon. */
    fun set(context: Context, name: String) {
        if (all.none { it.name == name } || current(context) == name) return
        val pm = context.packageManager
        runCatching {
            pm.setComponentEnabledSetting(component(context, name),
                if (name == "Standard") PackageManager.COMPONENT_ENABLED_STATE_DEFAULT else PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                PackageManager.DONT_KILL_APP)
            all.filter { it.name != name }.forEach { other ->
                pm.setComponentEnabledSetting(component(context, other.name),
                    if (other.name == "Standard") PackageManager.COMPONENT_ENABLED_STATE_DISABLED else PackageManager.COMPONENT_ENABLED_STATE_DEFAULT,
                    PackageManager.DONT_KILL_APP)
            }
            Support.log("App-Icon: $name")
        }.onFailure { Support.log("App-Icon fehlgeschlagen: $it") }
    }

    /** Back to the standard icon, e.g. when a refunded purchase withdraws the status. */
    fun reset(context: Context) {
        if (current(context) != "Standard") set(context, "Standard")
    }
}

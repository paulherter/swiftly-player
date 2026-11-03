package de.paulherter.swiftly.support

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import de.paulherter.swiftly.R

/**
 * **App icons on the phone, only with the looks**: one `activity-alias` per icon in the manifest, all pointing
 * at `MainActivity`; exactly one carries the launcher entry at a time. Switching enables the new
 * alias first and only then disables the others, so the app is never without an icon.
 *
 * The alias names are strings in the manifest (`.icon.Standard`, `.icon.LookNeonNight` …).
 * `Werkzeuge/manifest-classes-check.py` checks that every alias points at a class in the DEX.
 *
 * TV has no alternate icons (the banner stays), as on tvOS.
 */
object AppIcons {
    data class Icon(val name: String, val background: Int, val foreground: Int)

    /** The standard icon; the others are the looks' (`looks`). */
    val all = listOf(
        Icon("Standard", R.drawable.ic_launcher_background, R.drawable.ic_launcher_foreground),
    )

    /** One icon per look (`tools/look-icons.py`), as `activity-alias` `.icon.Look<Name>`. */
    val looks = listOf(
        Icon("LookHalloween", R.drawable.ic_launcher_look_halloween_background, R.drawable.ic_launcher_look_halloween_foreground),
        Icon("LookNeonNight", R.drawable.ic_launcher_look_neonnight_background, R.drawable.ic_launcher_look_neonnight_foreground),
        Icon("LookGold", R.drawable.ic_launcher_look_gold_background, R.drawable.ic_launcher_look_gold_foreground),
        Icon("LookAurora", R.drawable.ic_launcher_look_aurora_background, R.drawable.ic_launcher_look_aurora_foreground),
        Icon("LookSunset", R.drawable.ic_launcher_look_sunset_background, R.drawable.ic_launcher_look_sunset_foreground),
        Icon("LookIce", R.drawable.ic_launcher_look_ice_background, R.drawable.ic_launcher_look_ice_foreground),
        Icon("LookEmber", R.drawable.ic_launcher_look_ember_background, R.drawable.ic_launcher_look_ember_foreground),
        Icon("LookEmerald", R.drawable.ic_launcher_look_emerald_background, R.drawable.ic_launcher_look_emerald_foreground),
    )

    /** Every alias there is. */
    private val universe get() = all + looks

    /** The icon of a look alias; the standard icon for none. */
    fun forAlias(alias: String?): Icon = universe.firstOrNull { it.name == alias } ?: all.first()

    private fun component(context: Context, name: String) =
        ComponentName(context.packageName, "de.paulherter.swiftly.icon.$name")

    /** The icon whose alias is enabled now; Standard when none is (fresh install: the manifest default). */
    fun current(context: Context): String {
        val pm = context.packageManager
        return universe.firstOrNull { icon ->
            when (runCatching { pm.getComponentEnabledSetting(component(context, icon.name)) }.getOrNull()) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
                PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> icon.name == "Standard"
                else -> false
            }
        }?.name ?: "Standard"
    }

    /** Switch to `name`. The launcher may take a moment to show the new icon. */
    fun set(context: Context, name: String) {
        if (universe.none { it.name == name } || current(context) == name) return
        val pm = context.packageManager
        runCatching {
            pm.setComponentEnabledSetting(component(context, name),
                if (name == "Standard") PackageManager.COMPONENT_ENABLED_STATE_DEFAULT else PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                PackageManager.DONT_KILL_APP)
            universe.filter { it.name != name }.forEach { other ->
                pm.setComponentEnabledSetting(component(context, other.name),
                    if (other.name == "Standard") PackageManager.COMPONENT_ENABLED_STATE_DISABLED else PackageManager.COMPONENT_ENABLED_STATE_DEFAULT,
                    PackageManager.DONT_KILL_APP)
            }
            Support.log("App-Icon: $name")
        }.onFailure { Support.log("App-Icon fehlgeschlagen: $it") }
    }
}

using System.Globalization;
using System.Text;
using Jellyfin.Plugin.Swiftly.Configuration;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Common.Plugins;
using MediaBrowser.Model.Plugins;
using MediaBrowser.Model.Serialization;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.Swiftly;

/// <summary>
/// Swiftly — das Erscheinungsbild der App für die Weboberfläche.
///
/// **Was ein Jellyfin-Plugin kann und was nicht.** Es läuft auf dem Server,
/// in .NET. Eine Schnittstelle, um in der Weboberfläche etwas zu zeichnen,
/// gibt es nicht — die Oberfläche ist eine eigene Anwendung, und Jellyfin
/// sieht keine Erweiterung dafür vor.
///
/// Der Weg, den alle Themenplugins gehen, ist deshalb derselbe: das Plugin
/// legt **eine Zeile** in die `index.html` der Weboberfläche, die ein
/// Skript nachlädt. Das Skript hängt das Stilblatt ein und erledigt, was
/// ein Stilblatt nicht kann.
///
/// Diese eine Zeile ist der ganze Eingriff — und sie ist der Preis:
/// `index.html` gehört Jellyfin, nicht uns. Bei jedem Serverwechsel wird
/// sie überschrieben, und das Plugin legt sie beim nächsten Start wieder
/// hinein. Zwischen den Marken steht nichts anderes, damit ein Rückbau
/// vollständig ist.
/// </summary>
public class Plugin : BasePlugin<PluginConfiguration>, IHasWebPages
{
    /// <summary>Fest, für die Lebensdauer des Plugins. Der Server erkennt es daran.</summary>
    public const string PluginId = "b7f4c1a2-3d6e-4c58-9a10-5f2e8c7d4b39";

    private const string MarkeAuf = "<!-- swiftly-thema:anfang -->";
    private const string MarkeZu = "<!-- swiftly-thema:ende -->";

    private readonly ILogger<Plugin> _log;
    private readonly string _webPfad;

    public Plugin(
        IApplicationPaths applicationPaths,
        IXmlSerializer xmlSerializer,
        ILogger<Plugin> logger)
        : base(applicationPaths, xmlSerializer)
    {
        Instance = this;
        _log = logger;
        _webPfad = applicationPaths.WebPath;

        Einhaengen();
    }

    public static Plugin? Instance { get; private set; }

    public override string Name => "Swiftly";

    public override string Description =>
        "Bringt die Weboberfläche auf das Erscheinungsbild der Swiftly-App — "
        + "genauer: auf das der macOS-Fassung.";

    public override Guid Id => Guid.Parse(PluginId);

    public IEnumerable<PluginPageInfo> GetPages() =>
    [
        new PluginPageInfo
        {
            Name = Name,
            EmbeddedResourcePath = $"{GetType().Namespace}.Configuration.configPage.html"
        }
    ];

    /// <summary>
    /// Legt die eine Zeile in die `index.html` — oder erneuert sie.
    ///
    /// **Zwischen den Marken steht nur unsere Zeile.** Wer das Plugin
    /// entfernt, bekommt mit <see cref="Aushaengen"/> genau den Zustand
    /// zurück, der vorher da war; ein Rückbau, der Reste lässt, ist kein
    /// Rückbau.
    /// </summary>
    public void Einhaengen()
    {
        var datei = Path.Combine(_webPfad, "index.html");
        if (!File.Exists(datei))
        {
            _log.LogWarning("Swiftly: {Datei} gibt es nicht — nichts eingehängt.", datei);
            return;
        }

        try
        {
            var text = File.ReadAllText(datei, Encoding.UTF8);
            var ohne = Ausschneiden(text);

            // Die Fassung hängt am Zeitpunkt der Einstellungen: ändert Paul
            // den Akzent, ändert sich die Adresse, und der Browser holt neu.
            var stand = Configuration.Akzent.GetHashCode(StringComparison.Ordinal)
                        ^ Configuration.Kachelbreite
                        ^ (Configuration.Seitenleiste ? 2 : 0)
                        ^ (Configuration.MeineMedienAusblenden ? 4 : 0);

            var zeile = string.Create(CultureInfo.InvariantCulture,
                $"{MarkeAuf}<script defer src=\"/Swiftly/swiftly.js?v={stand:x}\"></script>{MarkeZu}");

            var stelle = ohne.LastIndexOf("</body>", StringComparison.OrdinalIgnoreCase);
            var neu = stelle < 0
                ? ohne + zeile
                : ohne.Insert(stelle, zeile);

            if (neu != text)
            {
                File.WriteAllText(datei, neu, Encoding.UTF8);
                _log.LogInformation("Swiftly: in {Datei} eingehängt.", datei);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // **Kein Grund, den Server zu stören.** Ohne Schreibrecht auf das
            // Web-Verzeichnis bleibt das Thema aus; alles andere läuft weiter.
            _log.LogError(e, "Swiftly: {Datei} lässt sich nicht schreiben. Thema bleibt aus.", datei);
        }
    }

    /// <summary>Nimmt die Zeile wieder heraus.</summary>
    public void Aushaengen()
    {
        var datei = Path.Combine(_webPfad, "index.html");
        if (!File.Exists(datei))
        {
            return;
        }

        try
        {
            var text = File.ReadAllText(datei, Encoding.UTF8);
            var ohne = Ausschneiden(text);
            if (ohne != text)
            {
                File.WriteAllText(datei, ohne, Encoding.UTF8);
                _log.LogInformation("Swiftly: aus {Datei} ausgehängt.", datei);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _log.LogError(e, "Swiftly: {Datei} lässt sich nicht schreiben.", datei);
        }
    }

    public override void UpdateConfiguration(BasePluginConfiguration configuration)
    {
        base.UpdateConfiguration(configuration);
        // Die Adresse des Skripts trägt den Stand der Einstellungen — also
        // muss die Zeile neu geschrieben werden, sonst holt der Browser
        // weiter die alte.
        Einhaengen();
    }

    private static string Ausschneiden(string text)
    {
        while (true)
        {
            var a = text.IndexOf(MarkeAuf, StringComparison.Ordinal);
            if (a < 0)
            {
                return text;
            }

            var z = text.IndexOf(MarkeZu, a, StringComparison.Ordinal);
            if (z < 0)
            {
                return text.Remove(a);
            }

            text = text.Remove(a, z - a + MarkeZu.Length);
        }
    }
}

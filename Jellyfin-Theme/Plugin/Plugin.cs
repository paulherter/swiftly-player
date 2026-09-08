using System.Globalization;
using System.Text;
using Jellyfin.Plugin.Swiftly.Configuration;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Common.Plugins;
using MediaBrowser.Controller.Configuration;
using MediaBrowser.Model.Branding;
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

    // **In CSS ist ein HTML-Kommentar keiner.** `<!--` und `-->` überliest
    // ein Stilblatt zwar (sie stammen aus der Zeit, als man Stil in eine
    // Seite schrieb und ihn vor alten Browsern verstecken musste) — der Text
    // *dazwischen* nicht. Der wäre eine kaputte Regel, und eine kaputte Regel
    // vor einem `@import` macht den `@import` ungültig: er gilt nur, solange
    // vor ihm nichts als Regel steht. Das Thema wäre still ausgeblieben.
    private const string MarkeAufCss = "/* swiftly-thema:anfang */";
    private const string MarkeZuCss = "/* swiftly-thema:ende */";

    private readonly ILogger<Plugin> _log;
    private readonly string _webPfad;
    private readonly IServerConfigurationManager _serverKonfig;

    public Plugin(
        IApplicationPaths applicationPaths,
        IXmlSerializer xmlSerializer,
        ILogger<Plugin> logger,
        IServerConfigurationManager serverKonfig)
        : base(applicationPaths, xmlSerializer)
    {
        Instance = this;
        _log = logger;
        _serverKonfig = serverKonfig;
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
        if (UeberIndexDatei())
        {
            // Der volle Weg hat geklappt: Stilblatt **und** Skript.
            UeberBranding(false);
            return;
        }

        // **Der Rückfall.** Ohne Schreibrecht auf das Web-Verzeichnis bleibt
        // Jellyfins eigenes Feld für genau diesen Zweck: das Branding-CSS.
        // Es kostet das Skript — ein Stilblatt kann kein Skript nachladen —,
        // und damit die drei Sachen, die es tut. Das Aussehen kommt
        // vollständig an; nur die Schalter aus dem Dashboard wirken dann
        // über das Stilblatt statt über Klassen an der Wurzel.
        UeberBranding(true);
    }

    /// <summary>Der volle Weg. <c>true</c>, wenn die Zeile liegt.</summary>
    private bool UeberIndexDatei()
    {
        var datei = Path.Combine(_webPfad, "index.html");
        if (!File.Exists(datei))
        {
            _log.LogWarning("Swiftly: {Datei} gibt es nicht.", datei);
            return false;
        }

        try
        {
            var text = File.ReadAllText(datei, Encoding.UTF8);
            var ohne = Ausschneiden(text);

            // Die Fassung hängt am Stand der Einstellungen: ändert Paul den
            // Akzent, ändert sich die Adresse, und der Browser holt neu.
            var stand = Stand();

            var zeile = string.Create(CultureInfo.InvariantCulture,
                $"{MarkeAuf}<script defer src=\"/Swiftly/swiftly.js?v={stand:x}\"></script>{MarkeZu}");

            var stelle = ohne.LastIndexOf("</body>", StringComparison.OrdinalIgnoreCase);
            var neu = stelle < 0
                ? ohne + zeile
                : ohne.Insert(stelle, zeile);

            if (neu != text)
            {
                File.WriteAllText(datei, neu, Encoding.UTF8);
                _log.LogInformation("Swiftly: in {Datei} eingehängt — mit Skript.", datei);
            }

            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // **Kein Grund, den Server zu stören.** Eine Paketinstallation
            // legt die Weboberfläche nach /usr/share/jellyfin/web; das gehört
            // root, und der Dienst läuft als jellyfin. Das ist so gewollt.
            _log.LogInformation(
                "Swiftly: {Datei} ist nicht schreibbar ({Grund}) — nehme das Branding-CSS.",
                datei, e.GetType().Name);
            return false;
        }
    }

    /// <summary>
    /// Der Rückfallweg: Jellyfins eigenes Feld für zusätzliches CSS.
    ///
    /// **Warum nicht gleich so.** Ein Stilblatt kann kein Skript nachladen,
    /// und das Skript benennt unter anderem die gerade offene Seite — etwas,
    /// das eine CSS-Regel nicht selbst herausfinden kann. Deshalb erst die
    /// `index.html`, und nur wenn die nicht geht, dieser Weg.
    ///
    /// **Und warum unser <c>@import</c> hinter alle anderen kommt.** Ein
    /// <c>@import</c> gilt nur, solange vor ihm nichts als Regel steht — er
    /// muss also nach oben. Steht dort schon ein fremdes Thema, gewinnt bei
    /// gleicher Auszeichnungsstärke das spätere: also hinter das letzte.
    /// </summary>
    private void UeberBranding(bool einhaengen)
    {
        try
        {
            var marken = _serverKonfig.GetConfiguration<BrandingOptions>("branding");
            var alt = marken.CustomCss ?? string.Empty;
            var ohne = Ausschneiden(alt, MarkeAufCss, MarkeZuCss);

            string neu;
            if (!einhaengen)
            {
                neu = ohne;
            }
            else
            {
                var stand = Stand();
                var block = $"{MarkeAufCss}\n@import url(\"/Swiftly/swiftly.css?v={stand:x}\");\n{MarkeZuCss}\n";
                var stelle = NachDenImporten(ohne);
                neu = ohne.Insert(stelle, block);

                var fremd = ohne.Trim();
                if (fremd.Length > 0)
                {
                    _log.LogWarning(
                        "Swiftly: im Branding-CSS steht noch anderes ({Zeichen} Zeichen). "
                        + "Zwei Themen kämpfen um jede Farbe — bitte herausnehmen.",
                        fremd.Length);
                }
            }

            if (neu != alt)
            {
                marken.CustomCss = neu;
                _serverKonfig.SaveConfiguration("branding", marken);
                _log.LogInformation(einhaengen
                    ? "Swiftly: über das Branding-CSS eingehängt — ohne Skript."
                    : "Swiftly: aus dem Branding-CSS entfernt.");
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            _log.LogError(e, "Swiftly: auch das Branding-CSS lässt sich nicht setzen. Thema bleibt aus.");
        }
    }

    /// <summary>
    /// Hinter den führenden <c>@charset</c>- und <c>@import</c>-Zeilen —
    /// dort darf ein weiterer <c>@import</c> stehen, und dort gewinnt er.
    /// </summary>
    private static int NachDenImporten(string css)
    {
        var i = 0;
        while (i < css.Length)
        {
            while (i < css.Length && char.IsWhiteSpace(css[i]))
            {
                i++;
            }

            if (css.AsSpan(i).StartsWith("/*", StringComparison.Ordinal))
            {
                var e = css.IndexOf("*/", i, StringComparison.Ordinal);
                if (e < 0)
                {
                    return i;
                }

                i = e + 2;
                continue;
            }

            if (!css.AsSpan(i).StartsWith("@import", StringComparison.OrdinalIgnoreCase)
                && !css.AsSpan(i).StartsWith("@charset", StringComparison.OrdinalIgnoreCase))
            {
                return i;
            }

            var s = css.IndexOf(';', i);
            if (s < 0)
            {
                return css.Length;
            }

            i = s + 1;
        }

        return css.Length;
    }

    private int Stand() =>
        Configuration.Akzent.GetHashCode(StringComparison.Ordinal)
        ^ Configuration.Kachelbreite
        ^ (Configuration.Seitenleiste ? 2 : 0)
        ^ (Configuration.MeineMedienAusblenden ? 4 : 0);

    /// <summary>Nimmt die Zeile wieder heraus — auf beiden Wegen.</summary>
    public void Aushaengen()
    {
        UeberBranding(false);

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

    private static string Ausschneiden(string text) => Ausschneiden(text, MarkeAuf, MarkeZu);

    /// <summary>
    /// Nimmt jeden Block zwischen den Marken heraus — auch mehrere, falls
    /// eine frühere Fassung einen liegengelassen hat.
    /// </summary>
    private static string Ausschneiden(string text, string auf, string zu)
    {
        while (true)
        {
            var a = text.IndexOf(auf, StringComparison.Ordinal);
            if (a < 0)
            {
                return text;
            }

            var z = text.IndexOf(zu, a, StringComparison.Ordinal);
            if (z < 0)
            {
                return text.Remove(a);
            }

            text = text.Remove(a, z - a + zu.Length);
        }
    }
}

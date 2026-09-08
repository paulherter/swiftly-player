using MediaBrowser.Model.Plugins;

namespace Jellyfin.Plugin.Swiftly.Configuration;

/// <summary>
/// Was am Erscheinungsbild einstellbar ist.
///
/// **Wenig, und jedes mit einem Grund.** Die Gestaltung ist entschieden
/// (GESTALTUNG.md); was hier steht, sind die drei Stellen, an denen ein
/// Server sich vom naechsten unterscheidet — und der Notausgang, falls die
/// Seitenleiste auf einer Fassung nicht traegt.
/// </summary>
public class PluginConfiguration : BasePluginConfiguration
{
    /// <summary>
    /// Traegt Fortschritt, Auswahl und den Direct-Play-Beleg — nie eine
    /// Flaeche. Voreinstellung ist Swiftlys eigener Akzent.
    /// </summary>
    public string Akzent { get; set; } = "#5CD1C2";

    /// <summary>
    /// Die stehende Seitenleiste statt Jellyfins Schublade.
    ///
    /// Abschaltbar, weil sie der eine Griff ist, der wirklich am Aufbau
    /// dreht: sie verschiebt Kopf, Inhalt und Hintergrund gemeinsam. Wenn
    /// eine kuenftige Fassung von Jellyfin die Schublade anders baut,
    /// bleibt der Rest des Themas trotzdem stehen.
    /// </summary>
    public bool Seitenleiste { get; set; } = true;

    /// <summary>
    /// „Meine Medien" auf der Startseite ausblenden.
    ///
    /// Auf dem Mac gibt es die Reihe nicht — die Bibliotheken stehen in der
    /// Leiste, und zweimal derselbe Weg auf einer Seite ist einer zu viel.
    /// Wer keine Seitenleiste will, will diese Reihe vermutlich behalten.
    /// </summary>
    public bool MeineMedienAusblenden { get; set; } = true;

    /// <summary>
    /// Breite eines Plakats in Punkten. 150 wie auf dem Mac.
    ///
    /// Jellyfin teilt die Zeile in Prozente, die Kachel waechst also mit dem
    /// Fenster; Swiftly macht es andersherum, und die Spaltenzahl ergibt
    /// sich daraus. Wer einen sehr grossen Schirm hat, mag hoeher gehen.
    /// </summary>
    public int Kachelbreite { get; set; } = 150;
}

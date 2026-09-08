using System.Globalization;
using System.Reflection;
using System.Text;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Jellyfin.Plugin.Swiftly;

/// <summary>
/// Liefert Stilblatt und Skript aus.
///
/// **Ohne Anmeldung.** Beides wird von der `index.html` geholt, und die
/// steht vor der Anmeldeseite — mit Token käme das Thema erst, nachdem man
/// sich angemeldet hat, und die Anmeldeseite selbst bliebe fremd.
///
/// Weder Stilblatt noch Skript tragen Daten: das eine ist Gestaltung, das
/// andere sind die Einstellungen dieses Plugins.
/// </summary>
[ApiController]
[Route("Swiftly")]
[AllowAnonymous]
public class SwiftlyController : ControllerBase
{
    private static readonly Assembly Buendel = typeof(SwiftlyController).Assembly;

    /// <summary>Das Skript: hängt das Stilblatt ein und tut, was Stil nicht kann.</summary>
    [HttpGet("swiftly.js")]
    [Produces("application/javascript")]
    public ActionResult Skript()
    {
        var js = Lesen("Jellyfin.Plugin.Swiftly.Web.swiftly.js");
        return js is null
            ? NotFound()
            : Content(js, "application/javascript; charset=utf-8");
    }

    /// <summary>
    /// Das Stilblatt, mit den Einstellungen vorne dran.
    ///
    /// **Die Einstellungen stehen als Marken über der Datei, nicht in ihr.**
    /// Das Stilblatt bleibt damit dasselbe, das man auch von Hand einsetzen
    /// kann — eine Fassung, nicht zwei. Dieselbe Regel wie
    /// „Eine kopierte Funktion ist ein Fehler".
    /// </summary>
    [HttpGet("swiftly.css")]
    [Produces("text/css")]
    public ActionResult Stilblatt()
    {
        var css = Lesen("Jellyfin.Plugin.Swiftly.Web.swiftly.css");
        if (css is null)
        {
            return NotFound();
        }

        var c = Plugin.Instance?.Configuration;
        if (c is null)
        {
            return Content(css, "text/css; charset=utf-8");
        }

        var kopf = new StringBuilder();
        kopf.AppendLine("/* Aus den Einstellungen des Plugins. */");
        kopf.AppendLine(":root {");
        kopf.Append(CultureInfo.InvariantCulture, $"  --sw-akzent: {Saeubern(c.Akzent)} !important;\n");
        kopf.Append(CultureInfo.InvariantCulture, $"  --sw-akzent-kanal: {Kanal(c.Akzent)} !important;\n");
        kopf.Append(CultureInfo.InvariantCulture,
            $"  --jf-palette-primary-main: {Saeubern(c.Akzent)} !important;\n");
        kopf.Append(CultureInfo.InvariantCulture,
            $"  --jf-palette-secondary-main: {Saeubern(c.Akzent)} !important;\n");
        kopf.Append(CultureInfo.InvariantCulture,
            $"  --jf-palette-primary-mainChannel: {Kanal(c.Akzent)} !important;\n");
        kopf.Append(CultureInfo.InvariantCulture,
            $"  --sw-kachel-breite: {Math.Clamp(c.Kachelbreite, 90, 320)}px !important;\n");
        kopf.AppendLine("}");

        return Content(kopf + "\n" + css, "text/css; charset=utf-8");
    }

    /// <summary>
    /// Die Einstellungen, so weit das Skript sie braucht — zwei Schalter.
    ///
    /// **Nicht die ganze Konfiguration.** Was das Skript nicht braucht,
    /// gehört nicht in eine Antwort, die ohne Anmeldung zu haben ist.
    /// </summary>
    [HttpGet("einstellungen")]
    [Produces("application/json")]
    public ActionResult Einstellungen()
    {
        var c = Plugin.Instance?.Configuration;
        return new JsonResult(new
        {
            Seitenleiste = c?.Seitenleiste ?? true,
            MeineMedienAusblenden = c?.MeineMedienAusblenden ?? true
        });
    }

    private static string? Lesen(string name)
    {
        using var strom = Buendel.GetManifestResourceStream(name);
        if (strom is null)
        {
            return null;
        }

        using var leser = new StreamReader(strom, Encoding.UTF8);
        return leser.ReadToEnd();
    }

    /// <summary>
    /// **Nur Raute und Hexziffern.** Was aus einer Einstellung in ein
    /// Stilblatt wandert, ist Eingabe — auch wenn sie vom eigenen Dashboard
    /// kommt. Passt sie nicht, gilt der Wert aus `Farben.swift`.
    /// </summary>
    private static string Saeubern(string? farbe)
    {
        if (string.IsNullOrWhiteSpace(farbe))
        {
            return "#5CD1C2";
        }

        var f = farbe.Trim();
        if (f.Length is not (4 or 7) || f[0] != '#')
        {
            return "#5CD1C2";
        }

        return f.Skip(1).All(Uri.IsHexDigit) ? f : "#5CD1C2";
    }

    /// <summary>Dieselbe Farbe als drei Zahlen — für die Stellen, an denen
    /// Jellyfin sie mit einer eigenen Deckkraft mischt.</summary>
    private static string Kanal(string? farbe)
    {
        var f = Saeubern(farbe);
        if (f.Length == 4)
        {
            f = $"#{f[1]}{f[1]}{f[2]}{f[2]}{f[3]}{f[3]}";
        }

        var r = Convert.ToInt32(f.Substring(1, 2), 16);
        var g = Convert.ToInt32(f.Substring(3, 2), 16);
        var b = Convert.ToInt32(f.Substring(5, 2), 16);
        return string.Create(CultureInfo.InvariantCulture, $"{r} {g} {b}");
    }
}

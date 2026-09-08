/* Swiftly — der Teil, den ein Stilblatt nicht erledigen kann.
 *
 * **Wenig, und jedes Stück mit einem Grund.** Das Aussehen steckt in
 * `swiftly.css`; hier steht nur, was CSS nicht erreicht:
 *
 *   1. das Stilblatt überhaupt einhängen
 *   2. die Einstellungen des Plugins als Marken an die Wurzel schreiben,
 *      damit das Stilblatt sie abfragen kann
 *   3. die gerade sichtbare Seite benennen — Jellyfin schreibt sie nirgends
 *      hin, und ohne sie muss jede Regel raten, auf welcher Seite sie gilt
 *
 * Was hier **nicht** steht: Bewegungen, Farben, Maße. Die gehören ins
 * Stilblatt, wo man sie sieht.
 */
(function () {
    'use strict';

    var WURZEL = document.documentElement;
    var stand = (function () {
        var s = document.currentScript && document.currentScript.src;
        var m = s && s.match(/[?&]v=([^&]+)/);
        return m ? m[1] : '0';
    })();

    // --- 1 · Das Stilblatt ------------------------------------------------
    // Vor allem anderen, damit die Seite nicht erst in Jellyfins Farben
    // aufblitzt. „Nichts erscheint hart" (E18) fängt hier an.
    (function stilblatt() {
        if (document.getElementById('swiftly-stilblatt')) { return; }
        var l = document.createElement('link');
        l.id = 'swiftly-stilblatt';
        l.rel = 'stylesheet';
        l.href = '/Swiftly/swiftly.css?v=' + encodeURIComponent(stand);
        (document.head || WURZEL).appendChild(l);
    })();

    // --- 2 · Die Einstellungen als Marken ---------------------------------
    // Ein Schalter im Dashboard soll eine Regel im Stilblatt an- und
    // ausschalten können. Der Weg dahin ist eine Klasse an der Wurzel:
    // `html.swiftly-leiste .mainDrawer { … }`.
    function marken(e) {
        WURZEL.classList.toggle('swiftly-leiste', e.Seitenleiste !== false);
        WURZEL.classList.toggle('swiftly-ohne-medien', e.MeineMedienAusblenden !== false);
        WURZEL.classList.add('swiftly');
    }

    // Bis die Antwort da ist, gilt die Voreinstellung — sonst steht die
    // Seite einen Wimpernschlag lang ohne Leiste da und springt dann.
    marken({});

    fetch('/Swiftly/einstellungen', { credentials: 'omit' })
        .then(function (a) { return a.ok ? a.json() : null; })
        .then(function (e) { if (e) { marken(e); } })
        .catch(function () { /* Voreinstellung bleibt. */ });

    // --- 3 · Welche Seite gerade offen ist --------------------------------
    // Jellyfin hängt die Seiten als `.mainAnimatedPage` nebeneinander und
    // versteckt alle bis auf eine mit `.hide`. Welche das ist, steht an
    // keiner Stelle, die eine CSS-Regel erreichen könnte — `:has()` hilft
    // nicht, weil die Seiten Geschwister sind und nicht Vorfahren.
    //
    // Also einmal notiert, bei jedem Wechsel: `<html data-seite="itemDetailPage">`.
    // Damit kann eine Regel sagen „nur auf der Detailseite" statt „überall,
    // wo dieses Stück zufällig auch vorkommt".
    var letzte = '';

    function seiteMerken() {
        var offen = document.querySelector('.mainAnimatedPage:not(.hide)');
        var name = (offen && (offen.id || offen.getAttribute('data-type'))) || '';
        if (name !== letzte) {
            letzte = name;
            WURZEL.setAttribute('data-seite', name);
        }
    }

    // **Ein Beobachter, nicht ein Takt.** Ein Zeitgeber liefe auch dann,
    // wenn sich nichts ändert; hier ist das teuerste Stück Seite eine
    // scrollende Kachelreihe, und die soll nichts abbekommen.
    function beobachten() {
        seiteMerken();
        var ziel = document.querySelector('.mainAnimatedPages') || document.body;
        new MutationObserver(seiteMerken).observe(ziel, {
            subtree: true,
            attributes: true,
            attributeFilter: ['class']
        });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', beobachten, { once: true });
    } else {
        beobachten();
    }
})();

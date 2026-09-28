<?php
// Router fuer die lokale Vorschau: dieselben Regeln wie Website/blog/.htaccess,
// damit /blog/ hier so antwortet wie auf dem Webspace. PHPs eingebauter Server
// kennt .htaccess nicht. Statische Dateien lassen wir ihm (return false).
$pfad   = rawurldecode(parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH) ?? '/');
$wurzel = $_SERVER['DOCUMENT_ROOT'];
$blog   = $wurzel . '/blog';

function laufen($datei, $get = []) {
    foreach ($get as $k => $v) { $_GET[$k] = $v; }
    chdir(dirname($datei));
    require $datei;
    return true;
}

if (preg_match('#^/blog/_artikel(/.*)?$#', $pfad)) { http_response_code(404); echo "404"; return true; }
if ($pfad === '/blog')                { header('Location: /blog/', true, 301); return true; }
if ($pfad === '/blog/')               { return laufen("$blog/index.php"); }
if ($pfad === '/blog/feed.xml')       { return laufen("$blog/feed.php"); }
if ($pfad === '/blog/sitemap.xml')    { return laufen("$blog/sitemap.php"); }
if ($pfad === '/blog/llms.txt')       { return laufen("$blog/llms.php"); }
if (preg_match('#^/blog/titel/([a-z0-9]+(?:-[a-z0-9]+)*)\.(jpg|svg)$#', $pfad, $m)) {
    return laufen("$blog/titel.php", ['slug' => $m[1], 'typ' => $m[2]]);
}
if (preg_match('#^/blog/([a-z0-9]+(?:-[a-z0-9]+)*)/?$#', $pfad, $m) && !is_dir("$blog/{$m[1]}")) {
    return laufen("$blog/artikel.php", ['slug' => $m[1]]);
}
return false;

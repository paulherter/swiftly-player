#!/usr/bin/env node
//
// Google Play Developer API fuer Swiftly Android — ohne Abhaengigkeiten.
//
//   node Werkzeuge/play.mjs pruefen
//       liest nur: Tracks und Releases. Oeffnet eine Bearbeitung und verwirft sie wieder.
//   node Werkzeuge/play.mjs hochladen <datei.aab> <track> [hinweise.json] [--entwurf]
//       laedt das Bundle, legt ein Release im Track an und veroeffentlicht es
//       (mit --entwurf bleibt es ein Entwurf in der Play Console).
//       hinweise.json: { "de-DE": "…", "en-US": "…" } — je hoechstens 500 Zeichen.
//   node Werkzeuge/play.mjs apk-anhaengen <versionscode> [--fassung 1.0.4] [--dry-run]
//       holt die von Google signierte Universal-APK zu diesem Versionscode (`generatedApks`)
//       und haengt sie als `Swiftly-<Fassung>.apk` an das GitHub-Release `v<Fassung>`
//       (`gh release upload`). Die Fassung kommt aus dem Namen des Play-Releases, sonst aus
//       --fassung. Mit --dry-run wird nur gelesen: nichts geladen, nichts hochgeladen.
//       Das Release muss es schon geben; eine gleichnamige APK wird nicht ersetzt. Ob und wann
//       eine APK an ein Release kommt, entscheidet Paul (Android ist noch nicht in Produktion).
//
// **Der Schluessel liegt ausserhalb des Repos** (`~/.swiftly-android/play-dienstkonto.json`)
// und wird nur hier gelesen, nie ausgegeben. Dieselbe Regel wie beim Signatur-Passwort im
// Schluesselbund: Zugangsdaten gehoeren nicht in eine Datei im Repo und nicht in ein Protokoll.

import { readFileSync, statSync, writeFileSync, mkdtempSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createSign } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";

const PAKET = "de.paulherter.swiftly";
const SCHLUESSEL = join(homedir(), ".swiftly-android", "play-dienstkonto.json");
const API = `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${PAKET}`;
const HOCHLADEN = `https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/${PAKET}`;

function b64url(daten) {
  return Buffer.from(daten).toString("base64").replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
}

export async function zugang() {
  let konto;
  try { konto = JSON.parse(readFileSync(SCHLUESSEL, "utf8")); }
  catch { throw new Error(`Kein Dienstkonto unter ${SCHLUESSEL}.`); }
  const jetzt = Math.floor(Date.now() / 1000);
  const kopf = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const inhalt = b64url(JSON.stringify({
    iss: konto.client_email, scope: "https://www.googleapis.com/auth/androidpublisher",
    aud: konto.token_uri || "https://oauth2.googleapis.com/token", iat: jetzt, exp: jetzt + 3600,
  }));
  const signierer = createSign("RSA-SHA256");
  signierer.update(`${kopf}.${inhalt}`);
  const jwt = `${kopf}.${inhalt}.${b64url(signierer.sign(konto.private_key))}`;
  const antwort = await fetch(konto.token_uri || "https://oauth2.googleapis.com/token", {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: jwt }),
  });
  const json = await antwort.json();
  if (!json.access_token) throw new Error(`Anmeldung abgelehnt: ${json.error_description || json.error || antwort.status}`);
  console.log(`Angemeldet als ${konto.client_email}`);
  return json.access_token;
}

export async function aufruf(token, methode, url, body, typ = "application/json") {
  const antwort = await fetch(url, {
    method: methode,
    headers: { Authorization: `Bearer ${token}`, ...(body !== undefined ? { "Content-Type": typ } : {}) },
    body: body === undefined ? undefined : (typ === "application/json" ? JSON.stringify(body) : body),
  });
  const text = await antwort.text();
  if (!antwort.ok) {
    let meldung = text;
    try { meldung = JSON.parse(text).error?.message ?? text; } catch {}
    throw new Error(`${methode} ${url.replace(API, "").replace(HOCHLADEN, "")} → ${antwort.status}: ${meldung}`);
  }
  return text ? JSON.parse(text) : {};
}

async function pruefen() {
  const token = await zugang();
  const bearbeitung = await aufruf(token, "POST", `${API}/edits`, {});
  try {
    const { tracks = [] } = await aufruf(token, "GET", `${API}/edits/${bearbeitung.id}/tracks`);
    for (const t of tracks) {
      console.log(`\nTrack „${t.track}"`);
      for (const r of t.releases ?? []) {
        console.log(`  ${r.name ?? "(ohne Namen)"} · Versionscodes ${(r.versionCodes ?? []).join(", ")} · ${r.status}`);
      }
    }
  } finally {
    await aufruf(token, "DELETE", `${API}/edits/${bearbeitung.id}`);
  }
  console.log("\nNur gelesen, nichts geaendert.");
}

async function hochladen(datei, track, hinweiseDatei, entwurf) {
  if (!datei || !track) throw new Error("Aufruf: play.mjs hochladen <datei.aab> <track> [hinweise.json] [--entwurf]");
  const groesse = statSync(datei).size;
  const hinweise = hinweiseDatei ? JSON.parse(readFileSync(hinweiseDatei, "utf8")) : null;
  for (const [sprache, text] of Object.entries(hinweise ?? {})) {
    if (text.length > 500) throw new Error(`Versionshinweise ${sprache}: ${text.length} Zeichen, Google erlaubt 500.`);
  }
  const token = await zugang();
  const bearbeitung = await aufruf(token, "POST", `${API}/edits`, {});
  let fertig = false;
  try {
    console.log(`Lade ${datei} (${(groesse / 1e6).toFixed(1)} MB) …`);
    const bundle = await aufruf(token, "POST", `${HOCHLADEN}/edits/${bearbeitung.id}/bundles?uploadType=media`,
      readFileSync(datei), "application/octet-stream");
    console.log(`Bundle angenommen: Versionscode ${bundle.versionCode}`);
    const release = {
      versionCodes: [String(bundle.versionCode)],
      status: entwurf ? "draft" : "completed",
      ...(hinweise ? { releaseNotes: Object.entries(hinweise).map(([language, text]) => ({ language, text })) } : {}),
    };
    await aufruf(token, "PUT", `${API}/edits/${bearbeitung.id}/tracks/${encodeURIComponent(track)}`, { track, releases: [release] });
    await aufruf(token, "POST", `${API}/edits/${bearbeitung.id}:commit`);
    fertig = true;
    console.log(`\n${entwurf ? "Als Entwurf" : "Veroeffentlicht"} in „${track}": Versionscode ${bundle.versionCode}.`);
  } finally {
    if (!fertig) await aufruf(token, "DELETE", `${API}/edits/${bearbeitung.id}`).catch(() => {});
  }
}

/**
 * **Die APK fuer GitHub** — Nutzer ohne Play Store (oder mit einem Fernseher ohne) sollen Swiftly
 * auch von den Releases laden koennen. Genommen wird die Universal-APK, die Google aus dem Bundle
 * erzeugt und **mit dem App-Signaturschluessel von Play** signiert: so passt sie zu jeder
 * Play-Installation, und ein Update ueber Play laeuft danach weiter. Eine selbst gebaute Release-APK
 * traegt den Upload-Schluessel und passt nicht (Signatur), das hiesse deinstallieren.
 */
async function apkAnhaengen(versionscode, fassungVorgabe, probe) {
  if (!/^\d+$/.test(versionscode ?? "")) {
    throw new Error("Aufruf: play.mjs apk-anhaengen <versionscode> [--fassung 1.0.4] [--dry-run]");
  }
  const token = await zugang();

  // Die Fassung: aus dem Namen des Play-Releases, der diesen Versionscode traegt („1.0.4 (8)").
  let fassung = fassungVorgabe;
  if (!fassung) {
    const bearbeitung = await aufruf(token, "POST", `${API}/edits`, {});
    try {
      const { tracks = [] } = await aufruf(token, "GET", `${API}/edits/${bearbeitung.id}/tracks`);
      for (const t of tracks) for (const r of t.releases ?? []) {
        if ((r.versionCodes ?? []).includes(String(versionscode))) {
          fassung ??= (r.name ?? "").match(/\d+\.\d+(?:\.\d+)?/)?.[0];
          console.log(`Play: „${t.track}" · ${r.name ?? "(ohne Namen)"} · ${r.status}`);
        }
      }
    } finally {
      await aufruf(token, "DELETE", `${API}/edits/${bearbeitung.id}`);
    }
  }
  if (!fassung) throw new Error(`Keine Fassung zu Versionscode ${versionscode} gefunden — mit --fassung angeben.`);
  const tag = `v${fassung}`;
  const name = `Swiftly-${fassung}.apk`;

  // Welche APKs Google erzeugt hat — je Signaturschluessel eine Gruppe, darin die Universal-APK.
  const { generatedApks = [] } = await aufruf(token, "GET", `${API}/generatedApks/${versionscode}`);
  const universal = generatedApks.map((g) => g.generatedUniversalApk?.downloadId).filter(Boolean);
  if (universal.length === 0) throw new Error(`Google hat zu Versionscode ${versionscode} keine Universal-APK erzeugt.`);
  if (universal.length > 1) throw new Error(`${universal.length} Signaturschluessel mit Universal-APK — nicht eindeutig.`);
  console.log(`Universal-APK zu Versionscode ${versionscode}: vorhanden (von Play signiert).`);

  // Das Release muss es schon geben — angelegt wird hier keins.
  const wurzel = join(dirname(fileURLToPath(import.meta.url)), "..");
  let vorhanden = [];
  try {
    const release = JSON.parse(execFileSync("gh", ["release", "view", tag, "--json", "assets"],
                                            { cwd: wurzel, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }));
    vorhanden = (release.assets ?? []).map((a) => a.name);
  } catch {
    throw new Error(`Kein GitHub-Release „${tag}". Erst das Release anlegen, dann die APK anhaengen.`);
  }
  console.log(`GitHub-Release „${tag}": ${vorhanden.length} Anhaenge${vorhanden.includes(name) ? `, ${name} schon dabei` : ""}.`);
  if (vorhanden.includes(name)) throw new Error(`${name} haengt schon an „${tag}" — nichts ersetzt.`);

  if (probe) {
    console.log(`\n--dry-run: wuerde die APK laden und als ${name} an „${tag}" haengen. Nichts geladen, nichts geaendert.`);
    return;
  }

  const url = `${API}/generatedApks/${versionscode}/downloads/${encodeURIComponent(universal[0])}:download?alt=media`;
  const antwort = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (!antwort.ok) throw new Error(`Laden der APK → ${antwort.status}: ${(await antwort.text()).slice(0, 300)}`);
  const daten = Buffer.from(await antwort.arrayBuffer());
  // Eine APK ist ein ZIP — faengt die Antwort nicht mit „PK" an, ist es eine Fehlerseite.
  if (daten.length < 1e6 || daten[0] !== 0x50 || daten[1] !== 0x4b) throw new Error(`Die Antwort ist keine APK (${daten.length} Bytes).`);
  const datei = join(mkdtempSync(join(tmpdir(), "swiftly-apk-")), name);
  writeFileSync(datei, daten);
  console.log(`Geladen: ${datei} (${(daten.length / 1e6).toFixed(1)} MB)`);
  execFileSync("gh", ["release", "upload", tag, datei], { cwd: wurzel, stdio: "inherit" });
  console.log(`\nAngehaengt: ${name} an „${tag}".`);
}

export { API };

// Nur als Befehl ausfuehren, nicht wenn der Waechter die Anmeldung importiert.
if (import.meta.url === `file://${process.argv[1]}`) {
const [befehl, ...rest] = process.argv.slice(2);
const entwurf = rest.includes("--entwurf");
const probe = rest.includes("--dry-run");
const fassungStelle = rest.indexOf("--fassung");
const fassung = fassungStelle >= 0 ? rest[fassungStelle + 1] : undefined;
const argumente = rest.filter((a, i) => a !== "--entwurf" && a !== "--dry-run" && a !== "--fassung"
                                        && (fassungStelle < 0 || i !== fassungStelle + 1));
try {
  if (befehl === "pruefen") await pruefen();
  else if (befehl === "hochladen") await hochladen(argumente[0], argumente[1], argumente[2], entwurf);
  else if (befehl === "apk-anhaengen") await apkAnhaengen(argumente[0], fassung, probe);
  else {
    console.error("Befehle: pruefen · hochladen <datei.aab> <track> [hinweise.json] [--entwurf]"
                  + " · apk-anhaengen <versionscode> [--fassung 1.0.4] [--dry-run]");
    process.exitCode = 2;
  }
} catch (fehler) {
  console.error(`\nFehlgeschlagen: ${fehler.message}`);
  process.exitCode = 1;
}
}

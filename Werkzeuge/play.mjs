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
//
// **Der Schluessel liegt ausserhalb des Repos** (`~/.swiftly-android/play-dienstkonto.json`)
// und wird nur hier gelesen, nie ausgegeben. Dieselbe Regel wie beim Signatur-Passwort im
// Schluesselbund: Zugangsdaten gehoeren nicht in eine Datei im Repo und nicht in ein Protokoll.

import { readFileSync, statSync } from "node:fs";
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

export { API };

// Nur als Befehl ausfuehren, nicht wenn der Waechter die Anmeldung importiert.
if (import.meta.url === `file://${process.argv[1]}`) {
const [befehl, ...rest] = process.argv.slice(2);
const entwurf = rest.includes("--entwurf");
const argumente = rest.filter((a) => a !== "--entwurf");
try {
  if (befehl === "pruefen") await pruefen();
  else if (befehl === "hochladen") await hochladen(argumente[0], argumente[1], argumente[2], entwurf);
  else { console.error("Befehle: pruefen · hochladen <datei.aab> <track> [hinweise.json] [--entwurf]"); process.exitCode = 2; }
} catch (fehler) {
  console.error(`\nFehlgeschlagen: ${fehler.message}`);
  process.exitCode = 1;
}
}

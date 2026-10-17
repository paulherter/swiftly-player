#!/usr/bin/env node
//
// Google Play Developer API for Swiftly Android -- no dependencies.
//
//   node Werkzeuge/play.mjs pruefen
//       read-only: tracks and releases. Opens an edit and discards it again.
//   node Werkzeuge/play.mjs hochladen <file.aab> <track> [notes.json] [--entwurf]
//       uploads the bundle, creates a release in the track and publishes it
//       (with --entwurf it stays a draft in the Play Console).
//       notes.json: { "de-DE": "...", "en-US": "..." } -- at most 500 characters each.
//   node Werkzeuge/play.mjs freigeben <versionCode> <track> [notes.json]
//       releases an already uploaded version code in another track.
//   node Werkzeuge/play.mjs apk-anhaengen <versionCode> [--fassung 1.0.4] [--dry-run]
//       fetches the universal APK signed by Google for this version code
//       (`generatedApks`) and attaches it as `Swiftly-<version>.apk` to the
//       GitHub release `v<version>` (`gh release upload`). The version comes
//       from the name of the Play release, otherwise from --fassung. With
//       --dry-run it only reads: nothing is downloaded or uploaded.
//       The release must already exist; an APK of the same name is not replaced.
//
// **The key lives outside the repo** (`~/.swiftly-android/play-dienstkonto.json`)
// and is only read here, never printed. Credentials do not belong in a file in
// the repo or in a log.

import { readFileSync, statSync, writeFileSync, mkdtempSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createSign } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";

const PACKAGE_NAME = "de.paulherter.swiftly";
const KEY_FILE = join(homedir(), ".swiftly-android", "play-dienstkonto.json");
// Google refuses an automatic review submission while a rejected release is pending in the
// Console. PLAY_NOT_SENT=1 commits anyway; the release is then sent for review from the Console.
const COMMIT_QUERY = process.env.PLAY_NOT_SENT === "1" ? "?changesNotSentForReview=true" : "";
const API = `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${PACKAGE_NAME}`;
const UPLOAD_API = `https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/${PACKAGE_NAME}`;

function b64url(bytes) {
  return Buffer.from(bytes).toString("base64").replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
}

export async function zugang() {
  let account;
  try { account = JSON.parse(readFileSync(KEY_FILE, "utf8")); }
  catch { throw new Error(`Kein Dienstkonto unter ${KEY_FILE}.`); }
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const payload = b64url(JSON.stringify({
    iss: account.client_email, scope: "https://www.googleapis.com/auth/androidpublisher",
    aud: account.token_uri || "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600,
  }));
  const signer = createSign("RSA-SHA256");
  signer.update(`${header}.${payload}`);
  const jwt = `${header}.${payload}.${b64url(signer.sign(account.private_key))}`;
  const response = await fetch(account.token_uri || "https://oauth2.googleapis.com/token", {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: jwt }),
  });
  const json = await response.json();
  if (!json.access_token) throw new Error(`Anmeldung abgelehnt: ${json.error_description || json.error || response.status}`);
  console.log(`Angemeldet als ${account.client_email}`);
  return json.access_token;
}

export async function aufruf(token, method, url, body, typ = "application/json") {
  const response = await fetch(url, {
    method: method,
    headers: { Authorization: `Bearer ${token}`, ...(body !== undefined ? { "Content-Type": typ } : {}) },
    body: body === undefined ? undefined : (typ === "application/json" ? JSON.stringify(body) : body),
  });
  const text = await response.text();
  if (!response.ok) {
    let message = text;
    try { message = JSON.parse(text).error?.message ?? text; } catch {}
    throw new Error(`${method} ${url.replace(API, "").replace(UPLOAD_API, "")} → ${response.status}: ${message}`);
  }
  return text ? JSON.parse(text) : {};
}

async function verify() {
  const token = await zugang();
  const edit = await aufruf(token, "POST", `${API}/edits`, {});
  try {
    const { tracks = [] } = await aufruf(token, "GET", `${API}/edits/${edit.id}/tracks`);
    for (const t of tracks) {
      console.log(`\nTrack „${t.track}"`);
      for (const r of t.releases ?? []) {
        console.log(`  ${r.name ?? "(ohne Namen)"} · Versionscodes ${(r.versionCodes ?? []).join(", ")} · ${r.status}`);
      }
    }
  } finally {
    await aufruf(token, "DELETE", `${API}/edits/${edit.id}`);
  }
  console.log("\nNur gelesen, nichts geaendert.");
}

async function upload(file, track, notesFile, draft) {
  if (!file || !track) throw new Error("Aufruf: play.mjs hochladen <datei.aab> <track> [hinweise.json] [--entwurf]");
  const size = statSync(file).size;
  const notes = notesFile ? JSON.parse(readFileSync(notesFile, "utf8")) : null;
  for (const [language, text] of Object.entries(notes ?? {})) {
    if (text.length > 500) throw new Error(`Versionshinweise ${language}: ${text.length} Zeichen, Google erlaubt 500.`);
  }
  const token = await zugang();
  const edit = await aufruf(token, "POST", `${API}/edits`, {});
  let done = false;
  try {
    console.log(`Lade ${file} (${(size / 1e6).toFixed(1)} MB) …`);
    const bundle = await aufruf(token, "POST", `${UPLOAD_API}/edits/${edit.id}/bundles?uploadType=media`,
      readFileSync(file), "application/octet-stream");
    console.log(`Bundle angenommen: Versionscode ${bundle.versionCode}`);
    const release = {
      versionCodes: [String(bundle.versionCode)],
      status: draft ? "draft" : "completed",
      ...(notes ? { releaseNotes: Object.entries(notes).map(([language, text]) => ({ language, text })) } : {}),
    };
    await aufruf(token, "PUT", `${API}/edits/${edit.id}/tracks/${encodeURIComponent(track)}`, { track, releases: [release] });
    await aufruf(token, "POST", `${API}/edits/${edit.id}:commit${COMMIT_QUERY}`);
    done = true;
    console.log(`\n${draft ? "Als Entwurf" : "Veroeffentlicht"} in „${track}": Versionscode ${bundle.versionCode}.`);
  } finally {
    if (!done) await aufruf(token, "DELETE", `${API}/edits/${edit.id}`).catch(() => {});
  }
}

/** Releases a version code that is already uploaded (e.g. in another track) in `track`. */
async function promote(versionCode, track, notesFile) {
  if (!/^\d+$/.test(versionCode ?? "") || !track) throw new Error("Aufruf: play.mjs freigeben <versionscode> <track> [hinweise.json]");
  const notes = notesFile ? JSON.parse(readFileSync(notesFile, "utf8")) : null;
  const token = await zugang();
  const edit = await aufruf(token, "POST", `${API}/edits`, {});
  let done = false;
  try {
    const release = {
      versionCodes: [versionCode], status: "completed",
      ...(notes ? { releaseNotes: Object.entries(notes).map(([language, text]) => ({ language, text })) } : {}),
    };
    await aufruf(token, "PUT", `${API}/edits/${edit.id}/tracks/${encodeURIComponent(track)}`, { track, releases: [release] });
    await aufruf(token, "POST", `${API}/edits/${edit.id}:commit${COMMIT_QUERY}`);
    done = true;
    console.log(`Veroeffentlicht in „${track}": Versionscode ${versionCode}.`);
  } finally {
    if (!done) await aufruf(token, "DELETE", `${API}/edits/${edit.id}`).catch(() => {});
  }
}

/**
 * **The APK for GitHub** -- users without the Play Store (or with a TV that
 * lacks it) should be able to download Swiftly from the releases too. The
 * universal APK that Google generates from the bundle is used, **signed with
 * the Play app signing key**: it matches every Play installation, and an
 * update through Play keeps working afterwards. A self-built release APK
 * carries the upload key and does not match (signature), which would mean
 * uninstalling first.
 */
async function appendApk(versionCode, versionDefault, dryRun) {
  if (!/^\d+$/.test(versionCode ?? "")) {
    throw new Error("Aufruf: play.mjs apk-anhaengen <versionscode> [--fassung 1.0.4] [--dry-run]");
  }
  const token = await zugang();

  // The version: from the name of the Play release carrying this version code ("1.0.4 (8)").
  let version = versionDefault;
  if (!version) {
    const edit = await aufruf(token, "POST", `${API}/edits`, {});
    try {
      const { tracks = [] } = await aufruf(token, "GET", `${API}/edits/${edit.id}/tracks`);
      for (const t of tracks) for (const r of t.releases ?? []) {
        if ((r.versionCodes ?? []).includes(String(versionCode))) {
          version ??= (r.name ?? "").match(/\d+\.\d+(?:\.\d+)?/)?.[0];
          console.log(`Play: „${t.track}" · ${r.name ?? "(ohne Namen)"} · ${r.status}`);
        }
      }
    } finally {
      await aufruf(token, "DELETE", `${API}/edits/${edit.id}`);
    }
  }
  if (!version) throw new Error(`Keine Fassung zu Versionscode ${versionCode} gefunden — mit --fassung angeben.`);
  const tag = `v${version}`;
  const name = `Swiftly-${version}.apk`;

  // Which APKs Google generated -- one group per signing key, containing the universal APK.
  const { generatedApks = [] } = await aufruf(token, "GET", `${API}/generatedApks/${versionCode}`);
  const universal = generatedApks.map((g) => g.generatedUniversalApk?.downloadId).filter(Boolean);
  if (universal.length === 0) throw new Error(`Google hat zu Versionscode ${versionCode} keine Universal-APK erzeugt.`);
  if (universal.length > 1) throw new Error(`${universal.length} Signaturschluessel mit Universal-APK — nicht eindeutig.`);
  console.log(`Universal-APK zu Versionscode ${versionCode}: vorhanden (von Play signiert).`);

  // The release must already exist -- none is created here.
  const root = join(dirname(fileURLToPath(import.meta.url)), "..");
  let present = [];
  try {
    const release = JSON.parse(execFileSync("gh", ["release", "view", tag, "--json", "assets"],
                                            { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }));
    present = (release.assets ?? []).map((a) => a.name);
  } catch {
    throw new Error(`Kein GitHub-Release „${tag}". Erst das Release anlegen, dann die APK anhaengen.`);
  }
  console.log(`GitHub-Release „${tag}": ${present.length} Anhaenge${present.includes(name) ? `, ${name} schon dabei` : ""}.`);
  if (present.includes(name)) throw new Error(`${name} haengt schon an „${tag}" — nichts ersetzt.`);

  if (dryRun) {
    console.log(`\n--dry-run: wuerde die APK laden und als ${name} an „${tag}" haengen. Nichts geladen, nichts geaendert.`);
    return;
  }

  const url = `${API}/generatedApks/${versionCode}/downloads/${encodeURIComponent(universal[0])}:download?alt=media`;
  const response = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (!response.ok) throw new Error(`Laden der APK → ${response.status}: ${(await response.text()).slice(0, 300)}`);
  const bytes = Buffer.from(await response.arrayBuffer());
  // An APK is a ZIP -- if the response does not start with "PK", it is an error page.
  if (bytes.length < 1e6 || bytes[0] !== 0x50 || bytes[1] !== 0x4b) throw new Error(`Die Antwort ist keine APK (${bytes.length} Bytes).`);
  const file = join(mkdtempSync(join(tmpdir(), "swiftly-apk-")), name);
  writeFileSync(file, bytes);
  console.log(`Geladen: ${file} (${(bytes.length / 1e6).toFixed(1)} MB)`);
  execFileSync("gh", ["release", "upload", tag, file], { cwd: root, stdio: "inherit" });
  console.log(`\nAngehaengt: ${name} an „${tag}".`);
}

export { API };

// Run only as a command, not when another script imports the sign-in code.
if (import.meta.url === `file://${process.argv[1]}`) {
const [command, ...rest] = process.argv.slice(2);
const draft = rest.includes("--entwurf");
const dryRun = rest.includes("--dry-run");
const versionIndex = rest.indexOf("--fassung");
const version = versionIndex >= 0 ? rest[versionIndex + 1] : undefined;
const args = rest.filter((a, i) => a !== "--entwurf" && a !== "--dry-run" && a !== "--fassung"
                                        && (versionIndex < 0 || i !== versionIndex + 1));
try {
  if (command === "pruefen") await verify();
  else if (command === "hochladen") await upload(args[0], args[1], args[2], draft);
  else if (command === "freigeben") await promote(args[0], args[1], args[2]);
  else if (command === "apk-anhaengen") await appendApk(args[0], version, dryRun);
  else {
    console.error("Befehle: pruefen · hochladen <datei.aab> <track> [hinweise.json] [--entwurf]"
                  + " · apk-anhaengen <versionscode> [--fassung 1.0.4] [--dry-run]");
    process.exitCode = 2;
  }
} catch (failure) {
  console.error(`\nFehlgeschlagen: ${failure.message}`);
  process.exitCode = 1;
}
}

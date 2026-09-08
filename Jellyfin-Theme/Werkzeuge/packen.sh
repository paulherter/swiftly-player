#!/bin/bash
# Baut das Plugin und legt Paket und Verzeichnis daneben.
#
# Ein Jellyfin-Plugin wird als Zip mit `meta.json` und der DLL ausgeliefert;
# damit es sich im Dashboard **mit einem Klick** einrichten lässt, braucht es
# zusätzlich ein Verzeichnis (`manifest.json`) mit Pruefsumme und Adresse.
#
#   Jellyfin-Theme/Werkzeuge/packen.sh [Fassung]
#
# Ohne Angabe gilt die Fassung aus dem Skript.

set -eu
cd "$(dirname "$0")/.."          # Jellyfin-Theme
FASSUNG="${1:-1.0.0.0}"
ZIEL="$FASSUNG"
NAME="swiftly_$FASSUNG.zip"
# Wohin das Paket zeigt, wenn es im Verzeichnis steht.
BASIS="https://github.com/paulherter/swiftly-player/raw/main/Jellyfin-Theme/Pakete"

export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1

echo "── Bauen ──────────────────────────────────────────────"
dotnet build Plugin/Jellyfin.Plugin.Swiftly.csproj -c Release -v minimal \
    -p:AssemblyVersion="$FASSUNG" -p:FileVersion="$FASSUNG"

DLL=$(find Plugin/bin/Release -name 'Jellyfin.Plugin.Swiftly.dll' | head -1)
[ -n "$DLL" ] || { echo "Keine DLL gefunden."; exit 1; }

echo
echo "── Packen ─────────────────────────────────────────────"
mkdir -p Pakete
BAU=$(mktemp -d)
cp "$DLL" "$BAU/"

# `meta.json` liegt **im** Paket. Der Server liest daraus, was er anzeigt.
cat > "$BAU/meta.json" <<META
{
    "category": "General",
    "guid": "b7f4c1a2-3d6e-4c58-9a10-5f2e8c7d4b39",
    "name": "Swiftly",
    "overview": "Das Erscheinungsbild der Swiftly-App für die Weboberfläche.",
    "description": "Bringt die Weboberfläche auf das Erscheinungsbild der Swiftly-App — genauer: auf das der macOS-Fassung. Farben, Eckenskala, Schriftstufen, Zeiten und Bausteine stammen aus dem Quelltext der App.",
    "owner": "paulherter",
    "targetAbi": "12.0.0.0",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "version": "$FASSUNG",
    "changelog": "",
    "imageUrl": null
}
META

(cd "$BAU" && zip -q -r "$OLDPWD/Pakete/$NAME" .)
rm -rf "$BAU"

PRUEF=$(md5 -q "Pakete/$NAME" 2>/dev/null || md5sum "Pakete/$NAME" | cut -d' ' -f1)
GROESSE=$(wc -c < "Pakete/$NAME" | tr -d ' ')

echo "  Pakete/$NAME  ($GROESSE Bytes, MD5 $PRUEF)"

echo
echo "── Verzeichnis ────────────────────────────────────────"
# **Ein Eintrag je Fassung, neueste zuerst.** Jellyfin liest die Liste und
# bietet an, was zur eigenen ABI passt.
python3 - "$FASSUNG" "$PRUEF" "$BASIS/$NAME" <<'PY'
import json, pathlib, subprocess, sys

fassung, pruef, adresse = sys.argv[1], sys.argv[2], sys.argv[3]
datei = pathlib.Path("manifest.json")
zeit = subprocess.run(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"],
                      capture_output=True, text=True).stdout.strip()

if datei.exists():
    verzeichnis = json.loads(datei.read_text(encoding="utf-8"))
else:
    verzeichnis = [{
        "guid": "b7f4c1a2-3d6e-4c58-9a10-5f2e8c7d4b39",
        "name": "Swiftly",
        "description": "Bringt die Weboberfläche auf das Erscheinungsbild der "
                       "Swiftly-App — genauer: auf das der macOS-Fassung.",
        "overview": "Das Erscheinungsbild der Swiftly-App für die Weboberfläche.",
        "owner": "paulherter",
        "category": "General",
        "imageUrl": None,
        "versions": [],
    }]

fassungen = verzeichnis[0]["versions"]
fassungen = [v for v in fassungen if v["version"] != fassung]
fassungen.insert(0, {
    "version": fassung,
    "changelog": "",
    "targetAbi": "12.0.0.0",
    "sourceUrl": adresse,
    "checksum": pruef,
    "timestamp": zeit,
})
verzeichnis[0]["versions"] = fassungen
datei.write_text(json.dumps(verzeichnis, indent=4, ensure_ascii=False) + "\n",
                 encoding="utf-8")
print(f"  manifest.json — {len(fassungen)} Fassung(en), neueste {fassung}")
PY

echo
echo "Fertig. Einrichten im Dashboard über die Verzeichnis-Adresse:"
echo "  https://raw.githubusercontent.com/paulherter/swiftly-player/main/Jellyfin-Theme/manifest.json"

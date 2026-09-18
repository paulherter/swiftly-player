# Einmal einrichten, dann läuft es von selbst

Diese Schritte macht Paul **einmal**. Danach landet jede neue GitHub-Version
automatisch bei winget und im AUR — der Auslöser ist die Veröffentlichung
des Releases, ohne dass jemand etwas anstößt.

Die beiden Workflows liegen bereits im Repository
(`.github/workflows/winget.yml`, `.github/workflows/aur.yml`) und sind
committet, aber **nicht gepusht** — sie werden erst mit dem nächsten Push
scharf, und erst danach greifen die Secrets unten.

## 1. winget (Windows)

1. **Klassisches Personal Access Token anlegen:** GitHub → Settings →
   Developer settings → Personal access tokens → Tokens (classic) → Generate
   new token, Recht `public_repo`, keine weiteren. *Fine-grained*-Token
   funktionieren mit `winget-releaser` nicht.
2. **`microsoft/winget-pkgs` einmal forken**, unter dem eigenen Konto
   (`paulherter`) — der Fork bleibt liegen, `winget-releaser` öffnet PRs von
   dort aus.
3. **Token als Secret hinterlegen:**
   ```sh
   gh secret set WINGET_TOKEN --repo paulherter/swiftly-player
   ```
   (fragt interaktiv nach dem Wert; das Token nie in eine Datei schreiben).
4. **Erste Einreichung von Hand**, weil `winget-releaser` mindestens eine
   vorhandene Fassung im Community-Repository als Vorlage braucht. Am
   einfachsten mit `wingetcreate` (läuft unter Windows oder per `dotnet` auf
   jedem Rechner):
   ```sh
   wingetcreate submit --token <PAT> Verteilung/winget/1.0.3/PaulHerter.SwiftlyPlayer.yaml
   ```
   Die drei fertigen Manifeste liegen unter `Verteilung/winget/1.0.3/` und
   sind bereits gegen das aktuelle Schema geschrieben, inklusive der
   SHA256-Prüfsumme des Installers. `wingetcreate submit` liest alle drei aus
   demselben Ordner und öffnet den PR gegen `microsoft/winget-pkgs`.
5. Ab der nächsten Veröffentlichung (`gh release create` oder über die
   Weboberfläche) baut `winget-releaser` das Manifest selbst und öffnet den
   Aktualisierungs-PR — läuft von selbst bei jedem Release.

## 2. AUR (Arch Linux)

1. **AUR-Konto anlegen** unter <https://aur.archlinux.org/register/>.
2. **SSH-Schlüsselpaar nur für das AUR** erzeugen (nicht den eigenen
   Alltagsschlüssel verwenden):
   ```sh
   ssh-keygen -t ed25519 -f ~/.ssh/aur-swiftly -C "aur@paulherter.de" -N ""
   ```
3. **Öffentlichen Schlüssel im AUR-Konto hinterlegen** (Kontoseite → "My
   Account" → SSH Public Key → den Inhalt von `~/.ssh/aur-swiftly.pub`
   einfügen, speichern).
4. **Paket einmal von Hand anlegen** — das AUR nimmt kein leeres Paket per
   Workflow an, es muss den ersten Push von einem Rechner mit `git` und dem
   hinterlegten Schlüssel sehen:
   ```sh
   git clone ssh://aur@aur.archlinux.org/swiftly-player-bin.git
   cp Verteilung/aur/swiftly-player-bin/PKGBUILD \
      Verteilung/aur/swiftly-player-bin/.SRCINFO \
      swiftly-player-bin/
   cd swiftly-player-bin
   git add PKGBUILD .SRCINFO
   git commit -m "swiftly-player-bin 1.0.3"
   git push
   ```
   Die mitgelieferte `.SRCINFO` wurde von Hand nach dem PKGBUILD geschrieben,
   weil `makepkg` auf diesem Rechner fehlt und `cachy` beim Einrichten nicht
   erreichbar war (kein Weg zum Host). **Vor diesem ersten Push einmal
   gegenprüfen:**
   ```sh
   cd swiftly-player-bin && makepkg --printsrcinfo > .SRCINFO
   ```
   falls ein Arch-Rechner (z. B. cachy) zur Hand ist — sonst reicht auch der
   Stand hier, `makepkg` prüft Feldnamen beim ersten Bau eines Nutzers ohnehin
   nach.
5. **Drei Secrets im Repository hinterlegen:**
   ```sh
   gh secret set AUR_SSH_PRIVATE_KEY --repo paulherter/swiftly-player < ~/.ssh/aur-swiftly
   gh secret set AUR_USERNAME --repo paulherter/swiftly-player   # AUR-Kontoname
   gh secret set AUR_EMAIL --repo paulherter/swiftly-player      # E-Mail des AUR-Kontos
   ```
6. Ab der nächsten Veröffentlichung schreibt der Workflow `aur.yml` pkgver
   und Prüfsumme selbst neu und pusht — läuft von selbst bei jedem Release.

## 3. Was absichtlich fehlt

- **Homebrew Cask:** entfällt. Es gibt keinen Mac-Download außerhalb des App
  Stores, ein Cask hätte nichts zum Verweisen.
- **Flathub:** zurückgestellt. Braucht ein eigenes Flatpak-Manifest und eine
  redaktionelle Prüfung durch Flathub — kein reiner Automatisierungsschritt,
  eher ein eigenes Paketierungsprojekt für später.

## 4. Danach

Kein weiterer Schritt. `gh release create v1.0.4 ...` (oder ein Release über
die Weboberfläche) löst `linux-pakete.yml`, `winget.yml` und `aur.yml`
gleichzeitig aus.

# One-time setup

These steps are done **once**. After that, every new GitHub release is
published to winget and the AUR automatically. The trigger is publishing the
release; nobody has to start anything.

Both workflows are in the repository (`.github/workflows/winget.yml`,
`.github/workflows/aur.yml`). They only run once they are on the default
branch, and the secrets below are needed before they can succeed.

## 1. winget (Windows)

1. **Create a classic personal access token:** GitHub → Settings →
   Developer settings → Personal access tokens → Tokens (classic) → Generate
   new token, scope `public_repo`, nothing else. *Fine-grained* tokens do not
   work with `winget-releaser`.
2. **Fork `microsoft/winget-pkgs` once**, under the publishing account
   (`paulherter`). The fork stays in place; `winget-releaser` opens its PRs
   from there.
3. **Store the token as a secret:**
   ```sh
   gh secret set WINGET_TOKEN --repo paulherter/swiftly-player
   ```
   (prompts for the value; never write the token to a file).
4. **Submit the first version by hand**, because `winget-releaser` needs at
   least one existing version in the community repository as a template. The
   easiest way is `wingetcreate` (runs on Windows, or through `dotnet` on any
   machine):
   ```sh
   wingetcreate submit --token <PAT> Distribution/winget/1.0.3/PaulHerter.SwiftlyPlayer.yaml
   ```
   The three finished manifests are in `Distribution/winget/1.0.3/`. They follow
   the current schema and include the installer's SHA256 checksum.
   `wingetcreate submit` reads all three from the same folder and opens the PR
   against `microsoft/winget-pkgs`.
5. From the next release on (`gh release create` or the web UI),
   `winget-releaser` builds the manifest itself and opens the update PR.

## 2. AUR (Arch Linux)

1. **Create an AUR account** at <https://aur.archlinux.org/register/>.
2. **Generate an SSH key pair just for the AUR** (do not reuse your everyday
   key):
   ```sh
   ssh-keygen -t ed25519 -f ~/.ssh/aur-swiftly -C "aur@paulherter.de" -N ""
   ```
3. **Add the public key to the AUR account** (account page → "My Account" →
   SSH Public Key → paste the contents of `~/.ssh/aur-swiftly.pub`, save).
4. **Create the package by hand once.** The AUR does not accept an empty
   package from a workflow; the first push has to come from a machine with
   `git` and the registered key:
   ```sh
   git clone ssh://aur@aur.archlinux.org/swiftly-player-bin.git
   cp Distribution/aur/swiftly-player-bin/PKGBUILD \
      Distribution/aur/swiftly-player-bin/.SRCINFO \
      swiftly-player-bin/
   cd swiftly-player-bin
   git add PKGBUILD .SRCINFO
   git commit -m "swiftly-player-bin 1.0.3"
   git push
   ```
   The shipped `.SRCINFO` was written by hand from the PKGBUILD, because
   `makepkg` was not available where it was prepared. **Check it once before
   the first push**, on an Arch machine:
   ```sh
   cd swiftly-player-bin && makepkg --printsrcinfo > .SRCINFO
   ```
   Without an Arch machine the shipped file is acceptable; `makepkg` checks the
   field names on the first build by a user anyway.
5. **Add three secrets to the repository:**
   ```sh
   gh secret set AUR_SSH_PRIVATE_KEY --repo paulherter/swiftly-player < ~/.ssh/aur-swiftly
   gh secret set AUR_USERNAME --repo paulherter/swiftly-player   # AUR account name
   gh secret set AUR_EMAIL --repo paulherter/swiftly-player      # AUR account email
   ```
6. From the next release on, the `aur.yml` workflow rewrites pkgver and the
   checksum itself and pushes.

## 3. What is missing on purpose

- **Homebrew Cask:** not planned. There is no Mac download outside the App
  Store, so a cask would have nothing to point to.
- **Flathub:** postponed. It needs its own Flatpak manifest and an editorial
  review by Flathub, so it is a packaging project of its own, not an
  automation step.

## 4. After that

Nothing else to do. `gh release create v1.0.4 ...` (or a release through the
web UI) triggers `linux-packages.yml`, `winget.yml` and `aur.yml` at the same
time.

#!/usr/bin/env bash
# rlottie fuer die Startanimation bauen — ohne cmake.
#
# **Warum nicht das Paket.** Auf Arch gibt es rlottie weder in den
# Paketquellen noch als fertige Bibliothek; im AUR liegt ein cmake-Bau, und
# cmake selbst ist auf dieser Kiste nicht da. Die Bibliothek hat keine
# externen Abhaengigkeiten — sie bringt Freetype-Teile, Pixman und stb selbst
# mit —, also laesst sie sich in einem Zug uebersetzen.
#
# Legt alles unter ~/.local ab. Nichts davon beruehrt das System, und es
# braucht kein Passwort.
set -euo pipefail

quelle="${1:-$HOME/rlottie-bau}"
ziel="${SWIFTLY_RLOTTIE_ZIEL:-$HOME/.local}"

if [ ! -d "$quelle" ]; then
    git clone --depth 1 https://github.com/Samsung/rlottie.git "$quelle"
fi
cd "$quelle"

# Die Kopfdatei, die sonst cmake schreibt.
#
# **Ohne Faeden, und das ist gemessen.** Mit `LOTTIE_THREAD_SUPPORT` legt
# rlottie einen Fadenpool an, der beim Laden der Vorlage startet und danach
# leer weiterdreht: drei Faeden, zusammen 90 % einer Kerne-Last, dauerhaft.
# Die App wurde davon so langsam, dass ihr Fenster schwarz blieb. Fuer eine
# Marke von 360 Punkten, die einmal beim Start laeuft, ist ein Faden mehr als
# genug.
cat > src/vector/config.h <<'EOF'
#define LOTTIE_IMAGE_MODULE_PLUGIN ""
#define LOTTIE_CACHE
#define LOTTIE_CACHE_SUPPORT
EOF

mkdir -p "$ziel/lib/pkgconfig" "$ziel/include"

quellen=$(find src/lottie src/vector src/binding -name '*.cpp' | grep -v wasm)
flaggen=(-std=c++14 -O2 -fPIC -w -DNDEBUG
    -Iinc -Isrc/vector -Isrc/vector/freetype -Isrc/vector/pixman
    -Isrc/vector/stb -Isrc/lottie -Isrc/binding)

# **Ein Archiv, keine Bibliothek neben der App.**
#
# Die Bibliothek gibt es in keiner Paketquelle. Als `.so` muesste sie
# mitgeliefert und ueber einen Suchpfad gefunden werden — genau die Sorte
# Installation, die auf einem fremden Rechner schiefgeht. Statisch gebunden
# ist sie einfach im Binaerprogramm drin, und das Paket haengt nur noch an
# Sachen, die jede Distribution hat.
rm -rf "$quelle/.obj"
mkdir -p "$quelle/.obj"
zaehler=0
for datei in $quellen; do
    g++ "${flaggen[@]}" -c "$datei" -o "$quelle/.obj/$zaehler.o" &
    zaehler=$((zaehler + 1))
    if [ $((zaehler % 8)) -eq 0 ]; then wait; fi
done
wait

ar rcs "$ziel/lib/librlottie.a" "$quelle"/.obj/*.o
rm -f "$ziel/lib/librlottie.so"

cp inc/rlottie_capi.h inc/rlottiecommon.h "$ziel/include/"

# **Nur `-L` und `-l`, nichts sonst.** SwiftPM liest die pkg-config-Angaben
# nicht durch, sondern filtert sie: alles, was kein `-l` oder `-L` ist, faellt
# weg. Ein voller Archivpfad und `-Wl,--whole-archive` kamen beim Binder nie
# an — der Bau brach an lauter `undefined reference to lottie_animation_*` ab.
# Deshalb `-lrlottie`, und deshalb liegt neben dem Archiv keine `.so`: sonst
# nimmt der Binder die.
cat > "$ziel/lib/pkgconfig/rlottie.pc" <<EOF
prefix=$ziel
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: rlottie
Description: Lottie-Abspieler
Version: 0.2
Libs: -L\${libdir} -lrlottie -lstdc++ -lm
Cflags: -I\${includedir}
EOF

echo "librlottie.a liegt in $ziel/lib"
echo "PKG_CONFIG_PATH=$ziel/lib/pkgconfig muss beim Bauen gesetzt sein."

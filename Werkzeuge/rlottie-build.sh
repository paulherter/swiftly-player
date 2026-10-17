#!/usr/bin/env bash
# Build rlottie for the start animation -- without cmake.
#
# **Why not the package.** On Arch, rlottie is neither in the package
# repositories nor available as a ready-made library; the AUR has a cmake
# build, and cmake itself may not be installed. The library has no external
# dependencies -- it bundles its Freetype parts, Pixman and stb -- so it can
# be compiled in a single step.
#
# Puts everything under ~/.local. Nothing touches the system, and no
# password is needed.
set -euo pipefail

source="${1:-$HOME/rlottie-bau}"
target="${SWIFTLY_RLOTTIE_ZIEL:-$HOME/.local}"

if [ ! -d "$source" ]; then
    git clone --depth 1 https://github.com/Samsung/rlottie.git "$source"
fi
cd "$source"

# The header that cmake would otherwise write.
#
# **No threads, and this was measured.** With `LOTTIE_THREAD_SUPPORT` rlottie
# creates a thread pool that starts when the template is loaded and then keeps
# spinning idle: three threads, together about 90% of one core, permanently.
# That slowed the app down so much that its window stayed black. For a mark of
# 360 points that plays once at startup, one thread is more than enough.
cat > src/vector/config.h <<'EOF'
#define LOTTIE_IMAGE_MODULE_PLUGIN ""
#define LOTTIE_CACHE
#define LOTTIE_CACHE_SUPPORT
EOF

mkdir -p "$target/lib/pkgconfig" "$target/include"

sources=$(find src/lottie src/vector src/binding -name '*.cpp' | grep -v wasm)
flaggen=(-std=c++14 -O2 -fPIC -w -DNDEBUG
    -Iinc -Isrc/vector -Isrc/vector/freetype -Isrc/vector/pixman
    -Isrc/vector/stb -Isrc/lottie -Isrc/binding)

# **An archive, not a library next to the app.**
#
# The library is in no package repository. As a `.so` it would have to be
# shipped and found through a search path -- exactly the kind of installation
# that goes wrong on someone else's machine. Linked statically it is simply
# inside the binary, and the package depends only on things every
# distribution has.
rm -rf "$source/.obj"
mkdir -p "$source/.obj"
counter=0
for file in $sources; do
    g++ "${flaggen[@]}" -c "$file" -o "$source/.obj/$counter.o" &
    counter=$((counter + 1))
    if [ $((counter % 8)) -eq 0 ]; then wait; fi
done
wait

ar rcs "$target/lib/librlottie.a" "$source"/.obj/*.o
rm -f "$target/lib/librlottie.so"

cp inc/rlottie_capi.h inc/rlottiecommon.h "$target/include/"

# **Only `-L` and `-l`, nothing else.** SwiftPM does not pass the pkg-config
# output through but filters it: everything that is not `-l` or `-L` is
# dropped. A full archive path and `-Wl,--whole-archive` never reached the
# linker -- the build failed with lots of `undefined reference to
# lottie_animation_*`. Hence `-lrlottie`, and hence no `.so` next to the
# archive: the linker would pick it instead.
cat > "$target/lib/pkgconfig/rlottie.pc" <<EOF
prefix=$target
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: rlottie
Description: Lottie-Abspieler
Version: 0.2
Libs: -L\${libdir} -lrlottie -lstdc++ -lm
Cflags: -I\${includedir}
EOF

echo "librlottie.a liegt in $target/lib"
echo "PKG_CONFIG_PATH=$target/lib/pkgconfig muss beim Bauen gesetzt sein."

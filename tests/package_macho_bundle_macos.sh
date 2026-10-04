#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_root="$(mktemp -d "${TMPDIR:-/tmp}/macho-bundle-test.XXXXXX")"
trap 'rm -rf "$task_root"' EXIT
target_arch="${TARGET_ARCH:-$(uname -m)}"
sdl2_prefix="$task_root/sdl2"
sdl3_prefix="$task_root/sdl3"
mkdir -p "$sdl2_prefix/bin" "$sdl2_prefix/lib" "$sdl3_prefix/lib"

cat > "$task_root/dependency.c" <<'C'
int dependency_value(void) { return 42; }
C
cat > "$task_root/sdl3.c" <<'C'
extern int dependency_value(void);
int sdl3_value(void) { return dependency_value(); }
C
cat > "$task_root/sdl2.c" <<'C'
#include <dlfcn.h>
const char *compat_marker(void) { return "sdl2-compat:"; }
int sdl2_value(void) {
    void *handle = dlopen("@loader_path/libSDL3.dylib", RTLD_NOW);
    if (!handle) return -1;
    int (*value)(void) = dlsym(handle, "sdl3_value");
    int result = value ? value() : -1;
    dlclose(handle);
    return result;
}
C
cat > "$task_root/player.c" <<'C'
#include <stdio.h>
extern int sdl2_value(void);
int main(void) {
    int value = sdl2_value();
    printf("SDL runtime value: %d\n", value);
    return value != 42;
}
C

clang -arch "$target_arch" -dynamiclib -Wl,-headerpad_max_install_names \
  "$task_root/dependency.c" -install_name "$sdl3_prefix/lib/libfixture.dylib" \
  -o "$sdl3_prefix/lib/libfixture.dylib"
clang -arch "$target_arch" -dynamiclib -Wl,-headerpad_max_install_names \
  "$task_root/sdl3.c" "$sdl3_prefix/lib/libfixture.dylib" \
  -install_name "$sdl3_prefix/lib/libSDL3.0.dylib" -o "$sdl3_prefix/lib/libSDL3.0.dylib"
ln -s libSDL3.0.dylib "$sdl3_prefix/lib/libSDL3.dylib"
clang -arch "$target_arch" -dynamiclib -Wl,-headerpad_max_install_names \
  "$task_root/sdl2.c" -install_name "$sdl2_prefix/lib/libSDL2-2.0.0.dylib" \
  -o "$sdl2_prefix/lib/libSDL2-2.0.0.dylib"
clang -arch "$target_arch" -Wl,-headerpad_max_install_names "$task_root/player.c" \
  "$sdl2_prefix/lib/libSDL2-2.0.0.dylib" -o "$sdl2_prefix/bin/player"

if ruby "$repo_root/tools/package_macho_bundle.rb" "$task_root/missing" \
  "$sdl2_prefix" -- "$sdl2_prefix/bin/player" > "$task_root/missing.log" 2>&1; then
  echo "Packaging unexpectedly succeeded without SDL3" >&2
  exit 1
fi
grep -F 'Missing required runtime dependency @rpath/libSDL3.dylib' "$task_root/missing.log"

ruby "$repo_root/tools/package_macho_bundle.rb" "$task_root/bundle" \
  "$sdl2_prefix" "$sdl3_prefix" -- "$sdl2_prefix/bin/player" > "$task_root/package.log" 2>&1
test -f "$task_root/bundle/lib/libSDL3.dylib"
test -f "$task_root/bundle/lib/libfixture.dylib"
mv "$sdl2_prefix" "$task_root/hidden-sdl2"
mv "$sdl3_prefix" "$task_root/hidden-sdl3"
mv "$task_root/bundle" "$task_root/relocated bundle"
env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH \
  "$task_root/relocated bundle/bin/player" | grep -Fx 'SDL runtime value: 42'

echo "PASS: $target_arch SDL3 dlopen dependency, transitive dylib, and bundle relocation"

# The pinned Intel toolchain still uses native SDL2, which does not need SDL3.
native_prefix="$task_root/native-sdl2"
mkdir -p "$native_prefix/bin" "$native_prefix/lib"
printf 'int sdl2_value(void) { return 42; }\n' > "$task_root/native-sdl2.c"
clang -arch "$target_arch" -dynamiclib -Wl,-headerpad_max_install_names \
  "$task_root/native-sdl2.c" -install_name "$native_prefix/lib/libSDL2-2.0.0.dylib" \
  -o "$native_prefix/lib/libSDL2-2.0.0.dylib"
clang -arch "$target_arch" -Wl,-headerpad_max_install_names "$task_root/player.c" \
  "$native_prefix/lib/libSDL2-2.0.0.dylib" -o "$native_prefix/bin/player"
ruby "$repo_root/tools/package_macho_bundle.rb" "$task_root/native-bundle" \
  "$native_prefix" -- "$native_prefix/bin/player" > "$task_root/native.log" 2>&1
test ! -e "$task_root/native-bundle/lib/libSDL3.dylib"
mv "$native_prefix" "$task_root/hidden-native-sdl2"
env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH \
  "$task_root/native-bundle/bin/player" | grep -Fx 'SDL runtime value: 42'
echo "PASS: $target_arch native SDL2 needs no SDL3"

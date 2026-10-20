#!/usr/bin/env bash
set -euo pipefail

NP03J_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NP03J_SOURCE="$NP03J_ROOT/manager-source"
NP03J_LOCK="$NP03J_ROOT/source-lock/source-lock.json"
NP03J_OUTPUT="$NP03J_ROOT/manager-artifacts"
NP03J_NDK_VERSION="$(python3 -c 'import json; print(json.load(open("manager-source/np03j-toolchain.json"))["ndk"])')"
NP03J_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:?Android SDK is missing}}"
NP03J_NDK="$NP03J_SDK/ndk/$NP03J_NDK_VERSION"
NP03J_LLVM="$NP03J_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
NP03J_CC="$NP03J_LLVM/aarch64-linux-android26-clang"
test -x "$NP03J_CC"

export ANDROID_NDK_HOME="$NP03J_NDK" ANDROID_NDK_ROOT="$NP03J_NDK"
export CLANG_PATH="$NP03J_CC"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$NP03J_CC"
export CC_aarch64_linux_android="$NP03J_CC"
export CXX_aarch64_linux_android="${NP03J_CC}++"
export AR_aarch64_linux_android="$NP03J_LLVM/llvm-ar"
export LIBCLANG_PATH
LIBCLANG_PATH="$(llvm-config --libdir)"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android
BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--target=aarch64-linux-android26 --sysroot=$NP03J_NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$NP03J_NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android -I$NP03J_NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include"

rustup target add aarch64-linux-android
cd "$NP03J_SOURCE"
NP03J_BUILTINS="$("$NP03J_CC" --print-resource-dir)/lib/linux/libclang_rt.builtins-aarch64-android.a"
test -f "$NP03J_BUILTINS"
RUSTFLAGS="-C target-feature=+crt-static -C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wno-unused-command-line-argument -C link-arg=$NP03J_BUILTINS" \
  cargo build --locked --release --target aarch64-linux-android --manifest-path userspace/ksuinit/Cargo.toml
install -m 0755 userspace/ksuinit/target/aarch64-linux-android/release/ksuinit userspace/ksud/bin/aarch64/ksuinit
RUSTFLAGS="-C link-arg=-Wl,-z,max-page-size=16384" \
  cargo build --locked --release --target aarch64-linux-android --manifest-path userspace/ksud/Cargo.toml
mkdir -p manager/app/src/main/jniLibs/arm64-v8a
install -m 0755 userspace/ksud/target/aarch64-linux-android/release/ksud manager/app/src/main/jniLibs/arm64-v8a/libksud.so
"$NP03J_LLVM/llvm-readelf" -h manager/app/src/main/jniLibs/arm64-v8a/libksud.so
cd manager
chmod +x gradlew
./gradlew --no-daemon --no-build-cache -Dorg.gradle.caching=false -Dorg.gradle.configuration-cache=false clean assembleRelease
cd "$NP03J_ROOT"
python3 .github/np03j/np03j.py manager-metadata "$NP03J_LOCK" "$NP03J_SOURCE" "$NP03J_OUTPUT"

# Build only the CLI needed for this ARM64 device. The kernel driver is built in.
NP03J_NOMOUNT_SHA="$(python3 -c 'import json; print(json.load(open("source-lock/source-lock.json"))["sources"]["nomount"]["sha"])')"
python3 - <<'PY'
import importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location('np03j', '.github/np03j/np03j.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
lock = m.load_lock('source-lock/source-lock.json')
m.clone_at(lock['sources']['nomount']['url'], lock['sources']['nomount']['sha'], Path('nomount-module-source'))
PY
mkdir -p nomount-module-source/module/bin
"$NP03J_CC" -Oz -static -nostdlib -ffreestanding -fno-builtin -fno-stack-protector \
  -fno-pie -no-pie -fno-unwind-tables -fno-ident -Wno-invalid-noreturn \
  -Wl,--entry=_start nomount-module-source/userspace/src/nm.c \
  -o nomount-module-source/module/bin/nm-arm64
"$NP03J_LLVM/llvm-readelf" -h nomount-module-source/module/bin/nm-arm64
cp .github/np03j/nomount-customize.sh nomount-module-source/module/customize.sh
printf '%s\n' "$NP03J_NOMOUNT_SHA" > nomount-module-source/module/NOMOUNT_SOURCE_COMMIT
python3 - <<'PY'
import importlib.util
spec = importlib.util.spec_from_file_location('np03j', '.github/np03j/np03j.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
mprop = m.ROOT / 'nomount-module-source/module/module.prop'
import re
stamp = m.run('git', 'show', '-s', '--format=%ct', 'HEAD', cwd='nomount-module-source', capture=True).strip()
mprop.write_text(re.sub(r'^versionCode=.*$', 'versionCode=' + stamp, mprop.read_text(), flags=re.M))
m.zip_tree('nomount-module-source/module', 'manager-artifacts/NoMount-NP03J-Builtin.zip')
PY

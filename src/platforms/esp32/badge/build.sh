#!/usr/bin/env bash
# Build the badge VM image and boot.avm. Expects ESP-IDF v5.5.5 exported.
# --vm-only skips boot.avm (for hosts without Erlang/Elixir, e.g. CI's IDF
# container). Output: src/platforms/esp32/build-badge/out/
set -euo pipefail

vm_only=no
case "${1:-}" in
    --vm-only) vm_only=yes ;;
    "") ;;
    *) echo "usage: $0 [--vm-only]" >&2; exit 2 ;;
esac

esp32="$(cd "$(dirname "$0")/.." && pwd)"
root="$(cd "$esp32/../../.." && pwd)"
build="$esp32/build-badge"
out="$build/out"

cd "$esp32"
# set-target starts from a fresh sdkconfig, so the result depends only on
# sdkconfig.defaults + badge/sdkconfig.badge.
idf.py -B "$build" \
    -DSDKCONFIG="$build/sdkconfig" \
    -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;badge/sdkconfig.badge" \
    -DEXTRA_COMPONENT_DIRS="$esp32/badge/components" \
    -DATOMVM_ELIXIR_SUPPORT=on \
    -DAVM_USE_LIBSODIUM=ON \
    -DATOMIC_POINTER_LOCK_FREE_IS_TWO=ON \
    set-target esp32s3
# Configure a second time: CMakeLists.txt declares AVM_CREATE_STACKTRACES and
# AVM_PRINT_PROCESS_CRASH_DUMPS (both ON) after project() has already
# configured libAtomVM, so a fresh build directory only gets them on the
# second configure.
idf.py -B "$build" -DSDKCONFIG="$build/sdkconfig" reconfigure build

mkdir -p "$out"
cp "$build/atomvm-esp32.bin" "$out/atomvm-esp32s3-badge.bin"
cp "$build/bootloader/bootloader.bin" "$build/partition_table/partition-table.bin" "$out/"

if [ "$vm_only" = no ]; then
    # Use the Erlang/Elixir pinned in .tool-versions when mise is around.
    run=()
    if command -v mise >/dev/null 2>&1; then
        run=(mise exec --)
    fi
    (
        cd "$root"
        ${run[@]+"${run[@]}"} cmake -S . -B build
        ${run[@]+"${run[@]}"} cmake --build build --target elixir_esp32boot
    )
    cp "$root/build/libs/esp32boot/elixir_esp32boot.avm" "$out/boot.avm"
    size=$(($(wc -c < "$out/boot.avm")))
    max=$((0x88000))
    echo "boot.avm $size of $max bytes"
    [ "$size" -le "$max" ] || { echo "boot.avm does not fit its partition" >&2; exit 1; }
fi

ls -l "$out"

# Badge build overlay

Everything the badge build needs beyond upstream AtomVM lives in this
directory. The overlay adds nothing to the upstream esp32 build (`idf.py build`
in `src/platforms/esp32`) except the patches listed below, and does not compile
anything from here. Both builds share `managed_components/` and
`dependencies.lock` in that project directory.

| File | What it does |
| --- | --- |
| `build.sh` | Builds the VM image and `boot.avm` into `../build-badge/out/` |
| `sdkconfig.badge` | sdkconfig options layered over `sdkconfig.defaults` (comments say why each is there) |
| `partitions.csv` | Badge partition table |
| `components/atomgl` | Display driver (git submodule, upstream atomgl `main`) |
| `components/atomvm_websocket_client` | WebSocket client (git submodule) |
| `components/atomvm_espnow` | ESP-NOW port driver (git submodule, upstream `main`). Open the `espnow` port once and keep it: `espnow:close/1` frees the driver's port data while its static pointer and ESP-NOW stay live (use-after-free on upstream AtomVM, which frees `platform_data` in `context_destroy`). |
| `components/badge` | Pulls in libsodium and compiles mbedTLS at `-O2` |

## Building

    git clone --recurse-submodules https://github.com/protolux-electronics/AtomVM.git
    cd AtomVM
    . $IDF_PATH/export.sh            # ESP-IDF v5.5.5
    src/platforms/esp32/badge/build.sh

An existing clone needs `git submodule update --init --recursive` once.
Output in `src/platforms/esp32/build-badge/out/`: `atomvm-esp32s3-badge.bin`,
`bootloader.bin`, `partition-table.bin`, `boot.avm`. `--vm-only` skips
`boot.avm`, for hosts without Erlang/Elixir (CI builds it separately).

`build.sh` passes `SDKCONFIG_DEFAULTS="sdkconfig.defaults;badge/sdkconfig.badge"`,
`EXTRA_COMPONENT_DIRS=badge/components` and these CMake flags:

- `ATOMVM_ELIXIR_SUPPORT=on`: selects the Elixir boot library
  (`elixir_esp32boot.avm`) that `idf.py flash` writes. The partition table it
  would pick is overridden by `sdkconfig.badge`.
- `AVM_USE_LIBSODIUM=ON`: Ed25519 via libsodium (for firmware signatures).
  `components/badge/idf_component.yml` makes the component manager fetch
  `espressif/libsodium`.
- `ATOMIC_POINTER_LOCK_FREE_IS_TWO=ON`: esp32s3 with PSRAM builds with
  `-mdisable-hardware-atomics` (an S32C1I/PSRAM erratum), so libAtomVM's
  lock-free probe fails to compile. IDF still supplies correct
  interrupt-safe `__atomic_*` libcalls; the probe only tests lock-freedom.

`build.sh` always starts from a fresh `sdkconfig` (`set-target`), then
configures a second time: `AVM_CREATE_STACKTRACES` and
`AVM_PRINT_PROCESS_CRASH_DUMPS` are declared after libAtomVM is configured,
so only the second configure turns them on.

To flash by hand: bootloader `0x0`, partition table `0x8000`, VM `0x10000`,
`boot.avm` `0x1F0000`, `updater.avm` `0x278000` (192K), `main.avm`
`0x2A8000` (1376K). Never erase NVS at `0x9000`. The firmware carries its
fonts and images in its own `priv/`; there is no assets partition.

`esp32init` runs the pack named by NVS `atomvm/boot_path`, or `main.avm` when
it is unset. The firmware points `boot_path` at `updater.avm` to install an
update and clears it afterwards. If the named pack cannot be opened (a badge
from before badge-v3 still pointing at `alt.avm`, for one), `esp32init` falls
back to `main.avm`.

The display needs atomgl with the ST7789 rotation-3 fix (atomgl PR #16);
without it the panel is silently black. Keep that in mind when moving the
atomgl pin.

## boot.avm

`boot.avm` is the Elixir standard library image
(`build/libs/esp32boot/elixir_esp32boot.avm` from a host build). `build.sh`
runs the host build under `mise exec`, so it uses the Erlang and Elixir
pinned in the repo's `.tool-versions` (CI reads the same file; it matches
`../firmware`'s, keep them in sync); without mise it uses whatever is on
`PATH`. By hand, at the repo root:
`cmake -B build . && cmake --build build --target elixir_esp32boot`. It must fit the 0x88000 (557056 byte)
`boot.avm` partition, and `build.sh` fails if it does not. Beams embed the
build path, so a long checkout path grows it by about 96 bytes per module.
With the pinned toolchain it is about 510 KB.

## Memory

Internal RAM is the scarce one (~300K); it stays above ~140 KB free across
Chat, Schedule and Update. The settings that keep it there are
`SPIRAM_MALLOC_ALWAYSINTERNAL=64` and `MBEDTLS_EXTERNAL_MEM_ALLOC` (see
`sdkconfig.badge` for the evidence). Leave `MBEDTLS_DYNAMIC_BUFFER` off: it
frees the peer/CA certs after the handshake, and otp_ssl's contexts free them
again in `sslcontext_dtor` (heap corruption). Watch memory with
`:erlang.system_info(:esp32_internal_free_size)` and
`:esp32_internal_largest_free_block`.

## Patches outside this directory

These are code changes no build flag can express, so they stay in the
upstream tree:

- `src/libAtomVM/otp_ssl.c`, `libs/estdlib/src/ssl.erl`: verify TLS peers
  against the ESP-IDF certificate bundle. Upstream rejects
  `{verify, verify_peer}` with `function_clause` (issue #2401); drop this once
  atomvm/AtomVM#2390 lands and the firmware passes `cacerts: :crt_bundle`.
- `components/avm_builtins/cjson_nif.c` (+ `Kconfig`, `CMakeLists.txt`):
  cJSON NIFs, on by default; turn off with `AVM_ENABLE_CJSON_NIFS=n`.
- `components/avm_sys/sys.c`: the `esp32_internal_*` `system_info` keys.
- `libs/esp32boot/esp32init.erl`: fall back to `main.avm` when the pack at
  `boot_path` cannot be opened, instead of stopping in dev mode (upstream PR
  candidate).
- `GetBootAVM.cmake`: select the boot library for any non-JIT partition
  table, not only ones with `main.avm` at `0x250000` (upstream PR candidate:
  otherwise custom layouts get "esp32boot flavor: NONE" and `idf.py flash`
  skips `boot.avm`).

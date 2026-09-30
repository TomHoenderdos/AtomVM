# Badge build overlay

Everything the badge build needs beyond upstream AtomVM lives in this
directory. The upstream esp32 build (`idf.py build` in `src/platforms/esp32`)
is untouched by it and does not compile anything from here.

| File | What it does |
| --- | --- |
| `build.sh` | Builds the VM image and `boot.avm` into `../build-badge/out/` |
| `sdkconfig.badge` | sdkconfig options layered over `sdkconfig.defaults` (comments say why each is there) |
| `partitions.csv` | Badge partition table |
| `components/atomgl` | Display driver (git submodule, upstream atomgl `main`) |
| `components/atomvm_websocket_client` | WebSocket client (git submodule) |
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

To flash by hand: bootloader at `0x0`, partition table at `0x8000`, VM at
`0x10000`, `boot.avm` at `0x1F0000`.

## boot.avm

`boot.avm` is the Elixir standard library image
(`build/libs/esp32boot/elixir_esp32boot.avm` from a host build). `build.sh`
runs the host build under `mise exec`, so it uses the Erlang and Elixir
pinned in the repo's `.tool-versions` (CI reads the same file); without mise
it uses whatever is on `PATH`. It must fit the 0x88000 (557056 byte)
`boot.avm` partition, and `build.sh` fails if it does not. Beams embed the
build path, so a long checkout path grows it by about 96 bytes per module.
With the pinned toolchain it is about 510 KB.

## Memory

Internal RAM is the scarce one (~300K). The settings that matter are
`SPIRAM_MALLOC_ALWAYSINTERNAL=64`, no `MBEDTLS_DYNAMIC_BUFFER`, and software
AES (see `sdkconfig.badge`). Without them internal RAM fell to 3 KB after a
NervesHub TLS connect (esp-aes "Failed to allocate memory", then an SPI DMA
failure and an abort); with them it stays around 140 KB. Watch it with
`:erlang.system_info(:esp32_internal_free_size)` and
`:esp32_internal_largest_free_block`.

## Patches outside this directory

These are code changes no build flag can express, so they stay in the
upstream tree:

- `src/libAtomVM/otp_ssl.c`, `libs/estdlib/src/ssl.erl`: verify TLS peers
  against the ESP-IDF certificate bundle; back off on `want_write` instead of
  spinning.
- `components/avm_builtins/cjson_nif.c` (+ `Kconfig`, `CMakeLists.txt`):
  cJSON NIFs, on by default; turn off with `AVM_ENABLE_CJSON_NIFS=n`.
- `components/avm_sys/sys.c`: the `esp32_internal_*` `system_info` keys.
- `components/avm_builtins/network_driver.c`, `libs/avm_network/src/network.erl`:
  let the application choose the wifi power save mode.
- `GetBootAVM.cmake`: select the boot library for any non-JIT partition
  table, not only ones with `main.avm` at `0x250000`.

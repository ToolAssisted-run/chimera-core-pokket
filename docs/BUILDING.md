# Building the Pokket core

This repository builds Pokket's PocketStation emulator as a sandboxed guest
(`core.wbx`) and packages it as one file, `pokket.chimeraCore`, which Chimera
loads as a Sony PocketStation. The steps below are the ones
`.github/workflows/chimera.yml` runs from a fresh clone on a public Ubuntu
runner.

Two placeholders are used throughout:

- `<chimera>` is the absolute path of a Chimera checkout
  (https://github.com/ToolAssisted-run/chimera).
- `<minibox>` is `<chimera>/extern/chimera-common-minibox`, the miniBox
  submodule of that checkout. miniBox is the sandbox host and the guest
  toolchain.

## Requirements

- Linux, on x86_64 or aarch64. CI uses `ubuntu-24.04` and `ubuntu-24.04-arm`.
  A package is built on the CPU it is for; the package that comes out runs
  on Windows, Linux and macOS of that CPU.
- git.
- For the core, the package and the core tests:

  ```
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends meson ninja-build build-essential python3 binutils-arm-none-eabi
  ```

  `binutils-arm-none-eabi` (GNU as, ld and objcopy for ARM) assembles the
  stand-in BIOS the tests boot.

  The compiler is the distribution's gcc. The guest is compiled by the same
  gcc through miniBox's musl specs file, so there is no cross compiler to
  install. Pokket is plain C99: no C++ guest toolchain, and nothing is
  downloaded.
- For the frontend tests only, Chimera built with its window. Chimera's
  `tools/ci-chimera.sh` installs what that needs (Qt 6.12) and builds it.

## Get the sources

```
git clone https://github.com/ToolAssisted-run/chimera-core-pokket.git
cd chimera-core-pokket
git submodule update --init
```

The submodule is `extern/pokket`, pinned to an unmodified upstream commit
(v1.24). Nothing in it is changed or patched.

A Chimera checkout, for miniBox:

```
git clone https://github.com/ToolAssisted-run/chimera.git <chimera>
git -C <chimera> submodule update --init extern/chimera-common-minibox
```

The frontend tests build Chimera itself and need all of its submodules
(`git -C <chimera> submodule update --init --recursive`).

No script guesses a path: pass `-m <minibox>` and `-r <chimera>` (or
`-Dminibox_dir=<minibox>`) as every command below does. `build-package.sh`
and `tests/run-frontend.sh` look at `../chimera` beside this repository when
no Chimera is given.

## Build miniBox

```
meson setup <minibox>/build/meson-linux <minibox>
meson compile -C <minibox>/build/meson-linux
```

That gives the sandbox host library (`source/host/libminiboxhost.so`, which
`run-wbx` links) and the C guest toolchain (`guest-sysroot/`).

## Build the core

```
# the native reference (run-native) and the sandbox driver (run-wbx)
meson setup build/meson-native -Dminibox_dir=<minibox>
ninja -C build/meson-native

# the guest, core.wbx
sh waterbox/setup-guest.sh -m <minibox>
ninja -C build/meson-guest core.wbx
```

Both builds compile Pokket's `core/src/*.c`, the source list of upstream's
`core/CMakeLists.txt`, with `PSEMU_TRACE_HOOKS` (upstream's hook on every bus
read, which tells the core when the machine reads its buttons), and the same
`waterbox/cinterface.c`. The native build uses `waterbox/native-shim/emulibc.h`
in place of miniBox's emulibc.

After a source change, `ninja -C build/meson-native` and
`ninja -C build/meson-guest`.

## Build the package

```
./waterbox/build-package.sh -m <minibox> -r <chimera>
```

It builds `core.wbx` if needed, runs miniBox's `check-wbx.sh` on it (and
`wbx-tp-rewrite.py` on aarch64), and writes `<chimera>/build/Cores/pokket.chimeraCore`:
`core.wbx`, `waterbox.config`, `file_slots.json`, `default_keybinds.json`,
`languages/`, `build.json` and the licence texts. The zip is deterministic: the
same commit gives the same file. A package built by hand is stamped
`<commit>+local` (or `-dirty+local`); CI sets `CORE_VERSION`.

## The tests

There is no free PocketStation BIOS and no program runs without one, so the
tests boot this repository's own stand-in BIOS, `tests/standin-bios/bios.s`,
which `tests/standin-bios/build-bios.sh` assembles into the test's work
folder each run. The memory card is upstream's homebrew
`extern/pokket/pk_timing_bench/pk_timing_bench.mcs`. `docs/PLAN.md` says what
the stand-in does and what it does not stand in for.

```
./waterbox/run-gate.sh                                        # 17 checks, 2 skipped
CHIMERA_ROOT=<chimera> ./waterbox/run-gate.sh                 # 19 checks
./waterbox/tests/run-frontend.sh --chimera-root <chimera>     # 4 checks
<chimera>/build/meson-linux/source/ui/test-packages <a folder holding only pokket.chimeraCore>
```

- `run-gate.sh`: native == sandbox, an idle run differs, turbo and a save and
  load before every frame change nothing, for the card as `.mcs` and as
  `.pss`; then the clock start, lag frames, the sound, the card kinds, save
  data out and back in (and the refusal of a wrong file), the hardware ID
  setting and the reset button. With `CHIMERA_ROOT` (and the package built
  into it) two more through `chimera-run`: a project of the card, the BIOS
  and a clock start, and the reads of the buttons reaching Chimera.
- `run-frontend.sh`: Chimera's window, headless, opens projects of the card
  with the stand-in BIOS as firmware: RAM equals the native reference's; the
  hardware ID and the clock start reach the machine; the package's keybinds
  are the window's. Run it with no display (`env -u DISPLAY
  QT_QPA_PLATFORM=offscreen`). Its work folder is `waterbox/tests/work/`.
- The contract tests need no content.

Each script ends with "<n> ok, 0 failed". A SKIP is not a pass.

## Content

Never commit a BIOS, a game or a card that is not free. A user's own files for
trying the core by hand go in `tests/roms-local/` (gitignored). The
PocketStation BIOS the user brings is 16384 bytes; Chimera asks for it as
`pocketstation.bin`.

## Troubleshooting

- "missing .../pk_timing_bench.mcs": the submodule is not checked out
  (`git submodule update --init`).
- "miniBox guest toolchain missing": build `<minibox>/build/meson-linux`
  first.
- A stale guest after a flag change: delete `build/meson-guest` and run
  `setup-guest.sh` again.

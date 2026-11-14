# AGENTS.md - Pokket core for Chimera

This repository builds Pokket (a Sony PocketStation emulator) as a sandboxed
guest for Chimera, a frontend for tool-assisted speedruns. It produces one
file, `pokket.chimeraCore`: a zip holding `core.wbx` (the emulator built for
the miniBox sandbox), `waterbox.config`, `file_slots.json`,
`default_keybinds.json`, `languages/`, `build.json` and the licence texts.
`docs/BUILDING.md` has the detailed build; this file is the short operating
guide.

## Layout

- `extern/pokket/` - upstream, a git submodule pinned to unmodified upstream
  (v1.24). Only `core/` (MIT) is built. There are no patches.
- `meson.build`, `meson_options.txt` - one build description, two flavors:
  native (`run-native`, `run-wbx`) and guest (`core.wbx`).
- `waterbox/cinterface.c` - the adapter: Pokket behind Chimera's guest ABI.
  Compiled unchanged into both flavors.
- `waterbox/native-shim/emulibc.h` - replaces miniBox's emulibc in the native
  build, and gives it the clock start the sandbox would.
- `waterbox/run-native.c`, `waterbox/run-wbx.c`, `waterbox/gate-harness.h` -
  the reference driver, the sandbox driver, and the run-and-digest loop they
  share.
- `waterbox/waterbox.config`, `file_slots.json`, `default_keybinds.json`,
  `package-licenses.json`, `languages/*.json` - what Chimera is told.
- `waterbox/setup-guest.sh`, `waterbox/build-package.sh` - the build scripts.
- `waterbox/run-gate.sh` - the core tests. `waterbox/tests/run-frontend.sh`
  and its helpers - the frontend tests.
- `tests/standin-bios/bios.s`, `build-bios.sh` - the free stand-in BIOS the
  tests boot: ARM assembly, assembled at test time with GNU binutils for ARM
  (`binutils-arm-none-eabi`).
- `docs/PLAN.md` - the design log. `docs/BUILDING.md` - the build.
- `.github/workflows/chimera.yml` - CI and publishing.
- `build/` - every output (gitignored).

## Commands, in order

```
git submodule update --init
MB=<chimera>/extern/chimera-common-minibox
meson setup "$MB/build/meson-linux" "$MB" && meson compile -C "$MB/build/meson-linux"
meson setup build/meson-native -Dminibox_dir="$MB" && ninja -C build/meson-native
./waterbox/build-package.sh -m "$MB" -r <chimera>        # also builds core.wbx
./waterbox/run-gate.sh                                     # 17 ok, 0 failed (2 SKIP)
CHIMERA_ROOT=<chimera> ./waterbox/run-gate.sh              # 19 ok, 0 failed
env -u DISPLAY QT_QPA_PLATFORM=offscreen ./waterbox/tests/run-frontend.sh --chimera-root <chimera>   # 4 ok
<chimera>/build/meson-linux/source/ui/test-packages <folder holding only pokket.chimeraCore>
```

Rebuild both flavors before testing (`ninja -C build/meson-native && ninja -C
build/meson-guest`): the tests build nothing and compare what is there.

## Rules of this repository

- Upstream is unmodified. A change upstream is needed only through a
  numbered patch in `patches/` applied by a script, and today there is none.
  Everything the core needs is in `core/include/psemu/psemu.h` and
  `core/src/psemu_internal.h`.
- Determinism is the product. The guest reads no host time (the clock comes
  from the project's clock start, at `Init` only), no randomness, nothing
  that differs between runs, and a savestate must round-trip.
- A new check is broken on purpose once and seen to fail; say so in the
  commit (docs/PLAN.md lists the ones done).
- Never commit a BIOS, a game or a card that is not free. `tests/roms-local/`
  is gitignored for local files. The PocketStation BIOS is Sony's.
- Every text a person reads is a key of `waterbox/languages/*.json`, in all
  26 languages, in the same commit.
- Do not write `version` or `versionDate` into `waterbox.config`:
  `build-package.sh` stamps them.
- Documentation is plain ASCII and plain language.
- Commits: `type(scope): what changed`, a short body with what was tested and
  the numbers, then the trailers. Stage explicit paths.

# chimera-core-pokket

[Pokket](https://github.com/mentalfoundry/Pokket) as a
[Chimera](https://github.com/ToolAssisted-run/chimera) core: the Sony
PocketStation, in miniBox's sandbox, packaged as `pokket.chimeraCore`.

The PocketStation is a PlayStation memory card with a 32 by 32 pixel screen,
five buttons, a speaker, a clock and an ARM processor. Pokket is a
cycle-accurate emulator of it in portable C. This repository builds Pokket's
emulation core, unchanged, behind Chimera's interface.

## What it is

- **One memory card a project**: a whole card (`.mcd`, `.mcr`, `.mc`, `.mem`,
  or a `.bin` of 128 KB), a DexDrive dump (`.gme`), one save (`.mcs`) or one
  app (`.pss`). Pokket works out which from the contents.
- **The controls**: Up, Right, Down, Left, Action, and Reset (the button
  behind the case).
- **The clock** starts at the project's clock start and runs on the
  machine's own time, so a movie replays the same.
- **Save data**: the card is the machine's memory. Emulator > Export Save
  Data... writes it as `card.mcd` (128 KB, the layout memory card tools
  open); the project's save data slot takes that file back.
- **Settings**: the unit's hardware ID (serial number), which some games
  read.
- **Memory**: RAM, Flash (the card), VRAM (the screen) and BIOS; the CPU's
  registers.

## What you bring

The PocketStation BIOS, 16 KB, dumped from a real unit. Chimera asks for it
as `pocketstation.bin`. Nothing runs without it: even a single app is started
by the BIOS's own menu. No BIOS or game is included.

## Using it in Chimera

Chimera ships no cores and downloads none. Download the package from this
repository's Releases page, or build it, and put it in the `cores` folder
beside Chimera's program. Tools > Core Manager... lists the cores there.

## Building and testing

`docs/BUILDING.md` has every step, from a fresh clone to the tests. In short,
with `<chimera>` a Chimera checkout and `<minibox>` its
`extern/chimera-common-minibox`:

```
git submodule update --init
meson setup build/meson-native -Dminibox_dir=<minibox> && ninja -C build/meson-native
./waterbox/build-package.sh -m <minibox> -r <chimera>
./waterbox/run-gate.sh
./waterbox/tests/run-frontend.sh --chimera-root <chimera>
```

The tests boot a free stand-in BIOS this repository builds from source,
because Sony's may not be distributed. An AI coding agent should start with
[AGENTS.md](AGENTS.md). The design log is [docs/PLAN.md](docs/PLAN.md).

## Licence

This repository is MIT. Pokket's emulation core is MIT (Darien Liu,
mentalfoundry); the rest of Pokket's repository, which is not built here, is
GPL-3.0. See [LICENSE](LICENSE).

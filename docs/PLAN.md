# Pokket as a Chimera core: plan and log

The Sony PocketStation (SCPH-4000), a memory card for the PlayStation with a
32 by 32 pixel screen, five buttons, a speaker, a clock and an ARM7TDMI
processor. This core is Pokket (https://github.com/mentalfoundry/Pokket), a
PocketStation emulator in portable C, built for miniBox's sandbox and
packaged for Chimera as `pokket.chimeraCore`. Requested in
ToolAssisted-run/chimera#575; the owner approved building it on 2026-11-14.

## 2026-11-14: feasibility (docs/new-core.md, section 1)

Read from upstream's source at the version this core builds, v1.24
(4bf542953909c4efee926b9a344831f331b7de45, 2026-11-05, the head of `main`
on 2026-11-14).

- **Is it a new core at all?** Yes. No core here emulates a PocketStation.
  The PlayStation cores (DuckStation, Mednafen) treat a memory card as
  storage and do not run its processor.
- **May it be distributed, modified?** Yes. Upstream has two licences, by
  folder, and says so in its README and in each file's
  `SPDX-License-Identifier`: `core/` (the emulator) and `tests/` are MIT;
  everything else (the frontends, the tools, `pk_timing_bench`) is GPL-3.0.
  This core compiles `core/` and nothing else, and every one of its 31
  files says MIT at the version built. The package is therefore this
  repository's MIT code and upstream's MIT code. Both allow a modified binary
  to be passed on, with the copyright notices.
- **Compiled-in firmware?** None. The emulator holds no BIOS, boot ROM or
  font: the only table that names a BIOS is `known_bios_hashes` in
  `core/src/psemu.c`, one 32-bit FNV-1a hash of the retail J110 BIOS (it
  decides whether two BIOS-owned RAM bytes may be written; nothing of the
  BIOS is in it). The other constant tables are month lengths and interrupt
  lines. `psemu_save_state` leaves the BIOS out of a state on purpose.
- **What must the user bring?** The PocketStation BIOS, 16 KiB, Sony's.
  Upstream says there is no way past it: even a single app (`.pss`,
  `.mcs`) is started by the real BIOS's menu. It is declared as firmware,
  `pocketstation.bin` (upstream's libretro core's name for it), and never
  committed. No SHA-1 is pinned: no dump was available here to hash, and a
  pin would also refuse the free stand-in BIOS below. The core checks the
  size.
- **One thread on one clock?** Yes, already. Upstream has no threads and
  reads no host clock (`grep` for `time(`, `clock`, `pthread`: none in
  `core/`). Its machine time is a 64-bit count of units of
  `PSEMU_TIME_HZ`, exact, and `psemu_run(ps, 33000)` runs one 32 Hz frame of
  reference cycles with nothing rounded between calls. Its idle-loop skip is
  documented to give the same machine bit for bit.
- **The clock.** The machine has a real-time clock that upstream starts at
  its power-on value, 1998-01-01 00:00:00. The core sets it from the
  project's clock start at power-on: Chimera tells miniBox when the
  machine's clock starts (`clockStart`, user-decided 2026-10-24), the guest
  reads that second with `clock_gettime` in `Init`, and hands it to
  `psemu_set_datetime` in UTC. The clock then runs on the machine's own
  time. No setting of this core's own is needed.
- **Where does the picture come from?** The machine's own framebuffer:
  `psemu_get_framebuffer` gives 32 by 32 pixels at one bit each, with the
  display switch and the 180 degree rotation applied. No GPU.
- **Does it recompile?** No. An interpreter.
- **Sound.** A 10-bit DAC that software writes directly; upstream resamples
  it to 8000 Hz mono. 250 samples a frame, exactly.
- **How big is it?** Tiny: 2 KiB of RAM, 16 KiB of BIOS, 128 KiB of flash
  (the memory card). The whole machine (`psemu_t`) is about 355 KiB.
- **What can a test run on a public runner?** No PocketStation program runs
  without the BIOS, and Sony's may not be distributed. So the tests use a
  free stand-in BIOS of this repository's own (below), built from source by
  the tests. As content, upstream's own homebrew `pk_timing_bench.mcs`
  (GPL-3.0, in the submodule) is loaded as a card: the stand-in BIOS does
  not start apps, but it reads the card, so the card's path through the
  core is tested.

Nothing blocks the core.

## The free stand-in BIOS (planned 2026-11-14, before it was written)

A 16 KiB ARM program in place of Sony's BIOS, for the tests. It is not a
replacement BIOS: it implements no kernel calls and starts no apps. It
exercises every part of the machine the core passes through:

- **The picture.** It writes all 32 rows of the screen every pass of its
  main loop. Rows 0 and 1 are the clock's time and date registers as raw
  bits (so the clock start is visible in the picture), row 2 a count of
  timer interrupts, row 3 the buttons held, rows 4 and 5 two words of the
  card (its first word, and a word it writes itself near the end), row 6 a
  count of clock interrupts, and rows 8 to 31 a dot the direction buttons
  move. (As built: row 7 is the tick count times three, worked out by a
  Thumb routine, the dot has rows 8 to 30, and row 31 is the unit's serial
  number, so the hardware ID setting is visible too.)
- **The buttons.** It reads the interrupt controller's status register,
  where the five buttons are, once a pass. (As built: only while its count
  of clock interrupts is even, so about half the frames are frames that did
  not read the controls, and a test can see lag counted.)
- **The sound.** Timer 1 interrupts at about 1 kHz; while Action is held
  the handler flips the DAC between two levels, a square wave.
- **The clock.** The clock's interrupt is enabled and counted, so the
  clock's ticks are machine state a test can see.
- **The card.** Holding Left and Action together writes the timer count
  into the card's last word, so a test can see the card the game changed
  come out of Export Save Data and go back in through the save data slot.

**How it is built.** The plan was to assemble it with GNU binutils for ARM
(`binutils-arm-none-eabi`). Neither the build container nor the build
machine has an ARM assembler (no `arm-none-eabi-as`, no `clang`, no
`llvm-mc`, checked 2026-11-14). It is therefore written as a Python script,
`tests/standin-bios/make-bios.py`, that assembles a listing of ARM
instructions into the 16 KiB file, the same way chimera-core-gpgx's
`tests/make-pico.py` writes its 68000 test cartridge. Python is already
needed by every build here; the script needs nothing else, and the same
source gives the same file byte for byte. If the owner prefers real
assembly, `binutils-arm-none-eabi` is the package to install, and the
listing translates line for line.

**What it does not stand in for** (docs/gates.md, E). Sony's BIOS: its boot
animation, its menus, its date screen, its app dispatch, its kernel calls,
its sleep. No app has been run by this core, because no app runs without
Sony's BIOS. With the stand-in, the CPU runs ARM code and one small Thumb
routine, never uses FIQ, never stops its clock, never changes CLK_MODE after
boot, and never talks to a PlayStation or over infra-red. Those parts of upstream are proved by upstream's own tests, not
by this core's.

## Decisions

- **Upstream unchanged, no patches.** Everything the core needs is in
  upstream's public interface (`core/include/psemu/psemu.h`) and its
  machine structure (`core/src/psemu_internal.h`, for the VRAM and BIOS
  domains, the registers, and the clock kept across a reset). Lag frames
  need to know when the machine reads its buttons, and upstream already has
  a hook for every bus read, compiled in with `PSEMU_TRACE_HOOKS` (its
  `psemu_trace` library): the core is built with it, and the hook marks a
  frame as one that read its controls when the CPU reads the first byte of
  the interrupt controller's hold or status register, where the buttons are.
  Upstream measured the hook at about 20% slower; for a 4 MHz machine that
  costs nothing that matters.
- **What a frame is.** One 32nd of a second: 33000 reference cycles, as
  upstream's libretro core does. Vsync 32/1.
- **The controls.** Up, Right, Down, Left and Action, the five buttons; and
  Reset, the reset button behind the case, which resets the machine
  (`psemu_reset`) and leaves the card and the clock as they were.
- **The content.** One file, the card: a whole memory card (`.mcd`, `.mcr`,
  `.mc`, `.mem`, `.bin`, exactly 128 KiB), a DexDrive dump (`.gme`), one save
  (`.mcs`) or one app (`.pss`). Upstream decides which by its contents
  (`psemu_load_content`), never by the name.
- **Save data.** The card the machine writes to is the machine's own memory
  (flash), so a savestate already carries it. Export Save Data writes the
  whole card as `card.mcd`, 128 KiB, the raw layout PlayStation memory card
  tools open. The `savedata` slot takes that file back: the machine then
  starts with that card in place of the one the project's file made. A file
  of another name or size is refused.
- **Settings.** `hardwareId`: the unit's serial number, eight hex digits,
  upstream's default `410000D3`. A game reads it (upstream's notes: one
  game's companion app takes a rank from it), so it is part of the machine.
- **Memory.** Domains RAM (2 KiB), Flash (the card, 128 KiB), VRAM (the
  screen, 128 bytes) and BIOS (16 KiB, read-only). The CPU's registers are
  exported for the debugger (R0 to R15 and CPSR, as the current mode sees
  them).

## 2026-11-14: the core, its package and its tests (M1)

Built against Chimera main a0b446f8 and its miniBox, in the `chimera-dev`
container (Ubuntu 24.04, GCC 13.3, meson 1.3.2) on jaffanator01.

What was done:

- `meson.build` compiles upstream's 16 `core/src/*.c` files (its own
  `PSEMU_SOURCES`) and `waterbox/cinterface.c`, natively (`run-native`) and
  for the guest (`core.wbx`, 123 KB, `check-wbx.sh` clean). No patch.
- The adapter: `Init` reads the BIOS (`pocketstation.bin`), the card slot's
  file (`psemu_load_content`), the save data slot (`card.mcd` only), the
  hardware ID setting, resets the machine and then sets the clock from
  `clock_gettime`. A frame is `psemu_run(ps, 33000)`; the picture is the
  32 by 32 framebuffer as black on white; the sound 250 samples at 8000 Hz.
  A CPU fault (an opcode Pokket does not know) stops the machine and prints
  upstream's crash report once.
- The reset button keeps the clock: `psemu_reset` puts the clock back to its
  power-on value (1998-01-01), so the adapter keeps the clock's registers
  across it. On a real unit the clock has its own oscillator and battery.
- Exports beyond the required: the input-poll callback, turbo
  (`SetRenderingEnabled`, which skips only the conversion of the picture),
  memory domains, registers with their roles, and the save data group.

Measured:

- `waterbox/run-gate.sh`: 17 ok, 0 failed, 2 skipped (the chimera-run
  checks, which need `CHIMERA_ROOT`); with `CHIMERA_ROOT` 19 ok, 0 failed.
  For the card as `.mcs` (640 frames) and as `.pss` (320 frames) under a
  pattern on every button: native == sandbox on the picture, the sound, lag
  and all four memory domains; an idle run differs; a save and a load before
  every frame change nothing; turbo over the first half changes nothing
  else. Then: the clock start (2026-11-14 12:34:56 reads 12:35:05 at frame
  320, natively, in the sandbox and with a save and load before every frame;
  the sandbox's own start, 2017-05-27 12:44:28, reads 12:44:37); lag (319 of
  640 frames, the program reading its buttons in 10 of the 20 seconds);
  sound (250 samples a frame; Action held: 31979 of 32000 samples not
  silent, nothing held: 0); the card kinds (`.mcs`, `.pss` and a 128 KiB
  card give the same flash); save data (the card written by the program,
  exported as `card.mcd`, native == sandbox, taken back through the slot;
  another name and another size refused); the hardware ID (0x410000D3 by
  default, 0x1234ABCD set, `A0237468Z` refused); Reset (the program starts
  again, the clock goes on). Through chimera-run: a project of the card,
  the BIOS and a clock start, made with `--new-project` and played by
  another process, gives the native reference's VRAM; 4996 reads of the
  buttons reach Chimera in 320 frames (159 lag frames), and counting them
  moves nothing.
- `waterbox/tests/run-frontend.sh` (Chimera's window, headless, offscreen
  Qt): 4 ok, 0 failed. RAM after 320 frames equals the native reference's;
  the hardware ID and the project's clock start reach the machine; the 6
  bindings of the package are the window's.
- Chimera's contract tests on a folder holding only this package: 24 PASS,
  0 failed. `tools/check-core-texts.py`: 17 keys, every one named.

Seen to fail (each on a copy with one line of `cinterface.c` broken, then
put back): the clock not set (`clock-start` and `reset` fail, the frontend's
`clock-start` fails: the date reads 98-01-01); the bus-read hook not set
(`lag`: 640 of 640); the clock not kept across a reset (`reset`); the save
data name not checked (`savedata:refused`); the hardware ID not applied
(`settings:hardwareId`, in both scripts); turbo a no-op (`turbo`, "drew
every frame"); no save data exported (`savedata:export` and
`savedata:import`). Not seen to fail: the save and load before every frame
(`savestate`). It fails only on machine state kept outside the sandbox's
memory, and this core keeps none; no honest break of it was found.

Not done or not proved:

- **No real PocketStation software has run.** Sony's BIOS was not on the
  build machine (the owner's files were still being copied; no file under
  `/home/jaffar/roms` or `/home/jaffar/firmware` is a PocketStation BIOS,
  card, `.mcs` or `.pss`), and without it no app starts. Nothing of the
  BIOS's menus, date screen, app dispatch, kernel calls, sleep, FIQ, Thumb
  apps or CLK_MODE changes has been through this core. A first test with
  the real BIOS is to boot `pk_timing_bench.mcs` and follow upstream's
  README (Down, Action, Right, Action) to start it.
- **The clock with the real BIOS.** The core sets the clock's registers
  before the first frame. How the real BIOS treats a clock that is already
  set at a cold boot (it shows its date screen; upstream's notes say it may
  reset the clock to 1999-01-01) is not known here. Upstream's own desktop
  app writes the date every frame while the BIOS's menus run; this core
  does not, because that would change the machine between frames. Upstream
  also notes that the century the BIOS's clock screen shows is a RAM byte
  the BIOS writes once at boot.
- **No SHA-1 is pinned for the BIOS.** None was available to hash, and a
  pin would refuse the stand-in. The core checks only the size (16384).
- **CI has not run**: nothing is pushed. The workflow is written from
  chimera-core-stella's, with the x86_64 and aarch64 runners and a miniBox
  cache key that carries `meson --version`. aarch64 has not been built
  anywhere.
- **Windows and macOS** have not run the package.

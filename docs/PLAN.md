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
  size. (Superseded 2026-11-15: the retail dump is pinned, and the pin does
  not stop the stand-in; see the last section.)
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

**How it is built** (superseded below, 2026-11-14: it is ARM assembly now).
The plan was to assemble it with GNU binutils for ARM
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

- **No real PocketStation software has run.** (Superseded 2026-11-15: see
  the last section.) Sony's BIOS was not on the
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
  (Superseded 2026-11-15: pinned.)
- **CI has not run**: nothing is pushed. The workflow is written from
  chimera-core-stella's, with the x86_64 and aarch64 runners and a miniBox
  cache key that carries `meson --version`. aarch64 has not been built
  anywhere.
- **Windows and macOS** have not run the package.

## 2026-11-14: the owner's answers to the three open questions

**The stand-in BIOS is ARM assembly (user-decided, 2026-11-14).** The owner
installed `binutils-arm-none-eabi` (GNU as 2.42) in the build container and
asked for real assembly in place of the Python encoder.
`tests/standin-bios/bios.s` is the same program, instruction for
instruction; `tests/standin-bios/build-bios.sh` assembles it at test time
(`arm-none-eabi-as -march=armv4t -mcpu=arm7tdmi`, linked at 0x04000000,
`objcopy -O binary`, padded with 0xFF to 16 KiB). `make-bios.py` is gone.
CI installs the package in both jobs.

The bytes changed: SHA-1 39324be3... (Python) became 788556ae... (GNU as),
116 bytes apart. GNU as writes `ldr rN, =constant` as a `mov` when the
constant fits an ARM immediate (0x700, 0x7F0, 0x0B000000, 0x400,
0x0A000000, 0x08000000), where the Python encoder always used a literal, so
the literal pool is shorter and moves. The disassembly is otherwise the same.
Measured with it: `run-gate.sh` with `CHIMERA_ROOT` 19 ok, 0 failed;
`run-frontend.sh` 4 ok; `test-packages` 0 failed. Native == sandbox ==
rerecord as before. Two numbers moved by the few cycles the `mov`s save:
Action held gives 31981 not-silent samples of 32000 (was 31979), and
chimera-run counts 4995 button reads with 160 lag frames in 320 frames (was
4996 and 159). Every other figure is the same.

**The BIOS's SHA-1 is pinned once a good dump is checked (user-decided,
2026-11-14).** Not yet: `/home/jaffar/firmware` did not exist on
jaffanator01 on 2026-11-14, and no file under `/home/jaffar/roms` is a
PocketStation BIOS. When one comes, it is hashed, compared with known good
dumps and pinned in `waterbox.config`; the tests keep handing the core the
stand-in by path (`run-wbx`/`run-native` mount the work folder's
`pocketstation.bin`; `run-frontend.sh` and the chimera-run checks pass
`--firmware pocketstation.bin=<path>`), so a pin must not refuse it there:
check that before pinning. (Done 2026-11-15: pinned, and checked; see the
last section.)

**The clock question stays open until the real BIOS boots (user-decided,
2026-11-14).** No dump was available to boot, so what the real BIOS's date
screen does with the clock the core set is still unknown. (Answered
2026-11-15: the BIOS sets the clock to 1999-01-01 itself at a cold boot.
What to do about it is put to the owner in the last section.)

## 2026-11-15: Sony's BIOS and 110 real programs (issue 575)

Run on jaffanator01 in the `chimera-dev` container, against Chimera
a0b446f8, with the owner's files: the BIOS in `/home/jaffar/firmware` and
110 programs in `/home/jaffar/roms/pocketstation`. None of them is in this
repository.

**The BIOS dump is good.** `pocketstation.bin`, 16384 bytes, SHA-1
`b29a77bd9f91ce72582015ee6f6b6a740f1cc505`, CRC32 `5b91d3e4`, MD5
`0e4712cdf113190a012c5fb415060ec7`. It is the main PocketStation entry of
the retrobios collection's `database.json` (the other entry, SHA-1
`6ae88049...`, is the J061 prototype, 60 bytes apart). Its version tags
read `C110` at 0x1DFC and `J110` at 0x3FFC: the retail revision. Its
FNV-1a hash (the one upstream's `known_bios_hashes` uses) is `0xDDF1F248`,
not the `0xB2E46838` upstream lists for J110. So upstream's
`psemu_settings_offsets_known` says no for this dump. Nothing in this core
calls it, so nothing changes; why upstream's hash differs is not known here.

**The BIOS's SHA-1 is pinned** in `waterbox.config` (the owner's decision of
2026-11-14). The plan feared a pin would refuse the free stand-in BIOS the
tests use. It does not, and no setting or second declaration is needed:

- `run-native` and `run-wbx` mount the work folder's file directly; no hash
  is asked.
- `chimera-run --new-project --firmware` pins the hash of the file it is
  given, and a project then looks for that hash. The two chimera-run checks
  pass with the stand-in.
- The window's tests choose the stand-in by path, as a person does with
  Select File for a project already made, and open projects pinned to its
  hash. `run-frontend.sh` passes: 4 ok.
- Chimera's engine calls a file of the right size and another hash
  "unrecognised, used anyway" (`ce_firmware_state`), never refused.

What a person sees: the window's firmware list marks Sony's retail dump as
good and any other 16 KiB file as one it does not know. The New Project
window's firmware page asks for the pinned dump. Other cores keep a free
firmware set beside a pinned one with a setting (geartowns' `freeTownsRoms`
picks between two pinned sets); that adds a setting a person sees, and this
core does not need it, because its free BIOS is only for the tests.
`nameHints` is gone from the entry: Chimera reads hints only for an entry
with no SHA-1.

**How a program is started.** As on a real unit, and as upstream's README
says: the BIOS shows HELLO and a heart (frames 0 to about 330), then its
date screen. Down, then Action, leave it for the clock; Right moves to the
first app on the card; Action starts it. The sweep below pressed Down at
frame 400, Action at 440, Right at 480 and Action at 520, two frames each.
A project holds the card, and the movie holds these presses.

**Fixed: a frame ran a little long.** The real BIOS and its apps slow the
CPU's clock (`CLK_MODE`). One instruction is then longer than one of the
reference cycles a frame is counted in, and `psemu_run` stops after the
instruction that crosses the end of the frame. The extra time was never
taken back: 1600 frames of Chocobo World gave 400041 sound samples, not
400000, so frames were about 0.01% longer than a 32nd of a second, and the
machine's clock and sound drifted from the frame count. The adapter now
carries each frame's overrun into the next one, which runs that much less
(`g_overrun` in `cinterface.c`, kept in the savestate like every other
variable of the guest). 1600 frames now give exactly 400000 samples, for
every program measured. The stand-in BIOS never slows the clock, so its
numbers did not move.

**The clock start does not reach the real BIOS (a question for the owner).**
The core sets the machine's clock to the project's clock start before the
first frame. At a cold boot the real BIOS sets the clock to 1999-01-01
00:00:00 itself and shows its date screen, so a project of 2026 and one of
2000 give the same picture, byte for byte, at frame 420 (the
`real-bios:date-screen` check). Upstream's notes say the same: in Pokket
every boot is a cold boot after a new battery, because `BATT_CTRL` reads 0,
and whether a real unit with a good battery keeps its clock is not known. A
person sets the date with the buttons in the date screen, which a movie
records, so nothing is lost for determinism. Three ways forward, none chosen
here: leave it (every project starts on 1999-01-01, as a unit with a new
battery); set the project's clock again at a fixed point after the BIOS has
reset it (deterministic, but it writes the BIOS's RAM, and upstream's guard
for that, `psemu_settings_offsets_known`, says no for this dump); or patch
upstream to read a good battery (unknown hardware behaviour). The stand-in
BIOS still shows the clock start, and the `clock-start` checks still pass.

**Lag frames mean little with the real BIOS.** The five buttons share the
interrupt controller's status register with every other interrupt, and the
BIOS's interrupt handler reads that register on every timer and clock
interrupt. So almost every frame "reads the controls": 14 lag frames of
1000 in nearly every program (for Aliens, 11 of them in the boot animation,
between frames 100 and 330). A program
that stops its clock to sleep (Calculator, Phone Book, Hit & Blow, World
Time, EnPKclock) shows more, 155 to 411. Telling a read of the buttons from
a read for another interrupt would need to know which bits the program
looks at; that is not done.

**The programs.** Each of the 110 files was given as the project's card,
run for 1000 frames natively with the presses above, and again with 24 more
presses from frame 600 (every button, three frames each, twelve frames
apart). The pictures of frames 300, 560 and 999 were looked at as text, and
frame 999 of the two runs compared.

- 106 loaded; 4 were refused with the core's "not a card" message:
  `BreakThru (Jason)`, `PacClone (Jason)`, `Sample (SN Systems)` and
  `Sporting Clays (Charles Doty)`. They are bare ARM programs (they start
  `SN`, then code) with no PlayStation file header and no `MCX0` title, so
  neither upstream nor the real BIOS can place them in the card's directory.
- No program stopped the CPU (no instruction Pokket does not know).
- 105 reached their own screen. `Rockman 3 - Part 1` is not an app: its one
  file is game data (`CRD0`, not `MCX0`), so the BIOS lists it and does not
  start it, as a real unit would; `Rockman 3 - Part 2` is the app, and runs.
- In 93 the presses changed frame 999. In R4 the presses left the app for
  the BIOS's clock, which the app allows. In 12 more the program ran and its
  picture was right, but these presses changed nothing by frame 999:
  `Ana-Digi Clock` (both), `Beat Timer`, `Denki`, `EnPKclock`, `Hata`,
  `Integral`, `Line Art`, `Mimique`, `Number`, `Poketro`, `Wose`. They are
  clocks, timers and screens of text; their controls were not worked out.
- `Dice` is a short DexDrive file (102208 bytes, twelve blocks); upstream
  takes it and it runs.
- `Apple`, `Lo` and `Tetris` by SN Systems are bare apps (`.bin`, 8192 bytes,
  with the `MCX0` title): upstream puts them on a card of their own, as a
  `.pss`, and they run.

Looked at closely, with the pictures read frame by frame: Chocobo World
(HELLO at frame 8, the heart at 160, the date screen at 352, the clock at
460, Chocobo World's icon in the menu at 500, the chocobo walking at 540 to
699); Aliens, Astro Fighter, Black Jack, Block Out 1, Dice, Calculator,
World Time (SCEI's Pocket MuuMuu programs); Brightis; Chocobo Stallion;
Rockman 2; R4; Pocket Fighter Alpha 3 part 1; MGS Integral; Harvest Moon;
Pocket Digimon World (Agumon); Pinball; homebrew 15 Puzzle, Tetris (both),
Lights Out, Mine Sweeper, Pocket Sokoban, Tic-Tac-Toe, Ana-Digi Clock,
Hata, Mimique. Text reads the right way round, nothing is mirrored, and
tiles, cards, pieces and cursors moved with the presses (15 Puzzle's tiles,
Tetris's piece, Lights Out's lights, Tic-Tac-Toe's marks, Dice's dice).

**Determinism, with the real BIOS.** For Chocobo World, Aliens, Brightis,
Tetris (homebrew and SN Systems), Rockman 2, Calculator and Dice, 1600
frames through the BIOS and into the app with 33 presses: native == sandbox
== the sandbox with a save and a load before every frame, and the sandbox
twice gives the same result. Through Chimera's own runner, as a person
uses the package: for Chocobo World, Tetris (SN Systems, a `.bin`), Aliens,
Brightis, Rockman 2 and 15 Puzzle, `chimera-run --new-project` made a
project of the card, the real BIOS and a movie of 1200 frames; played twice,
it gave the same VRAM and RAM, and the VRAM was the native reference's under
the same presses.

**New checks** (`run-gate.sh`, "with Sony's BIOS"): they run only where the
pinned dump is on hand (`POKKET_REAL_BIOS`, by default
`tests/roms-local/pocketstation.bin`), and say SKIP elsewhere, as on CI. The
card is the free `pk_timing_bench.mcs`. `real-bios:date-screen` (frame 420
is the date screen of 1999-01-01 for two clock starts), `real-bios:app`
(Down, Action, Right, Action start the bench: frame 700 is its first
screen, not the menu), `real-bios:equivalence` (1600 frames, native ==
sandbox == rerecord), `real-bios:input-shaped`, and `real-bios:frame-length`
(1600 frames give 400000 samples). Seen to fail, each on a build with one
change, then put back: the overrun not carried (`frame-length`: 400008
samples); the clock set again at frame 400 (`date-screen`); Action not
passed to the machine (`app`: frame 700 is the menu); no buttons while an
app runs (`input-shaped`). `real-bios:equivalence` was not seen to fail, for
the reason `savestate` was not (above).

`waterbox/gate-harness.h` takes `--shot <frame>:<file.tga>` (up to 64), for
the picture of any frame, and up to 128 presses.

Measured: `run-gate.sh` 17 ok, 0 failed, 3 skipped; with `CHIMERA_ROOT` and
the real BIOS 24 ok, 0 failed. `run-frontend.sh` 4 ok, 0 failed. Chimera's
contract tests on a folder holding only this package: 24 PASS, 0 failed.
`check-core-texts.py`: 17 keys, every one named.

Not proved:

- Chimera's window with the real BIOS (its tests use the stand-in); the
  package path was proved through `chimera-run`.
- The PlayStation side: docking, the PS1 game talking to its app, and
  infra-red between two units. Chimera has one machine per project.
- Long play: no program was played to an end, and no program's own save
  (written to the card while it runs) was exported and taken back with the
  real BIOS. The stand-in's `savedata` checks cover that path.
- The 12 programs whose controls these presses did not reach.
- Windows, macOS and aarch64, as before.

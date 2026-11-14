#!/bin/bash
# The core tests: for every check the sandboxed core must give byte-identical
# picture, sound, lag and memory digests to the native reference build (the
# same cinterface.c compiled for the host), and must survive a whole-machine
# savestate round trip around every frame.
#
# No PocketStation program runs without a BIOS, and Sony's may not be passed
# on. Every check therefore boots this repository's own free stand-in BIOS
# (tests/standin-bios/make-bios.py, built here from source), with upstream's
# homebrew pk_timing_bench.mcs as the memory card. docs/PLAN.md says what the
# stand-in does not stand in for.
#
# Usage: ./run-gate.sh [-n <native build dir>] [-g <guest build dir>]
# CHIMERA_ROOT=<a Chimera checkout with this package installed> adds the
# checks through Chimera's own runner (chimera-run).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
nat="$root/build/meson-native"
gst="$root/build/meson-guest"
while getopts "n:g:" opt; do
	case "$opt" in
		n) nat="$OPTARG" ;;
		g) gst="$OPTARG" ;;
		*) exit 2 ;;
	esac
done

[ -x "$nat/run-native" ] && [ -x "$nat/run-wbx" ] || {
	echo "native build missing: meson setup build/meson-native -Dminibox_dir=<miniBox> && ninja -C build/meson-native" >&2; exit 1; }
[ -f "$gst/core.wbx" ] || {
	echo "guest build missing: sh waterbox/setup-guest.sh -m <miniBox> && ninja -C build/meson-guest" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
digests() { grep -E '^(frames|vsync|videoHash|audioHash|audioSamples|audioNonZero|lagFrames|domain\[)'; }
turboDigests() { grep -E '^(frames|vsync|tailVideoHash|audioHash|audioSamples|lagFrames|domain\[)'; }
value() { sed -n "s/^$1=//p" "$2"; }

ok=0
failed=0
report() { printf "%-26s %-6s %s\n" "$1" "$2" "$3"; case "$2" in PASS) ok=$((ok+1)) ;; SKIP) ;; *) failed=$((failed+1)) ;; esac; }
printf "%-26s %-6s %s\n" "Check" "Result" "Detail"
printf "%-26s %-6s %s\n" "-----" "------" "------"

# ---- the content: the stand-in BIOS, and three forms of one card ----
bios="$work/pocketstation.bin"
python3 "$root/tests/standin-bios/make-bios.py" "$bios" || { echo "the stand-in BIOS was not built" >&2; exit 1; }
mcs="$root/extern/pokket/pk_timing_bench/pk_timing_bench.mcs"
[ -f "$mcs" ] || { echo "missing $mcs (git submodule update --init)" >&2; exit 1; }
echo "stand-in BIOS sha1 $(sha1sum "$bios" | cut -c1-40); card pk_timing_bench.mcs sha1 $(sha1sum "$mcs" | cut -c1-40)"
# the same app without its directory frame: a .pss
pss="$work/pk_timing_bench.pss"
tail -c +129 "$mcs" > "$pss"

# workdir <name> <card file> [settings JSON] [save data file]: what a project mounts
workdir() {
	local wd="$work/$1" card="$2" settings="${3:-}" save="${4:-}"
	rm -rf "$wd"
	mkdir -p "$wd"
	cp "$bios" "$wd/pocketstation.bin"
	cp "$card" "$wd/"
	if [ -n "$save" ]; then
		cp "$save" "$wd/"
		printf '{"card":["%s"],"savedata":["%s"]}' "$(basename "$card")" "$(basename "$save")" > "$wd/slots"
	else
		printf '{"card":["%s"]}' "$(basename "$card")" > "$wd/slots"
	fi
	[ -n "$settings" ] && printf '%s' "$settings" > "$wd/settings"
	echo "$wd"
}

# ---- native == sandbox == rerecord, under a pattern on every button ----
# name card frames
tests=(
	"mcs $mcs 640"
	"pss $pss 320"
)
for t in "${tests[@]}"; do
	read -r name card frames <<< "$t"
	wd="$(workdir "$name" "$card")"
	args=(--frames "$frames" --exercise)

	if ! "$nat/run-native" "$wd" "${args[@]}" 2>"$work/nat.err" | digests > "$work/nat.txt" || [ ! -s "$work/nat.txt" ]; then
		report "$name:equivalence" FAIL "native runner error: $(head -1 "$work/nat.err")"; continue
	fi
	if ! "$nat/run-wbx" "$gst/core.wbx" "$wd" "${args[@]}" 2>"$work/box.err" | digests > "$work/box.txt" || [ ! -s "$work/box.txt" ]; then
		report "$name:equivalence" FAIL "sandbox runner error: $(head -1 "$work/box.err")"; continue
	fi
	if cmp -s "$work/nat.txt" "$work/box.txt"; then
		report "$name:equivalence" PASS "$frames frames, native == sandbox ($(grep -c '^domain' "$work/box.txt") memory domains, picture, sound, lag)"
	else
		report "$name:equivalence" FAIL "$(diff "$work/nat.txt" "$work/box.txt" | tr '\n' ' ' | head -c 160)"
		continue
	fi

	# the presses must have shaped the machine: an idle run of the same length differs
	"$nat/run-wbx" "$gst/core.wbx" "$wd" --frames "$frames" 2>/dev/null | digests > "$work/idle.txt"
	if [ -s "$work/idle.txt" ] && ! cmp -s "$work/box.txt" "$work/idle.txt"; then
		report "$name:input-shaped" PASS "the presses changed the machine"
	else
		report "$name:input-shaped" FAIL "the presses changed nothing"
	fi

	# turbo: no picture for the first half, the same machine, sound and second half
	"$nat/run-wbx" "$gst/core.wbx" "$wd" "${args[@]}" 2>/dev/null > "$work/tnorm.raw"
	if "$nat/run-wbx" "$gst/core.wbx" "$wd" "${args[@]}" --turbo 2>/dev/null > "$work/tturbo.raw"; then
		turboDigests < "$work/tnorm.raw" > "$work/tnorm.txt"
		turboDigests < "$work/tturbo.raw" > "$work/turbo.txt"
		nvh="$(grep -m1 '^videoHash=' "$work/tnorm.raw")"
		tvh="$(grep -m1 '^videoHash=' "$work/tturbo.raw")"
		if [ ! -s "$work/turbo.txt" ] || ! cmp -s "$work/tnorm.txt" "$work/turbo.txt"; then
			report "$name:turbo" FAIL "$(diff "$work/tnorm.txt" "$work/turbo.txt" | tr '\n' ' ' | head -c 160)"
		elif [ "$nvh" = "$tvh" ]; then
			report "$name:turbo" FAIL "the turbo run drew every frame - nothing was skipped"
		else
			report "$name:turbo" PASS "half of $frames frames undrawn, same machine, sound and later pictures"
		fi
	else
		report "$name:turbo" FAIL "turbo runner error"
	fi

	if ! "$nat/run-wbx" "$gst/core.wbx" "$wd" "${args[@]}" --rerecord 2>/dev/null | digests > "$work/rr.txt" || [ ! -s "$work/rr.txt" ]; then
		report "$name:savestate" FAIL "rerecord runner error"; continue
	fi
	if cmp -s "$work/box.txt" "$work/rr.txt"; then
		report "$name:savestate" PASS "a save and a load before every frame change nothing"
	else
		report "$name:savestate" FAIL "$(diff "$work/box.txt" "$work/rr.txt" | tr '\n' ' ' | head -c 160)"
	fi
done

# VRAM row <n> of a dump, as a 32-bit little-endian hex word
row() { od -An -tx4 -j $(( $2 * 4 )) -N4 "$1" | tr -d ' '; }

# ---- the clock starts at the project's second ----
# 2026-11-14 12:34:56 UTC is 1794659696, a Saturday. The stand-in BIOS draws
# the clock's time register in row 0 and its date register in row 1 (BCD,
# lowest byte first). The clock steps once a second, and the picture of the
# 320th frame (10 s) is drawn just before its tenth step: 12:35:05.
start=1794659696
wd="$(workdir clock "$mcs")"
clock_ok=1
detail=""
for flavor in native sandbox rerecord; do
	case "$flavor" in
		native) "$nat/run-native" "$wd" --frames 320 --clock-start "$start" --dump-domain VRAM "$work/clock.$flavor" > /dev/null 2>&1 ;;
		sandbox) "$nat/run-wbx" "$gst/core.wbx" "$wd" --frames 320 --clock-start "$start" --dump-domain VRAM "$work/clock.$flavor" > /dev/null 2>&1 ;;
		rerecord) "$nat/run-wbx" "$gst/core.wbx" "$wd" --frames 320 --clock-start "$start" --rerecord --dump-domain VRAM "$work/clock.$flavor" > /dev/null 2>&1 ;;
	esac
	t="$(row "$work/clock.$flavor" 0 2>/dev/null)"
	d="$(row "$work/clock.$flavor" 1 2>/dev/null)"
	detail="$detail $flavor=$d/$t"
	[ "$t" = "07123505" ] && [ "$d" = "00261114" ] || clock_ok=0
done
"$nat/run-wbx" "$gst/core.wbx" "$wd" --frames 320 --dump-domain VRAM "$work/clock.default" > /dev/null 2>&1
dflt="$(row "$work/clock.default" 1 2>/dev/null)/$(row "$work/clock.default" 0 2>/dev/null)"
if [ "$clock_ok" = 1 ] && [ "$dflt" = "00170527/07124437" ]; then
	report "clock-start" PASS "2026-11-14 12:34:56 reads 26-11-14 12:35:05 (Saturday) at frame 320 in all three; the sandbox's own start, 17-05-27 12:44:28, reads 12:44:37"
else
	report "clock-start" FAIL "date/time words:$detail default=$dflt (want 00261114/07123505, default 00170527/07124437)"
fi

# ---- lag frames: the stand-in BIOS reads its buttons only in even seconds ----
lag="$(value lagFrames "$work/box.txt")"
"$nat/run-wbx" "$gst/core.wbx" "$(workdir lag "$mcs")" --frames 640 2>/dev/null | digests > "$work/lag.txt"
lag="$(value lagFrames "$work/lag.txt")"
if [ -n "$lag" ] && [ "$lag" -ge 300 ] && [ "$lag" -le 340 ]; then
	report "lag" PASS "$lag of 640 frames did not read the buttons (the program reads them in 10 of the 20 seconds)"
else
	report "lag" FAIL "lagFrames=${lag:-none} of 640 (want about 320)"
fi

# ---- the sound: Action held is a square wave, nothing held is silence ----
wd="$(workdir sound "$mcs")"
"$nat/run-wbx" "$gst/core.wbx" "$wd" --frames 128 --press 4:0:128 2>/dev/null | digests > "$work/loud.txt"
"$nat/run-wbx" "$gst/core.wbx" "$wd" --frames 128 2>/dev/null | digests > "$work/quiet.txt"
loud="$(value audioNonZero "$work/loud.txt")"
quiet="$(value audioNonZero "$work/quiet.txt")"
samples="$(value audioSamples "$work/loud.txt")"
if [ "${samples:-0}" = 32000 ] && [ "${quiet:-1}" = 0 ] && [ "${loud:-0}" -gt 10000 ]; then
	report "sound" PASS "250 samples a frame (8000 Hz); Action held: $loud of $samples samples not silent, nothing held: 0"
else
	report "sound" FAIL "samples=${samples:-?} (want 32000), not silent with Action=${loud:-?}, without=${quiet:-?} (want 0)"
fi

# ---- the card kinds: a .mcs, a .pss and a whole card make the same flash ----
"$nat/run-wbx" "$gst/core.wbx" "$(workdir kindmcs "$mcs")" --frames 1 --dump-domain Flash "$work/flash.mcs" > /dev/null 2>&1
"$nat/run-wbx" "$gst/core.wbx" "$(workdir kindpss "$pss")" --frames 1 --dump-domain Flash "$work/flash.pss" > /dev/null 2>&1
cp "$work/flash.mcs" "$work/whole.mcd" 2>/dev/null
"$nat/run-wbx" "$gst/core.wbx" "$(workdir kindmcd "$work/whole.mcd")" --frames 1 --dump-domain Flash "$work/flash.mcd" > /dev/null 2>&1
if [ "$(stat -c %s "$work/flash.mcs" 2>/dev/null)" = 131072 ] && cmp -s "$work/flash.mcs" "$work/flash.pss" \
	&& cmp -s "$work/flash.mcs" "$work/flash.mcd" && [ "$(head -c 2 "$work/flash.mcs")" = MC ]; then
	report "card-kinds" PASS "pk_timing_bench as .mcs, as .pss and as a 128 KiB card: the same flash, a card starting MC"
else
	report "card-kinds" FAIL "the three forms of the card made different flash (or none)"
fi

# ---- save data: written by the program, exported, taken back ----
# Left and Action held write the tick count into the card's last word.
wd="$(workdir save "$mcs")"
mkdir -p "$work/export.native" "$work/export.box"
"$nat/run-native" "$wd" --frames 64 --press 3:0:64 --press 4:0:64 --savedata-out "$work/export.native" > "$work/save.native.txt" 2>&1
"$nat/run-wbx" "$gst/core.wbx" "$wd" --frames 64 --press 3:0:64 --press 4:0:64 --savedata-out "$work/export.box" > "$work/save.box.txt" 2>&1
exported="$work/export.box/card.mcd"
lastword="$(od -An -tx4 -j 131068 -N4 "$exported" 2>/dev/null | tr -d ' ')"
if [ "$(value savedataFiles "$work/save.box.txt")" = 1 ] && [ "$(stat -c %s "$exported" 2>/dev/null)" = 131072 ] \
	&& cmp -s "$exported" "$work/export.native/card.mcd" && ! cmp -s "$exported" "$work/flash.mcs" \
	&& [ "$lastword" != 00000000 ] && [ "$lastword" != ffffffff ]; then
	report "savedata:export" PASS "card.mcd, 131072 bytes, native == sandbox, the card's last word written (0x$lastword)"
else
	report "savedata:export" FAIL "files=$(value savedataFiles "$work/save.box.txt") last word=${lastword:-none}, or native and sandbox differ"
fi
# the export back in through the savedata slot: the machine starts with that card
wd="$(workdir saveback "$mcs" "" "$exported")"
"$nat/run-native" "$wd" --frames 2 --dump-domain Flash "$work/back.native" > /dev/null 2>&1
"$nat/run-wbx" "$gst/core.wbx" "$wd" --frames 2 --dump-domain Flash "$work/back.box" > /dev/null 2>&1
"$nat/run-wbx" "$gst/core.wbx" "$wd" --frames 2 --dump-domain VRAM "$work/back.vram" > /dev/null 2>&1
if cmp -s "$work/back.box" "$exported" && cmp -s "$work/back.native" "$exported" && [ "$(row "$work/back.vram" 5)" = "$lastword" ]; then
	report "savedata:import" PASS "the exported card is the machine's card again; the program shows its last word 0x$lastword"
else
	report "savedata:import" FAIL "the card taken back is not the card exported (row 5 = $(row "$work/back.vram" 5 2>/dev/null))"
fi
# a file of another name, or of another size, is refused
cp "$exported" "$work/other.mcd"
"$nat/run-wbx" "$gst/core.wbx" "$(workdir savename "$mcs" "" "$work/other.mcd")" --frames 1 > /dev/null 2> "$work/savename.err"
mkdir -p "$work/short"
head -c 1000 "$exported" > "$work/short/card.mcd"
"$nat/run-wbx" "$gst/core.wbx" "$(workdir savesize "$mcs" "" "$work/short/card.mcd")" --frames 1 > /dev/null 2> "$work/savesize.err"
if grep -q 'error.save_name' "$work/savename.err" && grep -q 'error.save_size' "$work/savesize.err"; then
	report "savedata:refused" PASS "save data named other.mcd, and a card.mcd of 1000 bytes, are refused"
else
	report "savedata:refused" FAIL "a wrong save data file was taken: $(head -1 "$work/savename.err") / $(head -1 "$work/savesize.err")"
fi

# ---- the hardware ID setting reaches the machine (row 31 is F_SN) ----
"$nat/run-wbx" "$gst/core.wbx" "$(workdir iddefault "$mcs")" --frames 2 --dump-domain VRAM "$work/id.default" > /dev/null 2>&1
"$nat/run-native" "$(workdir idset "$mcs" '{"hardwareId":"1234ABCD"}')" --frames 2 --dump-domain VRAM "$work/id.native" > /dev/null 2>&1
"$nat/run-wbx" "$gst/core.wbx" "$work/idset" --frames 2 --dump-domain VRAM "$work/id.set" > /dev/null 2>&1
"$nat/run-wbx" "$gst/core.wbx" "$(workdir idbad "$mcs" '{"hardwareId":"A0237468Z"}')" --frames 1 > /dev/null 2> "$work/idbad.err"
iddef="$(row "$work/id.default" 31 2>/dev/null)"
idset="$(row "$work/id.set" 31 2>/dev/null)"
if [ "$iddef" = 410000d3 ] && [ "$idset" = 1234abcd ] && cmp -s "$work/id.set" "$work/id.native" && grep -q 'error.hardware_id' "$work/idbad.err"; then
	report "settings:hardwareId" PASS "the program reads 0x410000D3 by default and 0x1234ABCD when set; A0237468Z is refused"
else
	report "settings:hardwareId" FAIL "default=${iddef:-?} set=${idset:-?} (want 410000d3 and 1234abcd), refusal: $(head -1 "$work/idbad.err")"
fi

# ---- the reset button: the program starts again, the clock goes on ----
# Reset at frame 320 (10 s): the clock interrupt count (row 6) starts again
# from 0, and the clock goes on from where it was: at frame 384 (12 s) it
# reads 12:44:39, as it does with no reset.
wd="$(workdir reset "$mcs")"
"$nat/run-native" "$wd" --frames 384 --press 5:320:1 --dump-domain VRAM "$work/reset.native" > /dev/null 2>&1
"$nat/run-wbx" "$gst/core.wbx" "$wd" --frames 384 --press 5:320:1 --dump-domain VRAM "$work/reset.box" > /dev/null 2>&1
"$nat/run-wbx" "$gst/core.wbx" "$wd" --frames 384 --press 5:320:1 --rerecord --dump-domain VRAM "$work/reset.rr" > /dev/null 2>&1
rtcs="$(row "$work/reset.box" 6 2>/dev/null)"
rtime="$(row "$work/reset.box" 0 2>/dev/null)"
rdate="$(row "$work/reset.box" 1 2>/dev/null)"
if cmp -s "$work/reset.box" "$work/reset.native" && cmp -s "$work/reset.box" "$work/reset.rr" \
	&& [ "$rdate" = 00170527 ] && [ "$rtime" = 07124439 ] && [ "$((16#${rtcs:-ff}))" -le 2 ]; then
	report "reset" PASS "after Reset at 10 s the program counted $((16#$rtcs)) clock ticks again, and the clock reads 12:44:39 (native == sandbox == rerecord)"
else
	report "reset" FAIL "date=${rdate:-?} time=${rtime:-?} (want 00170527 07124439), clock ticks counted after the reset=${rtcs:-?}"
fi

# ------------------------------------------------- through Chimera's own runner
# Needs CHIMERA_ROOT, a Chimera checkout with this core's package installed.
runner="${CHIMERA_ROOT:-}/build/meson-linux/chimera-run"
[ -x "$runner" ] || runner="${CHIMERA_ROOT:-}/build/dll/chimera-run"
package="${CHIMERA_ROOT:-}/build/Cores/pokket.chimeraCore"
if [ -n "${CHIMERA_ROOT:-}" ] && [ -x "$runner" ] && [ -f "$package" ]; then
	files="$work/files"
	mkdir -p "$files"
	cp "$mcs" "$bios" "$files/"
	fw=(--firmware "pocketstation.bin=$files/pocketstation.bin")
	# A game runs only in a project (Chimera, 2026-10-26), and a project plays
	# its movie: one with no input records 320 idle frames, and a project of
	# those frames is the one played.
	"$runner" --new-project "$work/empty.chimeraProject" "$package" "$files/pk_timing_bench.mcs" "${fw[@]}" \
		--clock-start "$start" > "$work/empty.make.log" 2>&1
	"$runner" --project "$work/empty.chimeraProject" "$package" --files "$files" "${fw[@]}" \
		--frames 320 --record "$work/idle.txt" > "$work/empty.log" 2>&1
	# a project of the card, the firmware and a clock start, played by another process
	"$runner" --new-project "$work/clock.chimeraProject" "$package" "$files/pk_timing_bench.mcs" "$work/idle.txt" \
		"${fw[@]}" --clock-start "$start" > "$work/project.make.log" 2>&1
	"$runner" --project "$work/clock.chimeraProject" "$package" --files "$files" "${fw[@]}" \
		--dump "VRAM=$work/project.vram" --meta "$work/project.meta" > "$work/project.log" 2>&1
	if [ "$(value frames "$work/project.meta")" = 320 ] && [ "$(row "$work/project.vram" 0 2>/dev/null)" = 07123505 ] \
		&& [ "$(row "$work/project.vram" 1 2>/dev/null)" = 00261114 ] && cmp -s "$work/project.vram" "$work/clock.native"; then
		report "engine:project" PASS "a project of the card, the BIOS and a clock start plays 320 frames in chimera-run: the clock reads 26-11-14 12:35:05 and VRAM is the native reference's"
	else
		report "engine:project" FAIL "frames=$(value frames "$work/project.meta" 2>/dev/null) VRAM rows 1/0 $(row "$work/project.vram" 1 2>/dev/null)/$(row "$work/project.vram" 0 2>/dev/null); the runner said: $(tail -1 "$work/project.log" 2>/dev/null) $(tail -1 "$work/project.make.log" 2>/dev/null)"
	fi

	# each read of the buttons reaches Chimera as it happens, and counting moves nothing
	"$runner" --project "$work/clock.chimeraProject" "$package" --files "$files" "${fw[@]}" \
		--dump "RAM=$work/plain.ram" > "$work/plain.log" 2>&1
	"$runner" --project "$work/clock.chimeraProject" "$package" --files "$files" "${fw[@]}" --count-input-polls \
		--dump "RAM=$work/polls.ram" --meta "$work/polls.meta" > "$work/polls.log" 2>&1
	polls="$(value inputPolls "$work/polls.meta" 2>/dev/null)"
	lags="$(value lagFrames "$work/polls.meta" 2>/dev/null)"
	if [ "${polls:-none}" != none ] && [ "${lags:-320}" -lt 320 ] && [ "${lags:-0}" -gt 0 ] \
		&& [ "${polls:-0}" -ge $(( 320 - ${lags:-320} )) ] && [ -s "$work/plain.ram" ] && cmp -s "$work/plain.ram" "$work/polls.ram"; then
		report "engine:input-polls" PASS "$polls reads of the buttons reach Chimera in 320 frames, $lags of them lag frames; RAM is the run's without counting"
	else
		report "engine:input-polls" FAIL "inputPolls=${polls:-missing} lagFrames=${lags:-?}, or counting moved RAM; the runner said: $(tail -1 "$work/polls.log" 2>/dev/null)"
	fi
else
	report "engine:project" SKIP "needs CHIMERA_ROOT with build/meson-linux/chimera-run and build/Cores/pokket.chimeraCore"
	report "engine:input-polls" SKIP "needs CHIMERA_ROOT with build/meson-linux/chimera-run and build/Cores/pokket.chimeraCore"
fi

echo
echo "$ok ok, $failed failed"
[ "$failed" -eq 0 ]

#!/bin/bash
# The frontend half of the tests: load the Pokket package in Chimera's window,
# run headless (no display), open a project of a memory card with the free
# stand-in BIOS as its firmware, play a fixed number of frames with nothing
# pressed, and require a whole memory domain to be byte-identical to the
# native reference. Then prove that a setting (the hardware ID) and the
# project's clock start reach the machine through the window, and that the
# package's keybinds are the machine's when nobody changed them.
#
# Usage: ./run-frontend.sh [--chimera-root <path>] [--frames N]
set -u

here="$(cd "$(dirname "$0")" && pwd)"
wb="$(cd "$here/.." && pwd)"
root="$(cd "$wb/.." && pwd)"
frames=320
chimera_root=""
while [ $# -gt 0 ]; do
	case "$1" in
		--chimera-root) chimera_root="$2"; shift ;;
		--frames) frames="$2"; shift ;;
		-*) echo "unknown option: $1" >&2; exit 2 ;;
		*) break ;;
	esac
	shift
done

if [ -z "$chimera_root" ] && [ -d "$root/../chimera" ]; then
	chimera_root="$root/../chimera"
fi
[ -n "$chimera_root" ] && [ -d "$chimera_root" ] || {
	echo "chimera checkout not found; pass --chimera-root <path>" >&2; exit 1; }
chimera_root="$(cd "$chimera_root" && pwd)"

chimera_exe="$chimera_root/build/meson-linux/source/ui/chimera"
package="$chimera_root/build/Cores/pokket.chimeraCore"
rn="$root/build/meson-native/run-native"
crun="$chimera_root/build/meson-linux/chimera-run"
[ -x "$crun" ] || crun="$chimera_root/build/dll/chimera-run"
[ -x "$chimera_exe" ] || { echo "Chimera not built: $chimera_exe" >&2; exit 1; }
[ -x "$crun" ] || { echo "chimera-run not built under $chimera_root/build" >&2; exit 1; }
[ -f "$package" ] || { echo "package not installed: $package (run ../build-package.sh)" >&2; exit 1; }
[ -x "$rn" ] || { echo "native reference not built" >&2; exit 1; }

work="$here/work"
rm -rf "$work"
mkdir -p "$work"

# the content: the stand-in BIOS, built from source, and upstream's homebrew card
bios="$work/pocketstation.bin"
python3 "$root/tests/standin-bios/make-bios.py" "$bios" || { echo "the stand-in BIOS was not built" >&2; exit 1; }
card="$root/extern/pokket/pk_timing_bench/pk_timing_bench.mcs"
[ -f "$card" ] || { echo "missing $card (git submodule update --init)" >&2; exit 1; }

# Chimera's window, run headless: the cores installed in the checkout, its
# settings, cache and recovery files the run's own, and nothing carried over
# from a Chimera installed on this machine
export ALSOFT_DRIVERS=null CHIMERA_CORES_DIR="$chimera_root/build/Cores" CHIMERA_QT_CACHE="$work/qt-cache" CHIMERA_QT_RECOVERY="$work/qt-recovery" \
	CHIMERA_QT_HASHES="$work/qt-file-hashes.txt" CHIMERA_QT_CHIMERA_SETTINGS="$work/no-chimera-config.ini"

ok=0
failed=0
report() { printf "%-24s %-9s %s\n" "$1" "$2" "$3"; case "$2" in PASS) ok=$((ok+1)) ;; *) failed=$((failed+1)) ;; esac; }
printf "%-24s %-9s %s\n" "Check" "Result" "Detail"
printf "%-24s %-9s %s\n" "-----" "------" "------"

# the window's settings: empty but for the firmware, chosen as by hand
firmware_json="{\"pocketstation.bin\": \"$bios\"}"
python3 "$here/settings-config.py" "$work/settings.json" '{}' "$firmware_json"

# A game runs only in a project (Chimera, 2026-10-26): game_project <tag>
# <settings JSON> [clock start] makes one of the card and the firmware and
# prints its path.
game_project() {
	local dir="$work/project.$1" settings="$2" clock="${3:-}"
	local extra=()
	[ -n "$clock" ] && extra=(--clock-start "$clock")
	rm -rf "$dir" && mkdir -p "$dir" && cp "$card" "$dir/"
	"$crun" --new-project "$dir/$1.chimeraProject" "$package" "$dir/$(basename "$card")" \
		--firmware "pocketstation.bin=$bios" --settings "$settings" "${extra[@]}" > "$dir/make.log" 2>&1 \
		&& echo "$dir/$1.chimeraProject"
}

# run_frontend <tag> <domain> <settings JSON> [clock start]
run_frontend() {
	local tag="$1" domain="$2" settings="$3" clock="${4:-}"
	local job="$work/job.$tag.txt" project
	printf 'frames=%s\nout=%s\nmeta=%s\ndomain=%s\n' "$frames" "$work/$tag.dump.bin" "$work/$tag.meta.txt" "$domain" > "$job"
	project="$(game_project "$tag" "$settings" "$clock")" || { echo "no project made (see tests/work/project.$tag/make.log)" > "$work/$tag.log"; return 1; }
	( cd "$chimera_root" && MINIHAWK_JOB="$job" timeout -s KILL 900 "$chimera_exe" --headless \
		"--config=$work/settings.json" "--core=$package" \
		"--lua=$here/frontend-ram.lua" "--project=$project" ) > "$work/$tag.log" 2>&1
	[ -f "$work/$tag.meta.txt" ] && grep -q "^status=OK" "$work/$tag.meta.txt"
}

# native_dump <tag> <domain> <settings JSON> [clock start]: the native reference
native_dump() {
	local tag="$1" domain="$2" settings="$3" clock="${4:-1495889068}"
	local wd="$work/native.$tag"
	rm -rf "$wd" && mkdir -p "$wd"
	cp "$card" "$wd/" && cp "$bios" "$wd/pocketstation.bin"
	printf '{"card":["%s"]}' "$(basename "$card")" > "$wd/slots"
	printf '%s' "$settings" > "$wd/settings"
	"$rn" "$wd" --frames "$frames" --clock-start "$clock" --dump-domain "$domain" "$work/native.$tag.bin" \
		> "$work/native.$tag.txt" 2>&1
}

# --- the machine the window builds is the one the core tests signed off on ---
if ! native_dump base RAM '{}'; then
	report "card:frontend" FAIL "native runner error (see tests/work/native.base.txt)"
elif ! run_frontend base RAM '{}'; then
	report "card:frontend" FAIL "no OK meta (see tests/work/base.log)"
elif cmp -s "$work/native.base.bin" "$work/base.dump.bin"; then
	report "card:frontend" PASS "$frames frames, RAM identical to the native reference"
else
	report "card:frontend" FAIL "RAM differs from the native reference"
fi

# --- a setting reaches the machine through the window: the program draws F_SN in row 31 ---
set_json='{"hardwareId": "1234ABCD"}'
if ! native_dump id VRAM "$set_json"; then
	report "settings:hardwareId" FAIL "native runner error (see tests/work/native.id.txt)"
elif ! run_frontend id VRAM "$set_json"; then
	report "settings:hardwareId" FAIL "run did not report OK (see tests/work/id.log)"
elif ! cmp -s "$work/native.id.bin" "$work/id.dump.bin"; then
	report "settings:hardwareId" FAIL "VRAM differs from its native reference"
elif [ "$(od -An -tx4 -j 124 -N4 "$work/id.dump.bin" | tr -d ' ')" = 1234abcd ]; then
	report "settings:hardwareId" PASS "hardwareId 1234ABCD reaches the machine (the program reads it) and VRAM matches its native reference"
else
	report "settings:hardwareId" FAIL "the program read $(od -An -tx4 -j 124 -N4 "$work/id.dump.bin" | tr -d ' '), not 1234abcd"
fi

# --- the project's clock start reaches the machine's clock: rows 0 and 1 ---
start=1794659696   # 2026-11-14 12:34:56 UTC
if ! native_dump clock VRAM '{}' "$start"; then
	report "clock-start" FAIL "native runner error (see tests/work/native.clock.txt)"
elif ! run_frontend clock VRAM '{}' "$start"; then
	report "clock-start" FAIL "run did not report OK (see tests/work/clock.log)"
elif ! cmp -s "$work/native.clock.bin" "$work/clock.dump.bin"; then
	report "clock-start" FAIL "VRAM differs from its native reference"
elif [ "$(od -An -tx4 -j 4 -N4 "$work/clock.dump.bin" | tr -d ' ')" = 00261114 ]; then
	report "clock-start" PASS "a project starting at 2026-11-14 12:34:56 has the clock on 26-11-14, as natively"
else
	report "clock-start" FAIL "the date register reads $(od -An -tx4 -j 4 -N4 "$work/clock.dump.bin" | tr -d ' ')"
fi

# --- the bindings the package ships are the machine's when nobody changed them ---
job="$work/job.keys.txt"
printf 'out=%s/keys.controls.json\nmeta=%s/keys.meta.txt\n' "$work" "$work" > "$job"
if project="$(game_project keys '{}')" && ( cd "$chimera_root" && MINIHAWK_JOB="$job" timeout -s KILL 900 "$chimera_exe" --headless \
	"--config=$work/settings.json" "--core=$package" "--lua=$here/dump-controls.lua" "--project=$project" ) > "$work/keys.log" 2>&1 \
	&& grep -q "^status=OK" "$work/keys.meta.txt" 2>/dev/null; then
	if python3 "$here/check-keybinds.py" "$work/keys.controls.json" "$wb/default_keybinds.json" "PocketStation" > "$work/keys.txt" 2>&1; then
		report "keybinds" PASS "$(cat "$work/keys.txt")"
	else
		report "keybinds" FAIL "$(head -1 "$work/keys.txt")"
	fi
else
	report "keybinds" FAIL "run did not report OK (see tests/work/keys.log)"
fi

echo
echo "$ok ok, $failed failed"
[ "$failed" -eq 0 ]

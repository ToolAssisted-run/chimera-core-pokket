#!/bin/sh
# Assembles the free stand-in BIOS (bios.s) into the 16 KiB file the tests
# give the core as pocketstation.bin. Needs GNU binutils for ARM
# (Debian and Ubuntu: binutils-arm-none-eabi).
#
# usage: build-bios.sh <out.bin>
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
out="$1"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
command -v arm-none-eabi-as > /dev/null || {
	echo "arm-none-eabi-as not found: install binutils-arm-none-eabi" >&2; exit 1; }
# ARMv4T, the ARM7TDMI's architecture; the BIOS is mapped at 0x04000000
arm-none-eabi-as -march=armv4t -mcpu=arm7tdmi -o "$tmp/bios.o" "$here/bios.s"
arm-none-eabi-ld -Ttext=0x04000000 -e reset --no-warn-rwx-segments -o "$tmp/bios.elf" "$tmp/bios.o"
arm-none-eabi-objcopy -O binary "$tmp/bios.elf" "$tmp/bios.bin"
size="$(wc -c < "$tmp/bios.bin")"
[ "$size" -le 16384 ] || { echo "the stand-in BIOS is $size bytes, more than 16384" >&2; exit 1; }
# the rest of the 16 KiB ROM is 0xFF, as an erased ROM reads
cp "$tmp/bios.bin" "$out"
head -c $((16384 - size)) /dev/zero | tr '\0' '\377' >> "$out"

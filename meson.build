# chimera-core-pokket: Pokket (a Sony PocketStation) in miniBox's sandbox, as a
# Chimera core.
#
# Native reference build (run-native + run-wbx under the build dir):
#     meson setup build/meson-native -Dminibox_dir=<miniBox> && ninja -C build/meson-native
# Guest (core.wbx) build via the cross file waterbox/setup-guest.sh writes:
#     sh waterbox/setup-guest.sh -m <miniBox> && ninja -C build/meson-guest core.wbx
#
# THE SOURCE LIST IS UPSTREAM'S OWN: core/CMakeLists.txt's PSEMU_SOURCES, the
# emulator alone, built unchanged. Both flavors compile the SAME
# waterbox/cinterface.c; only emulibc.h differs (waterbox/native-shim for the
# reference build).
project('chimera-core-pokket', 'c',
  default_options: ['c_std=c99', 'optimization=2', 'debug=false', 'warning_level=0'])

pk = 'extern/pokket/core'

mb = get_option('minibox_dir')
if mb == ''
  error('pass -Dminibox_dir=<miniBox checkout>, the extern/chimera-common-minibox of a Chimera checkout')
endif

# PSEMU_TRACE_HOOKS: upstream's hook on every bus read, which is how this core
# learns that the machine read its buttons (lag frames, Chimera's input-poll
# callback). It is upstream's psemu_trace library; see docs/PLAN.md.
# _POSIX_C_SOURCE: clock_gettime under -std=c99.
add_project_arguments('-DPSEMU_TRACE_HOOKS', '-D_POSIX_C_SOURCE=200809L', '-fno-strict-aliasing',
  language: 'c')

inc = include_directories('waterbox', pk / 'include', pk / 'src')

core_sources = files(
  pk / 'src/arm_exec.c',
  pk / 'src/clk.c',
  pk / 'src/com.c',
  pk / 'src/cpu.c',
  pk / 'src/dac.c',
  pk / 'src/flash.c',
  pk / 'src/intc.c',
  pk / 'src/iop.c',
  pk / 'src/ir.c',
  pk / 'src/lcd.c',
  pk / 'src/memory.c',
  pk / 'src/psemu.c',
  pk / 'src/rtc.c',
  pk / 'src/state.c',
  pk / 'src/thumb_exec.c',
  pk / 'src/timer.c',
  'waterbox/cinterface.c',
)

if meson.is_cross_build()
  # ---- the guest: core.wbx --------------------------------------------------
  # miniBox's musl toolchain arrives through the cross file (setup-guest.sh);
  # the link recipe is the guest kit's - --no-relax for the large code model,
  # emulibc from the miniBox build, plain C (no unwinder, no libstdc++).
  mbdir = meson.get_external_property('minibox_dir')
  mbuild = meson.get_external_property('minibox_build')
  sr = meson.get_external_property('guest_sysroot')

  executable('core', core_sources,
    name_suffix: 'wbx',
    include_directories: inc,
    link_args: [
      '-static', '-no-pie',
      '-Wl,--eh-frame-hdr', '-Wl,-O2', '-Wl,--no-relax',
      '-T', mbdir / 'source/guest/linkscript.T',
      mbuild / 'source/guest/emulibc.c.o',
      '-L' + sr / 'lib', '-lgcc', '-lc'])
else
  # ---- the native reference -------------------------------------------------
  # the same cinterface over shimmed emulibc; the guest kit headers
  # (waterbox_settings/slots, jsmn) are plain stdio C and run as-is.
  # -ffp-contract=off: the machine has no floating point, but the rule for
  # every native reference here costs nothing.
  m = meson.get_compiler('c').find_library('m', required: false)
  executable('run-native', core_sources + files('waterbox/run-native.c'),
    include_directories: [include_directories('waterbox/native-shim'), inc],
    c_args: ['-I' + mb / 'source/guest/include', '-I' + mb / 'extern/jsmn', '-ffp-contract=off'],
    dependencies: [m])

  mbhost = mb / 'build/meson-linux/source/host'
  executable('run-wbx', files('waterbox/run-wbx.c'),
    c_args: ['-I' + mb / 'source/host', '-D_DEFAULT_SOURCE'],
    link_args: [mbhost / 'libminiboxhost.so', '-Wl,-rpath,' + mbhost])
endif

#!/usr/bin/env python3
"""Writes the free stand-in BIOS the core's tests boot in place of Sony's.

usage: make-bios.py <out.bin>

A PocketStation runs nothing without its BIOS, and Sony's may not be passed
on, so the tests use this one: a 16 KiB ARM7TDMI program written for this
repository (docs/PLAN.md, "The free stand-in BIOS"). It is not a replacement
BIOS: it has no kernel calls, no menus and does not start apps. It uses the
parts of the machine the core passes through, so a test can see each of them:

  - the clock: the CPU is set to its fastest documented speed (CLK_MODE 7);
  - two interrupts: Timer 1 at about 1000 Hz and the real-time clock at 1 Hz,
    each counted in RAM by an IRQ handler;
  - the sound: while Action is held, the Timer 1 handler flips the DAC
    between two levels (a square wave of about 500 Hz); otherwise it writes 0;
  - the buttons: the main loop reads the interrupt controller's status
    register, where the five buttons are, but only while the clock's
    interrupt count is even. The other seconds are frames that do not read
    the controls, so a test can see lag frames counted. The IRQ handler
    reads only the second byte of the hold register (the timers and the
    clock), never the byte that holds the buttons;
  - the picture: the main loop writes all 32 rows of the screen after every
    Timer 1 tick. Row 0 is the clock's time register and row 1 its date
    register, as raw bits; row 2 the tick count; row 3 the buttons last read;
    row 4 the first word of the card; row 5 the card's last word; row 6 the
    clock's interrupt count; row 7 the tick count times three, worked out by
    a Thumb routine; rows 8 to 30 a dot that the direction buttons move (one
    step each 32 ticks); row 31 the unit's serial number (F_SN, the
    hardware ID);
  - the card: holding Left and Action together writes the tick count into
    the card's last word (flash, 0x0801FFFC);
  - the idle-loop skip: between ticks the main loop waits, reading RAM only.

There is no ARM assembler in the build machine (docs/PLAN.md), so the
program is written below as ARM instructions, one Python call each, and
assembled by the encoders in this file. Each call's comment is the
instruction in ARM assembly. The same source gives the same 16 KiB file,
byte for byte.
"""
import struct
import sys

COND = {"al": 0xE, "eq": 0x0, "ne": 0x1, "ge": 0xA, "lt": 0xB, "gt": 0xC, "le": 0xD}
DP = {"and": 0, "eor": 1, "sub": 2, "rsb": 3, "add": 4, "tst": 8, "cmp": 10,
      "orr": 12, "mov": 13, "bic": 14, "mvn": 15}
SHIFT = {"lsl": 0, "lsr": 1, "asr": 2, "ror": 3}

BIOS_BASE = 0x04000000
BIOS_SIZE = 16 * 1024

# RAM the program keeps (the user half of the 2 KiB, 0x200-0x7FF)
TICK = 0x400       # Timer 1 interrupts counted
SOUND = 0x404      # nonzero while Action is held
LEVEL = 0x408      # the DAC level the next tick writes (+-LEVEL_AMPLITUDE)
RTCS = 0x40C       # clock interrupts counted
DOTX = 0x410
DOTY = 0x414
BUTTONS = 0x418    # the buttons last read
LEVEL_AMPLITUDE = 200

INTC = 0x0A000000  # hold +0, status +4, enable +8, mask +0xC, acknowledge +0x10
TIMER1 = 0x0A800010  # period +0, count +4, control +8
CLK = 0x0B000000
RTC = 0x0B800000   # time +8, date +0xC
VRAM = 0x0D000100
DAC = 0x0D800010   # control +0, data +4
CARD = 0x08000000
CARD_LAST = 0x0801FFFC
F_SN = 0x06000300  # the serial number: F_SN_LO +0, F_SN_HI +2

INT_TIMER1 = 0x100
INT_RTC = 0x200


def rotated_imm(value):
    value &= 0xFFFFFFFF
    for rot in range(16):
        v = ((value << (2 * rot)) | (value >> (32 - 2 * rot))) & 0xFFFFFFFF if rot else value
        if v < 256:
            return (rot << 8) | v
    raise ValueError(f"0x{value:x} is not an ARM immediate")


class Assembler:
    def __init__(self, base):
        self.base = base
        self.items = []      # (kind, payload)
        self.labels = {}
        self.literals = []   # values for the pool, in order

    # ---- layout ----
    def here(self):
        return self.base + 4 * len(self.items)

    def label(self, name):
        assert name not in self.labels, name
        self.labels[name] = self.here()

    def word(self, value):
        self.items.append(("word", value))

    def emit(self, fn):
        self.items.append(("fn", fn))

    # ---- ARM instructions ----
    def dp(self, op, rd, rn, operand, s=False, cond="al", shift=None):
        """operand: an int (immediate) or ("r", rm) with an optional shift
        ("lsl", 3) or ("lsl", "r", rs)."""
        opc = DP[op]
        if op in ("tst", "cmp"):
            s = True
        word = (COND[cond] << 28) | (opc << 21) | (int(s) << 20) | (rn << 16) | (rd << 12)
        if isinstance(operand, int):
            word |= (1 << 25) | rotated_imm(operand)
        else:
            rm = operand[1]
            if shift is None:
                word |= rm
            elif len(shift) == 2:
                word |= (shift[1] << 7) | (SHIFT[shift[0]] << 5) | rm
            else:
                word |= (shift[2] << 8) | (SHIFT[shift[0]] << 5) | (1 << 4) | rm
        self.word(word)

    def mem(self, load, rd, rn, offset=0, byte=False, cond="al"):
        """LDR/STR rd, [rn, #offset]"""
        u = 1 if offset >= 0 else 0
        assert abs(offset) < 4096
        word = ((COND[cond] << 28) | (1 << 26) | (1 << 24) | (u << 23) | (int(byte) << 22)
                | (int(load) << 20) | (rn << 16) | (rd << 12) | abs(offset))
        self.word(word)

    def ldr_const(self, rd, value, cond="al"):
        """LDR rd, =value (a literal in the pool after the code)"""
        if value not in self.literals:
            self.literals.append(value)
        index = self.literals.index(value)
        cond_bits = COND[cond]

        def fn(at, pool):
            offset = pool + 4 * index - (at + 8)
            u = 1 if offset >= 0 else 0
            assert abs(offset) < 4096
            return ((cond_bits << 28) | (1 << 26) | (1 << 24) | (u << 23) | (1 << 20)
                    | (15 << 16) | (rd << 12) | abs(offset))
        self.emit(fn)

    def b(self, target, cond="al", link=False):
        cond_bits = COND[cond]

        def fn(at, pool):
            offset = (self.labels[target] - (at + 8)) >> 2
            return (cond_bits << 28) | (0b101 << 25) | (int(link) << 24) | (offset & 0xFFFFFF)
        self.emit(fn)

    def bx(self, rm, cond="al"):
        self.word((COND[cond] << 28) | 0x012FFF10 | rm)

    def push(self, regs):
        """STMFD sp!, {regs}"""
        self.word(0xE92D0000 | sum(1 << r for r in regs))

    def pop(self, regs):
        """LDMFD sp!, {regs}"""
        self.word(0xE8BD0000 | sum(1 << r for r in regs))

    def msr_c(self, imm):
        """MSR CPSR_c, #imm"""
        self.word(0xE321F000 | rotated_imm(imm))

    def subs_pc_lr_4(self):
        """SUBS pc, lr, #4: the return from an IRQ"""
        self.word(0xE25EF004)

    # ---- output ----
    def assemble(self):
        pool = self.here()
        out = bytearray()
        for i, (kind, payload) in enumerate(self.items):
            at = self.base + 4 * i
            value = payload if kind == "word" else payload(at, pool)
            out += struct.pack("<I", value & 0xFFFFFFFF)
        for value in self.literals:
            out += struct.pack("<I", value & 0xFFFFFFFF)
        return out


R0, R1, R2, R3, R4, R5, R6, R7, R8, R9, R10, R11, R12, SP, LR, PC = range(16)


def program():
    a = Assembler(BIOS_BASE)

    # ---- reset: the CPU starts here in Supervisor mode, interrupts off ----
    a.label("reset")
    a.msr_c(0xD2)                                  # msr cpsr_c, #0xD2   (IRQ mode)
    a.ldr_const(SP, 0x700)                         # ldr sp, =0x700
    a.msr_c(0xD3)                                  # msr cpsr_c, #0xD3   (Supervisor mode)
    a.ldr_const(SP, 0x7F0)                         # ldr sp, =0x7F0
    # the CPU at its fastest documented speed, 3997696 Hz
    a.ldr_const(R0, CLK)                           # ldr r0, =CLK_MODE
    a.dp("mov", R1, 0, 7)                          # mov r1, #7
    a.mem(False, R1, R0)                           # str r1, [r0]
    # the exception vectors in RAM: IRQ goes to the handler, the rest stop
    a.ldr_const(R1, 0xEAFFFFFE)                    # ldr r1, =<b .>
    a.dp("mov", R2, 0, 0)                          # mov r2, #0
    for vector in (0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x1C):
        a.mem(False, R1, R2, vector)               # str r1, [r2, #vector]
    a.ldr_const(R1, 0xE59FF000)                    # ldr r1, =<ldr pc, [pc, #0]>
    a.mem(False, R1, R2, 0x18)                     # str r1, [r2, #0x18]
    a.ldr_const(R1, "irq")                         # ldr r1, =irq
    a.mem(False, R1, R2, 0x20)                     # str r1, [r2, #0x20]: the literal it loads
    # the program's RAM
    a.ldr_const(R4, TICK)                          # ldr r4, =TICK (the base of the program's RAM)
    a.dp("mov", R1, 0, LEVEL_AMPLITUDE)            # mov r1, #LEVEL_AMPLITUDE
    a.mem(False, R1, R4, LEVEL - TICK)             # str r1, [r4, #LEVEL]
    a.dp("mov", R1, 0, 16)                         # mov r1, #16
    a.mem(False, R1, R4, DOTX - TICK)              # str r1, [r4, #DOTX]
    a.dp("mov", R1, 0, 12)                         # mov r1, #12
    a.mem(False, R1, R4, DOTY - TICK)              # str r1, [r4, #DOTY]
    # the DAC on
    a.ldr_const(R0, DAC)                           # ldr r0, =DAC_CTRL
    a.dp("mov", R1, 0, 1)                          # mov r1, #1
    a.mem(False, R1, R0)                           # str r1, [r0]
    # Timer 1: divide by 32, period 124: an interrupt each 125 * 32 cycles
    a.ldr_const(R0, TIMER1)                        # ldr r0, =TIMER1
    a.dp("mov", R1, 0, 124)                        # mov r1, #124
    a.mem(False, R1, R0, 0)                        # str r1, [r0, #0]   (period)
    a.dp("mov", R1, 0, 5)                          # mov r1, #5
    a.mem(False, R1, R0, 8)                        # str r1, [r0, #8]   (enable, /32)
    # the interrupt controller: Timer 1 and the clock
    a.ldr_const(R0, INTC)                          # ldr r0, =INTC
    a.dp("mov", R1, 0, INT_TIMER1 | INT_RTC)       # mov r1, #0x300
    a.mem(False, R1, R0, 8)                        # str r1, [r0, #8]   (enable)
    a.msr_c(0x53)                                  # msr cpsr_c, #0x53  (IRQ on, FIQ off)
    a.dp("mov", R6, 0, 0)                          # mov r6, #0         (the tick last drawn)

    # ---- the main loop ----
    a.label("main")
    a.label("wait")
    a.mem(True, R0, R4, 0)                         # ldr r0, [r4]       (TICK)
    a.dp("cmp", 0, R0, ("r", R6))                  # cmp r0, r6
    a.b("wait", "eq")                              # beq wait
    a.dp("mov", R6, 0, ("r", R0))                  # mov r6, r0
    # the buttons, read only while the clock's interrupt count is even
    a.mem(True, R0, R4, RTCS - TICK)               # ldr r0, [r4, #RTCS]
    a.dp("tst", 0, R0, 1)                          # tst r0, #1
    a.b("noread", "ne")                            # bne noread
    a.ldr_const(R1, INTC + 4)                      # ldr r1, =INT_STATUS
    a.mem(True, R2, R1)                            # ldr r2, [r1]
    a.dp("and", R2, R2, 0x1F)                      # and r2, r2, #0x1F
    a.mem(False, R2, R4, BUTTONS - TICK)           # str r2, [r4, #BUTTONS]
    a.label("noread")
    a.mem(True, R2, R4, BUTTONS - TICK)            # ldr r2, [r4, #BUTTONS]
    # Action (bit 0) makes the sound
    a.dp("and", R3, R2, 1)                         # and r3, r2, #1
    a.mem(False, R3, R4, SOUND - TICK)             # str r3, [r4, #SOUND]
    # Left and Action together write the tick count into the card
    a.dp("and", R3, R2, 5)                         # and r3, r2, #5
    a.dp("cmp", 0, R3, 5)                          # cmp r3, #5
    a.ldr_const(R0, CARD_LAST, "eq")               # ldreq r0, =CARD_LAST
    a.mem(False, R6, R0, 0, cond="eq")             # streq r6, [r0]
    # the dot moves one step each 32 ticks: Right bit 1, Left bit 2, Down bit 3, Up bit 4
    a.dp("tst", 0, R6, 31)                         # tst r6, #31
    a.b("draw", "ne")                              # bne draw
    a.mem(True, R0, R4, DOTX - TICK)               # ldr r0, [r4, #DOTX]
    a.mem(True, R1, R4, DOTY - TICK)               # ldr r1, [r4, #DOTY]
    a.dp("tst", 0, R2, 2)                          # tst r2, #2
    a.dp("add", R0, R0, 1, cond="ne")              # addne r0, r0, #1
    a.dp("tst", 0, R2, 4)                          # tst r2, #4
    a.dp("sub", R0, R0, 1, cond="ne")              # subne r0, r0, #1
    a.dp("tst", 0, R2, 8)                          # tst r2, #8
    a.dp("add", R1, R1, 1, cond="ne")              # addne r1, r1, #1
    a.dp("tst", 0, R2, 16)                         # tst r2, #16
    a.dp("sub", R1, R1, 1, cond="ne")              # subne r1, r1, #1
    a.dp("and", R0, R0, 31)                        # and r0, r0, #31  (x wraps 0..31)
    a.dp("cmp", 0, R1, 23)                         # cmp r1, #23
    a.dp("mov", R1, 0, 0, cond="ge")               # movge r1, #0     (y wraps 0..22)
    a.dp("cmp", 0, R1, 0)                          # cmp r1, #0
    a.dp("mov", R1, 0, 22, cond="lt")              # movlt r1, #22
    a.mem(False, R0, R4, DOTX - TICK)              # str r0, [r4, #DOTX]
    a.mem(False, R1, R4, DOTY - TICK)              # str r1, [r4, #DOTY]

    # ---- the picture ----
    a.label("draw")
    a.ldr_const(R7, VRAM)                          # ldr r7, =VRAM
    a.ldr_const(R0, RTC + 8)                       # ldr r0, =RTC_TIME
    a.mem(True, R1, R0, 0)                         # ldr r1, [r0]
    a.mem(False, R1, R7, 0)                        # str r1, [r7, #0]    row 0: time
    a.mem(True, R1, R0, 4)                         # ldr r1, [r0, #4]
    a.mem(False, R1, R7, 4)                        # str r1, [r7, #4]    row 1: date
    a.mem(False, R6, R7, 8)                        # str r6, [r7, #8]    row 2: ticks
    a.mem(False, R2, R7, 12)                       # str r2, [r7, #12]   row 3: buttons
    a.ldr_const(R0, CARD)                          # ldr r0, =CARD
    a.mem(True, R1, R0, 0)                         # ldr r1, [r0]
    a.mem(False, R1, R7, 16)                       # str r1, [r7, #16]   row 4: card's first word
    a.ldr_const(R0, CARD_LAST)                     # ldr r0, =CARD_LAST
    a.mem(True, R1, R0, 0)                         # ldr r1, [r0]
    a.mem(False, R1, R7, 20)                       # str r1, [r7, #20]   row 5: card's last word
    a.mem(True, R1, R4, RTCS - TICK)               # ldr r1, [r4, #RTCS]
    a.mem(False, R1, R7, 24)                       # str r1, [r7, #24]   row 6: clock interrupts
    # row 7: the tick count times three, from Thumb
    a.dp("mov", R0, 0, ("r", R6))                  # mov r0, r6
    a.ldr_const(R12, ("thumb", "triple"))          # ldr r12, =triple+1
    a.dp("mov", LR, 0, ("r", PC))                  # mov lr, pc
    a.bx(R12)                                      # bx r12
    a.mem(False, R0, R7, 28)                       # str r0, [r7, #28]   row 7
    # row 31: the serial number, F_SN_LO and F_SN_HI as one word
    a.ldr_const(R0, F_SN)                          # ldr r0, =F_SN
    a.mem(True, R1, R0, 0)                         # ldr r1, [r0]
    a.mem(False, R1, R7, 124)                      # str r1, [r7, #124]  row 31: hardware ID
    # rows 8 to 30: the dot
    a.mem(True, R0, R4, DOTX - TICK)               # ldr r0, [r4, #DOTX]
    a.mem(True, R1, R4, DOTY - TICK)               # ldr r1, [r4, #DOTY]
    a.dp("mov", R3, 0, 1)                          # mov r3, #1
    a.dp("mov", R3, 0, ("r", R3), shift=("lsl", "r", R0))  # mov r3, r3, lsl r0
    a.dp("mov", R8, 0, 0)                          # mov r8, #0
    a.dp("add", R9, R7, 32)                        # add r9, r7, #32
    a.dp("mov", R10, 0, 0)                         # mov r10, #0
    a.label("row")
    a.dp("cmp", 0, R8, ("r", R1))                  # cmp r8, r1
    a.mem(False, R3, R9, 0, cond="eq")             # streq r3, [r9]
    a.mem(False, R10, R9, 0, cond="ne")            # strne r10, [r9]
    a.dp("add", R9, R9, 4)                         # add r9, r9, #4
    a.dp("add", R8, R8, 1)                         # add r8, r8, #1
    a.dp("cmp", 0, R8, 23)                         # cmp r8, #23
    a.b("row", "lt")                               # blt row
    a.b("main")                                    # b main

    # ---- the IRQ handler ----
    a.label("irq")
    a.push([R0, R1, R2, R3, LR])                   # stmfd sp!, {r0-r3, lr}
    a.ldr_const(R0, INTC)                          # ldr r0, =INTC
    a.mem(True, R1, R0, 1, byte=True)              # ldrb r1, [r0, #1]  (hold, bits 8-15)
    a.mem(True, R2, R0, 9, byte=True)              # ldrb r2, [r0, #9]  (enable, bits 8-15)
    a.dp("and", R1, R1, ("r", R2))                 # and r1, r1, r2
    a.dp("tst", 0, R1, INT_TIMER1 >> 8)            # tst r1, #1
    a.b("notimer", "eq")                           # beq notimer
    a.dp("mov", R2, 0, INT_TIMER1)                 # mov r2, #0x100
    a.mem(False, R2, R0, 0x10)                     # str r2, [r0, #0x10] (acknowledge)
    a.ldr_const(R2, TICK)                          # ldr r2, =TICK
    a.mem(True, R3, R2, 0)                         # ldr r3, [r2]
    a.dp("add", R3, R3, 1)                         # add r3, r3, #1
    a.mem(False, R3, R2, 0)                        # str r3, [r2]
    a.mem(True, R3, R2, SOUND - TICK)              # ldr r3, [r2, #SOUND]
    a.dp("cmp", 0, R3, 0)                          # cmp r3, #0
    a.mem(True, R3, R2, LEVEL - TICK, cond="ne")   # ldrne r3, [r2, #LEVEL]
    a.dp("rsb", R3, R3, 0, cond="ne")              # rsbne r3, r3, #0
    a.mem(False, R3, R2, LEVEL - TICK, cond="ne")  # strne r3, [r2, #LEVEL]
    a.dp("mov", R3, 0, ("r", R3), shift=("lsl", 6))  # mov r3, r3, lsl #6 (DACV is bits 6-15)
    a.ldr_const(R2, DAC + 4)                       # ldr r2, =DAC_DATA
    a.mem(False, R3, R2, 0)                        # str r3, [r2]
    a.label("notimer")
    a.dp("tst", 0, R1, INT_RTC >> 8)               # tst r1, #2
    a.b("done", "eq")                              # beq done
    a.dp("mov", R2, 0, INT_RTC)                    # mov r2, #0x200
    a.mem(False, R2, R0, 0x10)                     # str r2, [r0, #0x10] (acknowledge)
    a.ldr_const(R2, RTCS)                          # ldr r2, =RTCS
    a.mem(True, R3, R2, 0)                         # ldr r3, [r2]
    a.dp("add", R3, R3, 1)                         # add r3, r3, #1
    a.mem(False, R3, R2, 0)                        # str r3, [r2]
    a.label("done")
    a.pop([R0, R1, R2, R3, LR])                    # ldmfd sp!, {r0-r3, lr}
    a.subs_pc_lr_4()                               # subs pc, lr, #4

    # ---- Thumb: r0 = r0 * 3 ----
    a.label("triple")
    a.word(0x18400041)                             # lsls r1, r0, #1 / adds r0, r0, r1
    a.word(0x46C04770)                             # bx lr / nop
    return a


def resolve_literals(a):
    resolved = []
    for value in a.literals:
        if isinstance(value, tuple):
            value = a.labels[value[1]] | 1
        elif isinstance(value, str):
            value = a.labels[value]
        resolved.append(value)
    a.literals = resolved


def self_check():
    # encodings checked against the ARM Architecture Reference Manual
    t = Assembler(0)
    t.dp("mov", R1, 0, 7)           # e3a01007
    t.mem(False, R1, R0)            # e5801000
    t.mem(True, R1, R0, 1, byte=True)  # e5d01001
    t.push([R0, R1, R2, R3, LR])    # e92d400f
    t.dp("mov", R3, 0, ("r", R3), shift=("lsl", "r", R0))  # e1a03013
    t.dp("mov", R3, 0, ("r", R3), shift=("lsl", 6))        # e1a03303
    t.dp("rsb", R3, R3, 0, cond="ne")                      # 12633000
    t.bx(R12)                       # e12fff1c
    t.dp("cmp", 0, R0, ("r", R6))   # e1500006
    t.dp("mov", R1, 0, 0x300)       # e3a01c03
    got = [struct.unpack_from("<I", t.assemble(), 4 * i)[0] for i in range(10)]
    want = [0xE3A01007, 0xE5801000, 0xE5D01001, 0xE92D400F, 0xE1A03013, 0xE1A03303,
            0x12633000, 0xE12FFF1C, 0xE1500006, 0xE3A01C03]
    assert got == want, [f"{g:08x}/{w:08x}" for g, w in zip(got, want)]


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__.split("\n\n")[1])
    self_check()
    a = program()
    resolve_literals(a)
    image = a.assemble()
    assert len(image) <= BIOS_SIZE, len(image)
    image += b"\xff" * (BIOS_SIZE - len(image))
    with open(sys.argv[1], "wb") as f:
        f.write(image)


if __name__ == "__main__":
    main()

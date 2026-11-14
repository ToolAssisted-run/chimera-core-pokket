@ bios.s - the free stand-in BIOS the core's tests boot in place of Sony's.
@
@ A PocketStation runs nothing without its BIOS, and Sony's may not be passed
@ on, so the tests use this one: an ARM7TDMI program written for this
@ repository (docs/PLAN.md, "The free stand-in BIOS"). build-bios.sh
@ assembles it with GNU binutils for ARM into the 16 KiB file. It is not a
@ replacement BIOS: it has no kernel calls, no menus and does not start apps.
@ It uses the parts of the machine the core passes through, so a test can see
@ each of them:
@
@   - the clock: the CPU is set to its fastest documented speed (CLK_MODE 7);
@   - two interrupts: Timer 1 at about 1000 Hz and the real-time clock at
@     1 Hz, each counted in RAM by an IRQ handler;
@   - the sound: while Action is held, the Timer 1 handler flips the DAC
@     between two levels (a square wave of about 500 Hz); otherwise it
@     writes 0;
@   - the buttons: the main loop reads the interrupt controller's status
@     register, where the five buttons are, but only while the clock's
@     interrupt count is even. The other seconds are frames that do not read
@     the controls, so a test can see lag frames counted. The IRQ handler
@     reads only the second byte of the hold register (the timers and the
@     clock), never the byte that holds the buttons;
@   - the picture: the main loop writes all 32 rows of the screen after every
@     Timer 1 tick. Row 0 is the clock's time register and row 1 its date
@     register, as raw bits; row 2 the tick count; row 3 the buttons last
@     read; row 4 the first word of the card; row 5 the card's last word;
@     row 6 the clock's interrupt count; row 7 the tick count times three,
@     worked out by a Thumb routine; rows 8 to 30 a dot that the direction
@     buttons move (one step each 32 ticks); row 31 the unit's serial number
@     (F_SN, the hardware ID);
@   - the card: holding Left and Action together writes the tick count into
@     the card's last word (flash, 0x0801FFFC);
@   - the idle-loop skip: between ticks the main loop waits, reading RAM only.

	.syntax unified
	.arm
	.text

@ RAM the program keeps (the user half of the 2 KiB, 0x200-0x7FF), as
@ offsets from TICK, which r4 holds
	.equ TICK, 0x400		@ Timer 1 interrupts counted
	.equ SOUND, 0x04		@ nonzero while Action is held
	.equ LEVEL, 0x08		@ the DAC level the next tick writes (+-200)
	.equ RTCS, 0x0C			@ clock interrupts counted
	.equ DOTX, 0x10
	.equ DOTY, 0x14
	.equ BUTTONS, 0x18		@ the buttons last read

	.equ INTC, 0x0A000000		@ hold +0, status +4, enable +8, acknowledge +0x10
	.equ TIMER1, 0x0A800010		@ period +0, count +4, control +8
	.equ CLK_MODE, 0x0B000000
	.equ RTC_TIME, 0x0B800008	@ date +4
	.equ VRAM, 0x0D000100
	.equ DAC_CTRL, 0x0D800010	@ data +4
	.equ CARD, 0x08000000
	.equ CARD_LAST, 0x0801FFFC
	.equ F_SN, 0x06000300		@ F_SN_LO +0, F_SN_HI +2
	.equ INT_TIMER1, 0x100
	.equ INT_RTC, 0x200

	.global reset
@ ---- reset: the CPU starts here in Supervisor mode, interrupts off ----
reset:
	msr	cpsr_c, #0xD2		@ IRQ mode
	ldr	sp, =0x700
	msr	cpsr_c, #0xD3		@ Supervisor mode
	ldr	sp, =0x7F0
	@ the CPU at its fastest documented speed, 3997696 Hz
	ldr	r0, =CLK_MODE
	mov	r1, #7
	str	r1, [r0]
	@ the exception vectors in RAM: IRQ goes to the handler, the rest stop
	ldr	r1, =0xEAFFFFFE		@ b .
	mov	r2, #0
	str	r1, [r2, #0x00]
	str	r1, [r2, #0x04]
	str	r1, [r2, #0x08]
	str	r1, [r2, #0x0C]
	str	r1, [r2, #0x10]
	str	r1, [r2, #0x14]
	str	r1, [r2, #0x1C]
	ldr	r1, =0xE59FF000		@ ldr pc, [pc, #0]
	str	r1, [r2, #0x18]
	ldr	r1, =irq
	str	r1, [r2, #0x20]		@ the address that instruction loads
	@ the program's RAM
	ldr	r4, =TICK
	mov	r1, #200
	str	r1, [r4, #LEVEL]
	mov	r1, #16
	str	r1, [r4, #DOTX]
	mov	r1, #12
	str	r1, [r4, #DOTY]
	@ the DAC on
	ldr	r0, =DAC_CTRL
	mov	r1, #1
	str	r1, [r0]
	@ Timer 1: divide by 32, period 124: an interrupt each 125 * 32 cycles
	ldr	r0, =TIMER1
	mov	r1, #124
	str	r1, [r0, #0]		@ period
	mov	r1, #5
	str	r1, [r0, #8]		@ enable, /32
	@ the interrupt controller: Timer 1 and the clock
	ldr	r0, =INTC
	mov	r1, #(INT_TIMER1 | INT_RTC)
	str	r1, [r0, #8]		@ enable
	msr	cpsr_c, #0x53		@ IRQ on, FIQ off
	mov	r6, #0			@ the tick last drawn

@ ---- the main loop ----
main:
wait:
	ldr	r0, [r4]
	cmp	r0, r6
	beq	wait
	mov	r6, r0
	@ the buttons, read only while the clock's interrupt count is even
	ldr	r0, [r4, #RTCS]
	tst	r0, #1
	bne	noread
	ldr	r1, =(INTC + 4)
	ldr	r2, [r1]
	and	r2, r2, #0x1F
	str	r2, [r4, #BUTTONS]
noread:
	ldr	r2, [r4, #BUTTONS]
	@ Action (bit 0) makes the sound
	and	r3, r2, #1
	str	r3, [r4, #SOUND]
	@ Left and Action together write the tick count into the card
	and	r3, r2, #5
	cmp	r3, #5
	ldreq	r0, =CARD_LAST
	streq	r6, [r0]
	@ the dot moves one step each 32 ticks: Right bit 1, Left bit 2, Down bit 3, Up bit 4
	tst	r6, #31
	bne	draw
	ldr	r0, [r4, #DOTX]
	ldr	r1, [r4, #DOTY]
	tst	r2, #2
	addne	r0, r0, #1
	tst	r2, #4
	subne	r0, r0, #1
	tst	r2, #8
	addne	r1, r1, #1
	tst	r2, #16
	subne	r1, r1, #1
	and	r0, r0, #31		@ x wraps 0..31
	cmp	r1, #23
	movge	r1, #0			@ y wraps 0..22
	cmp	r1, #0
	movlt	r1, #22
	str	r0, [r4, #DOTX]
	str	r1, [r4, #DOTY]

@ ---- the picture ----
draw:
	ldr	r7, =VRAM
	ldr	r0, =RTC_TIME
	ldr	r1, [r0]
	str	r1, [r7, #0]		@ row 0: time
	ldr	r1, [r0, #4]
	str	r1, [r7, #4]		@ row 1: date
	str	r6, [r7, #8]		@ row 2: ticks
	str	r2, [r7, #12]		@ row 3: buttons
	ldr	r0, =CARD
	ldr	r1, [r0]
	str	r1, [r7, #16]		@ row 4: the card's first word
	ldr	r0, =CARD_LAST
	ldr	r1, [r0]
	str	r1, [r7, #20]		@ row 5: the card's last word
	ldr	r1, [r4, #RTCS]
	str	r1, [r7, #24]		@ row 6: clock interrupts
	@ row 7: the tick count times three, from Thumb
	mov	r0, r6
	ldr	r12, =(triple + 1)
	mov	lr, pc
	bx	r12
	str	r0, [r7, #28]		@ row 7
	@ row 31: the serial number, F_SN_LO and F_SN_HI as one word
	ldr	r0, =F_SN
	ldr	r1, [r0]
	str	r1, [r7, #124]		@ row 31: hardware ID
	@ rows 8 to 30: the dot
	ldr	r0, [r4, #DOTX]
	ldr	r1, [r4, #DOTY]
	mov	r3, #1
	mov	r3, r3, lsl r0
	mov	r8, #0
	add	r9, r7, #32
	mov	r10, #0
row:
	cmp	r8, r1
	streq	r3, [r9]
	strne	r10, [r9]
	add	r9, r9, #4
	add	r8, r8, #1
	cmp	r8, #23
	blt	row
	b	main

@ ---- the IRQ handler ----
irq:
	push	{r0-r3, lr}
	ldr	r0, =INTC
	ldrb	r1, [r0, #1]		@ hold, bits 8-15
	ldrb	r2, [r0, #9]		@ enable, bits 8-15
	and	r1, r1, r2
	tst	r1, #(INT_TIMER1 >> 8)
	beq	notimer
	mov	r2, #INT_TIMER1
	str	r2, [r0, #0x10]		@ acknowledge
	ldr	r2, =TICK
	ldr	r3, [r2]
	add	r3, r3, #1
	str	r3, [r2]
	ldr	r3, [r2, #SOUND]
	cmp	r3, #0
	ldrne	r3, [r2, #LEVEL]
	rsbne	r3, r3, #0
	strne	r3, [r2, #LEVEL]
	mov	r3, r3, lsl #6		@ DACV is bits 6-15
	ldr	r2, =(DAC_CTRL + 4)
	str	r3, [r2]
notimer:
	tst	r1, #(INT_RTC >> 8)
	beq	done
	mov	r2, #INT_RTC
	str	r2, [r0, #0x10]		@ acknowledge
	ldr	r2, =(TICK + RTCS)
	ldr	r3, [r2]
	add	r3, r3, #1
	str	r3, [r2]
done:
	pop	{r0-r3, lr}
	subs	pc, lr, #4

@ ---- Thumb: r0 = r0 * 3 ----
	.thumb
	.thumb_func
triple:
	lsls	r1, r0, #1
	adds	r0, r0, r1
	bx	lr
	nop
	.arm
	.ltorg

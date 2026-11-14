/* cinterface.c - Pokket (a Sony PocketStation) behind Chimera's guest ABI.
 *
 * Upstream's emulator is a library with a small public interface
 * (core/include/psemu/psemu.h), made for frontends: load a BIOS, load a card,
 * set the buttons, run a 32nd of a second, take the picture and the sound.
 * This file is that frontend, for miniBox's sandbox. Upstream is built
 * unchanged.
 *
 * This file compiles identically for the guest (miniBox's emulibc) and for
 * the native reference build (native-shim/emulibc.h), which is what makes
 * the comparison of the two a proof.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <emulibc.h>
#include <waterbox_settings.h>
#include <waterbox_slots.h>

#include "psemu/psemu.h"
/* the machine's structure, for the domains (VRAM, BIOS), the registers, and
 * the clock kept across a reset; upstream's own header */
#include "psemu_internal.h"

/* A text a person reads is a key of languages/en.json, each of its arguments
 * after a TEXT_ARG (chimera docs/translations.md). */
#define TEXT_ARG "\x1f"

/* The firmware's id in waterbox.config, which is the name it is mounted
 * under, and the one name save data is exported and taken back under. */
#define BIOS_FILE "pocketstation.bin"
#define SAVE_FILE "card.mcd"

/* The largest file the card slot takes: a DexDrive dump of a whole card is
 * 134976 bytes, every other kind is smaller. Anything much larger is not a
 * card, and is refused before it is read. */
#define MAX_CONTENT (1u << 20)

/* One frame: a 32nd of a second, 33000 reference cycles, as upstream's own
 * libretro core runs it. psemu_run counts reference-cycle boundaries, so a
 * sequence of frames loses nothing to rounding. */
#define FRAME_CYCLES (PSEMU_REFERENCE_CLOCK_HZ / 32u)
#define VSYNC_NUM 32
#define VSYNC_DEN 1

/* 8000 Hz mono: 250 samples a frame. The buffer has room for more in case a
 * frame gives a few more (it does not: the DAC resamples on exact boundaries). */
#define MAX_SAMPLES 1024

static char g_loadError[1200];
static psemu_t *g_ps;
static int g_inited;

/* ---- the controls: waterbox.config "input.buttons" order ----
 * 0 Up, 1 Right, 2 Down, 3 Left, 4 Action, 5 Reset */
#define BTN_UP 0
#define BTN_RIGHT 1
#define BTN_DOWN 2
#define BTN_LEFT 3
#define BTN_ACTION 4
#define BTN_RESET 5
#define BTN_COUNT 6
static const uint32_t k_psemuBit[5] = {
	PSEMU_BUTTON_UP, PSEMU_BUTTON_RIGHT, PSEMU_BUTTON_DOWN, PSEMU_BUTTON_LEFT, PSEMU_BUTTON_FIRE
};
/* Two channels reach a core: the packed mask in FrameAdvance (the frontend)
 * and SetButton (the test harness). A frame is their union. */
static uint8_t g_setButtons[BTN_COUNT];
static int g_resetHeld;

/* ---- the picture ---- */
static uint32_t g_video[PSEMU_LCD_WIDTH * PSEMU_LCD_HEIGHT];

/* ---- the sound ---- */
static int16_t g_audio[MAX_SAMPLES];
static int g_nsamples;

/* ---- lag frames and Chimera's input-poll callback ----
 * The five buttons are bits 0 to 4 of the interrupt controller's hold
 * (0x0A000000) and status (0x0A000004) registers, so the machine reads its
 * controls when the CPU reads the first byte of either. Upstream reports every
 * bus read through psemu_bus_read_trace_cb when it is built with
 * PSEMU_TRACE_HOOKS (meson.build); nothing else is needed from it. */
static int g_inputRead;
ECL_INVISIBLE static uintptr_t (*g_inputPoll)(uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t);

ECL_EXPORT void SetInputPollCallback(uint64_t fn)
{
	g_inputPoll = (uintptr_t (*)(uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t))(uintptr_t)fn;
}

static void on_bus_read(uint32_t addr, uint8_t value, uint32_t pc)
{
	(void)value;
	(void)pc;
	if (addr == 0x0A000000u || addr == 0x0A000004u)
	{
		g_inputRead = 1;
		if (g_inputPoll)
			g_inputPoll(0, 0, 0, 0, 0, 0);
	}
}

/* Turbo: the frontend's choice for the moment, not the machine's. */
ECL_INVISIBLE static int g_render = 1;

/* ---- the clock ----
 * The machine's real-time clock starts at the project's clock start
 * (Chimera's clockStart, which miniBox answers clock_gettime with). The
 * native reference has no sandbox to ask, so its shim gives the same second
 * (native-shim/emulibc.h, CHIMERA_NATIVE_CLOCK). */
#ifndef CHIMERA_NATIVE_CLOCK
static int64_t clock_start_seconds(void)
{
	struct timespec ts;
	if (clock_gettime(CLOCK_REALTIME, &ts) != 0)
		return 0;
	return (int64_t)ts.tv_sec;
}
#endif

/* Days since 1970-01-01 to a civil date (Howard Hinnant's algorithm). */
static void civil_from_days(int64_t z, int *y, int *m, int *d)
{
	z += 719468;
	const int64_t era = (z >= 0 ? z : z - 146096) / 146097;
	const int64_t doe = z - era * 146097;
	const int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
	const int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
	const int64_t mp = (5 * doy + 2) / 153;
	*d = (int)(doy - (153 * mp + 2) / 5 + 1);
	*m = (int)(mp < 10 ? mp + 3 : mp - 9);
	*y = (int)(yoe + era * 400 + (*m <= 2));
}

static int set_clock(int64_t seconds)
{
	if (seconds < 0)
		seconds = 0;
	const int64_t days = seconds / 86400;
	const int64_t secOfDay = seconds % 86400;
	int y, m, d;
	civil_from_days(days, &y, &m, &d);
	/* 1970-01-01 was a Thursday; the clock counts Sunday as 1 */
	const int dow = (int)((days + 4) % 7) + 1;
	return psemu_set_datetime(g_ps, y, m, d, (int)(secOfDay / 3600), (int)(secOfDay / 60 % 60),
		(int)(secOfDay % 60), dow);
}

/* ---- loading ---- */
static uint8_t *read_file(const char *name, size_t maxSize, long *outSize)
{
	*outSize = 0;
	FILE *f = fopen(name, "rb");
	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	const long size = ftell(f);
	fseek(f, 0, SEEK_SET);
	*outSize = size;
	if (size <= 0 || (size_t)size > maxSize)
	{
		fclose(f);
		return NULL;
	}
	uint8_t *buf = (uint8_t *)malloc((size_t)size);
	if (!buf || fread(buf, 1, (size_t)size, f) != (size_t)size)
	{
		free(buf);
		fclose(f);
		*outSize = -1;
		return NULL;
	}
	fclose(f);
	return buf;
}

ECL_EXPORT const char *GetLoadError(void) { return g_loadError; }

ECL_EXPORT int Init(void)
{
	g_loadError[0] = '\0';

	/* the card: the project slot's file, else the plain rom mount */
	char card[512];
	const char *cardName = "rom";
	if (wbx_slot_count("card") > 0 && wbx_slot_name("card", 0, card, sizeof card) != NULL)
		cardName = card;

	/* save data is taken back only under the name it is exported as: a file
	 * of another name would be carried by the project and then ignored */
	char save[512];
	const char *saveName = NULL;
	if (wbx_slot_count("savedata") > 0 && wbx_slot_name("savedata", 0, save, sizeof save) != NULL)
	{
		if (strcmp(save, SAVE_FILE) != 0)
		{
			snprintf(g_loadError, sizeof g_loadError, "error.save_name" TEXT_ARG "%s" TEXT_ARG "%s",
				save, SAVE_FILE);
			return 0;
		}
		saveName = save;
	}

	/* the unit's serial number, which games may read */
	char idText[32] = "410000D3";
	wbx_setting_str("hardwareId", idText, sizeof idText);
	uint32_t hardwareId = PSEMU_DEFAULT_HARDWARE_ID;
	if (!psemu_parse_hardware_id(idText, &hardwareId))
	{
		snprintf(g_loadError, sizeof g_loadError, "error.hardware_id" TEXT_ARG "%s", idText);
		return 0;
	}

	g_ps = psemu_create();
	if (!g_ps)
	{
		snprintf(g_loadError, sizeof g_loadError, "error.no_machine");
		return 0;
	}

	long size = 0;
	uint8_t *bios = read_file(BIOS_FILE, PSEMU_BIOS_SIZE, &size);
	if (size == 0 && !bios)
	{
		snprintf(g_loadError, sizeof g_loadError, "error.no_bios" TEXT_ARG "%s", BIOS_FILE);
		return 0;
	}
	if (!bios || size != PSEMU_BIOS_SIZE || psemu_load_bios(g_ps, bios, (size_t)size) != PSEMU_OK)
	{
		snprintf(g_loadError, sizeof g_loadError, "error.bios_size" TEXT_ARG "%s" TEXT_ARG "%ld",
			BIOS_FILE, size);
		return 0;
	}
	free(bios);

	uint8_t *content = read_file(cardName, MAX_CONTENT, &size);
	if (!content)
	{
		if (size == 0 && cardName == card)
			snprintf(g_loadError, sizeof g_loadError, "error.not_read" TEXT_ARG "%s", cardName);
		else if (size == 0)
			snprintf(g_loadError, sizeof g_loadError, "error.no_card");
		else
			snprintf(g_loadError, sizeof g_loadError, "error.not_card" TEXT_ARG "%s" TEXT_ARG "%ld",
				cardName, size);
		return 0;
	}
	if (psemu_load_content(g_ps, content, (size_t)size) != PSEMU_OK)
	{
		snprintf(g_loadError, sizeof g_loadError, "error.not_card" TEXT_ARG "%s" TEXT_ARG "%ld",
			cardName, size);
		return 0;
	}
	free(content);

	if (saveName)
	{
		uint8_t *saved = read_file(saveName, PSEMU_FLASH_SIZE, &size);
		if (!saved || size != PSEMU_FLASH_SIZE)
		{
			snprintf(g_loadError, sizeof g_loadError, "error.save_size" TEXT_ARG "%s" TEXT_ARG "%ld",
				saveName, size);
			return 0;
		}
		psemu_load_flash_image(g_ps, saved, (size_t)size);
		free(saved);
	}

	psemu_set_hardware_id(g_ps, hardwareId);
	psemu_reset(g_ps);
	/* after the reset, which puts the clock at its power-on value */
	set_clock(clock_start_seconds());

	psemu_bus_read_trace_cb = on_bus_read;
	g_inited = 1;
	return 1;
}

ECL_EXPORT void SetButton(int32_t index, int32_t state)
{
	if (index >= 0 && index < BTN_COUNT)
		g_setButtons[index] = state ? 1 : 0;
}

/* The PocketStation has buttons only. The export exists for the harness,
 * which drives the whole ABI. */
ECL_EXPORT void SetAxis(int32_t index, int32_t value)
{
	(void)index;
	(void)value;
}

static void draw(void)
{
	const uint8_t *fb = psemu_get_framebuffer(g_ps);
	for (int y = 0; y < PSEMU_LCD_HEIGHT; y++)
	{
		for (int x = 0; x < PSEMU_LCD_WIDTH; x++)
		{
			const int set = (fb[y * PSEMU_LCD_STRIDE + x / 8] >> (x % 8)) & 1;
			/* a set bit is a dark pixel, a clear one is the bare screen */
			g_video[y * PSEMU_LCD_WIDTH + x] = set ? 0xFF000000u : 0xFFFFFFFFu;
		}
	}
}

static int g_faultReported;

ECL_EXPORT void FrameAdvance(uint64_t packed)
{
	uint8_t held[BTN_COUNT];
	for (int i = 0; i < BTN_COUNT; i++)
		held[i] = g_setButtons[i] | (uint8_t)((packed >> i) & 1);
	g_inputRead = 0;
	g_nsamples = 0;
	if (!g_inited)
		return;

	/* The reset button, behind the case: the machine starts again and keeps
	 * its card and its clock, which runs on its own battery-backed
	 * oscillator. It acts when it goes down. */
	if (held[BTN_RESET] && !g_resetHeld)
	{
		const rtc_t clock = g_ps->rtc;
		psemu_reset(g_ps);
		g_ps->rtc = clock;
	}
	g_resetHeld = held[BTN_RESET];

	uint32_t buttons = 0;
	for (int i = 0; i < 5; i++)
		if (held[i])
			buttons |= k_psemuBit[i];
	psemu_set_buttons(g_ps, buttons);

	/* An opcode the emulator does not know stops the machine: what it would
	 * do next has no meaning (psemu.h, psemu_cpu_faulted). The picture stays
	 * on its last frame and the sound is silent. */
	if (!psemu_cpu_faulted(g_ps))
		psemu_run(g_ps, FRAME_CYCLES);
	else if (!g_faultReported)
	{
		g_faultReported = 1;
		fprintf(stderr, "[pokket] the CPU ran an instruction the emulator does not know; the machine has stopped\n");
		psemu_write_crash_report(g_ps, stderr);
	}

	if (g_render)
		draw();
	g_nsamples = (int)psemu_get_audio_samples(g_ps, g_audio, MAX_SAMPLES);
}

ECL_EXPORT void SetRenderingEnabled(int on) { g_render = on != 0; }

ECL_EXPORT uint32_t *GetVideoBgra(void) { return g_video; }
ECL_EXPORT int GetVideoWidth(void) { return PSEMU_LCD_WIDTH; }
ECL_EXPORT int GetVideoHeight(void) { return PSEMU_LCD_HEIGHT; }

ECL_EXPORT int16_t *GetAudio(void) { return g_audio; }
ECL_EXPORT int GetAudioSampleCount(void) { return g_nsamples; }

ECL_EXPORT int GetVsyncNumerator(void) { return VSYNC_NUM; }
ECL_EXPORT int GetVsyncDenominator(void) { return VSYNC_DEN; }

ECL_EXPORT int InputWasRead(void) { return g_inputRead; }

/* ---- memory domains ----
 * RAM: the 2 KiB of work RAM. Flash: the memory card, 128 KiB, in the layout
 * of a .mcd file. VRAM: the screen, 32 rows of 32 bits. BIOS: the firmware,
 * read-only. */
#define DOMAIN_COUNT 4
static const char *const k_domainNames[DOMAIN_COUNT] = { "RAM", "Flash", "VRAM", "BIOS" };

ECL_EXPORT int GetMemoryDomainCount(void) { return g_inited ? DOMAIN_COUNT : 0; }

ECL_EXPORT const char *GetMemoryDomainName(int i)
{
	return i >= 0 && i < DOMAIN_COUNT ? k_domainNames[i] : NULL;
}

ECL_EXPORT uint8_t *GetMemoryDomainPtr(int i)
{
	if (!g_inited)
		return NULL;
	switch (i)
	{
	case 0: return psemu_ram_data(g_ps);
	case 1: return psemu_flash_data(g_ps);
	case 2: return g_ps->lcd.vram;
	case 3: return g_ps->bus.bios;
	default: return NULL;
	}
}

ECL_EXPORT int64_t GetMemoryDomainSize(int i)
{
	switch (i)
	{
	case 0: return PSEMU_RAM_SIZE;
	case 1: return PSEMU_FLASH_SIZE;
	case 2: return LCD_VRAM_SIZE;
	case 3: return PSEMU_BIOS_SIZE;
	default: return 0;
	}
}

ECL_EXPORT int GetMemoryDomainWritable(int i) { return i >= 0 && i < 3; }

/* ---- registers: the ARM7TDMI's, as the current mode sees them ---- */
#define REG_COUNT 17
static const char *const k_regNames[REG_COUNT] = {
	"R0", "R1", "R2", "R3", "R4", "R5", "R6", "R7", "R8", "R9", "R10", "R11", "R12",
	"R13", "R14", "R15", "CPSR"
};

ECL_EXPORT int GetRegisterCount(void) { return REG_COUNT; }
ECL_EXPORT const char *GetRegisterName(int i) { return i >= 0 && i < REG_COUNT ? k_regNames[i] : NULL; }
ECL_EXPORT int GetRegisterBits(int i) { return i >= 0 && i < REG_COUNT ? 32 : 0; }
ECL_EXPORT int64_t GetRegisterValue(int i)
{
	if (!g_inited || i < 0 || i >= REG_COUNT)
		return 0;
	return i < 16 ? g_ps->cpu.r[i] : g_ps->cpu.cpsr;
}
ECL_EXPORT const char *GetRegisterRoles(void) { return "pc R15\nsp R13\nflags CPSR\n"; }

/* ---- save data: the card ----
 * The card is the machine's flash, so a savestate already carries it. This
 * is the way out: the whole card, 128 KiB, in the raw layout PlayStation
 * memory card tools open, under the one name the savedata slot takes back. */
ECL_EXPORT int32_t GetSaveDataFileCount(void) { return g_inited ? 1 : 0; }
ECL_EXPORT const char *GetSaveDataFileName(int32_t i) { return g_inited && i == 0 ? SAVE_FILE : NULL; }
ECL_EXPORT int64_t GetSaveDataFileSize(int32_t i) { return g_inited && i == 0 ? PSEMU_FLASH_SIZE : 0; }
ECL_EXPORT const uint8_t *GetSaveDataFileBuffer(int32_t i)
{
	return g_inited && i == 0 ? psemu_flash_data(g_ps) : NULL;
}

/* Boot-stage timing at the frontend handoff.
 *
 * CLOCK_BOOTTIME only starts once Linux initialises timekeeping, so on its own
 * it cannot see the bootloader or kernel decompression: everything before the
 * clock origin is invisible. The ARM generic counter (CNTVCT_EL0) is free
 * running and is not reset by the kernel, so the counter value at the handoff
 * covers the whole start, and subtracting CLOCK_MONOTONIC_RAW from it gives the
 * part that happened before Linux had a clock.
 *
 * Output is one line, four space-separated fields, so a shell can read it with
 * a single `read`:
 *
 *   <legacy centiseconds> <before Linux> <Linux to handoff> <total>
 *
 * The first field keeps the /proc/uptime format the /run/boot-frontend-exec
 * marker has always used; the other three are seconds with millisecond
 * precision. Exit status is non-zero whenever a trustworthy split is not
 * possible, and callers fall back to /proc/uptime alone.
 */
#define _POSIX_C_SOURCE 200809L
#include <inttypes.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

/* A kernel may forbid userspace counter reads (CNTKCTL_EL1.EL0VCTEN=0).
 * Turn the resulting SIGILL into an ordinary failure instead of a core dump
 * in the middle of the boot. */
static void unavailable(int signal_number)
{
	(void)signal_number;
	_exit(1);
}

static uint64_t counter(void)
{
	uint64_t value;
	__asm__ volatile("isb; mrs %0, cntvct_el0" : "=r"(value) : : "memory");
	return value;
}

static uint64_t nanoseconds(uint64_t ticks, uint64_t frequency)
{
	return ticks / frequency * UINT64_C(1000000000) +
	       ticks % frequency * UINT64_C(1000000000) / frequency;
}

static uint64_t time_ns(struct timespec t)
{
	return (uint64_t)t.tv_sec * UINT64_C(1000000000) + (uint64_t)t.tv_nsec;
}

static void seconds(uint64_t ns)
{
	uint64_t ms = (ns + 500000) / 1000000;
	printf("%" PRIu64 ".%03" PRIu64, ms / 1000, ms % 1000);
}

int main(void)
{
	if (signal(SIGILL, unavailable) == SIG_ERR)
		return 1;

	uint64_t frequency;
	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(frequency));
	/* 0 means the firmware never programmed it; anything outside 1 kHz..1 GHz
	 * is not a real system counter and would scale the result into nonsense. */
	if (frequency < 1000 || frequency > UINT64_C(1000000000))
		return 1;

	struct timespec raw, boot;
	uint64_t before = counter();
	if (clock_gettime(CLOCK_MONOTONIC_RAW, &raw))
		return 1;
	uint64_t after = counter();
	if (clock_gettime(CLOCK_BOOTTIME, &boot) || after < before)
		return 1;
	/* Two reads either side of clock_gettime bound the sampling error. A pair
	 * that straddles a reschedule is not a sample of the same instant, so
	 * refuse it rather than publish a split that is off by the sleep. */
	if (after - before > frequency / 10000)
		return 1;

	uint64_t total = nanoseconds(before + (after - before) / 2, frequency);
	uint64_t post = time_ns(raw);
	if (post > total)
		return 1;

	uint64_t legacy_cs = time_ns(boot) / 10000000;
	printf("%" PRIu64 ".%02" PRIu64 " ", legacy_cs / 100, legacy_cs % 100);
	seconds(total - post);
	putchar(' ');
	seconds(post);
	putchar(' ');
	seconds(total);
	putchar('\n');
	return fflush(stdout) == 0 ? 0 : 1;
}

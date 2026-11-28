/*
 * ninit_util.c -- timing helpers (T11/T13)
 *
 * Unity phase: this file is included by the single compilation entry point.
 * It is not a separate translation unit yet. Keep it free of direct references
 * to the main source file so the consumer guard stays green.
 */

/* Milliseconds from CLOCK_MONOTONIC: immune to wall-clock jumps (the grace
   window is a duration, not a date). Falls back to time(NULL) seconds if the
   monotonic clock is unavailable, keeping the window accurate to a second
   instead of failing outright. */
static long long monotonic_ms(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0)
        return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
    return (long long)time(NULL) * 1000;
}

/* Delay that never busy-waits: nanosleep() restarts on EINTR and reuses the
   remaining time reported back in &ts, so an interrupted sleep still completes
   in full. Used for the fork() EAGAIN backoff (T11) and the shutdown grace
   poll (T13) instead of sleep()/usleep(). */
static void sleep_ms(int ms)
{
    struct timespec ts;
    if (ms <= 0) return;
    ts.tv_sec  = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    while (nanosleep(&ts, &ts) < 0 && errno == EINTR)
        ;
}

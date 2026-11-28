/*
 * ninit_signals.c -- flags-only signal handlers
 *
 * Unity phase: this file is included by the single compilation entry point.
 * Not a separate translation unit yet. Keep it free of direct references to
 * the main source file so the consumer guard stays green.
 */

static void on_sigchld(int s) { (void)s; sigchld_flag = 1; }
static void on_sigterm(int s) { (void)s; sigterm_flag = 1; }
static void on_sigint (int s) { (void)s; sigint_flag  = 1; }
static void on_sigusr1(int s) { (void)s; sigusr1_flag = 1; }
static void on_sigusr2(int s) { (void)s; sigusr2_flag = 1; }

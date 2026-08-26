// pidfd-signal — race-free process termination helper for the system
// monitor's "End Process" action.
//
// Usage: pidfd-signal PID EXPECTED_LSTART
//
// The residual race in a validate-then-kill design is the gap between
// reading a PID's identity and signalling it: the process can exit, be
// reaped, and its PID handed to a different program. This helper closes
// that gap by pinning the process with a pidfd *first* — from that moment
// the kernel guarantees the file description refers to exactly one process
// and no reuse can swap it. Only then is the process's birth time
// re-derived from kernel truth (/proc/PID/stat field 22 + /proc/stat btime,
// CLK_TCK ticks) and compared with the caller's expected lstart token
// (captured when the user selected the row, in ps's locale-C
// "%a %b %e %H:%M:%S %Y" shape). A mismatch means the PID now names a
// different process and is never signalled.
//
// Exit codes:
//   0  signalled the confirmed process
//   1  internal error (unreadable /proc/stat, unset CLK_TCK, bad clock)
//   2  invalid arguments (non-numeric PID, empty identity token)
//   3  process vanished (pidfd_open failed, /proc/PID/stat unreadable)
//   4  identity mismatch — the PID now names a different process
//   5  signal delivery failed (e.g. EPERM)
//
// argv-only invocation; never interprets a shell, and a leading "-" in any
// argument is rejected outright so the helper cannot be turned into an
// option injection.

#define _GNU_SOURCE

#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

// Generic Linux ABI numbers; glibc headers predate these on some systems.
#ifndef SYS_pidfd_send_signal
#define SYS_pidfd_send_signal 424
#endif
#ifndef SYS_pidfd_open
#define SYS_pidfd_open 434
#endif

#define EXIT_INTERNAL 1
#define EXIT_ARGS 2
#define EXIT_VANISHED 3
#define EXIT_MISMATCH 4
#define EXIT_SIGNAL 5

#define TOKEN_MAX 256

static void die(int code, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fputs("pidfd-signal: ", stderr);
  vfprintf(stderr, fmt, ap);
  fputc('\n', stderr);
  va_end(ap);
  exit(code);
}

static int read_small_file(const char *path, char *buf, size_t cap) {
  FILE *f = fopen(path, "re");
  if (f == NULL) return -1;
  size_t n = fread(buf, 1, cap - 1, f);
  int bad = ferror(f);
  fclose(f);
  if (bad) return -1;
  buf[n] = '\0';
  return 0;
}

// /proc/PID/stat field 22 (starttime, in clock ticks since boot). Field 2
// (comm) may contain spaces and parentheses, so parsing starts after the
// final ')'; starttime is then the 20th token that follows (field 3 is
// state).
static long long read_starttime(pid_t pid) {
  char path[64];
  char buf[4096];
  snprintf(path, sizeof path, "/proc/%d/stat", pid);
  if (read_small_file(path, buf, sizeof buf) != 0) return -1;
  char *close = strrchr(buf, ')');
  if (close == NULL) return -1;
  char *save = NULL;
  char *tok = strtok_r(close + 1, " \t\n", &save);
  for (int i = 0; i < 19 && tok != NULL; i++)
    tok = strtok_r(NULL, " \t\n", &save);
  if (tok == NULL) return -1;
  errno = 0;
  char *end = NULL;
  unsigned long long ticks = strtoull(tok, &end, 10);
  if (errno != 0 || end == tok || *end != '\0') return -1;
  return (long long)ticks;
}

// Boot time in wall-clock seconds, exactly as ps derives process start
// times.
static long long read_btime(void) {
  char buf[4096];
  if (read_small_file("/proc/stat", buf, sizeof buf) != 0) return -1;
  const char *p = buf;
  while (*p != '\0') {
    const char *eol = strchr(p, '\n');
    size_t len = eol != NULL ? (size_t)(eol - p) : strlen(p);
    if (len >= 6 && strncmp(p, "btime ", 6) == 0) {
      errno = 0;
      char *end = NULL;
      long long value = strtoll(p + 6, &end, 10);
      if (errno == 0 && end != p + 6) return value;
      return -1;
    }
    if (eol == NULL) break;
    p = eol + 1;
  }
  return -1;
}

// ps's fixed English (locale-C) abbreviations — never the helper's locale.
static const char *const WDAY[7] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
static const char *const MON[12] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};

// Format an epoch time like `LC_ALL=C ps -o lstart=`: "%a %b %e %H:%M:%S %Y"
// in the caller's timezone (ps prints local time; the helper inherits the
// same TZ as the ps that produced the expected token). %e is the
// space-padded day of month, hence "%2d".
static int format_lstart(long long epoch, char *out, size_t cap) {
  time_t t = (time_t)epoch;
  struct tm tm;
  if (localtime_r(&t, &tm) == NULL) return -1;
  int n = snprintf(out, cap, "%s %s %2d %02d:%02d:%02d %d",
                   WDAY[tm.tm_wday], MON[tm.tm_mon], tm.tm_mday,
                   tm.tm_hour, tm.tm_min, tm.tm_sec, tm.tm_year + 1900);
  if (n < 0 || (size_t)n >= cap) return -1;
  return 0;
}

// Trim and collapse whitespace runs to single spaces, mirroring the model's
// normalizeStartToken, so "Mon Aug  5 ..." (ps pads single-digit days)
// compares equal to "Mon Aug 5 ...".
static void normalize_ws(const char *in, char *out, size_t cap) {
  size_t o = 0;
  int pending_space = 0;
  for (const char *p = in; *p != '\0'; p++) {
    if (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r' || *p == '\v' || *p == '\f') {
      pending_space = o > 0 ? 1 : 0;
      continue;
    }
    if (pending_space && o > 0) {
      if (o + 1 >= cap) break;
      out[o++] = ' ';
      pending_space = 0;
    }
    if (o + 1 >= cap) break;
    out[o++] = *p;
  }
  out[o] = '\0';
}


int main(int argc, char **argv) {
  if (argc != 3)
    die(EXIT_ARGS, "usage: pidfd-signal PID EXPECTED_LSTART");

  // PID: decimal digits only. Rejects signs, whitespace, and any leading
  // "-" so arguments can never be read as options.
  const char *pid_s = argv[1];
  if (pid_s[0] == '\0')
    die(EXIT_ARGS, "PID must be a positive integer");
  for (const char *p = pid_s; *p != '\0'; p++)
    if (*p < '0' || *p > '9')
      die(EXIT_ARGS, "PID must be a positive integer, got '%s'", pid_s);
  errno = 0;
  char *end = NULL;
  long pid_l = strtol(pid_s, &end, 10);
  if (errno != 0 || pid_l < 1 || pid_l > INT_MAX)
    die(EXIT_ARGS, "PID out of range: %s", pid_s);
  pid_t pid = (pid_t)pid_l;

  // Expected lstart token: nonempty after normalization. An empty identity
  // can never confirm anything, so it is refused before any pidfd is
  // opened.
  char expected[TOKEN_MAX];
  normalize_ws(argv[2], expected, sizeof expected);
  if (expected[0] == '\0')
    die(EXIT_ARGS, "expected lstart token must not be empty");
  if (expected[0] == '-')
    die(EXIT_ARGS, "expected lstart token must not begin with '-'");

  // Pin the process identity FIRST: the pidfd refers to exactly the process
  // owning this PID right now, and reuse cannot swap it afterwards.
  int pidfd = (int)syscall(SYS_pidfd_open, pid, 0);
  if (pidfd < 0) {
    if (errno == ESRCH)
      die(EXIT_VANISHED, "PID %ld no longer exists", pid_l);
    die(EXIT_VANISHED, "could not open pidfd for PID %ld: %s", pid_l, strerror(errno));
  }

  // Derive the pinned process's actual birth token from kernel truth.
  long long ticks = read_starttime(pid);
  if (ticks < 0)
    die(EXIT_VANISHED, "could not read /proc/%ld/stat", pid_l);
  long long btime = read_btime();
  if (btime < 0)
    die(EXIT_INTERNAL, "could not read btime from /proc/stat");
  long long hz = sysconf(_SC_CLK_TCK);
  if (hz <= 0)
    die(EXIT_INTERNAL, "CLK_TCK unavailable");
  long long start_epoch = btime + ticks / hz;

  char actual[TOKEN_MAX];
  if (format_lstart(start_epoch, actual, sizeof actual) != 0)
    die(EXIT_INTERNAL, "could not format start time");

  char actual_norm[TOKEN_MAX];
  normalize_ws(actual, actual_norm, sizeof actual_norm);
  if (strcmp(actual_norm, expected) != 0)
    die(EXIT_MISMATCH, "PID %ld is now \"%s\", expected \"%s\"", pid_l, actual_norm, expected);

  // Signal the pinned process. Even if the numeric PID is handed to a new
  // program between the comparison and this call, the pidfd still names the
  // confirmed process — a replacement can never receive this signal.
  if (syscall(SYS_pidfd_send_signal, pidfd, SIGTERM, NULL, 0) != 0)
    die(EXIT_SIGNAL, "could not signal PID %ld: %s", pid_l, strerror(errno));
  return 0;
}

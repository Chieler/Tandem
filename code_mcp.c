/* Downstream stdio MCP client, per-instance catalogs, atomic live recheck, and LRU server pool. */
#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#include "code_mcp.h"
#include "code_schema.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <libproc.h>
#else
#include <sys/syscall.h>
#endif

#define MCP_MAX_LIST_PAGES          64
#define MCP_CRASH_WINDOW_SEC        300
#define MCP_CRASH_LIMIT             3
#define MCP_INTAKE_WORKERS          4
#define MCP_REFRESH_RETRY_BUDGET    3
#define MCP_PROTOCOL_VERSION        "2025-06-18"
#define MCP_DISCARD_SNIP            512
#define MCP_MAX_PENDING_SRV_REPLIES 64
#define MCP_MAX_SRV_REPLY_BYTES     65536
#define MCP_SRV_REPLY_WRITE_MS      2000

static const char *const MCP_SUPPORTED_PROTOCOLS[] = {
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
    NULL
};

static char g_mcp_version[64] = "0.5.5";
static pthread_mutex_t *g_mcp_fork_mu = NULL;

void code_mcp_init(const char *version, pthread_mutex_t *fork_mu) {
    if (version && *version) snprintf(g_mcp_version, sizeof g_mcp_version, "%s", version);
    g_mcp_fork_mu = fork_mu;
}

static char *mfmt(const char *f, ...) {
    va_list ap;
    char *s = NULL;
    va_start(ap, f);
    if (vasprintf(&s, f, ap) < 0) abort();
    va_end(ap);
    return s;
}

static long long mono_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}

static void msleep_ms(int ms) {
    if (ms <= 0) return;
    struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000L };
    while (nanosleep(&ts, &ts) < 0 && errno == EINTR) {}
}

static void cond_init_mono(pthread_cond_t *cv) {
#ifndef __APPLE__
    pthread_condattr_t attr;
    pthread_condattr_init(&attr);
    pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
    pthread_cond_init(cv, &attr);
    pthread_condattr_destroy(&attr);
#else
    pthread_cond_init(cv, NULL);
#endif
}

static void cond_wait_ms(pthread_cond_t *cv, pthread_mutex_t *mu, int ms) {
    if (ms <= 0) return;
#ifdef __APPLE__
    struct timespec rel = { ms / 1000, (long)(ms % 1000) * 1000000L };
    pthread_cond_timedwait_relative_np(cv, mu, &rel);
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    ts.tv_sec += ms / 1000;
    ts.tv_nsec += (long)(ms % 1000) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) {
        ts.tv_sec++;
        ts.tv_nsec -= 1000000000L;
    }
    pthread_cond_timedwait(cv, mu, &ts);
#endif
}

static char *mcp_shell_quote(const char *s) {
    if (!s) s = "";
    size_t cap = 3;
    for (const char *p = s; *p; p++) cap += (*p == '\'') ? 4 : 1;
    char *out = malloc(cap), *o = out;
    if (!out) abort();
    *o++ = '\'';
    for (const char *p = s; *p; p++) {
        if (*p == '\'') {
            memcpy(o, "'\\''", 4);
            o += 4;
        } else {
            *o++ = *p;
        }
    }
    *o++ = '\'';
    *o = '\0';
    return out;
}

static char *build_grant_cmd(const char *project, const char *server, const char *tool, enum code_class eff, int user_scoped) {
    char *qroot = mcp_shell_quote(project ? project : "");
    char *target = (eff == CODE_READ) ? mfmt("%s.*", server) : mfmt("%s.%s", server, tool);
    char *qtarget = mcp_shell_quote(target);
    const char *lvl = (eff == CODE_READ) ? "read" : "allow";
    char *cmd = mfmt("cd %s && cntctr code grant %s %s", qroot, qtarget, lvl);
    if (eff == CODE_READ && user_scoped && strcmp(server, "cntctr") != 0) {   /* a read grant can also be user-wide, but only for a user-scoped server */
        char *all = mfmt("%s (all projects: cntctr code grant --all-projects %s read)", cmd, qtarget);
        free(cmd);
        cmd = all;
    }
    free(qroot);
    free(target);
    free(qtarget);
    return cmd;
}

const char *code_owner_project(const struct code_server_row *srv, const char *project) {
    if (!srv) return "";
    if (srv->scope_project[0] != '\0') return srv->scope_project;
    if (srv->isolated) return (project && *project) ? project : "";
    return "";
}

static void server_row_copy(struct code_server_row *dst, const struct code_server_row *src) {
    memset(dst, 0, sizeof *dst);
    snprintf(dst->scope_project, sizeof dst->scope_project, "%s", src->scope_project);
    snprintf(dst->name, sizeof dst->name, "%s", src->name);
    snprintf(dst->reg_id, sizeof dst->reg_id, "%s", src->reg_id);
    snprintf(dst->trust, sizeof dst->trust, "%s", src->trust);
    snprintf(dst->created_by, sizeof dst->created_by, "%s", src->created_by);
    dst->isolated = src->isolated;
    dst->created_at = src->created_at;
    dst->command = src->command ? strdup(src->command) : strdup("");
    dst->args_json = src->args_json ? strdup(src->args_json) : strdup("[]");
    dst->env_json = src->env_json ? strdup(src->env_json) : strdup("{}");
}

static long long pid_rss_bytes(pid_t pid) {
    if (pid <= 0) return 0;
#ifdef __APPLE__
    struct proc_taskinfo pti;
    int r = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &pti, (int)sizeof pti);
    if (r == (int)sizeof pti && pti.pti_resident_size > 0)
        return (long long)pti.pti_resident_size;
    return 0;
#else
    char path[64];
    snprintf(path, sizeof path, "/proc/%ld/statm", (long)pid);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    unsigned long long size_pages = 0, rss_pages = 0;
    int n = fscanf(f, "%llu %llu", &size_pages, &rss_pages);
    fclose(f);
    long pg = sysconf(_SC_PAGESIZE);
    if (n == 2 && pg > 0) return (long long)(rss_pages * (unsigned long long)pg);
    return 0;
#endif
}

/* ---- Bounded / cancel-aware SQLite open & busy/progress helpers ---- */

struct db_deadline_ctx {
    long long deadline_ms;
    const atomic_int *cancelled;
};

static int db_dl_aborted(const struct db_deadline_ctx *c) {
    if (!c) return 0;
    if (c->cancelled && atomic_load_explicit(c->cancelled, memory_order_acquire)) return 1;
    if (c->deadline_ms > 0 && mono_ms() >= c->deadline_ms) return 1;
    return 0;
}

static int db_dl_progress_cb(void *opaque) {
    return db_dl_aborted((const struct db_deadline_ctx *)opaque);
}

static int db_dl_busy_cb(void *opaque, int count) {
    const struct db_deadline_ctx *c = (const struct db_deadline_ctx *)opaque;
    if (db_dl_aborted(c)) return 0;
    int slice = (count < 5) ? 5 : (count < 20 ? 15 : 25);
    if (c && c->deadline_ms > 0) {
        long long rem = c->deadline_ms - mono_ms();
        if (rem <= 0) return 0;
        if (slice > rem) slice = (int)rem;
    }
    msleep_ms(slice);
    return db_dl_aborted(c) ? 0 : 1;
}

static sqlite3 *open_db_deadline(const char *db_path, struct db_deadline_ctx *ctx, char **err) {
    if (err) *err = NULL;
    if (!db_path || !*db_path) {
        if (err) *err = strdup("database path missing");
        return NULL;
    }
    sqlite3 *db = NULL;
    char *kerr = NULL;
    for (;;) {
        if (db_dl_aborted(ctx)) {
            free(kerr);
            if (err) *err = strdup((ctx && ctx->cancelled && atomic_load_explicit(ctx->cancelled, memory_order_acquire))
                                       ? "cancelled" : "database open timed out");
            return NULL;
        }
        int slice = 25;
        if (ctx && ctx->deadline_ms > 0) {
            long long rem = ctx->deadline_ms - mono_ms();
            if (rem <= 0) {
                free(kerr);
                if (err) *err = strdup("database open timed out");
                return NULL;
            }
            if (rem < slice) slice = (int)rem;
        }
        free(kerr);
        kerr = NULL;
        db = kb_open_timeout(db_path, &kerr, slice);
        if (db) break;
        if (!kerr || (!strstr(kerr, "locked") && !strstr(kerr, "busy"))) {
            if (err) *err = kerr ? kerr : strdup("database open failed");
            else free(kerr);
            return NULL;
        }
        msleep_ms(slice);
    }
    free(kerr);
    sqlite3_busy_handler(db, db_dl_busy_cb, ctx);
    sqlite3_progress_handler(db, 1000, db_dl_progress_cb, ctx);
    return db;
}

/* ---- Subprocess spawn (fork_mu + scrubbed env + env_json + FD_CLOEXEC + full close sweep) ---- */

static void free_strv(char **v) {
    if (!v) return;
    for (size_t i = 0; v[i]; i++) free(v[i]);
    free(v);
}

static int compute_max_fd(void) {
    int maxfd = getdtablesize();
    long sc_max = sysconf(_SC_OPEN_MAX);
    if (sc_max > maxfd && sc_max < INT_MAX) maxfd = (int)sc_max;
    struct rlimit nofile;
    if (getrlimit(RLIMIT_NOFILE, &nofile) == 0 && nofile.rlim_cur != RLIM_INFINITY &&
        nofile.rlim_cur > (rlim_t)maxfd && nofile.rlim_cur < (rlim_t)INT_MAX) {
        maxfd = (int)nofile.rlim_cur;
    }
#ifdef __APPLE__
    const char *fddir = "/dev/fd";
#else
    const char *fddir = "/proc/self/fd";
#endif
    DIR *dp = opendir(fddir);
    if (dp) {
        struct dirent *de;
        while ((de = readdir(dp)) != NULL) {
            if (!isdigit((unsigned char)de->d_name[0])) continue;
            char *end = NULL;
            long v = strtol(de->d_name, &end, 10);
            if (end && !*end && v >= 0 && v < INT_MAX - 64 && (int)v + 64 > maxfd) {
                maxfd = (int)v + 64;
            }
        }
        closedir(dp);
    }
    if (maxfd < 256) maxfd = 256;
    return maxfd;
}

static char **build_server_envp(const char *env_json, const char **path_out) {
    static const char *const BASE[] = {
        "HOME", "USER", "PATH", "LANG", "LC_ALL", "TMPDIR", "SHELL", NULL
    };
    size_t cap = 16, n = 0;
    char **envp = calloc(cap, sizeof(char *));
    if (!envp) abort();

    for (size_t i = 0; BASE[i]; i++) {
        const char *v = getenv(BASE[i]);
        if (!v) continue;
        if (n + 2 >= cap) {
            cap *= 2;
            envp = realloc(envp, cap * sizeof(char *));
            if (!envp) abort();
        }
        envp[n++] = mfmt("%s=%s", BASE[i], v);
    }

    if (env_json && *env_json) {
        json_object *eo = json_tokener_parse(env_json);
        if (eo && json_object_is_type(eo, json_type_object)) {
            json_object_object_foreach(eo, k, v) {
                if (!k || !*k || strchr(k, '=')) continue;
                if (!v || !json_object_is_type(v, json_type_string)) continue;
                const char *vs = json_object_get_string(v);
                size_t klen = strlen(k);
                int replaced = 0;
                for (size_t j = 0; j < n; j++) {
                    if (strncmp(envp[j], k, klen) == 0 && envp[j][klen] == '=') {
                        free(envp[j]);
                        envp[j] = mfmt("%s=%s", k, vs ? vs : "");
                        replaced = 1;
                        break;
                    }
                }
                if (!replaced) {
                    if (n + 2 >= cap) {
                        cap *= 2;
                        envp = realloc(envp, cap * sizeof(char *));
                        if (!envp) abort();
                    }
                    envp[n++] = mfmt("%s=%s", k, vs ? vs : "");
                }
            }
        }
        if (eo) json_object_put(eo);
    }
    envp[n] = NULL;

    if (path_out) {
        *path_out = NULL;
        for (size_t j = 0; j < n; j++) {
            if (strncmp(envp[j], "PATH=", 5) == 0) {
                *path_out = envp[j] + 5;
                break;
            }
        }
    }
    return envp;
}

static char **build_server_argv(const char *command, const char *args_json) {
    size_t cap = 8, n = 0;
    char **argv = calloc(cap, sizeof(char *));
    if (!argv) abort();
    argv[n++] = strdup(command ? command : "");

    if (args_json && *args_json) {
        json_object *ao = json_tokener_parse(args_json);
        if (ao && json_object_is_type(ao, json_type_array)) {
            size_t alen = json_object_array_length(ao);
            for (size_t i = 0; i < alen; i++) {
                json_object *el = json_object_array_get_idx(ao, i);
                if (!el || !json_object_is_type(el, json_type_string)) continue;
                if (n + 2 >= cap) {
                    cap *= 2;
                    argv = realloc(argv, cap * sizeof(char *));
                    if (!argv) abort();
                }
                const char *s = json_object_get_string(el);
                argv[n++] = strdup(s ? s : "");
            }
        }
        if (ao) json_object_put(ao);
    }
    argv[n] = NULL;
    return argv;
}

static char *resolve_executable(const char *cmd, const char *path_env, char **err) {
    if (!cmd || !*cmd) {
        if (err) *err = strdup("empty server command");
        return NULL;
    }
    if (strchr(cmd, '/')) {
        struct stat st;
        if (stat(cmd, &st) != 0) {
            if (err) *err = mfmt("cannot execute '%s': %s", cmd, strerror(errno));
            return NULL;
        }
        if (S_ISDIR(st.st_mode) || access(cmd, X_OK) != 0) {
            if (err) *err = mfmt("command '%s' is not executable", cmd);
            return NULL;
        }
        return strdup(cmd);
    }
    const char *p = (path_env && *path_env) ? path_env : "/usr/bin:/bin";
    const char *cur = p;
    while (*cur) {
        const char *col = strchr(cur, ':');
        size_t len = col ? (size_t)(col - cur) : strlen(cur);
        char cand[PATH_MAX];
        int n = (len == 0) ? snprintf(cand, sizeof cand, "./%s", cmd)
                           : snprintf(cand, sizeof cand, "%.*s/%s", (int)len, cur, cmd);
        if (n > 0 && n < (int)sizeof cand) {
            struct stat st;
            if (stat(cand, &st) == 0 && !S_ISDIR(st.st_mode) && access(cand, X_OK) == 0) {
                return strdup(cand);
            }
        }
        if (!col) break;
        cur = col + 1;
    }
    if (err) *err = mfmt("command '%s' not found on PATH", cmd);
    return NULL;
}

static void reap_child_process(pid_t pid, int graceful_ms) {
    if (pid <= 0) return;
    int st = 0;
    pid_t wr = waitpid(pid, &st, WNOHANG);
    if (wr == pid || (wr < 0 && errno == ECHILD)) return;

    (void)kill(-pid, SIGTERM);
    (void)kill(pid, SIGTERM);

    long long dl = mono_ms() + (graceful_ms > 0 ? graceful_ms : 50);
    while (mono_ms() < dl) {
        wr = waitpid(pid, &st, WNOHANG);
        if (wr == pid || (wr < 0 && errno == ECHILD)) return;
        msleep_ms(10);
    }

    (void)kill(-pid, SIGKILL);
    (void)kill(pid, SIGKILL);
    while ((wr = waitpid(pid, &st, 0)) < 0 && errno == EINTR) {}
}

struct spawned_proc {
    pid_t pid;
    int stdin_fd;
    int stdout_fd;
    int stderr_fd;
};

static int spawn_mcp_process(const struct code_server_row *srv, const char *owner_project,
                             long long deadline_ms, const atomic_int *cancelled,
                             struct spawned_proc *out, char **err) {
    memset(out, 0, sizeof *out);
    out->pid = -1;
    out->stdin_fd = out->stdout_fd = out->stderr_fd = -1;
    if (err) *err = NULL;

    const char *path_env = NULL;
    char **envp = build_server_envp(srv->env_json, &path_env);
    char *exe = resolve_executable(srv->command, path_env, err);
    if (!exe) {
        free_strv(envp);
        return -1;
    }
    char **argv = build_server_argv(srv->command, srv->args_json);
    const char *cwd = (owner_project && *owner_project) ? owner_project : getenv("HOME");
    if (!cwd || !*cwd) cwd = "/";
    int maxfd = compute_max_fd();

    int pin[2] = {-1, -1}, pout[2] = {-1, -1}, perr[2] = {-1, -1}, pexec[2] = {-1, -1};
    pid_t pid = -1;
    int saved_errno = 0;

    if (g_mcp_fork_mu) pthread_mutex_lock(g_mcp_fork_mu);
    int made = (pipe(pin) == 0 && pipe(pout) == 0 && pipe(perr) == 0 && pipe(pexec) == 0);
    if (!made) saved_errno = errno;
    int all[8] = { pin[0], pin[1], pout[0], pout[1], perr[0], perr[1], pexec[0], pexec[1] };
    for (int i = 0; i < 8; i++) {
        if (all[i] >= 0) (void)fcntl(all[i], F_SETFD, FD_CLOEXEC);
    }
    if (made) {
        pid = fork();
        if (pid < 0) saved_errno = errno;
    }
    if (pid == 0) {
        /* Child: async-signal-safe calls ONLY before execve. */
        if (setsid() < 0) {
            int e = errno;
            ssize_t w = write(pexec[1], &e, sizeof e);
            (void)w;
            _exit(127);
        }
        if (chdir(cwd) != 0) {
            int e = errno;
            ssize_t w = write(pexec[1], &e, sizeof e);
            (void)w;
            _exit(127);
        }

        int r_in = fcntl(pin[0], F_DUPFD, 10);
        int w_out = fcntl(pout[1], F_DUPFD, 10);
        int w_err = fcntl(perr[1], F_DUPFD, 10);
        int w_ex = fcntl(pexec[1], F_DUPFD, 10);
        if (r_in < 0 || w_out < 0 || w_err < 0 || w_ex < 0) _exit(127);

        if (dup2(r_in, 0) < 0 || dup2(w_out, 1) < 0 || dup2(w_err, 2) < 0 || dup2(w_ex, 3) < 0)
            _exit(127);
        if (fcntl(3, F_SETFD, FD_CLOEXEC) != 0) _exit(127);

        int closed_range = 0;
#if defined(__linux__) && defined(SYS_close_range)
        if (syscall(SYS_close_range, 4U, ~0U, 0U) == 0) closed_range = 1;
#endif
        if (!closed_range) {
            for (int fd = 4; fd <= maxfd; fd++) close(fd);
        }

        signal(SIGPIPE, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);

        execve(exe, argv, envp);
        int e = errno;
        ssize_t w = write(3, &e, sizeof e);
        (void)w;
        _exit(127);
    }
    if (g_mcp_fork_mu) pthread_mutex_unlock(g_mcp_fork_mu);

    free(exe);
    free_strv(argv);
    free_strv(envp);

    if (pin[0] >= 0) close(pin[0]);
    if (pout[1] >= 0) close(pout[1]);
    if (perr[1] >= 0) close(perr[1]);
    if (pexec[1] >= 0) close(pexec[1]);

    if (pid < 0) {
        if (pin[1] >= 0) close(pin[1]);
        if (pout[0] >= 0) close(pout[0]);
        if (perr[0] >= 0) close(perr[0]);
        if (pexec[0] >= 0) close(pexec[0]);
        if (err) *err = mfmt("failed to spawn server '%s': %s", srv->name, strerror(saved_errno));
        return -1;
    }

    (void)fcntl(pexec[0], F_SETFL, O_NONBLOCK);
    int child_err = 0;
    size_t got = 0;
    int exec_failed = 0;
    for (;;) {
        if (cancelled && atomic_load_explicit(cancelled, memory_order_acquire)) {
            exec_failed = 1;
            if (err) *err = strdup("cancelled while starting server");
            break;
        }
        long long rem = deadline_ms > 0 ? (deadline_ms - mono_ms()) : 5000LL;
        if (rem <= 0) {
            exec_failed = 1;
            if (err) *err = mfmt("timed out spawning server '%s'", srv->name);
            break;
        }
        struct pollfd pfd = { .fd = pexec[0], .events = POLLIN, .revents = 0 };
        int pr = poll(&pfd, 1, rem > 100 ? 100 : (int)rem);
        if (pr < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (pr == 0) continue;
        ssize_t n = read(pexec[0], ((char *)&child_err) + got, sizeof child_err - got);
        if (n > 0) {
            got += (size_t)n;
            if (got >= sizeof child_err) {
                exec_failed = 1;
                if (err) *err = mfmt("failed to exec server '%s': %s", srv->name, strerror(child_err));
                break;
            }
        } else if (n == 0) {
            break; /* FD_CLOEXEC closed pexec[1] on successful execve! */
        } else if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
            break;
        }
    }
    close(pexec[0]);

    if (exec_failed) {
        close(pin[1]);
        close(pout[0]);
        close(perr[0]);
        reap_child_process(pid, 50);
        return -1;
    }

    (void)fcntl(pin[1], F_SETFL, O_NONBLOCK);
    (void)fcntl(pout[0], F_SETFL, O_NONBLOCK);
    (void)fcntl(perr[0], F_SETFL, O_NONBLOCK);

    out->pid = pid;
    out->stdin_fd = pin[1];
    out->stdout_fd = pout[0];
    out->stderr_fd = perr[0];
    return 0;
}

/* ---- Budgeted nonblocking pipe write ---- */

static int write_all_pipe(int fd, const char *data, size_t len, long long deadline_ms,
                          const atomic_int *cancelled, int *got_epipe, char **err) {
    if (got_epipe) *got_epipe = 0;
    size_t off = 0;
    while (off < len) {
        if (cancelled && atomic_load_explicit(cancelled, memory_order_acquire)) {
            if (err) *err = strdup("cancelled");
            return -2;
        }
        int slice = 100;
        if (deadline_ms > 0) {
            long long rem = deadline_ms - mono_ms();
            if (rem <= 0) {
                if (err) *err = strdup("timed out writing to tool server");
                return -3;
            }
            if (rem < slice) slice = (int)rem;
        }
        ssize_t n = write(fd, data + off, len - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                struct pollfd pfd = { .fd = fd, .events = POLLOUT, .revents = 0 };
                int pr = poll(&pfd, 1, slice);
                if (pr < 0 && errno != EINTR) {
                    if (err) *err = mfmt("poll write error: %s", strerror(errno));
                    return -1;
                }
                if (pr > 0 && (pfd.revents & (POLLERR | POLLHUP | POLLNVAL))) {
                    if (got_epipe) *got_epipe = 1;
                    if (err) *err = strdup("server crashed");
                    return -4;
                }
                continue;
            }
            if (errno == EPIPE || errno == ECONNRESET) {
                if (got_epipe) *got_epipe = 1;
                if (err) *err = strdup("server crashed");
                return -4;
            }
            if (err) *err = mfmt("write to tool server failed: %s", strerror(errno));
            return -1;
        }
        if (n == 0) {
            if (err) *err = strdup("short write to tool server");
            return -1;
        }
        off += (size_t)n;
    }
    return 0;
}

/* ---- Tool catalog normalization & class mapping ---- */

struct live_tool {
    char *name;
    char *description;
    enum code_class base_class;
    json_object *input_schema; /* owned ref */
};

static void free_live_tools(struct live_tool *tools, size_t n) {
    if (!tools) return;
    for (size_t i = 0; i < n; i++) {
        free(tools[i].name);
        free(tools[i].description);
        if (tools[i].input_schema) json_object_put(tools[i].input_schema);
    }
    free(tools);
}

static const char *class_str(enum code_class c) {
    if (c == CODE_READ) return "read";
    if (c == CODE_WRITE) return "write";
    return "destructive";
}

/* Fail closed: destructiveHint:true -> destructive (EVEN under trust=none & even if readOnlyHint:true);
 * trust=none ignores readOnlyHint only (non-destructive tools become write);
 * otherwise readOnlyHint:true -> read, else write. */
static enum code_class assign_tool_class(json_object *raw_tool, const char *trust) {
    int destructive = 0, readonly = 0;
    json_object *ann = NULL;
    if (raw_tool && json_object_object_get_ex(raw_tool, "annotations", &ann) &&
        ann && json_object_is_type(ann, json_type_object)) {
        json_object *jd = NULL, *jr = NULL;
        if (json_object_object_get_ex(ann, "destructiveHint", &jd) &&
            jd && json_object_is_type(jd, json_type_boolean) && json_object_get_boolean(jd)) {
            destructive = 1;
        }
        if (json_object_object_get_ex(ann, "readOnlyHint", &jr) &&
            jr && json_object_is_type(jr, json_type_boolean) && json_object_get_boolean(jr)) {
            readonly = 1;
        }
    }
    if (destructive) return CODE_DESTRUCTIVE;
    if (!trust || strcmp(trust, "none") == 0) return CODE_WRITE;
    if (readonly) return CODE_READ;
    return CODE_WRITE;
}

/* A tool name safe to print and to quote: 1..128 bytes, no control characters (<0x20, 0x7f). */
static int code_tool_name_ok(const char *name) {
    size_t n = 0;
    for (const unsigned char *c = (const unsigned char *)name; *c; c++, n++)
        if (*c < 0x20 || *c == 0x7f) return 0;
    return n >= 1 && n <= 128;
}

/* Normalize raw MCP tools array into stored JSON array string + optional live_tool array. */
static int normalize_tools_array(json_object *raw_arr, const char *trust,
                                 char **tools_json_out, struct live_tool **live_out, size_t *nlive_out) {
    size_t raw_n = raw_arr ? json_object_array_length(raw_arr) : 0;
    json_object *norm = json_object_new_array();
    struct live_tool *lt = raw_n ? calloc(raw_n, sizeof *lt) : NULL;
    size_t nl = 0;

    for (size_t i = 0; i < raw_n; i++) {
        json_object *t = json_object_array_get_idx(raw_arr, i);
        if (!t || !json_object_is_type(t, json_type_object)) continue;
        json_object *jn = NULL, *jd = NULL, *js = NULL;
        if (!json_object_object_get_ex(t, "name", &jn) || !jn || !json_object_is_type(jn, json_type_string))
            continue;
        const char *name = json_object_get_string(jn);
        if (!name || !code_tool_name_ok(name)) continue;   /* hostile names never reach catalogs, grants or prose */

        const char *desc = "";
        if (json_object_object_get_ex(t, "description", &jd) && jd && json_object_is_type(jd, json_type_string))
            desc = json_object_get_string(jd);

        json_object *schema = NULL;
        if (json_object_object_get_ex(t, "inputSchema", &js) && js && json_object_is_type(js, json_type_object)) {
            schema = json_object_get(js);
        } else {
            schema = json_object_new_object();
            json_object_object_add(schema, "type", json_object_new_string("object"));
        }

        enum code_class cls = assign_tool_class(t, trust);

        json_object *nt = json_object_new_object();
        json_object_object_add(nt, "name", json_object_new_string(name));
        json_object_object_add(nt, "description", json_object_new_string(desc ? desc : ""));
        json_object_object_add(nt, "class", json_object_new_string(class_str(cls)));
        json_object_object_add(nt, "inputSchema", json_object_get(schema));
        json_object_array_add(norm, nt);

        if (lt) {
            lt[nl].name = strdup(name);
            lt[nl].description = strdup(desc ? desc : "");
            lt[nl].base_class = cls;
            lt[nl].input_schema = schema; /* takes ownership of ref */
            nl++;
        } else {
            json_object_put(schema);
        }
    }

    if (tools_json_out) {
        const char *s = json_object_to_json_string_ext(norm, JSON_C_TO_STRING_PLAIN);
        *tools_json_out = strdup(s ? s : "[]");
    }
    json_object_put(norm);

    if (live_out && nlive_out) {
        *live_out = lt;
        *nlive_out = nl;
    } else {
        free_live_tools(lt, nl);
    }
    return 0;
}

/* ---- Helper: extract integer JSON-RPC "id" from prefix/tail of an oversized line ---- */

static int extract_jsonrpc_id_from_text(const char *s, size_t len, int64_t *id_out) {
    if (!s || len < 6) return 0;
    for (size_t i = 0; i + 4 < len; i++) {
        if (s[i] == '"' && s[i + 1] == 'i' && s[i + 2] == 'd' && s[i + 3] == '"') {
            size_t j = i + 4;
            while (j < len && (s[j] == ' ' || s[j] == '\t')) j++;
            if (j >= len || s[j] != ':') continue;
            j++;
            while (j < len && (s[j] == ' ' || s[j] == '\t')) j++;
            if (j >= len || !isdigit((unsigned char)s[j])) continue;
            int64_t v = 0;
            while (j < len && isdigit((unsigned char)s[j])) {
                if (v > (INT64_MAX - 9) / 10) return 0;
                v = v * 10 + (s[j] - '0');
                j++;
            }
            if (j < len && (s[j] == ',' || s[j] == '}' || s[j] == ' ' || s[j] == '\t' || s[j] == '\r' || s[j] == '\n')) {
                *id_out = v;
                return 1;
            }
        }
    }
    return 0;
}

/* ---- Helper: unwrap MCP tools/call response ---- */

static int is_valid_json_text(const char *text, size_t len) {
    if (!text || len == 0 || len > (size_t)INT_MAX) return 0;
    struct json_tokener *tok = json_tokener_new();
    if (!tok) return 0;
    json_object *obj = json_tokener_parse_ex(tok, text, (int)len);
    enum json_tokener_error jerr = json_tokener_get_error(tok);
    size_t consumed = (size_t)json_tokener_get_parse_end(tok);
    json_tokener_free(tok);
    if (!obj || jerr != json_tokener_success) {
        if (obj) json_object_put(obj);
        return 0;
    }
    json_object_put(obj);
    while (consumed < len && isspace((unsigned char)text[consumed])) consumed++;
    return consumed == len;
}

static void unwrap_mcp_call_response(json_object *msg, enum code_call_status *status_out,
                                     char **payload_out, int *is_json_out) {
    *status_out = CODE_CALL_ERROR;
    *payload_out = NULL;
    *is_json_out = 0;

    json_object *jerr = NULL;
    if (json_object_object_get_ex(msg, "error", &jerr) && jerr && !json_object_is_type(jerr, json_type_null)) {
        json_object *jm = NULL;
        if (json_object_is_type(jerr, json_type_object) &&
            json_object_object_get_ex(jerr, "message", &jm) && jm && json_object_is_type(jm, json_type_string)) {
            *payload_out = strdup(json_object_get_string(jm));
        } else {
            const char *s = json_object_to_json_string_ext(jerr, JSON_C_TO_STRING_PLAIN);
            *payload_out = strdup(s ? s : "MCP tool error");
        }
        return;
    }

    json_object *jres = NULL;
    if (!json_object_object_get_ex(msg, "result", &jres) || !jres || !json_object_is_type(jres, json_type_object)) {
        *payload_out = strdup("malformed MCP tools/call response");
        return;
    }

    int is_err = 0;
    json_object *jie = NULL;
    if (json_object_object_get_ex(jres, "isError", &jie) && jie &&
        json_object_is_type(jie, json_type_boolean) && json_object_get_boolean(jie)) {
        is_err = 1;
    }

    json_object *jsc = NULL;
    if (!is_err && json_object_object_get_ex(jres, "structuredContent", &jsc) &&
        jsc && !json_object_is_type(jsc, json_type_null)) {
        const char *s = json_object_to_json_string_ext(jsc, JSON_C_TO_STRING_PLAIN);
        *status_out = CODE_CALL_OK;
        *payload_out = strdup(s ? s : "null");
        *is_json_out = 1;
        return;
    }

    json_object *jcont = NULL;
    if (json_object_object_get_ex(jres, "content", &jcont) &&
        jcont && json_object_is_type(jcont, json_type_array) && json_object_array_length(jcont) > 0) {
        json_object *c0 = json_object_array_get_idx(jcont, 0);
        json_object *jtype = NULL, *jtext = NULL;
        if (c0 && json_object_is_type(c0, json_type_object) &&
            json_object_object_get_ex(c0, "type", &jtype) && jtype &&
            json_object_is_type(jtype, json_type_string) &&
            strcmp(json_object_get_string(jtype), "text") == 0 &&
            json_object_object_get_ex(c0, "text", &jtext) && jtext &&
            json_object_is_type(jtext, json_type_string)) {
            const char *txt = json_object_get_string(jtext);
            size_t tlen = (size_t)json_object_get_string_len(jtext);
            *payload_out = malloc(tlen + 1);
            if (!*payload_out) abort();
            memcpy(*payload_out, txt, tlen);
            (*payload_out)[tlen] = '\0';
            if (is_err) {
                *status_out = CODE_CALL_ERROR;
                *is_json_out = 0;
            } else {
                *status_out = CODE_CALL_OK;
                *is_json_out = is_valid_json_text(*payload_out, tlen);
            }
            return;
        }
    }

    const char *s = json_object_to_json_string_ext(jres, JSON_C_TO_STRING_PLAIN);
    *status_out = is_err ? CODE_CALL_ERROR : CODE_CALL_OK;
    *payload_out = strdup(s ? s : (is_err ? "tool returned isError" : "{}"));
    *is_json_out = is_err ? 0 : 1;
}

/* ---- One-shot direct stdio probe (no daemon) ---- */

static json_object *make_srv_request_reply(json_object *jid, const char *method) {
    json_object *rep = json_object_new_object();
    json_object_object_add(rep, "jsonrpc", json_object_new_string("2.0"));
    json_object_object_add(rep, "id", json_object_get(jid));
    if (method && strcmp(method, "ping") == 0) {
        json_object_object_add(rep, "result", json_object_new_object());
    } else {
        json_object *je = json_object_new_object();
        json_object_object_add(je, "code", json_object_new_int(-32601));
        json_object_object_add(je, "message", json_object_new_string("method not found"));
        json_object_object_add(rep, "error", je);
    }
    return rep;
}

static int probe_send_json(int stdin_fd, json_object *obj, long long deadline_ms, char **err);

static int probe_read_response(int stdin_fd, int stdout_fd, int stderr_fd, int64_t want_id,
                               long long deadline_ms, size_t line_cap,
                               char **lbuf, size_t *llen, size_t *lcap,
                               json_object **resp_out, char **err) {
    *resp_out = NULL;
    int err_open = (stderr_fd >= 0);
    int srv_replies_sent = 0;
    for (;;) {
        /* Scan buffered lines first. */
        while (*llen > 0) {
            char *nl = memchr(*lbuf, '\n', *llen);
            if (!nl) break;
            size_t n = (size_t)(nl - *lbuf);
            size_t clean = (n > 0 && (*lbuf)[n - 1] == '\r') ? n - 1 : n;
            char *line = malloc(clean + 1);
            if (!line) abort();
            memcpy(line, *lbuf, clean);
            line[clean] = '\0';
            size_t rem = *llen - (n + 1);
            if (rem > 0) memmove(*lbuf, nl + 1, rem);
            *llen = rem;

            json_object *msg = json_tokener_parse(line);
            free(line);
            if (!msg || !json_object_is_type(msg, json_type_object)) {
                if (msg) json_object_put(msg);
                continue; /* ignore non-JSON banner lines */
            }
            json_object *jid = NULL, *jmeth = NULL;
            int has_method = json_object_object_get_ex(msg, "method", &jmeth) && jmeth &&
                             json_object_is_type(jmeth, json_type_string);
            int has_req_id = json_object_object_get_ex(msg, "id", &jid) && jid &&
                             (json_object_is_type(jid, json_type_int) ||
                              json_object_is_type(jid, json_type_double) ||
                              json_object_is_type(jid, json_type_string));
            if (has_method) {
                if (has_req_id && stdin_fd >= 0 && srv_replies_sent < MCP_MAX_PENDING_SRV_REPLIES) {
                    json_object *rep = make_srv_request_reply(jid, json_object_get_string(jmeth));
                    const char *rs = json_object_to_json_string_ext(rep, JSON_C_TO_STRING_PLAIN);
                    if (rs && strlen(rs) + 1 <= MCP_MAX_SRV_REPLY_BYTES) {
                        (void)probe_send_json(stdin_fd, rep, deadline_ms, NULL);
                        srv_replies_sent++;
                    }
                    json_object_put(rep);
                }
                json_object_put(msg);
                continue;
            }
            if (jid && (json_object_is_type(jid, json_type_int) || json_object_is_type(jid, json_type_double)) &&
                json_object_get_int64(jid) == want_id) {
                *resp_out = msg;
                return 0;
            }
            json_object_put(msg);
        }
        if (*llen >= line_cap) {
            if (err) *err = strdup("MCP response exceeds line limit");
            return -1;
        }
        long long rem_ms = deadline_ms - mono_ms();
        if (rem_ms <= 0) {
            if (err) *err = strdup("MCP probe timed out");
            return -1;
        }
        struct pollfd pf[2];
        int nfds = 0;
        pf[nfds].fd = stdout_fd;
        pf[nfds].events = POLLIN;
        pf[nfds].revents = 0;
        nfds++;
        int err_idx = -1;
        if (err_open) {
            err_idx = nfds;
            pf[nfds].fd = stderr_fd;
            pf[nfds].events = POLLIN;
            pf[nfds].revents = 0;
            nfds++;
        }
        int pr = poll(pf, (nfds_t)nfds, rem_ms > 100 ? 100 : (int)rem_ms);
        if (pr < 0) {
            if (errno == EINTR) continue;
            if (err) *err = mfmt("poll error: %s", strerror(errno));
            return -1;
        }
        if (pr == 0) continue;
        if (err_idx >= 0 && (pf[err_idx].revents & (POLLIN | POLLHUP | POLLERR))) {
            char drain[4096];
            ssize_t en = read(stderr_fd, drain, sizeof drain);
            if (en == 0 || (en < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK))
                err_open = 0;
        }
        if (pf[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            if (*lcap - *llen < 4096) {
                size_t nc = *lcap ? (*lcap * 2) : 8192;
                if (nc > line_cap + 1) nc = line_cap + 1;
                if (nc <= *llen) {
                    if (err) *err = strdup("MCP response exceeds line limit");
                    return -1;
                }
                char *nb = realloc(*lbuf, nc);
                if (!nb) abort();
                *lbuf = nb;
                *lcap = nc;
            }
            ssize_t rn = read(stdout_fd, *lbuf + *llen, *lcap - *llen);
            if (rn < 0) {
                if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
                if (err) *err = mfmt("read error from tool server: %s", strerror(errno));
                return -1;
            }
            if (rn == 0) {
                if (err) *err = strdup("tool server closed stdout during probe");
                return -1;
            }
            *llen += (size_t)rn;
        }
    }
}

static int probe_send_json(int stdin_fd, json_object *obj, long long deadline_ms, char **err) {
    const char *s = json_object_to_json_string_ext(obj, JSON_C_TO_STRING_PLAIN);
    if (!s) {
        if (err) *err = strdup("failed to serialize JSON-RPC request");
        return -1;
    }
    size_t slen = strlen(s);
    char *buf = malloc(slen + 1);
    if (!buf) abort();
    memcpy(buf, s, slen);
    buf[slen] = '\n';
    int rc = write_all_pipe(stdin_fd, buf, slen + 1, deadline_ms, NULL, NULL, err);
    free(buf);
    return rc == 0 ? 0 : -1;
}

static json_object *make_init_req(int64_t id) {
    json_object *req = json_object_new_object();
    json_object_object_add(req, "jsonrpc", json_object_new_string("2.0"));
    json_object_object_add(req, "id", json_object_new_int64(id));
    json_object_object_add(req, "method", json_object_new_string("initialize"));
    json_object *params = json_object_new_object();
    json_object_object_add(params, "protocolVersion", json_object_new_string(MCP_PROTOCOL_VERSION));
    json_object_object_add(params, "capabilities", json_object_new_object());
    json_object *ci = json_object_new_object();
    json_object_object_add(ci, "name", json_object_new_string("cntctr"));
    json_object_object_add(ci, "version", json_object_new_string(g_mcp_version));
    json_object_object_add(params, "clientInfo", ci);
    json_object_object_add(req, "params", params);
    return req;
}

static json_object *make_initialized_notif(void) {
    json_object *req = json_object_new_object();
    json_object_object_add(req, "jsonrpc", json_object_new_string("2.0"));
    json_object_object_add(req, "method", json_object_new_string("notifications/initialized"));
    return req;
}

static json_object *make_tools_list_req(int64_t id, const char *cursor) {
    json_object *req = json_object_new_object();
    json_object_object_add(req, "jsonrpc", json_object_new_string("2.0"));
    json_object_object_add(req, "id", json_object_new_int64(id));
    json_object_object_add(req, "method", json_object_new_string("tools/list"));
    json_object *params = json_object_new_object();
    if (cursor && *cursor) json_object_object_add(params, "cursor", json_object_new_string(cursor));
    json_object_object_add(req, "params", params);
    return req;
}

static int validate_init_resp(json_object *resp, char **err) {
    json_object *je = NULL, *jr = NULL, *jpv = NULL;
    if (json_object_object_get_ex(resp, "error", &je) && je && !json_object_is_type(je, json_type_null)) {
        json_object *jm = NULL;
        const char *m = (json_object_is_type(je, json_type_object) &&
                         json_object_object_get_ex(je, "message", &jm) && jm && json_object_is_type(jm, json_type_string))
                            ? json_object_get_string(jm)
                            : "initialize rejected";
        if (err) *err = mfmt("MCP initialize error: %s", m);
        return -1;
    }
    if (!json_object_object_get_ex(resp, "result", &jr) || !jr || !json_object_is_type(jr, json_type_object)) {
        if (err) *err = strdup("MCP initialize returned invalid result");
        return -1;
    }
    if (!json_object_object_get_ex(jr, "protocolVersion", &jpv) || !jpv ||
        !json_object_is_type(jpv, json_type_string) || !*json_object_get_string(jpv)) {
        if (err) *err = strdup("MCP initialize missing protocolVersion");
        return -1;
    }
    const char *pv = json_object_get_string(jpv);
    int supported = 0;
    for (size_t i = 0; MCP_SUPPORTED_PROTOCOLS[i]; i++) {
        if (strcmp(pv, MCP_SUPPORTED_PROTOCOLS[i]) == 0) {
            supported = 1;
            break;
        }
    }
    if (!supported) {
        if (err) *err = mfmt("MCP initialize returned unsupported protocolVersion '%s'", pv);
        return -1;
    }
    return 0;
}

int code_mcp_probe_server(sqlite3 *db, const struct code_server_row *srv, const char *project,
                          int timeout_sec, long long *meta_gen_out, char **err) {
    if (meta_gen_out) *meta_gen_out = 0;
    if (err) *err = NULL;
    if (!db || !srv || !srv->reg_id[0]) {
        if (err) *err = strdup("invalid server probe arguments");
        return -1;
    }
    if (timeout_sec <= 0) timeout_sec = 30;
    long long dl = mono_ms() + (long long)timeout_sec * 1000LL;
    const char *owner = code_owner_project(srv, project);

    struct spawned_proc sp;
    if (spawn_mcp_process(srv, owner, dl, NULL, &sp, err) != 0) return -1;

    char *lbuf = NULL;
    size_t llen = 0, lcap = 0;
    const size_t max_line = 16 * 1024 * 1024;
    int rc = -1;
    json_object *accum = json_object_new_array();
    int64_t next_id = 1;

    /* 1. initialize */
    json_object *ireq = make_init_req(next_id++);
    int s = probe_send_json(sp.stdin_fd, ireq, dl, err);
    json_object_put(ireq);
    if (s != 0) goto done;

    json_object *iresp = NULL;
    if (probe_read_response(sp.stdin_fd, sp.stdout_fd, sp.stderr_fd, 1, dl, max_line, &lbuf, &llen, &lcap, &iresp, err) != 0)
        goto done;
    int v = validate_init_resp(iresp, err);
    json_object_put(iresp);
    if (v != 0) goto done;

    /* 2. notifications/initialized */
    json_object *nreq = make_initialized_notif();
    s = probe_send_json(sp.stdin_fd, nreq, dl, err);
    json_object_put(nreq);
    if (s != 0) goto done;

    /* 3. paginated tools/list (max 64 pages) */
    char *cursor = NULL;
    for (int page = 0; page < MCP_MAX_LIST_PAGES; page++) {
        int64_t rid = next_id++;
        json_object *lreq = make_tools_list_req(rid, cursor);
        free(cursor);
        cursor = NULL;
        s = probe_send_json(sp.stdin_fd, lreq, dl, err);
        json_object_put(lreq);
        if (s != 0) goto done;

        json_object *lresp = NULL;
        if (probe_read_response(sp.stdin_fd, sp.stdout_fd, sp.stderr_fd, rid, dl, max_line, &lbuf, &llen, &lcap, &lresp, err) != 0)
            goto done;
        json_object *je = NULL, *jr = NULL, *jt = NULL, *jnc = NULL;
        if (json_object_object_get_ex(lresp, "error", &je) && je && !json_object_is_type(je, json_type_null)) {
            if (err) *err = strdup("MCP tools/list returned error");
            json_object_put(lresp);
            goto done;
        }
        if (!json_object_object_get_ex(lresp, "result", &jr) || !jr || !json_object_is_type(jr, json_type_object) ||
            !json_object_object_get_ex(jr, "tools", &jt) || !jt || !json_object_is_type(jt, json_type_array)) {
            if (err) *err = strdup("MCP tools/list returned invalid tools array");
            json_object_put(lresp);
            goto done;
        }
        size_t tn = json_object_array_length(jt);
        for (size_t i = 0; i < tn; i++) {
            json_object_array_add(accum, json_object_get(json_object_array_get_idx(jt, i)));
        }
        if (json_object_object_get_ex(jr, "nextCursor", &jnc) && jnc && json_object_is_type(jnc, json_type_string)) {
            const char *nc = json_object_get_string(jnc);
            if (nc && *nc) cursor = strdup(nc);
        }
        json_object_put(lresp);
        if (!cursor) break;
        if (page == MCP_MAX_LIST_PAGES - 1) {
            free(cursor);
            if (err) *err = strdup("MCP tools/list exceeded 64 pages");
            goto done;
        }
    }

    char *tools_json = NULL;
    normalize_tools_array(accum, srv->trust, &tools_json, NULL, NULL);
    long long gen = 0;
    if (kb_code_catalog_set(db, srv->reg_id, owner, tools_json, &gen) != 0) {
        if (err) *err = strdup("failed to persist discovered catalog");
        free(tools_json);
        goto done;
    }
    free(tools_json);
    if (meta_gen_out) *meta_gen_out = gen;
    rc = 0;

done:
    json_object_put(accum);
    free(lbuf);
    close(sp.stdin_fd);
    close(sp.stdout_fd);
    close(sp.stderr_fd);
    reap_child_process(sp.pid, 200);
    return rc;
}

/* ============================================================================
 * Daemon Pool: intake workers -> per-instance control thread + reader thread
 * ============================================================================ */

enum inst_state {
    INST_DOWN = 0,
    INST_STARTING = 1,
    INST_RUNNING = 2,
    INST_STOPPING = 3
};

struct crash_record {
    char reg_id[64];
    char owner_project[PATH_MAX];
    char server_name[64];
    time_t stamps[MCP_CRASH_LIMIT];
    int count;
    int tripped;
    struct crash_record *next;
};

struct call_job {
    char *project;
    char *server;
    char *expected_reg_id;
    long long expected_meta_gen;
    char *tool;
    json_object *args_owned;
    long long deadline_mono_ms;
    struct code_call_handle *h;
    atomic_int cancelled;
    int completed;
    struct call_job *next_intake;
    struct call_job *next_active;
};

struct discover_req {
    char *project;
    long long deadline_mono_ms;
    pthread_mutex_t mu;
    pthread_cond_t cv;
    int done;
    int rc;
    char *tools_json;
    long long meta_gen;
    char *err;
};

struct stop_req {
    pthread_mutex_t mu;
    pthread_cond_t cv;
    int done;
};

enum ctrl_item_kind {
    CTRL_CALL = 1,
    CTRL_DISCOVER = 2,
    CTRL_REFRESH = 3,
    CTRL_STOP = 4,
    CTRL_REAP = 5
};

struct ctrl_item {
    enum ctrl_item_kind kind;
    struct call_job *call;
    struct discover_req *disc;
    struct stop_req *stop;
    struct ctrl_item *next;
};

struct pending_rpc {
    int64_t id;
    struct code_call_handle *h;
    struct pending_rpc *next;
};

struct ctrl_waiter {
    int active;
    int64_t id;
    int done;
    json_object *resp;
    char *err;
};

struct seen_proj {
    char *project;
    struct seen_proj *next;
};

struct srv_reply {
    char *wire;
    size_t len;
    struct srv_reply *next;
};

struct mcp_instance {
    struct code_pool *pool;
    struct code_server_row srv;
    char owner_project[PATH_MAX];

    /* Protected by pool->mu: */
    int refcount;
    enum inst_state state;
    int inflight_calls;
    int ctrl_busy;
    long long last_used_mono_ms;
    time_t last_used_epoch;
    struct mcp_instance *next;

    /* Protected by inst->mu (strictly inner to pool->mu): */
    pthread_mutex_t mu;
    pthread_cond_t ctrl_cv;
    pthread_cond_t ctrl_wait_cv;

    pid_t pid;
    int stdin_fd;
    int stdout_fd;
    int stderr_fd;
    int stop_pipe[2];
    int stopping;
    int64_t next_rpc_id;

    pthread_t ctrl_tid;
    int ctrl_running;
    int ctrl_joinable;
    int ctrl_exit;

    pthread_t reader_tid;
    int reader_running;
    int reader_joinable;

    struct ctrl_item *ctrl_head;
    struct ctrl_item *ctrl_tail;
    int refresh_queued;
    int refresh_dirty;
    int refresh_fails; /* consecutive failed refreshes; reset on success/teardown */

    struct srv_reply *reply_head;
    struct srv_reply *reply_tail;
    int reply_count;

    struct pending_rpc *pending;
    struct ctrl_waiter waiter;

    struct live_tool *live_tools;
    size_t nlive_tools;
    long long meta_gen;

    struct seen_proj *seen_projects;
};

struct code_pool {
    char db_path[PATH_MAX];
    int max_servers;
    int idle_sec;
    int call_sec;
    size_t line_cap_bytes;
    size_t daemon_queue_bytes;

    pthread_mutex_t mu;
    pthread_cond_t intake_cv;
    int shutting_down;

    size_t queued_reply_bytes;

    struct mcp_instance *instances;
    struct crash_record *crashes;

    struct call_job *intake_head;
    struct call_job *intake_tail;
    struct call_job *active_jobs;

    pthread_t intake_tids[MCP_INTAKE_WORKERS];
    int n_intake_threads;
};

/* ---- Forward declarations ---- */
static void *inst_ctrl_thread(void *arg);
static void *inst_reader_thread(void *arg);
static void *intake_worker_thread(void *arg);

/* ---- Crash breaker helpers (caller holds p->mu) ---- */

static struct crash_record *find_crash_rec_locked(struct code_pool *p, const char *reg_id,
                                                  const char *owner_project, const char *srv_name, int create) {
    for (struct crash_record *c = p->crashes; c; c = c->next) {
        if (strcmp(c->reg_id, reg_id) == 0 && strcmp(c->owner_project, owner_project) == 0)
            return c;
    }
    if (!create) return NULL;
    struct crash_record *c = calloc(1, sizeof *c);
    if (!c) abort();
    snprintf(c->reg_id, sizeof c->reg_id, "%s", reg_id);
    snprintf(c->owner_project, sizeof c->owner_project, "%s", owner_project);
    if (srv_name) snprintf(c->server_name, sizeof c->server_name, "%s", srv_name);
    c->next = p->crashes;
    p->crashes = c;
    return c;
}

static void record_crash_locked(struct code_pool *p, const struct mcp_instance *inst) {
    struct crash_record *c = find_crash_rec_locked(p, inst->srv.reg_id, inst->owner_project, inst->srv.name, 1);
    time_t now = time(NULL);
    int keep = 0;
    for (int i = 0; i < c->count; i++) {
        if (now - c->stamps[i] <= MCP_CRASH_WINDOW_SEC) c->stamps[keep++] = c->stamps[i];
    }
    if (keep < MCP_CRASH_LIMIT) {
        c->stamps[keep++] = now;
    } else {
        memmove(&c->stamps[0], &c->stamps[1], (MCP_CRASH_LIMIT - 1) * sizeof(time_t));
        c->stamps[MCP_CRASH_LIMIT - 1] = now;
    }
    c->count = keep;
    if (c->count >= MCP_CRASH_LIMIT) c->tripped = 1;
}

static int is_breaker_open_locked(struct code_pool *p, const struct mcp_instance *inst) {
    struct crash_record *c = find_crash_rec_locked(p, inst->srv.reg_id, inst->owner_project, NULL, 0);
    if (!c) return 0;
    if (c->tripped) return 1;
    time_t now = time(NULL);
    int recent = 0;
    for (int i = 0; i < c->count; i++) {
        if (now - c->stamps[i] <= MCP_CRASH_WINDOW_SEC) recent++;
    }
    if (recent >= MCP_CRASH_LIMIT) {
        c->tripped = 1;
        return 1;
    }
    return 0;
}

/* ---- Active job tracking & teardown ---- */

static void free_call_job(struct call_job *j) {
    if (!j) return;
    free(j->project);
    free(j->server);
    free(j->expected_reg_id);
    free(j->tool);
    if (j->args_owned) json_object_put(j->args_owned);
    if (j->h) code_call_handle_unref(j->h);
    free(j);
}

static void unregister_active_job(struct code_pool *p, struct call_job *j) {
    pthread_mutex_lock(&p->mu);
    struct call_job **pp = &p->active_jobs;
    while (*pp) {
        if (*pp == j) {
            *pp = j->next_active;
            j->next_active = NULL;
            break;
        }
        pp = &(*pp)->next_active;
    }
    pthread_mutex_unlock(&p->mu);
}

static void finish_call_job(struct code_pool *p, struct call_job *j, enum code_call_status st,
                            const char *msg, int is_json, const char *grant_cmd) {
    unregister_active_job(p, j);
    if (j->h && !atomic_load_explicit(&j->cancelled, memory_order_acquire)) {
        code_js_complete(j->h, st, msg, is_json, grant_cmd);
    }
    free_call_job(j);
}

/* ---- Instance refcounting & lifecycle ---- */

static void free_srv_replies(struct srv_reply *list) {
    while (list) {
        struct srv_reply *nx = list->next;
        free(list->wire);
        free(list);
        list = nx;
    }
}

static void inst_destroy(struct mcp_instance *inst) {
    if (!inst) return;
    kb_code_server_free(&inst->srv);
    free_live_tools(inst->live_tools, inst->nlive_tools);
    free_srv_replies(inst->reply_head);
    inst->reply_head = inst->reply_tail = NULL;
    inst->reply_count = 0;
    while (inst->seen_projects) {
        struct seen_proj *sp = inst->seen_projects;
        inst->seen_projects = sp->next;
        free(sp->project);
        free(sp);
    }
    if (inst->stdin_fd >= 0) close(inst->stdin_fd);
    if (inst->stdout_fd >= 0) close(inst->stdout_fd);
    if (inst->stderr_fd >= 0) close(inst->stderr_fd);
    if (inst->stop_pipe[0] >= 0) close(inst->stop_pipe[0]);
    if (inst->stop_pipe[1] >= 0) close(inst->stop_pipe[1]);
    if (inst->waiter.resp) json_object_put(inst->waiter.resp);
    free(inst->waiter.err);
    pthread_cond_destroy(&inst->ctrl_wait_cv);
    pthread_cond_destroy(&inst->ctrl_cv);
    pthread_mutex_destroy(&inst->mu);
    free(inst);
}

static void inst_unref(struct code_pool *p, struct mcp_instance *inst) {
    if (!inst) return;
    pthread_mutex_lock(&p->mu);
    int last = (--inst->refcount == 0);
    pthread_mutex_unlock(&p->mu);
    if (last) inst_destroy(inst);
}

static void inst_record_seen_project(struct mcp_instance *inst, const char *project) {
    if (!project || !*project) return;
    pthread_mutex_lock(&inst->mu);
    for (struct seen_proj *sp = inst->seen_projects; sp; sp = sp->next) {
        if (strcmp(sp->project, project) == 0) {
            pthread_mutex_unlock(&inst->mu);
            return;
        }
    }
    struct seen_proj *sp = malloc(sizeof *sp);
    if (!sp) abort();
    sp->project = strdup(project);
    sp->next = inst->seen_projects;
    inst->seen_projects = sp;
    pthread_mutex_unlock(&inst->mu);
}

static void inst_enqueue_ctrl(struct mcp_instance *inst, struct ctrl_item *it) {
    it->next = NULL;
    pthread_mutex_lock(&inst->mu);
    if (it->kind == CTRL_REFRESH) {
        inst->refresh_dirty = 1;
        if (inst->refresh_queued) {
            pthread_mutex_unlock(&inst->mu);
            free(it);
            return;
        }
        inst->refresh_queued = 1;
    }
    if (it->kind == CTRL_STOP) {
        it->next = inst->ctrl_head;
        inst->ctrl_head = it;
        if (!inst->ctrl_tail) inst->ctrl_tail = it;
    } else {
        if (inst->ctrl_tail) inst->ctrl_tail->next = it;
        else inst->ctrl_head = it;
        inst->ctrl_tail = it;
    }
    pthread_cond_broadcast(&inst->ctrl_cv);
    pthread_mutex_unlock(&inst->mu);
}

static void inst_enqueue_srv_reply(struct code_pool *p, struct mcp_instance *inst,
                                   json_object *jid, const char *method) {
    json_object *rep = make_srv_request_reply(jid, method);
    const char *s = json_object_to_json_string_ext(rep, JSON_C_TO_STRING_PLAIN);
    size_t slen = s ? strlen(s) : 0;
    size_t max_wire = p->line_cap_bytes < MCP_MAX_SRV_REPLY_BYTES ? p->line_cap_bytes : MCP_MAX_SRV_REPLY_BYTES;
    if (!s || slen + 1 > max_wire) {
        json_object_put(rep);
        return;
    }
    char *wire = malloc(slen + 1);
    if (!wire) abort();
    memcpy(wire, s, slen);
    wire[slen] = '\n';
    json_object_put(rep);

    struct srv_reply *sr = calloc(1, sizeof *sr);
    if (!sr) abort();
    sr->wire = wire;
    sr->len = slen + 1;

    int queued = 0;
    pthread_mutex_lock(&inst->mu);
    if (!inst->stopping && !inst->ctrl_exit && inst->stdin_fd >= 0 &&
        inst->reply_count < MCP_MAX_PENDING_SRV_REPLIES) {
        if (inst->reply_tail) inst->reply_tail->next = sr;
        else inst->reply_head = sr;
        inst->reply_tail = sr;
        inst->reply_count++;
        pthread_cond_broadcast(&inst->ctrl_cv);
        pthread_cond_broadcast(&inst->ctrl_wait_cv);
        queued = 1;
    }
    pthread_mutex_unlock(&inst->mu);

    if (!queued) {
        free(sr->wire);
        free(sr);
    }
}

/* Called ONLY on inst->ctrl_thread so all writes to inst->stdin_fd remain strictly serialized. */
static void inst_drain_srv_replies(struct mcp_instance *inst, long long max_deadline_ms,
                                   const atomic_int *cancelled) {
    for (;;) {
        struct srv_reply *sr = NULL;
        struct srv_reply *drop_all = NULL;
        int sfd = -1;
        pthread_mutex_lock(&inst->mu);
        if (inst->stopping || inst->ctrl_exit || inst->stdin_fd < 0) {
            drop_all = inst->reply_head;
            inst->reply_head = inst->reply_tail = NULL;
            inst->reply_count = 0;
        } else if (inst->reply_head) {
            sr = inst->reply_head;
            inst->reply_head = sr->next;
            if (!inst->reply_head) inst->reply_tail = NULL;
            if (inst->reply_count > 0) inst->reply_count--;
            sfd = inst->stdin_fd;
        }
        pthread_mutex_unlock(&inst->mu);
        if (drop_all) {
            free_srv_replies(drop_all);
            break;
        }
        if (!sr) break;

        long long dl = mono_ms() + MCP_SRV_REPLY_WRITE_MS;
        if (max_deadline_ms > 0 && max_deadline_ms < dl) dl = max_deadline_ms;
        int epipe = 0;
        int wrc = write_all_pipe(sfd, sr->wire, sr->len, dl, cancelled, &epipe, NULL);
        free(sr->wire);
        free(sr);
        if (wrc != 0) {
            /* Drop remaining stale replies if pipe broke or timed out so callers cannot spin. */
            pthread_mutex_lock(&inst->mu);
            drop_all = inst->reply_head;
            inst->reply_head = inst->reply_tail = NULL;
            inst->reply_count = 0;
            pthread_mutex_unlock(&inst->mu);
            free_srv_replies(drop_all);
            break;
        }
    }
}

/* Ensure inst->ctrl_thread is running. Caller holds p->mu; may temporarily unlock/re-lock? No, pthread_create is fast. */
static int inst_ensure_ctrl_thread_locked(struct code_pool *p, struct mcp_instance *inst) {
    pthread_mutex_lock(&inst->mu);
    if (inst->ctrl_running) {
        pthread_mutex_unlock(&inst->mu);
        return 0;
    }
    inst->ctrl_exit = 0;
    inst->ctrl_running = 1;
    inst->ctrl_joinable = 1;
    inst->refcount++;
    pthread_mutex_unlock(&inst->mu);

    if (pthread_create(&inst->ctrl_tid, NULL, inst_ctrl_thread, inst) != 0) {
        pthread_mutex_lock(&inst->mu);
        inst->ctrl_running = 0;
        inst->ctrl_joinable = 0;
        pthread_mutex_unlock(&inst->mu);
        inst->refcount--;
        (void)p;
        return -1;
    }
    return 0;
}

/* Lookup or create instance for (srv->reg_id, owner_project). Returns refcounted inst (caller unrefs). */
static struct mcp_instance *pool_get_or_create_inst(struct code_pool *p, const struct code_server_row *srv,
                                                    const char *owner_project) {
    pthread_mutex_lock(&p->mu);
    if (p->shutting_down) {
        pthread_mutex_unlock(&p->mu);
        return NULL;
    }
    for (struct mcp_instance *it = p->instances; it; it = it->next) {
        if (strcmp(it->srv.reg_id, srv->reg_id) == 0 && strcmp(it->owner_project, owner_project) == 0) {
            it->refcount++;
            if (inst_ensure_ctrl_thread_locked(p, it) != 0) {
                it->refcount--;
                pthread_mutex_unlock(&p->mu);
                return NULL;
            }
            pthread_mutex_unlock(&p->mu);
            return it;
        }
    }
    struct mcp_instance *inst = calloc(1, sizeof *inst);
    if (!inst) abort();
    inst->pool = p;
    server_row_copy(&inst->srv, srv);
    snprintf(inst->owner_project, sizeof inst->owner_project, "%s", owner_project ? owner_project : "");
    inst->refcount = 2; /* 1 for pool->instances + 1 for caller */
    inst->state = INST_DOWN;
    inst->pid = -1;
    inst->stdin_fd = inst->stdout_fd = inst->stderr_fd = -1;
    inst->stop_pipe[0] = inst->stop_pipe[1] = -1;
    inst->next_rpc_id = 1;
    pthread_mutex_init(&inst->mu, NULL);
    cond_init_mono(&inst->ctrl_cv);
    cond_init_mono(&inst->ctrl_wait_cv);

    inst->next = p->instances;
    p->instances = inst;
    if (inst_ensure_ctrl_thread_locked(p, inst) != 0) {
        /* Leave in list with refcount 1; caller fails. */
        inst->refcount--;
        pthread_mutex_unlock(&p->mu);
        return NULL;
    }
    pthread_mutex_unlock(&p->mu);
    return inst;
}

/* ---- Child process teardown (called ONLY on inst->ctrl_thread!) ---- */

static void inst_teardown_proc(struct code_pool *p, struct mcp_instance *inst, int intentional) {
    int had_reader = 0;
    pthread_t rtid;
    pid_t pid = -1;
    int sfd = -1;
    int wpipe = -1;

    pthread_mutex_lock(&inst->mu);
    if (intentional) inst->stopping = 1;
    pid = inst->pid;
    inst->pid = -1;
    sfd = inst->stdin_fd;
    inst->stdin_fd = -1;
    wpipe = inst->stop_pipe[1];
    had_reader = inst->reader_joinable;
    rtid = inst->reader_tid;
    inst->reader_joinable = 0;
    pthread_mutex_unlock(&inst->mu);

    if (sfd >= 0) close(sfd);
    if (wpipe >= 0) {
        char b = 'x';
        ssize_t n = write(wpipe, &b, 1);
        (void)n;
    }
    if (pid > 0) {
        reap_child_process(pid, intentional ? 250 : 50);
    }
    if (had_reader) {
        pthread_join(rtid, NULL);
    }

    /* Fail any leftover pending calls (normally reader already drained them). */
    struct pending_rpc *leftover = NULL;
    struct srv_reply *leftover_replies = NULL;
    int dropped = 0;
    pthread_mutex_lock(&inst->mu);
    leftover = inst->pending;
    inst->pending = NULL;
    leftover_replies = inst->reply_head;
    inst->reply_head = inst->reply_tail = NULL;
    inst->reply_count = 0;
    inst->refresh_dirty = 0;
    inst->refresh_fails = 0;
    for (struct pending_rpc *pr = leftover; pr; pr = pr->next) dropped++;
    if (inst->stop_pipe[0] >= 0) { close(inst->stop_pipe[0]); inst->stop_pipe[0] = -1; }
    if (inst->stop_pipe[1] >= 0) { close(inst->stop_pipe[1]); inst->stop_pipe[1] = -1; }
    if (inst->stdout_fd >= 0) { close(inst->stdout_fd); inst->stdout_fd = -1; }
    if (inst->stderr_fd >= 0) { close(inst->stderr_fd); inst->stderr_fd = -1; }
    inst->stopping = 0;
    while (inst->seen_projects) {
        struct seen_proj *sp = inst->seen_projects;
        inst->seen_projects = sp->next;
        free(sp->project);
        free(sp);
    }
    pthread_mutex_unlock(&inst->mu);
    free_srv_replies(leftover_replies);

    pthread_mutex_lock(&p->mu);
    if (dropped > 0) {
        if (inst->inflight_calls >= dropped) inst->inflight_calls -= dropped;
        else inst->inflight_calls = 0;
    }
    inst->state = INST_DOWN;
    pthread_mutex_unlock(&p->mu);

    while (leftover) {
        struct pending_rpc *nx = leftover->next;
        if (leftover->h) {
            code_js_complete(leftover->h, CODE_CALL_ERROR, intentional ? "server stopped" : "server crashed", 0, NULL);
            code_call_handle_unref(leftover->h);
        }
        free(leftover);
        leftover = nx;
    }
}

/* Synchronous stop of an instance from any external thread (LRU eviction, idle tick, restart, reload). */
static void inst_stop_sync(struct code_pool *p, struct mcp_instance *inst) {
    struct stop_req sr;
    memset(&sr, 0, sizeof sr);
    pthread_mutex_init(&sr.mu, NULL);
    cond_init_mono(&sr.cv);

    pthread_mutex_lock(&p->mu);
    int running = 0;
    pthread_mutex_lock(&inst->mu);
    running = inst->ctrl_running;
    pthread_mutex_unlock(&inst->mu);
    if (!running) {
        pthread_mutex_unlock(&p->mu);
        pthread_cond_destroy(&sr.cv);
        pthread_mutex_destroy(&sr.mu);
        return;
    }
    pthread_mutex_unlock(&p->mu);

    struct ctrl_item *it = calloc(1, sizeof *it);
    if (!it) abort();
    it->kind = CTRL_STOP;
    it->stop = &sr;
    inst_enqueue_ctrl(inst, it);

    pthread_mutex_lock(&sr.mu);
    while (!sr.done) cond_wait_ms(&sr.cv, &sr.mu, 100);
    pthread_mutex_unlock(&sr.mu);

    pthread_cond_destroy(&sr.cv);
    pthread_mutex_destroy(&sr.mu);
}

/* ---- Control-thread synchronous RPC (used for initialize & tools/list; reader delivers reply) ---- */

static int inst_ctrl_rpc(struct mcp_instance *inst, json_object *req, int64_t id,
                         long long deadline_ms, const atomic_int *cancelled,
                         json_object **resp_out, char **err) {
    *resp_out = NULL;
    if (err) *err = NULL;

    const char *s = json_object_to_json_string_ext(req, JSON_C_TO_STRING_PLAIN);
    if (!s) {
        if (err) *err = strdup("failed to serialize JSON-RPC request");
        return -1;
    }
    size_t slen = strlen(s);
    if (slen + 1 > inst->pool->line_cap_bytes) {
        if (err) *err = strdup("outbound MCP request exceeds line limit");
        return -1;
    }
    char *wire = malloc(slen + 1);
    if (!wire) abort();
    memcpy(wire, s, slen);
    wire[slen] = '\n';

    pthread_mutex_lock(&inst->mu);
    int sfd = inst->stdin_fd;
    if (sfd < 0 || inst->stopping) {
        pthread_mutex_unlock(&inst->mu);
        free(wire);
        if (err) *err = strdup("server not running");
        return -1;
    }
    if (inst->waiter.resp) { json_object_put(inst->waiter.resp); inst->waiter.resp = NULL; }
    free(inst->waiter.err);
    inst->waiter.err = NULL;
    inst->waiter.active = 1;
    inst->waiter.id = id;
    inst->waiter.done = 0;
    pthread_mutex_unlock(&inst->mu);

    int epipe = 0;
    int wrc = write_all_pipe(sfd, wire, slen + 1, deadline_ms, cancelled, &epipe, err);
    free(wire);
    if (wrc != 0) {
        pthread_mutex_lock(&inst->mu);
        inst->waiter.active = 0;
        if (inst->waiter.resp) { json_object_put(inst->waiter.resp); inst->waiter.resp = NULL; }
        free(inst->waiter.err);
        inst->waiter.err = NULL;
        pthread_mutex_unlock(&inst->mu);
        return -1;
    }

    pthread_mutex_lock(&inst->mu);
    for (;;) {
        if (inst->waiter.done) {
            *resp_out = inst->waiter.resp;
            inst->waiter.resp = NULL;
            char *werr = inst->waiter.err;
            inst->waiter.err = NULL;
            inst->waiter.active = 0;
            pthread_mutex_unlock(&inst->mu);
            if (!*resp_out) {
                if (err) *err = werr ? werr : strdup("server crashed");
                else free(werr);
                return -1;
            }
            free(werr);
            return 0;
        }
        if (cancelled && atomic_load_explicit(cancelled, memory_order_acquire)) {
            inst->waiter.active = 0;
            pthread_mutex_unlock(&inst->mu);
            if (err) *err = strdup("cancelled");
            return -2;
        }
        if (inst->ctrl_exit || inst->stopping) {
            inst->waiter.active = 0;
            pthread_mutex_unlock(&inst->mu);
            if (err) *err = strdup("server stopped");
            return -1;
        }
        if (inst->reply_head) {
            pthread_mutex_unlock(&inst->mu);
            inst_drain_srv_replies(inst, deadline_ms, cancelled);
            pthread_mutex_lock(&inst->mu);
            continue;
        }
        long long rem = deadline_ms - mono_ms();
        if (rem <= 0) {
            inst->waiter.active = 0;
            pthread_mutex_unlock(&inst->mu);
            if (err) *err = strdup("MCP request timed out");
            return -3;
        }
        cond_wait_ms(&inst->ctrl_wait_cv, &inst->mu, rem > 50 ? 50 : (int)rem);
    }
}

/* Run paginated tools/list on a running instance, update inst->live_tools and persist code_catalogs. */
static int inst_refresh_catalog(struct code_pool *p, struct mcp_instance *inst,
                                long long deadline_ms, const atomic_int *cancelled,
                                char **tools_json_out, long long *meta_gen_out, char **err) {
    if (tools_json_out) *tools_json_out = NULL;
    if (meta_gen_out) *meta_gen_out = 0;
    if (err) *err = NULL;

    json_object *accum = json_object_new_array();
    char *cursor = NULL;
    int rc = -1;

    for (int page = 0; page < MCP_MAX_LIST_PAGES; page++) {
        pthread_mutex_lock(&inst->mu);
        int64_t rid = inst->next_rpc_id++;
        pthread_mutex_unlock(&inst->mu);

        json_object *lreq = make_tools_list_req(rid, cursor);
        free(cursor);
        cursor = NULL;
        json_object *lresp = NULL;
        int r = inst_ctrl_rpc(inst, lreq, rid, deadline_ms, cancelled, &lresp, err);
        json_object_put(lreq);
        if (r != 0) goto done;

        json_object *je = NULL, *jr = NULL, *jt = NULL, *jnc = NULL;
        if (json_object_object_get_ex(lresp, "error", &je) && je && !json_object_is_type(je, json_type_null)) {
            json_object *jm = NULL;
            const char *em = (json_object_is_type(je, json_type_object) &&
                              json_object_object_get_ex(je, "message", &jm) && jm && json_object_is_type(jm, json_type_string))
                                 ? json_object_get_string(jm)
                                 : "tools/list error";
            if (err) *err = mfmt("MCP tools/list failed: %s", em);
            json_object_put(lresp);
            goto done;
        }
        if (!json_object_object_get_ex(lresp, "result", &jr) || !jr || !json_object_is_type(jr, json_type_object) ||
            !json_object_object_get_ex(jr, "tools", &jt) || !jt || !json_object_is_type(jt, json_type_array)) {
            if (err) *err = strdup("MCP tools/list returned invalid tools array");
            json_object_put(lresp);
            goto done;
        }
        size_t tn = json_object_array_length(jt);
        for (size_t i = 0; i < tn; i++) {
            json_object_array_add(accum, json_object_get(json_object_array_get_idx(jt, i)));
        }
        if (json_object_object_get_ex(jr, "nextCursor", &jnc) && jnc && json_object_is_type(jnc, json_type_string)) {
            const char *nc = json_object_get_string(jnc);
            if (nc && *nc) cursor = strdup(nc);
        }
        json_object_put(lresp);
        if (!cursor) break;
        if (page == MCP_MAX_LIST_PAGES - 1) {
            free(cursor);
            if (err) *err = strdup("MCP tools/list exceeded 64 pages");
            goto done;
        }
    }

    char *tools_json = NULL;
    struct live_tool *new_lt = NULL;
    size_t new_n = 0;
    normalize_tools_array(accum, inst->srv.trust, &tools_json, &new_lt, &new_n);

    struct db_deadline_ctx dctx = { deadline_ms, cancelled };
    sqlite3 *db = open_db_deadline(p->db_path, &dctx, err);
    if (!db) {
        free(tools_json);
        free_live_tools(new_lt, new_n);
        goto done;
    }
    long long gen = 0;
    int sc = kb_code_catalog_set(db, inst->srv.reg_id, inst->owner_project, tools_json, &gen);
    sqlite3_close(db);
    if (sc != 0) {
        free(tools_json);
        free_live_tools(new_lt, new_n);
        if (err) *err = strdup("failed to persist tool catalog");
        goto done;
    }

    pthread_mutex_lock(&inst->mu);
    struct live_tool *old_lt = inst->live_tools;
    size_t old_n = inst->nlive_tools;
    inst->live_tools = new_lt;
    inst->nlive_tools = new_n;
    inst->meta_gen = gen;
    inst->refresh_fails = 0;
    pthread_mutex_unlock(&inst->mu);
    free_live_tools(old_lt, old_n);

    if (tools_json_out) *tools_json_out = tools_json;
    else free(tools_json);
    if (meta_gen_out) *meta_gen_out = gen;
    rc = 0;

done:
    json_object_put(accum);
    return rc;
}

/* A refresh failed: the instance stays stale (dirty) so no call is sent on old metadata until a
 * refresh succeeds. Returns 1 once the retry budget is spent: the caller must fail the instance
 * closed (tear down; the next call restarts it and re-reads the catalog). */
static int inst_refresh_failed(struct mcp_instance *inst, int counts) {
    pthread_mutex_lock(&inst->mu);
    inst->refresh_dirty = 1;
    int spent = counts && ++inst->refresh_fails >= MCP_REFRESH_RETRY_BUDGET;
    pthread_mutex_unlock(&inst->mu);
    return spent;
}

/* Start child process + reader thread + MCP initialize + notifications/initialized + paginated tools/list.
 * Enforces crash circuit breaker and CNTCTR_CODE_MAX_SERVERS cap + LRU idle eviction.
 * Called ONLY on inst->ctrl_thread! */
static int inst_ensure_started(struct code_pool *p, struct mcp_instance *inst,
                               long long deadline_ms, const atomic_int *cancelled,
                               char **tools_json_out, long long *meta_gen_out, char **err) {
    if (tools_json_out) *tools_json_out = NULL;
    if (meta_gen_out) *meta_gen_out = 0;
    if (err) *err = NULL;

    /* Clean up any previously crashed/dead or stopping process before checking state. */
    pthread_mutex_lock(&p->mu);
    enum inst_state cur_state = inst->state;
    pthread_mutex_unlock(&p->mu);
    if (cur_state == INST_DOWN || cur_state == INST_STOPPING) {
        int need_reap = (cur_state == INST_STOPPING);
        pthread_mutex_lock(&inst->mu);
        if (inst->reader_joinable || inst->pid > 0 || inst->stdin_fd >= 0) need_reap = 1;
        pthread_mutex_unlock(&inst->mu);
        if (need_reap) inst_teardown_proc(p, inst, cur_state == INST_STOPPING);
    }

    /* Loop in case we need to evict an LRU idle server before claiming a slot. */
    for (;;) {
        if (cancelled && atomic_load_explicit(cancelled, memory_order_acquire)) {
            if (err) *err = strdup("cancelled");
            return -2;
        }
        if (mono_ms() >= deadline_ms) {
            if (err) *err = strdup("timed out starting tool server");
            return -3;
        }

        struct mcp_instance *victim = NULL;
        pthread_mutex_lock(&p->mu);
        if (p->shutting_down) {
            pthread_mutex_unlock(&p->mu);
            if (err) *err = strdup("daemon shutting down");
            return -1;
        }
        if (inst->state == INST_RUNNING) {
            inst->last_used_mono_ms = mono_ms();
            inst->last_used_epoch = time(NULL);
            pthread_mutex_unlock(&p->mu);
            return 0;
        }
        if (is_breaker_open_locked(p, inst)) {
            pthread_mutex_unlock(&p->mu);
            if (err) *err = mfmt("server '%s' stayed down after 3 crashes in 5 minutes; restart to reset",
                                 inst->srv.name);
            return -1;
        }

        int live_cnt = 0;
        long long oldest_ms = LLONG_MAX;
        for (struct mcp_instance *it = p->instances; it; it = it->next) {
            if (it == inst) continue;
            if (it->state == INST_STARTING || it->state == INST_RUNNING || it->state == INST_STOPPING) {
                live_cnt++;
                if (it->state == INST_RUNNING && it->inflight_calls == 0 && !it->ctrl_busy) {
                    if (it->last_used_mono_ms < oldest_ms) {
                        oldest_ms = it->last_used_mono_ms;
                        victim = it;
                    }
                }
            }
        }

        if (live_cnt < p->max_servers) {
            inst->state = INST_STARTING;
            inst->last_used_mono_ms = mono_ms();
            inst->last_used_epoch = time(NULL);
            pthread_mutex_unlock(&p->mu);
            break;
        }

        if (!victim) {
            pthread_mutex_unlock(&p->mu);
            if (err) *err = mfmt("server cap reached (%d/%d servers busy; raise CNTCTR_CODE_MAX_SERVERS)",
                                 live_cnt, p->max_servers);
            return -1;
        }
        victim->state = INST_STOPPING;
        victim->refcount++;
        pthread_mutex_unlock(&p->mu);

        inst_stop_sync(p, victim);
        inst_unref(p, victim);
    }

    /* Slot reserved (state == INST_STARTING). Spawn process + start reader thread. */
    int spipe[2] = {-1, -1};
    if (pipe(spipe) != 0) {
        pthread_mutex_lock(&p->mu);
        inst->state = INST_DOWN;
        pthread_mutex_unlock(&p->mu);
        if (err) *err = mfmt("pipe failed: %s", strerror(errno));
        return -1;
    }
    (void)fcntl(spipe[0], F_SETFD, FD_CLOEXEC);
    (void)fcntl(spipe[1], F_SETFD, FD_CLOEXEC);
    (void)fcntl(spipe[0], F_SETFL, O_NONBLOCK);
    (void)fcntl(spipe[1], F_SETFL, O_NONBLOCK);

    struct spawned_proc sp;
    if (spawn_mcp_process(&inst->srv, inst->owner_project, deadline_ms, cancelled, &sp, err) != 0) {
        close(spipe[0]);
        close(spipe[1]);
        pthread_mutex_lock(&p->mu);
        inst->state = INST_DOWN;
        pthread_mutex_unlock(&p->mu);
        return -1;
    }

    pthread_mutex_lock(&p->mu);
    pthread_mutex_lock(&inst->mu);
    inst->pid = sp.pid;
    inst->stdin_fd = sp.stdin_fd;
    inst->stdout_fd = sp.stdout_fd;
    inst->stderr_fd = sp.stderr_fd;
    inst->stop_pipe[0] = spipe[0];
    inst->stop_pipe[1] = spipe[1];
    inst->stopping = 0;
    inst->next_rpc_id = 1;
    inst->reader_running = 1;
    inst->reader_joinable = 1;
    inst->refcount++;
    pthread_mutex_unlock(&inst->mu);
    pthread_mutex_unlock(&p->mu);

    if (pthread_create(&inst->reader_tid, NULL, inst_reader_thread, inst) != 0) {
        pthread_mutex_lock(&p->mu);
        pthread_mutex_lock(&inst->mu);
        inst->reader_running = 0;
        inst->reader_joinable = 0;
        pthread_mutex_unlock(&inst->mu);
        inst->refcount--;
        pthread_mutex_unlock(&p->mu);
        inst_teardown_proc(p, inst, 1);
        if (err) *err = strdup("failed to spawn MCP reader thread");
        return -1;
    }

    /* 1. initialize */
    pthread_mutex_lock(&inst->mu);
    int64_t init_id = inst->next_rpc_id++;
    pthread_mutex_unlock(&inst->mu);
    json_object *ireq = make_init_req(init_id);
    json_object *iresp = NULL;
    int irc = inst_ctrl_rpc(inst, ireq, init_id, deadline_ms, cancelled, &iresp, err);
    json_object_put(ireq);
    if (irc != 0) {
        inst_teardown_proc(p, inst, 1);
        return irc;
    }
    int vrc = validate_init_resp(iresp, err);
    json_object_put(iresp);
    if (vrc != 0) {
        inst_teardown_proc(p, inst, 1);
        return -1;
    }

    /* 2. notifications/initialized */
    json_object *nreq = make_initialized_notif();
    const char *ns = json_object_to_json_string_ext(nreq, JSON_C_TO_STRING_PLAIN);
    size_t nlen = ns ? strlen(ns) : 0;
    char *nwire = malloc(nlen + 1);
    if (!nwire) abort();
    if (nlen) memcpy(nwire, ns, nlen);
    nwire[nlen] = '\n';
    json_object_put(nreq);

    pthread_mutex_lock(&inst->mu);
    int sfd = inst->stdin_fd;
    pthread_mutex_unlock(&inst->mu);
    int epipe = 0;
    int wrc = (sfd >= 0) ? write_all_pipe(sfd, nwire, nlen + 1, deadline_ms, cancelled, &epipe, err) : -1;
    free(nwire);
    if (wrc != 0) {
        inst_teardown_proc(p, inst, 1);
        return -1;
    }

    /* 3. paginated tools/list + persist code_catalogs */
    int rrc = inst_refresh_catalog(p, inst, deadline_ms, cancelled, tools_json_out, meta_gen_out, err);
    if (rrc != 0) {
        inst_teardown_proc(p, inst, 1);
        return rrc;
    }

    pthread_mutex_lock(&p->mu);
    if (inst->state == INST_STARTING) {
        inst->state = INST_RUNNING;
        inst->last_used_mono_ms = mono_ms();
        inst->last_used_epoch = time(NULL);
    }
    pthread_mutex_unlock(&p->mu);
    return 0;
}

/* ---- Reader thread (drains stdout + stderr continuously, enforces line_cap & daemon_queue_bytes) ---- */

static void reader_release_queue_bytes(struct code_pool *p, size_t *reserved) {
    if (*reserved == 0) return;
    pthread_mutex_lock(&p->mu);
    if (p->queued_reply_bytes >= *reserved) p->queued_reply_bytes -= *reserved;
    else p->queued_reply_bytes = 0;
    pthread_mutex_unlock(&p->mu);
    *reserved = 0;
}

static int reader_reserve_queue_bytes(struct code_pool *p, size_t *reserved, size_t add) {
    if (add == 0) return 0;
    pthread_mutex_lock(&p->mu);
    if (add > p->daemon_queue_bytes || p->queued_reply_bytes > p->daemon_queue_bytes - add) {
        pthread_mutex_unlock(&p->mu);
        return -1;
    }
    p->queued_reply_bytes += add;
    pthread_mutex_unlock(&p->mu);
    *reserved += add;
    return 0;
}

static void reader_fail_id(struct code_pool *p, struct mcp_instance *inst, int has_id, int64_t id, const char *reason) {
    struct code_call_handle *h = NULL;
    int woke_waiter = 0;

    pthread_mutex_lock(&p->mu);
    pthread_mutex_lock(&inst->mu);
    if (has_id && inst->waiter.active && inst->waiter.id == id && !inst->waiter.done) {
        inst->waiter.done = 1;
        free(inst->waiter.err);
        inst->waiter.err = strdup(reason);
        pthread_cond_broadcast(&inst->ctrl_wait_cv);
        woke_waiter = 1;
    }
    if (!woke_waiter) {
        struct pending_rpc **pp = &inst->pending;
        if (has_id) {
            while (*pp) {
                if ((*pp)->id == id) {
                    struct pending_rpc *cur = *pp;
                    *pp = cur->next;
                    h = cur->h;
                    free(cur);
                    if (inst->inflight_calls > 0) inst->inflight_calls--;
                    inst->last_used_mono_ms = mono_ms();
                    inst->last_used_epoch = time(NULL);
                    break;
                }
                pp = &(*pp)->next;
            }
        } else if (inst->pending && !inst->pending->next) {
            /* Only one pending call and oversized line had no parseable id: fail that call. */
            struct pending_rpc *cur = inst->pending;
            inst->pending = NULL;
            h = cur->h;
            free(cur);
            if (inst->inflight_calls > 0) inst->inflight_calls--;
            inst->last_used_mono_ms = mono_ms();
            inst->last_used_epoch = time(NULL);
        }
    }
    pthread_mutex_unlock(&inst->mu);
    pthread_mutex_unlock(&p->mu);

    if (h) {
        code_js_complete(h, CODE_CALL_ERROR, reason, 0, NULL);
        code_call_handle_unref(h);
    }
}

static void reader_handle_json_line(struct code_pool *p, struct mcp_instance *inst, const char *line) {
    json_object *msg = json_tokener_parse(line);
    if (!msg || !json_object_is_type(msg, json_type_object)) {
        if (msg) json_object_put(msg);
        return; /* ignore non-JSON banner lines */
    }

    json_object *jid = NULL, *jmeth = NULL;
    int has_method = json_object_object_get_ex(msg, "method", &jmeth) && jmeth &&
                     json_object_is_type(jmeth, json_type_string);
    int has_req_id = json_object_object_get_ex(msg, "id", &jid) && jid &&
                     (json_object_is_type(jid, json_type_int) ||
                      json_object_is_type(jid, json_type_double) ||
                      json_object_is_type(jid, json_type_string));

    if (has_method) {
        const char *meth = json_object_get_string(jmeth);
        if (has_req_id) {
            /* Server-initiated JSON-RPC request: reply via bounded serialized ctrl_thread queue. */
            inst_enqueue_srv_reply(p, inst, jid, meth);
        } else if (strcmp(meth, "notifications/tools/list_changed") == 0) {
            /* Server-initiated notification: refresh catalog on control queue. */
            struct ctrl_item *it = calloc(1, sizeof *it);
            if (it) {
                it->kind = CTRL_REFRESH;
                inst_enqueue_ctrl(inst, it);
            }
        }
        json_object_put(msg);
        return;
    }

    int has_id = jid && (json_object_is_type(jid, json_type_int) || json_object_is_type(jid, json_type_double));
    if (!has_id) {
        json_object_put(msg);
        return;
    }

    int64_t id = json_object_get_int64(jid);
    struct code_call_handle *h = NULL;
    int handed_to_waiter = 0;

    pthread_mutex_lock(&p->mu);
    pthread_mutex_lock(&inst->mu);
    if (inst->waiter.active && inst->waiter.id == id && !inst->waiter.done) {
        inst->waiter.resp = msg;
        inst->waiter.done = 1;
        pthread_cond_broadcast(&inst->ctrl_wait_cv);
        handed_to_waiter = 1;
    } else {
        struct pending_rpc **pp = &inst->pending;
        while (*pp) {
            if ((*pp)->id == id) {
                struct pending_rpc *cur = *pp;
                *pp = cur->next;
                h = cur->h;
                free(cur);
                if (inst->inflight_calls > 0) inst->inflight_calls--;
                inst->last_used_mono_ms = mono_ms();
                inst->last_used_epoch = time(NULL);
                break;
            }
            pp = &(*pp)->next;
        }
    }
    pthread_mutex_unlock(&inst->mu);
    pthread_mutex_unlock(&p->mu);

    if (handed_to_waiter) return;
    if (!h) {
        json_object_put(msg);
        return;
    }

    enum code_call_status st = CODE_CALL_ERROR;
    char *payload = NULL;
    int is_json = 0;
    unwrap_mcp_call_response(msg, &st, &payload, &is_json);
    json_object_put(msg);
    code_js_complete(h, st, payload ? payload : "", is_json, NULL);
    free(payload);
    code_call_handle_unref(h);
}

static void *inst_reader_thread(void *arg) {
    struct mcp_instance *inst = (struct mcp_instance *)arg;
    struct code_pool *p = inst->pool;

    pthread_mutex_lock(&inst->mu);
    int out_fd = inst->stdout_fd;
    int err_fd = inst->stderr_fd;
    int stop_fd = inst->stop_pipe[0];
    pthread_mutex_unlock(&inst->mu);

    int err_open = (err_fd >= 0);
    char *lbuf = NULL;
    size_t llen = 0, lcap = 0, reserved = 0;

    int discard_mode = 0;
    const char *discard_reason = NULL;
    char d_prefix[MCP_DISCARD_SNIP];
    size_t d_prefix_len = 0;
    char d_tail[MCP_DISCARD_SNIP];
    size_t d_tail_len = 0;

    char chunk[16384];
    int eof_or_stop = 0;

    while (!eof_or_stop) {
        struct pollfd pf[3];
        int nfds = 0;
        int idx_out = nfds++;
        pf[idx_out].fd = out_fd;
        pf[idx_out].events = POLLIN;
        pf[idx_out].revents = 0;

        int idx_stop = -1;
        if (stop_fd >= 0) {
            idx_stop = nfds++;
            pf[idx_stop].fd = stop_fd;
            pf[idx_stop].events = POLLIN;
            pf[idx_stop].revents = 0;
        }
        int idx_err = -1;
        if (err_open) {
            idx_err = nfds++;
            pf[idx_err].fd = err_fd;
            pf[idx_err].events = POLLIN;
            pf[idx_err].revents = 0;
        }

        int pr = poll(pf, (nfds_t)nfds, 250);
        if (pr < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (pr == 0) continue;

        if (idx_err >= 0 && (pf[idx_err].revents & (POLLIN | POLLHUP | POLLERR))) {
            char drain[4096];
            for (;;) {
                ssize_t en = read(err_fd, drain, sizeof drain);
                if (en > 0) continue;
                if (en == 0) { err_open = 0; break; }
                if (errno == EINTR) continue;
                if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                err_open = 0;
                break;
            }
        }

        if (idx_stop >= 0 && (pf[idx_stop].revents & (POLLIN | POLLHUP | POLLERR))) {
            eof_or_stop = 1;
            break;
        }

        if (pf[idx_out].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t rn = read(out_fd, chunk, sizeof chunk);
            if (rn < 0) {
                if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
                eof_or_stop = 1;
                break;
            }
            if (rn == 0) {
                eof_or_stop = 1;
                break;
            }

            size_t pos = 0, total = (size_t)rn;
            while (pos < total) {
                char *nl = memchr(chunk + pos, '\n', total - pos);
                size_t seg = nl ? (size_t)(nl - (chunk + pos)) : (total - pos);

                if (discard_mode) {
                    /* Keep rolling tail for id extraction if "id" sits after a huge payload. */
                    if (seg >= sizeof d_tail) {
                        memcpy(d_tail, chunk + pos + seg - sizeof d_tail, sizeof d_tail);
                        d_tail_len = sizeof d_tail;
                    } else if (seg > 0) {
                        if (d_tail_len + seg > sizeof d_tail) {
                            size_t keep = sizeof d_tail - seg;
                            memmove(d_tail, d_tail + (d_tail_len - keep), keep);
                            d_tail_len = keep;
                        }
                        memcpy(d_tail + d_tail_len, chunk + pos, seg);
                        d_tail_len += seg;
                    }
                    if (nl) {
                        int64_t id = 0;
                        int has_id = extract_jsonrpc_id_from_text(d_prefix, d_prefix_len, &id);
                        if (!has_id) has_id = extract_jsonrpc_id_from_text(d_tail, d_tail_len, &id);
                        reader_fail_id(p, inst, has_id, id,
                                       discard_reason ? discard_reason : "result too large");
                        discard_mode = 0;
                        discard_reason = NULL;
                        d_prefix_len = d_tail_len = 0;
                    }
                } else {
                    int over_line = (seg > p->line_cap_bytes || llen > p->line_cap_bytes - seg);
                    int over_queue = 0;
                    if (!over_line && reader_reserve_queue_bytes(p, &reserved, seg) != 0) {
                        over_queue = 1;
                    }
                    if (over_line || over_queue) {
                        discard_mode = 1;
                        discard_reason = over_line
                            ? "result too large (exceeds line limit)"
                            : "daemon reply queue cap exceeded (CNTCTR_CODE_DAEMON_QUEUE_BYTES)";
                        d_prefix_len = llen < sizeof d_prefix ? llen : sizeof d_prefix;
                        if (d_prefix_len > 0) memcpy(d_prefix, lbuf, d_prefix_len);
                        if (d_prefix_len < sizeof d_prefix && seg > 0) {
                            size_t take = sizeof d_prefix - d_prefix_len;
                            if (take > seg) take = seg;
                            memcpy(d_prefix + d_prefix_len, chunk + pos, take);
                            d_prefix_len += take;
                        }
                        d_tail_len = 0;
                        if (seg >= sizeof d_tail) {
                            memcpy(d_tail, chunk + pos + seg - sizeof d_tail, sizeof d_tail);
                            d_tail_len = sizeof d_tail;
                        } else if (seg > 0) {
                            memcpy(d_tail, chunk + pos, seg);
                            d_tail_len = seg;
                        }
                        llen = 0;
                        reader_release_queue_bytes(p, &reserved);
                        if (nl) {
                            int64_t id = 0;
                            int has_id = extract_jsonrpc_id_from_text(d_prefix, d_prefix_len, &id);
                            if (!has_id) has_id = extract_jsonrpc_id_from_text(d_tail, d_tail_len, &id);
                            reader_fail_id(p, inst, has_id, id, discard_reason);
                            discard_mode = 0;
                            discard_reason = NULL;
                            d_prefix_len = d_tail_len = 0;
                        }
                    } else {
                        if (llen + seg + 1 > lcap) {
                            size_t nc = lcap ? lcap * 2 : 4096;
                            while (nc < llen + seg + 1) nc *= 2;
                            if (nc > p->line_cap_bytes + 1) nc = p->line_cap_bytes + 1;
                            char *nb = realloc(lbuf, nc);
                            if (!nb) abort();
                            lbuf = nb;
                            lcap = nc;
                        }
                        if (seg > 0) memcpy(lbuf + llen, chunk + pos, seg);
                        llen += seg;
                        if (nl) {
                            size_t clean = (llen > 0 && lbuf[llen - 1] == '\r') ? llen - 1 : llen;
                            lbuf[clean] = '\0';
                            reader_handle_json_line(p, inst, lbuf);
                            llen = 0;
                            reader_release_queue_bytes(p, &reserved);
                            if (lcap > 65536) {
                                free(lbuf);
                                lbuf = NULL;
                                lcap = 0;
                            }
                        }
                    }
                }
                pos += seg + (nl ? 1 : 0);
            }
        }
    }

    reader_release_queue_bytes(p, &reserved);
    free(lbuf);

    /* Teardown on EOF/crash/stop: record crash if unexpected, fail all pending calls and ctrl waiter. */
    struct pending_rpc *all_pending = NULL;
    int dropped = 0;
    int was_stopping = 0;

    pthread_mutex_lock(&p->mu);
    pthread_mutex_lock(&inst->mu);
    was_stopping = inst->stopping || p->shutting_down || inst->state == INST_STOPPING;
    all_pending = inst->pending;
    inst->pending = NULL;
    for (struct pending_rpc *pr = all_pending; pr; pr = pr->next) dropped++;
    if (inst->waiter.active && !inst->waiter.done) {
        inst->waiter.done = 1;
        free(inst->waiter.err);
        inst->waiter.err = strdup(was_stopping ? "server stopped" : "server crashed");
        pthread_cond_broadcast(&inst->ctrl_wait_cv);
    }
    if (inst->stdout_fd >= 0) { close(inst->stdout_fd); inst->stdout_fd = -1; }
    if (inst->stderr_fd >= 0) { close(inst->stderr_fd); inst->stderr_fd = -1; }
    inst->reader_running = 0;
    pthread_mutex_unlock(&inst->mu);

    if (dropped > 0) {
        if (inst->inflight_calls >= dropped) inst->inflight_calls -= dropped;
        else inst->inflight_calls = 0;
    }
    if (!was_stopping) {
        record_crash_locked(p, inst);
        inst->state = INST_DOWN;
    }
    pthread_mutex_unlock(&p->mu);

    while (all_pending) {
        struct pending_rpc *nx = all_pending->next;
        if (all_pending->h) {
            code_js_complete(all_pending->h, CODE_CALL_ERROR,
                             was_stopping ? "server stopped" : "server crashed", 0, NULL);
            code_call_handle_unref(all_pending->h);
        }
        free(all_pending);
        all_pending = nx;
    }

    if (!was_stopping) {
        /* Promptly reap crashed child on ctrl_thread (no zombies). */
        struct ctrl_item *rit = calloc(1, sizeof *rit);
        if (rit) {
            rit->kind = CTRL_REAP;
            inst_enqueue_ctrl(inst, rit);
        }
    }

    inst_unref(p, inst);
    return NULL;
}

/* ---- Atomic live recheck + stdio tools/call dispatch (on inst->ctrl_thread) ---- */

struct schema_job_abort {
    long long deadline_ms;
    const atomic_int *cancelled;
};

static int schema_job_abort_cb(void *ctx) {
    struct schema_job_abort *a = (struct schema_job_abort *)ctx;
    if (a->cancelled && atomic_load_explicit(a->cancelled, memory_order_acquire)) return 1;
    if (a->deadline_ms > 0 && mono_ms() >= a->deadline_ms) return 1;
    return 0;
}

static void ctrl_handle_call(struct code_pool *p, struct mcp_instance *inst, struct call_job *job) {
    if (atomic_load_explicit(&job->cancelled, memory_order_acquire)) {
        finish_call_job(p, job, CODE_CALL_ERROR, "cancelled", 0, NULL);
        return;
    }
    if (mono_ms() >= job->deadline_mono_ms) {
        finish_call_job(p, job, CODE_CALL_ERROR, "call timed out before dispatch", 0, NULL);
        return;
    }

    /* 1. Ensure server instance is running & has its live catalog. */
    char *serr = NULL;
    int src = inst_ensure_started(p, inst, job->deadline_mono_ms, &job->cancelled, NULL, NULL, &serr);
    if (src != 0) {
        finish_call_job(p, job, CODE_CALL_ERROR, serr ? serr : "failed to start server", 0, NULL);
        free(serr);
        return;
    }

    /* 2. ATOMIC LIVE RECHECK: pending list_changed refresh + live registration + meta_gen +
     *    live catalog tool + live grant + live schema, BEFORE stdio write! */
    struct pending_rpc *pr = NULL;
    int64_t rid = 0;
    int sfd = -1;

    for (int attempt = 0; ; attempt++) {
        if (atomic_load_explicit(&job->cancelled, memory_order_acquire)) {
            finish_call_job(p, job, CODE_CALL_ERROR, "cancelled", 0, NULL);
            return;
        }
        if (mono_ms() >= job->deadline_mono_ms) {
            finish_call_job(p, job, CODE_CALL_ERROR, "call timed out", 0, NULL);
            return;
        }

        int need_refresh = 0;
        pthread_mutex_lock(&inst->mu);
        if (inst->refresh_dirty || inst->meta_gen == 0) {
            inst->refresh_dirty = 0;
            need_refresh = 1;
        }
        long long live_meta_gen = inst->meta_gen;
        pthread_mutex_unlock(&inst->mu);

        if (need_refresh) {
            char *rerr = NULL;
            int rrc = inst_refresh_catalog(p, inst, job->deadline_mono_ms, &job->cancelled, NULL, &live_meta_gen, &rerr);
            if (rrc != 0) {
                int spent = inst_refresh_failed(inst, !atomic_load_explicit(&job->cancelled, memory_order_acquire));
                char *emsg = mfmt("stale catalog: refresh failed%s: %s", spent ? "; server will restart on the next call" : "",
                                  rerr ? rerr : "unknown error");
                finish_call_job(p, job, CODE_CALL_ERROR, emsg, 0, NULL);
                free(emsg);
                free(rerr);
                if (spent) inst_teardown_proc(p, inst, 1);
                return;
            }
            free(rerr);
        }

        struct db_deadline_ctx dctx = { job->deadline_mono_ms, &job->cancelled };
        char *dberr = NULL;
        sqlite3 *db = open_db_deadline(p->db_path, &dctx, &dberr);
        if (!db) {
            finish_call_job(p, job, CODE_CALL_ERROR, dberr ? dberr : "database error during live recheck", 0, NULL);
            free(dberr);
            return;
        }

        struct code_server_row cur_srv;
        if (kb_code_server_get(db, job->project, job->server, &cur_srv) != 0) {
            sqlite3_close(db);
            finish_call_job(p, job, CODE_CALL_DENIED, "server registration no longer exists", 0, NULL);
            return;
        }
        int same_reg = (strcmp(cur_srv.reg_id, inst->srv.reg_id) == 0) &&
                       (!job->expected_reg_id[0] || strcmp(cur_srv.reg_id, job->expected_reg_id) == 0);
        kb_code_server_free(&cur_srv);
        if (!same_reg) {
            sqlite3_close(db);
            finish_call_job(p, job, CODE_CALL_DENIED, "server registration changed; rerun", 0, NULL);
            return;
        }

        /* Compare job->expected_meta_gen against the current live & persisted catalog meta_gen. */
        long long db_meta_gen = 0;
        int cat_rc = kb_code_catalog_get(db, inst->srv.reg_id, inst->owner_project, NULL, &db_meta_gen);
        if (cat_rc != 0 || db_meta_gen <= 0 || db_meta_gen != live_meta_gen ||
            (job->expected_meta_gen > 0 && job->expected_meta_gen > live_meta_gen)) {
            sqlite3_close(db);
            if (attempt >= 2) {
                finish_call_job(p, job, CODE_CALL_ERROR, "stale catalog: metadata generation mismatch; rerun", 0, NULL);
                return;
            }
            pthread_mutex_lock(&inst->mu);
            inst->refresh_dirty = 1;
            pthread_mutex_unlock(&inst->mu);
            continue;
        }

        int meta_stale = (job->expected_meta_gen == 0 || job->expected_meta_gen != live_meta_gen);

        /* Look up tool in inst->live_tools (ctrl_thread is the sole writer of live_tools!). */
        const struct live_tool *lt = NULL;
        for (size_t i = 0; i < inst->nlive_tools; i++) {
            if (strcmp(inst->live_tools[i].name, job->tool) == 0) {
                lt = &inst->live_tools[i];
                break;
            }
        }
        if (!lt) {
            sqlite3_close(db);
            const char **cands = inst->nlive_tools ? calloc(inst->nlive_tools, sizeof *cands) : NULL;
            for (size_t i = 0; i < inst->nlive_tools; i++) cands[i] = inst->live_tools[i].name;
            char *sug = code_suggest_names(job->tool, cands, inst->nlive_tools);
            free(cands);
            char *msg = sug ? mfmt("unknown tool %s.%s; did you mean: %s?", job->server, job->tool, sug)
                            : mfmt("unknown tool %s.%s", job->server, job->tool);
            free(sug);
            finish_call_job(p, job, CODE_CALL_ERROR, msg, 0, NULL);
            free(msg);
            return;
        }

        /* Live grant check against live base_class (catches class escalation on meta_gen change & mid-queue revocation). */
        enum code_class eff = lt->base_class;
        char *why = NULL;
        int grc = kb_code_check_grant(db, job->project, inst->srv.reg_id, job->tool, lt->base_class, &eff, &why);
        int user_scoped = grc != 0 && kb_code_reg_user_scoped(db, inst->srv.reg_id);
        sqlite3_close(db);
        if (grc != 0) {
            char *gcmd = build_grant_cmd(job->project, job->server, job->tool, eff, user_scoped);
            finish_call_job(p, job, CODE_CALL_DENIED, why ? why : "denied", 0, gcmd);
            free(why);
            free(gcmd);
            return;
        }
        free(why);

        /* Live schema validation on meta_gen mismatch or uncatalogued lazy discovery
         * (catches same-class schema changes on restart or list_changed before stdio write). */
        if (meta_stale && lt->input_schema) {
            struct schema_job_abort sactx = { job->deadline_mono_ms, &job->cancelled };
            struct code_schema_budget sb = { 10000, 0, 0, schema_job_abort_cb, &sactx };
            char *val_err = NULL;
            int vrc = code_schema_validate_budget(lt->input_schema, job->args_owned, &sb, &val_err);
            if (vrc < 0) {
                free(val_err);
                finish_call_job(p, job, CODE_CALL_ERROR,
                                atomic_load_explicit(&job->cancelled, memory_order_acquire) ? "cancelled" : "schema validation timed out",
                                0, NULL);
                return;
            }
            if (vrc != 0) {
                char *msg = mfmt("%s.%s invalid arguments: %s", job->server, job->tool,
                                 val_err ? val_err : "schema mismatch");
                free(val_err);
                finish_call_job(p, job, CODE_CALL_ERROR, msg, 0, NULL);
                free(msg);
                return;
            }
            free(val_err);
        }

        if (atomic_load_explicit(&job->cancelled, memory_order_acquire) || mono_ms() >= job->deadline_mono_ms) {
            finish_call_job(p, job, CODE_CALL_ERROR,
                            atomic_load_explicit(&job->cancelled, memory_order_acquire) ? "cancelled" : "call timed out",
                            0, NULL);
            return;
        }

        /* 3. Atomically verify no list_changed arrived mid-check & register pending RPC BEFORE stdio write. */
        pr = calloc(1, sizeof *pr);
        if (!pr) abort();

        pthread_mutex_lock(&p->mu);
        pthread_mutex_lock(&inst->mu);
        if (inst->refresh_dirty) {
            pthread_mutex_unlock(&inst->mu);
            pthread_mutex_unlock(&p->mu);
            free(pr);
            pr = NULL;
            if (attempt >= 2) {
                finish_call_job(p, job, CODE_CALL_ERROR, "stale catalog: tool list changed before send; rerun", 0, NULL);
                return;
            }
            continue;
        }
        if (inst->state != INST_RUNNING || inst->stdin_fd < 0 || inst->stopping) {
            pthread_mutex_unlock(&inst->mu);
            pthread_mutex_unlock(&p->mu);
            free(pr);
            finish_call_job(p, job, CODE_CALL_ERROR, "server crashed", 0, NULL);
            return;
        }
        rid = inst->next_rpc_id++;
        sfd = inst->stdin_fd;
        pr->id = rid;
        pr->h = job->h; /* transfer dispatcher ref from job to pending_rpc */
        job->h = NULL;
        pr->next = inst->pending;
        inst->pending = pr;
        inst->inflight_calls++;
        inst->last_used_mono_ms = mono_ms();
        inst->last_used_epoch = time(NULL);
        pthread_mutex_unlock(&inst->mu);
        pthread_mutex_unlock(&p->mu);
        break;
    }

    inst_record_seen_project(inst, job->project);

    /* Serialize tools/call JSON-RPC frame */
    json_object *req = json_object_new_object();
    json_object_object_add(req, "jsonrpc", json_object_new_string("2.0"));
    json_object_object_add(req, "id", json_object_new_int64(rid));
    json_object_object_add(req, "method", json_object_new_string("tools/call"));
    json_object *params = json_object_new_object();
    json_object_object_add(params, "name", json_object_new_string(job->tool));
    json_object_object_add(params, "arguments",
                           job->args_owned ? json_object_get(job->args_owned) : json_object_new_object());
    json_object_object_add(req, "params", params);

    const char *s = json_object_to_json_string_ext(req, JSON_C_TO_STRING_PLAIN);
    size_t slen = s ? strlen(s) : 0;
    int over = (!s || slen + 1 > p->line_cap_bytes);
    char *wire = NULL;
    if (!over) {
        wire = malloc(slen + 1);
        if (!wire) abort();
        memcpy(wire, s, slen);
        wire[slen] = '\n';
    }
    json_object_put(req);

    char *werr = NULL;
    int epipe = 0;
    int wrc = over ? -1 : write_all_pipe(sfd, wire, slen + 1, job->deadline_mono_ms, &job->cancelled, &epipe, &werr);
    free(wire);

    if (wrc != 0) {
        /* Try to reclaim pr from inst->pending (reader may have already removed & completed it on EOF). */
        struct code_call_handle *reclaimed = NULL;
        pthread_mutex_lock(&p->mu);
        pthread_mutex_lock(&inst->mu);
        struct pending_rpc **pp = &inst->pending;
        while (*pp) {
            if (*pp == pr) {
                *pp = pr->next;
                reclaimed = pr->h;
                free(pr);
                if (inst->inflight_calls > 0) inst->inflight_calls--;
                break;
            }
            pp = &(*pp)->next;
        }
        pthread_mutex_unlock(&inst->mu);
        pthread_mutex_unlock(&p->mu);

        if (reclaimed) {
            if (!atomic_load_explicit(&job->cancelled, memory_order_acquire)) {
                const char *emsg = over ? "outbound tool call exceeds line limit"
                                 : epipe ? "server crashed"
                                         : (werr ? werr : "write to server failed");
                code_js_complete(reclaimed, CODE_CALL_ERROR, emsg, 0, NULL);
            }
            code_call_handle_unref(reclaimed);
        }
        free(werr);
    }

    unregister_active_job(p, job);
    free_call_job(job);
}

/* ---- Per-instance control worker thread ---- */

static void *inst_ctrl_thread(void *arg) {
    struct mcp_instance *inst = (struct mcp_instance *)arg;
    struct code_pool *p = inst->pool;

    for (;;) {
        struct ctrl_item *it = NULL;
        int do_refresh = 1;
        pthread_mutex_lock(&inst->mu);
        while (!inst->ctrl_head && !inst->reply_head && !inst->ctrl_exit) {
            pthread_cond_wait(&inst->ctrl_cv, &inst->mu);
        }
        if (inst->reply_head && !(inst->ctrl_head && inst->ctrl_head->kind == CTRL_STOP)) {
            pthread_mutex_unlock(&inst->mu);
            pthread_mutex_lock(&p->mu);
            inst->ctrl_busy = 1;
            pthread_mutex_unlock(&p->mu);
            inst_drain_srv_replies(inst, 0, NULL);
            pthread_mutex_lock(&p->mu);
            inst->ctrl_busy = 0;
            pthread_mutex_unlock(&p->mu);
            continue;
        }
        if (inst->ctrl_head) {
            it = inst->ctrl_head;
            inst->ctrl_head = it->next;
            if (!inst->ctrl_head) inst->ctrl_tail = NULL;
            if (it->kind == CTRL_REFRESH) {
                inst->refresh_queued = 0;
                do_refresh = inst->refresh_dirty;
                inst->refresh_dirty = 0;
            }
        } else if (inst->ctrl_exit) {
            inst->ctrl_running = 0;
            pthread_mutex_unlock(&inst->mu);
            break;
        }
        pthread_mutex_unlock(&inst->mu);

        if (!it) continue;

        pthread_mutex_lock(&p->mu);
        inst->ctrl_busy = 1;
        pthread_mutex_unlock(&p->mu);

        switch (it->kind) {
            case CTRL_CALL:
                ctrl_handle_call(p, inst, it->call);
                break;

            case CTRL_DISCOVER: {
                struct discover_req *dr = it->disc;
                char *tjson = NULL, *derr = NULL;
                long long gen = 0;
                int drc = inst_ensure_started(p, inst, dr->deadline_mono_ms, NULL, &tjson, &gen, &derr);
                if (drc == 0 && !tjson) {
                    /* Already running: run fresh paginated tools/list on live server. */
                    drc = inst_refresh_catalog(p, inst, dr->deadline_mono_ms, NULL, &tjson, &gen, &derr);
                }
                if (drc == 0 && dr->project && *dr->project) {
                    inst_record_seen_project(inst, dr->project);
                }
                pthread_mutex_lock(&dr->mu);
                dr->rc = drc;
                dr->tools_json = tjson;
                dr->meta_gen = gen;
                dr->err = derr;
                dr->done = 1;
                pthread_cond_broadcast(&dr->cv);
                pthread_mutex_unlock(&dr->mu);
                break;
            }

            case CTRL_REFRESH: {
                pthread_mutex_lock(&p->mu);
                int alive = (inst->state == INST_RUNNING && !p->shutting_down);
                pthread_mutex_unlock(&p->mu);
                if (alive && do_refresh) {
                    long long dl = mono_ms() + (long long)p->call_sec * 1000LL;
                    char *rerr = NULL;
                    if (inst_refresh_catalog(p, inst, dl, NULL, NULL, NULL, &rerr) != 0 &&
                        inst_refresh_failed(inst, 1)) {
                        inst_teardown_proc(p, inst, 1);
                    }
                    free(rerr);
                }
                break;
            }

            case CTRL_REAP: {
                pthread_mutex_lock(&p->mu);
                int is_down = (inst->state == INST_DOWN);
                pthread_mutex_unlock(&p->mu);
                if (is_down) inst_teardown_proc(p, inst, 0);
                break;
            }

            case CTRL_STOP: {
                inst_teardown_proc(p, inst, 1);
                if (it->stop) {
                    pthread_mutex_lock(&it->stop->mu);
                    it->stop->done = 1;
                    pthread_cond_broadcast(&it->stop->cv);
                    pthread_mutex_unlock(&it->stop->mu);
                }
                break;
            }
        }

        free(it);
        pthread_mutex_lock(&p->mu);
        inst->ctrl_busy = 0;
        pthread_mutex_unlock(&p->mu);
    }

    inst_teardown_proc(p, inst, 1);
    inst_unref(p, inst);
    return NULL;
}

/* ---- Intake worker thread (DB server resolve off QuickJS run thread) ---- */

static void *intake_worker_thread(void *arg) {
    struct code_pool *p = (struct code_pool *)arg;

    for (;;) {
        struct call_job *job = NULL;
        pthread_mutex_lock(&p->mu);
        while (!p->intake_head && !p->shutting_down) {
            pthread_cond_wait(&p->intake_cv, &p->mu);
        }
        if (p->intake_head) {
            job = p->intake_head;
            p->intake_head = job->next_intake;
            if (!p->intake_head) p->intake_tail = NULL;
            job->next_intake = NULL;
        } else if (p->shutting_down) {
            pthread_mutex_unlock(&p->mu);
            break;
        }
        pthread_mutex_unlock(&p->mu);

        if (!job) continue;
        if (atomic_load_explicit(&job->cancelled, memory_order_acquire) || mono_ms() >= job->deadline_mono_ms) {
            finish_call_job(p, job, CODE_CALL_ERROR,
                            atomic_load_explicit(&job->cancelled, memory_order_acquire) ? "cancelled" : "call timed out",
                            0, NULL);
            continue;
        }

        struct db_deadline_ctx dctx = { job->deadline_mono_ms, &job->cancelled };
        char *dberr = NULL;
        sqlite3 *db = open_db_deadline(p->db_path, &dctx, &dberr);
        if (!db) {
            finish_call_job(p, job, CODE_CALL_ERROR, dberr ? dberr : "database unavailable", 0, NULL);
            free(dberr);
            continue;
        }

        struct code_server_row srv;
        int gr = kb_code_server_get(db, job->project, job->server, &srv);
        sqlite3_close(db);
        if (gr != 0) {
            finish_call_job(p, job, CODE_CALL_ERROR, "server not found", 0, NULL);
            continue;
        }

        if (job->expected_reg_id && job->expected_reg_id[0] &&
            strcmp(srv.reg_id, job->expected_reg_id) != 0) {
            kb_code_server_free(&srv);
            finish_call_job(p, job, CODE_CALL_DENIED, "server registration changed; rerun", 0, NULL);
            continue;
        }

        const char *owner = code_owner_project(&srv, job->project);
        struct mcp_instance *inst = pool_get_or_create_inst(p, &srv, owner);
        kb_code_server_free(&srv);
        if (!inst) {
            finish_call_job(p, job, CODE_CALL_ERROR, "server pool shutting down", 0, NULL);
            continue;
        }

        struct ctrl_item *it = calloc(1, sizeof *it);
        if (!it) abort();
        it->kind = CTRL_CALL;
        it->call = job;
        inst_enqueue_ctrl(inst, it);
        inst_unref(p, inst);
    }

    return NULL;
}

/* ============================================================================
 * Public Pool API
 * ============================================================================ */

struct code_pool *code_pool_new(const char *db_path, int max_servers, int idle_sec, int call_sec,
                                size_t line_cap_bytes, size_t daemon_queue_bytes) {
    if (!db_path || !*db_path) return NULL;
    struct code_pool *p = calloc(1, sizeof *p);
    if (!p) abort();
    snprintf(p->db_path, sizeof p->db_path, "%s", db_path);
    p->max_servers = max_servers > 0 ? max_servers : 6;
    p->idle_sec = idle_sec > 0 ? idle_sec : 900;
    p->call_sec = call_sec > 0 ? call_sec : 30;
    p->line_cap_bytes = line_cap_bytes > 0 ? line_cap_bytes : (16 * 1024 * 1024);
    p->daemon_queue_bytes = daemon_queue_bytes > 0 ? daemon_queue_bytes : (32 * 1024 * 1024);
    pthread_mutex_init(&p->mu, NULL);
    cond_init_mono(&p->intake_cv);

    for (int i = 0; i < MCP_INTAKE_WORKERS; i++) {
        if (pthread_create(&p->intake_tids[i], NULL, intake_worker_thread, p) == 0) {
            p->n_intake_threads++;
        }
    }
    if (p->n_intake_threads == 0) {
        pthread_cond_destroy(&p->intake_cv);
        pthread_mutex_destroy(&p->mu);
        free(p);
        return NULL;
    }
    return p;
}

void code_pool_free(struct code_pool *p) {
    if (!p) return;

    pthread_mutex_lock(&p->mu);
    p->shutting_down = 1;
    for (struct call_job *j = p->active_jobs; j; j = j->next_active)
        atomic_store_explicit(&j->cancelled, 1, memory_order_release);
    pthread_cond_broadcast(&p->intake_cv);
    pthread_mutex_unlock(&p->mu);

    for (int i = 0; i < p->n_intake_threads; i++) {
        pthread_join(p->intake_tids[i], NULL);
    }

    /* Signal every instance's ctrl_thread to stop and exit, then join them all. */
    for (;;) {
        struct mcp_instance *inst = NULL;
        pthread_t ctid;
        int join_ctrl = 0;

        pthread_mutex_lock(&p->mu);
        for (struct mcp_instance *it = p->instances; it; it = it->next) {
            pthread_mutex_lock(&it->mu);
            if (it->ctrl_joinable) {
                it->ctrl_exit = 1;
                it->stopping = 1;
                pthread_cond_broadcast(&it->ctrl_cv);
                pthread_cond_broadcast(&it->ctrl_wait_cv);
                if (it->stop_pipe[1] >= 0) {
                    char b = 'q';
                    ssize_t n = write(it->stop_pipe[1], &b, 1);
                    (void)n;
                }
                ctid = it->ctrl_tid;
                it->ctrl_joinable = 0;
                join_ctrl = 1;
                inst = it;
                pthread_mutex_unlock(&it->mu);
                break;
            }
            pthread_mutex_unlock(&it->mu);
        }
        pthread_mutex_unlock(&p->mu);

        if (!inst) break;
        if (join_ctrl) pthread_join(ctid, NULL);
    }

    /* Fail any leftover ctrl items or intake jobs. */
    while (p->intake_head) {
        struct call_job *j = p->intake_head;
        p->intake_head = j->next_intake;
        finish_call_job(p, j, CODE_CALL_ERROR, "daemon shutting down", 0, NULL);
    }

    while (p->instances) {
        struct mcp_instance *inst = p->instances;
        p->instances = inst->next;
        while (inst->ctrl_head) {
            struct ctrl_item *ci = inst->ctrl_head;
            inst->ctrl_head = ci->next;
            if (ci->kind == CTRL_CALL && ci->call)
                finish_call_job(p, ci->call, CODE_CALL_ERROR, "daemon shutting down", 0, NULL);
            free(ci);
        }
        inst_destroy(inst);
    }

    while (p->crashes) {
        struct crash_record *c = p->crashes;
        p->crashes = c->next;
        free(c);
    }

    pthread_cond_destroy(&p->intake_cv);
    pthread_mutex_destroy(&p->mu);
    free(p);
}

int code_pool_discover(struct code_pool *p, const char *project, const char *server_name,
                       char **tools_json_out, long long *meta_gen_out, char **err) {
    if (tools_json_out) *tools_json_out = NULL;
    if (meta_gen_out) *meta_gen_out = 0;
    if (err) *err = NULL;
    if (!p || !server_name || !*server_name) {
        if (err) *err = strdup("invalid discover arguments");
        return -1;
    }

    long long dl = mono_ms() + (long long)p->call_sec * 1000LL;
    struct db_deadline_ctx dctx = { dl, NULL };
    sqlite3 *db = open_db_deadline(p->db_path, &dctx, err);
    if (!db) return -1;

    struct code_server_row srv;
    int gr = kb_code_server_get(db, project ? project : "", server_name, &srv);
    sqlite3_close(db);
    if (gr != 0) {
        if (err) *err = mfmt("server '%s' not found", server_name);
        return -1;
    }

    const char *owner = code_owner_project(&srv, project);
    struct mcp_instance *inst = pool_get_or_create_inst(p, &srv, owner);
    kb_code_server_free(&srv);
    if (!inst) {
        if (err) *err = strdup("server pool shutting down");
        return -1;
    }

    struct discover_req dr;
    memset(&dr, 0, sizeof dr);
    dr.project = project ? strdup(project) : strdup("");
    dr.deadline_mono_ms = dl;
    pthread_mutex_init(&dr.mu, NULL);
    cond_init_mono(&dr.cv);

    struct ctrl_item *it = calloc(1, sizeof *it);
    if (!it) abort();
    it->kind = CTRL_DISCOVER;
    it->disc = &dr;
    inst_enqueue_ctrl(inst, it);

    pthread_mutex_lock(&dr.mu);
    while (!dr.done) cond_wait_ms(&dr.cv, &dr.mu, 100);
    pthread_mutex_unlock(&dr.mu);

    int rc = dr.rc;
    if (rc == 0) {
        if (tools_json_out) *tools_json_out = dr.tools_json;
        else free(dr.tools_json);
        if (meta_gen_out) *meta_gen_out = dr.meta_gen;
        free(dr.err);
    } else {
        free(dr.tools_json);
        if (err) *err = dr.err ? dr.err : strdup("discover failed");
        else free(dr.err);
    }

    free(dr.project);
    pthread_cond_destroy(&dr.cv);
    pthread_mutex_destroy(&dr.mu);
    inst_unref(p, inst);
    return rc;
}

/* NEVER blocks on QuickJS run thread: copies metadata, takes ownership of args_owned & h, enqueues. */
void code_pool_dispatch(struct code_pool *p, const char *project, const char *server,
                        const char *expected_reg_id, long long expected_meta_gen,
                        const char *tool, json_object *args_owned, int timeout_ms,
                        struct code_call_handle *h) {
    if (!p || !server || !tool || !h) {
        if (args_owned) json_object_put(args_owned);
        if (h) {
            code_js_complete(h, CODE_CALL_ERROR, "invalid dispatch parameters", 0, NULL);
            code_call_handle_unref(h);
        }
        return;
    }

    struct call_job *job = calloc(1, sizeof *job);
    if (!job) abort();
    job->project = strdup(project ? project : "");
    job->server = strdup(server);
    job->expected_reg_id = strdup(expected_reg_id ? expected_reg_id : "");
    job->expected_meta_gen = expected_meta_gen;
    job->tool = strdup(tool);
    job->args_owned = args_owned;
    job->h = h;
    atomic_init(&job->cancelled, 0);
    int tms = timeout_ms > 0 ? timeout_ms : (p->call_sec * 1000);
    job->deadline_mono_ms = mono_ms() + (long long)tms;

    pthread_mutex_lock(&p->mu);
    if (p->shutting_down) {
        pthread_mutex_unlock(&p->mu);
        code_js_complete(job->h, CODE_CALL_ERROR, "daemon shutting down", 0, NULL);
        free_call_job(job);
        return;
    }
    job->next_active = p->active_jobs;
    p->active_jobs = job;
    if (p->intake_tail) p->intake_tail->next_intake = job;
    else p->intake_head = job;
    p->intake_tail = job;
    pthread_cond_signal(&p->intake_cv);
    pthread_mutex_unlock(&p->mu);
}

void code_pool_cancel_call(struct code_pool *p, struct code_call_handle *h) {
    if (!p || !h) return;

    struct code_call_handle *to_unref = NULL;
    pthread_mutex_lock(&p->mu);
    for (struct call_job *j = p->active_jobs; j; j = j->next_active) {
        if (j->h == h) {
            atomic_store_explicit(&j->cancelled, 1, memory_order_release);
        }
    }
    /* Wake any starting/waiting instance condvars AND remove from inst->pending if already sent. */
    for (struct mcp_instance *it = p->instances; it; it = it->next) {
        pthread_mutex_lock(&it->mu);
        pthread_cond_broadcast(&it->ctrl_wait_cv);
        struct pending_rpc **pp = &it->pending;
        while (*pp) {
            if ((*pp)->h == h) {
                struct pending_rpc *cur = *pp;
                *pp = cur->next;
                to_unref = cur->h;
                free(cur);
                if (it->inflight_calls > 0) it->inflight_calls--;
                break;
            }
            pp = &(*pp)->next;
        }
        pthread_mutex_unlock(&it->mu);
    }
    pthread_mutex_unlock(&p->mu);

    if (to_unref) code_call_handle_unref(to_unref);
}

int code_pool_tick(struct code_pool *p, time_t now) {
    if (!p) return 0;
    long long now_m = mono_ms();
    long long idle_ms = (long long)p->idle_sec * 1000LL;
    (void)now;

    /* Collect idle victims first (without holding p->mu across synchronous stops). */
    struct mcp_instance *victims[64];
    int nv = 0;

    pthread_mutex_lock(&p->mu);
    for (struct mcp_instance *it = p->instances; it; it = it->next) {
        if (it->state == INST_RUNNING && it->inflight_calls == 0 && !it->ctrl_busy) {
            if (now_m - it->last_used_mono_ms >= idle_ms && nv < 64) {
                it->state = INST_STOPPING;
                it->refcount++;
                victims[nv++] = it;
            }
        }
    }
    pthread_mutex_unlock(&p->mu);

    for (int i = 0; i < nv; i++) {
        inst_stop_sync(p, victims[i]);
        inst_unref(p, victims[i]);
    }

    int live = 0;
    pthread_mutex_lock(&p->mu);
    for (struct mcp_instance *it = p->instances; it; it = it->next) {
        if (it->state == INST_STARTING || it->state == INST_RUNNING || it->state == INST_STOPPING)
            live++;
    }
    pthread_mutex_unlock(&p->mu);
    return live;
}

void code_pool_stop(struct code_pool *p, const char *scope_project, const char *server_name) {
    if (!p) return;
    struct mcp_instance *targets[128];
    int nt = 0;

    pthread_mutex_lock(&p->mu);
    for (struct mcp_instance *it = p->instances; it && nt < 128; it = it->next) {
        if (it->state == INST_DOWN) continue;
        if (server_name && *server_name && strcmp(it->srv.name, server_name) != 0) continue;
        if (scope_project && *scope_project) {
            if (strcmp(it->srv.scope_project, scope_project) != 0 &&
                strcmp(it->owner_project, scope_project) != 0)
                continue;
        }
        it->state = INST_STOPPING;
        it->refcount++;
        targets[nt++] = it;
    }
    pthread_mutex_unlock(&p->mu);

    for (int i = 0; i < nt; i++) {
        inst_stop_sync(p, targets[i]);
        inst_unref(p, targets[i]);
    }
}

/* Exact instance identity (CODE-ADMIN-02): one registration's instance for one owner ("" = shared), nothing that merely
 * shares its name or project. */
void code_pool_stop_inst(struct code_pool *p, const char *reg_id, const char *owner_project) {
    if (!p || !reg_id || !*reg_id) return;
    struct mcp_instance *targets[128];
    int nt = 0;
    pthread_mutex_lock(&p->mu);
    for (struct mcp_instance *it = p->instances; it && nt < 128; it = it->next) {
        if (it->state == INST_DOWN) continue;
        if (strcmp(it->srv.reg_id, reg_id) != 0 || strcmp(it->owner_project, owner_project ? owner_project : "") != 0) continue;
        it->state = INST_STOPPING;
        it->refcount++;
        targets[nt++] = it;
    }
    pthread_mutex_unlock(&p->mu);
    for (int i = 0; i < nt; i++) {
        inst_stop_sync(p, targets[i]);
        inst_unref(p, targets[i]);
    }
}

/* Every instance of one registration, whatever its owner: used when that registration was replaced or removed. */
void code_pool_stop_reg(struct code_pool *p, const char *reg_id) {
    if (!p || !reg_id || !*reg_id) return;
    struct mcp_instance *targets[128];
    int nt = 0;
    pthread_mutex_lock(&p->mu);
    for (struct mcp_instance *it = p->instances; it && nt < 128; it = it->next) {
        if (it->state == INST_DOWN || strcmp(it->srv.reg_id, reg_id) != 0) continue;
        it->state = INST_STOPPING;
        it->refcount++;
        targets[nt++] = it;
    }
    pthread_mutex_unlock(&p->mu);
    for (int i = 0; i < nt; i++) {
        inst_stop_sync(p, targets[i]);
        inst_unref(p, targets[i]);
    }
}

void code_pool_reset_crashes_inst(struct code_pool *p, const char *reg_id, const char *owner_project) {
    if (!p || !reg_id || !*reg_id) return;
    pthread_mutex_lock(&p->mu);
    for (struct crash_record *c = p->crashes; c; c = c->next) {
        if (strcmp(c->reg_id, reg_id) != 0 || strcmp(c->owner_project, owner_project ? owner_project : "") != 0) continue;
        c->count = 0;
        c->tripped = 0;
    }
    pthread_mutex_unlock(&p->mu);
}

void code_pool_reset_crashes(struct code_pool *p, const char *project, const char *server_name) {
    if (!p) return;
    pthread_mutex_lock(&p->mu);
    for (struct crash_record *c = p->crashes; c; c = c->next) {
        if (server_name && *server_name && strcmp(c->server_name, server_name) != 0) continue;
        if (project && *project && c->owner_project[0] != '\0' && strcmp(c->owner_project, project) != 0)
            continue;
        c->count = 0;
        c->tripped = 0;
    }
    pthread_mutex_unlock(&p->mu);
}

struct status_snap {
    char name[64];
    char reg_id[64];
    char scope[16];
    char owner_project[PATH_MAX];
    int isolated;
    const char *state;
    pid_t pid;
    int inflight;
    time_t last_used;
    char *env_json;
    char **seen;
    size_t nseen;
};

static void add_unique_str(char ***arr, size_t *n, size_t *cap, const char *s) {
    if (!s || !*s) return;
    for (size_t i = 0; i < *n; i++) {
        if (strcmp((*arr)[i], s) == 0) return;
    }
    if (*n >= *cap) {
        *cap = *cap ? *cap * 2 : 8;
        *arr = realloc(*arr, *cap * sizeof(char *));
        if (!*arr) abort();
    }
    (*arr)[(*n)++] = strdup(s);
}

json_object *code_pool_status_json(struct code_pool *p, long *total_mem_mb, int *nprojects) {
    if (total_mem_mb) *total_mem_mb = 0;
    if (nprojects) *nprojects = 0;
    json_object *arr = json_object_new_array();
    if (!p) return arr;

    struct status_snap *snaps = NULL;
    size_t nsnaps = 0, cap = 0;

    pthread_mutex_lock(&p->mu);
    for (struct mcp_instance *it = p->instances; it; it = it->next) {
        if (it->state != INST_STARTING && it->state != INST_RUNNING) continue;
        if (nsnaps >= cap) {
            cap = cap ? cap * 2 : 8;
            snaps = realloc(snaps, cap * sizeof *snaps);
            if (!snaps) abort();
        }
        struct status_snap *sn = &snaps[nsnaps++];
        memset(sn, 0, sizeof *sn);
        snprintf(sn->name, sizeof sn->name, "%s", it->srv.name);
        snprintf(sn->reg_id, sizeof sn->reg_id, "%s", it->srv.reg_id);
        snprintf(sn->scope, sizeof sn->scope, "%s", it->srv.scope_project[0] ? "project" : "user");
        snprintf(sn->owner_project, sizeof sn->owner_project, "%s", it->owner_project);
        sn->isolated = it->srv.isolated;
        sn->inflight = it->inflight_calls;
        sn->last_used = it->last_used_epoch;
        sn->state = (it->state == INST_STARTING) ? "starting"
                  : (it->inflight_calls > 0 ? "running" : "idle");
        sn->env_json = it->srv.env_json ? strdup(it->srv.env_json) : NULL;

        pthread_mutex_lock(&it->mu);
        sn->pid = it->pid;
        size_t sc = 0;
        for (struct seen_proj *sp = it->seen_projects; sp; sp = sp->next) sc++;
        if (sc > 0) {
            sn->seen = calloc(sc, sizeof(char *));
            if (!sn->seen) abort();
            size_t k = 0;
            for (struct seen_proj *sp = it->seen_projects; sp; sp = sp->next)
                sn->seen[k++] = strdup(sp->project);
            sn->nseen = sc;
        }
        pthread_mutex_unlock(&it->mu);
    }
    pthread_mutex_unlock(&p->mu);

    long long total_bytes = 0;
    char **projs = NULL;
    size_t np = 0, pcap = 0;

    for (size_t i = 0; i < nsnaps; i++) {
        struct status_snap *sn = &snaps[i];
        long long rss = pid_rss_bytes(sn->pid);
        total_bytes += rss;
        long rss_mb = (long)((rss + (512 * 1024)) / (1024 * 1024));

        if (sn->owner_project[0]) add_unique_str(&projs, &np, &pcap, sn->owner_project);
        for (size_t j = 0; j < sn->nseen; j++) add_unique_str(&projs, &np, &pcap, sn->seen[j]);

        json_object *o = json_object_new_object();
        json_object_object_add(o, "name", json_object_new_string(sn->name));
        json_object_object_add(o, "reg_id", json_object_new_string(sn->reg_id));
        json_object_object_add(o, "scope", json_object_new_string(sn->scope));
        json_object_object_add(o, "owner_project", json_object_new_string(sn->owner_project));
        json_object_object_add(o, "isolated", json_object_new_boolean(sn->isolated != 0));
        json_object_object_add(o, "state", json_object_new_string(sn->state));
        json_object_object_add(o, "pid", json_object_new_int64((int64_t)sn->pid));
        json_object_object_add(o, "inflight", json_object_new_int(sn->inflight));
        json_object_object_add(o, "last_used", json_object_new_int64((int64_t)sn->last_used));
        json_object_object_add(o, "rss_bytes", json_object_new_int64(rss));
        json_object_object_add(o, "rss_mb", json_object_new_int64(rss_mb));

        /* Emit env_keys ONLY; never expose env values. */
        json_object *ek = json_object_new_array();
        if (sn->env_json) {
            json_object *eo = json_tokener_parse(sn->env_json);
            if (eo && json_object_is_type(eo, json_type_object)) {
                json_object_object_foreach(eo, k, v) {
                    (void)v;
                    json_object_array_add(ek, json_object_new_string(k));
                }
            }
            if (eo) json_object_put(eo);
        }
        json_object_object_add(o, "env_keys", ek);
        json_object_array_add(arr, o);

        free(sn->env_json);
        for (size_t j = 0; j < sn->nseen; j++) free(sn->seen[j]);
        free(sn->seen);
    }
    free(snaps);

    for (size_t i = 0; i < np; i++) free(projs[i]);
    free(projs);

    if (total_mem_mb) *total_mem_mb = (long)((total_bytes + (512 * 1024)) / (1024 * 1024));
    if (nprojects) *nprojects = (int)np;
    return arr;
}

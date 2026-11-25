/* Per-user code-mode daemon, Unix socket IPC, lockfile, and deadlock-free semver drain. */
#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#include "code_daemon.h"
#include "code_js.h"
#include "code_mcp.h"
#include "kb.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <libproc.h>
#else
#include <sys/syscall.h>
#endif

static char g_exe_path[PATH_MAX];
static char g_version[64] = "0.5.5";
static pthread_mutex_t *g_fork_mu;

void code_daemon_init(const char *exe_path, const char *version, pthread_mutex_t *fork_mu) {
    if (exe_path && *exe_path) {
        char real[PATH_MAX];
        if (realpath(exe_path, real)) snprintf(g_exe_path, sizeof g_exe_path, "%s", real);
        else snprintf(g_exe_path, sizeof g_exe_path, "%s", exe_path);
    }
    if (version && *version) snprintf(g_version, sizeof g_version, "%s", version);
    g_fork_mu = fork_mu;
    code_mcp_init(g_version, fork_mu);
}

static char *dfmt(const char *f, ...) {
    va_list ap;
    char *s = NULL;
    va_start(ap, f);
    if (vasprintf(&s, f, ap) < 0) abort();
    va_end(ap);
    return s;
}

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}

static void sleep_ms(int ms) {
    if (ms <= 0) return;
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    while (nanosleep(&ts, &ts) < 0 && errno == EINTR) {}
}

static int env_int(const char *name, int def, int minv, int maxv) {
    const char *v = getenv(name);
    if (!v || !*v) return def;
    char *end = NULL;
    long x = strtol(v, &end, 10);
    if (!end || *end || x < minv) return minv;
    if (x > maxv) return maxv;
    return (int)x;
}

static size_t env_size(const char *name, size_t def, size_t minv, size_t maxv) {
    const char *v = getenv(name);
    if (!v || !*v) return def;
    char *end = NULL;
    unsigned long long x = strtoull(v, &end, 10);
    if (!end || *end || x < minv) return minv;
    if (x > maxv) return maxv;
    return (size_t)x;
}

static size_t code_line_cap(void) {
    size_t max_mb = env_size("CNTCTR_CODE_MAX_MB", 64, 4, 256);
    size_t cap = (max_mb / 4) * 1024 * 1024;
    if (cap < 65536) cap = 65536;
    if (cap > 16 * 1024 * 1024) cap = 16 * 1024 * 1024;
    return cap;
}

static const char *client_version_str(void) {
#ifdef CNTCTR_TEST_HOOKS
    const char *v = getenv("CNTCTR_TEST_CLIENT_VERSION");
    if (v && *v) return v;
#endif
    return g_version;
}

static const char *daemon_version_str(void) {
#ifdef CNTCTR_TEST_HOOKS
    const char *v = getenv("CNTCTR_TEST_DAEMON_VERSION");
    if (v && *v) return v;
#endif
    return g_version;
}

/* ---- SemVer 2.0.0 comparison ---- */

static int is_all_digits(const char *s, size_t n) {
    if (n == 0) return 0;
    for (size_t i = 0; i < n; i++) {
        if (!isdigit((unsigned char)s[i])) return 0;
    }
    return 1;
}

static int cmp_numeric_id(const char *a, size_t alen, const char *b, size_t blen) {
    while (alen > 1 && *a == '0') { a++; alen--; }
    while (blen > 1 && *b == '0') { b++; blen--; }
    if (alen != blen) return alen < blen ? -1 : 1;
    int c = memcmp(a, b, alen);
    return c < 0 ? -1 : (c > 0 ? 1 : 0);
}

static int cmp_prerelease(const char *a, size_t alen, const char *b, size_t blen) {
    size_t ai = 0, bi = 0;
    while (ai < alen && bi < blen) {
        size_t astart = ai;
        while (ai < alen && a[ai] != '.') ai++;
        size_t aseg = ai - astart;

        size_t bstart = bi;
        while (bi < blen && b[bi] != '.') bi++;
        size_t bseg = bi - bstart;

        int anum = is_all_digits(a + astart, aseg);
        int bnum = is_all_digits(b + bstart, bseg);
        int cmp;
        if (anum && bnum) {
            cmp = cmp_numeric_id(a + astart, aseg, b + bstart, bseg);
        } else if (anum != bnum) {
            cmp = anum ? -1 : 1; /* numeric identifiers always have lower precedence than non-numeric */
        } else {
            size_t m = aseg < bseg ? aseg : bseg;
            cmp = memcmp(a + astart, b + bstart, m);
            if (cmp == 0 && aseg != bseg) cmp = aseg < bseg ? -1 : 1;
            else if (cmp != 0) cmp = cmp < 0 ? -1 : 1;
        }
        if (cmp != 0) return cmp;
        if (ai < alen && a[ai] == '.') ai++;
        if (bi < blen && b[bi] == '.') bi++;
    }
    if (ai < alen) return 1;
    if (bi < blen) return -1;
    return 0;
}

/* SemVer 2.0.0 precedence: major.minor.patch[-pre][+build]. Returns <0 if a<b, 0 if equal, >0 if a>b. */
static int semver_cmp(const char *a, const char *b) {
    if (!a) a = "";
    if (!b) b = "";
    const char *aplus = strchr(a, '+');
    const char *bplus = strchr(b, '+');
    size_t alen = aplus ? (size_t)(aplus - a) : strlen(a);
    size_t blen = bplus ? (size_t)(bplus - b) : strlen(b);

    const char *adash = memchr(a, '-', alen);
    const char *bdash = memchr(b, '-', blen);
    size_t acore = adash ? (size_t)(adash - a) : alen;
    size_t bcore = bdash ? (size_t)(bdash - b) : blen;

    const char *pa = a, *pa_end = a + acore;
    const char *pb = b, *pb_end = b + bcore;
    for (int i = 0; i < 3; i++) {
        const char *as = pa;
        while (pa < pa_end && *pa != '.') pa++;
        size_t al = (size_t)(pa - as);
        const char *bs = pb;
        while (pb < pb_end && *pb != '.') pb++;
        size_t bl = (size_t)(pb - bs);
        int cmp = cmp_numeric_id(al ? as : "0", al ? al : 1, bl ? bs : "0", bl ? bl : 1);
        if (cmp != 0) return cmp;
        if (pa < pa_end && *pa == '.') pa++;
        if (pb < pb_end && *pb == '.') pb++;
    }

    int a_pre = (adash != NULL);
    int b_pre = (bdash != NULL);
    if (!a_pre && !b_pre) return 0;
    if (a_pre != b_pre) return a_pre ? -1 : 1; /* prerelease < release */
    return cmp_prerelease(adash + 1, (size_t)((a + alen) - (adash + 1)),
                          bdash + 1, (size_t)((b + blen) - (bdash + 1)));
}

/* ---- Paths & trusted directories ---- */

static const char *resolve_raw_db(char def[PATH_MAX]) {
    const char *env = getenv("CNTCTR_DB");
    if (env && *env) return env;
    const char *home = getenv("HOME");
    snprintf(def, PATH_MAX, "%s/.local/share/cntctr/kb.db", (home && *home) ? home : ".");
    return def;
}

static int canon_dir_best_effort(const char *dir, char out[PATH_MAX], char **err) {
    if (realpath(dir, out)) return 0;
    if (errno != ENOENT) {
        if (err) *err = dfmt("cannot resolve directory %s: %s", dir, strerror(errno));
        return -1;
    }
    char cur[PATH_MAX];
    snprintf(cur, sizeof cur, "%s", dir);
    char tail[PATH_MAX] = "";
    for (;;) {
        char *sl = strrchr(cur, '/');
        const char *seg = sl ? sl + 1 : cur;
        char next_tail[PATH_MAX];
        if (*tail) {
            if (snprintf(next_tail, sizeof next_tail, "%s/%s", seg, tail) >= (int)sizeof next_tail) {
                if (err) *err = dfmt("path too long: %s", dir);
                return -1;
            }
        } else {
            snprintf(next_tail, sizeof next_tail, "%s", seg);
        }
        snprintf(tail, sizeof tail, "%s", next_tail);
        if (!sl) {
            snprintf(cur, sizeof cur, ".");
            break;
        }
        if (sl == cur) {
            cur[1] = '\0';
            break;
        }
        *sl = '\0';
        char r[PATH_MAX];
        if (realpath(cur, r)) {
            int n = strcmp(r, "/") == 0
                        ? snprintf(out, PATH_MAX, "/%s", tail)
                        : snprintf(out, PATH_MAX, "%s/%s", r, tail);
            if (n < 0 || n >= PATH_MAX) {
                if (err) *err = dfmt("path too long: %s", dir);
                return -1;
            }
            return 0;
        }
        if (errno != ENOENT) {
            if (err) *err = dfmt("cannot resolve directory %s: %s", cur, strerror(errno));
            return -1;
        }
    }
    char r[PATH_MAX];
    if (!realpath(cur, r)) {
        if (err) *err = dfmt("cannot resolve directory %s: %s", dir, strerror(errno));
        return -1;
    }
    int n = strcmp(r, "/") == 0
                ? snprintf(out, PATH_MAX, "/%s", tail)
                : snprintf(out, PATH_MAX, "%s/%s", r, tail);
    if (n < 0 || n >= PATH_MAX) {
        if (err) *err = dfmt("path too long: %s", dir);
        return -1;
    }
    return 0;
}

int code_canon_db(char out[PATH_MAX], char **err) {
    char def[PATH_MAX];
    const char *raw = resolve_raw_db(def);
    const char *sl = strrchr(raw, '/');
    char dir[PATH_MAX];
    const char *base = NULL;
    if (sl) {
        size_t dlen = (sl == raw) ? 1 : (size_t)(sl - raw);
        if (dlen >= sizeof dir) {
            if (err) *err = dfmt("database path too long: %s", raw);
            return -1;
        }
        memcpy(dir, raw, dlen);
        dir[dlen] = '\0';
        base = sl + 1;
    } else {
        snprintf(dir, sizeof dir, ".");
        base = raw;
    }
    if (!*base) {
        if (err) *err = dfmt("invalid database path: %s", raw);
        return -1;
    }
    char rdir[PATH_MAX];
    if (canon_dir_best_effort(dir, rdir, err) != 0) return -1;
    int n = strcmp(rdir, "/") == 0
                ? snprintf(out, PATH_MAX, "/%s", base)
                : snprintf(out, PATH_MAX, "%s/%s", rdir, base);
    if (n < 0 || n >= PATH_MAX) {
        if (err) *err = dfmt("canonical database path too long: %s", raw);
        return -1;
    }
    return 0;
}

int code_sock_path(char out[PATH_MAX], char **err) {
    char def[PATH_MAX], cand[PATH_MAX];
    const char *env = getenv("CNTCTR_CODE_SOCK");
    if (env && *env) {
        if (strlen(env) >= sizeof cand) {
            if (err) *err = dfmt("CNTCTR_CODE_SOCK path too long (%zu >= %zu bytes); set CNTCTR_CODE_SOCK to a shorter path",
                                 strlen(env), sizeof(((struct sockaddr_un *)0)->sun_path));
            return -1;
        }
        snprintf(cand, sizeof cand, "%s", env);
    } else {
        const char *raw = resolve_raw_db(def);
        const char *sl = strrchr(raw, '/');
        int n;
        if (!sl) n = snprintf(cand, sizeof cand, "code.sock");
        else if (sl == raw) n = snprintf(cand, sizeof cand, "/code.sock");
        else n = snprintf(cand, sizeof cand, "%.*s/code.sock", (int)(sl - raw), raw);
        if (n < 0 || n >= (int)sizeof cand) {
            if (err) *err = dfmt("code socket path too long; set CNTCTR_CODE_SOCK to a shorter path");
            return -1;
        }
    }
    size_t max_sun = sizeof(((struct sockaddr_un *)0)->sun_path);
    if (strlen(cand) >= max_sun) {
        if (err) *err = dfmt("code socket path too long (%zu >= %zu bytes): %s; set CNTCTR_CODE_SOCK to a shorter path",
                             strlen(cand), max_sun, cand);
        return -1;
    }
    snprintf(out, PATH_MAX, "%s", cand);
    return 0;
}

static int code_lock_path_for(const char *sock_path, char out[PATH_MAX], char **err) {
    size_t len = strlen(sock_path);
    int n;
    if (len > 5 && strcmp(sock_path + len - 5, ".sock") == 0) {
        n = snprintf(out, PATH_MAX, "%.*s.lock", (int)(len - 5), sock_path);
    } else {
        n = snprintf(out, PATH_MAX, "%s.lock", sock_path);
    }
    if (n < 0 || n >= PATH_MAX) {
        if (err) *err = dfmt("code lock path too long for %s", sock_path);
        return -1;
    }
    return 0;
}

static int parent_dir_of(const char *file_path, char dir[PATH_MAX], char **err) {
    const char *sl = strrchr(file_path, '/');
    if (!sl) {
        snprintf(dir, PATH_MAX, ".");
        return 0;
    }
    if (sl == file_path) {
        snprintf(dir, PATH_MAX, "/");
        return 0;
    }
    size_t dlen = (size_t)(sl - file_path);
    if (dlen >= PATH_MAX) {
        if (err) *err = dfmt("directory path too long: %s", file_path);
        return -1;
    }
    memcpy(dir, file_path, dlen);
    dir[dlen] = '\0';
    return 0;
}

static int verify_trusted_chain(const char *dir, int as_ancestor, char canon_out[PATH_MAX], char **err) {
    char canon[PATH_MAX];
    if (!realpath(dir, canon)) {
        if (err) *err = dfmt("cannot resolve socket directory %s: %s", dir, strerror(errno));
        return -1;
    }
    uid_t me = geteuid();
    size_t clen = strlen(canon);
    /* Walk every component of the canonical path with lstat, ending at dir itself. */
    char cur[PATH_MAX];
    size_t pos = 0;
    for (;;) {
        int is_final = 0;
        if (pos == 0) {
            cur[0] = '/';
            cur[1] = '\0';
            if (clen == 1) is_final = 1;
            pos = 1;
        } else {
            while (pos < clen && canon[pos] != '/') pos++;
            if (pos >= sizeof cur) {
                if (err) *err = dfmt("canonical socket directory too long: %s", canon);
                return -1;
            }
            memcpy(cur, canon, pos);
            cur[pos] = '\0';
            if (pos >= clen) is_final = 1;
            else pos++;
        }

        struct stat st;
        if (lstat(cur, &st) != 0) {
            if (err) *err = dfmt("cannot stat directory %s: %s", cur, strerror(errno));
            return -1;
        }
        if (!S_ISDIR(st.st_mode)) {
            if (err) *err = dfmt("socket path component %s is not a real directory", cur);
            return -1;
        }
        int gw_writable = (st.st_mode & (S_IWGRP | S_IWOTH)) != 0;
        if (is_final && !as_ancestor) {
            if (st.st_uid != me) {
                if (err) *err = dfmt("socket directory %s is not owned by current user", cur);
                return -1;
            }
            if (gw_writable) {
                if (err) *err = dfmt("socket directory %s must not be group/world writable (mode %04o)",
                                     cur, (unsigned)(st.st_mode & 07777));
                return -1;
            }
            break;
        } else {
            if (st.st_uid != me && st.st_uid != 0) {
                if (err) *err = dfmt("socket ancestor directory %s is not owned by current user or root", cur);
                return -1;
            }
            if (gw_writable && !(st.st_uid == 0 && (st.st_mode & S_ISVTX) != 0)) {
                if (err) *err = dfmt("socket ancestor directory %s must not be group/world writable (mode %04o)",
                                     cur, (unsigned)(st.st_mode & 07777));
                return -1;
            }
            if (is_final) break;
        }
    }
    if (canon_out) snprintf(canon_out, PATH_MAX, "%s", canon);
    return 0;
}

static int verify_trusted_dir(const char *dir, char canon_out[PATH_MAX], char **err) {
    return verify_trusted_chain(dir, 0, canon_out, err);
}

static int ensure_parent_dir_canon(const char *file_path, int require_trusted, char canon_dir[PATH_MAX], char **err) {
    char dir[PATH_MAX];
    if (parent_dir_of(file_path, dir, err) != 0) return -1;

    struct stat st;
    if (lstat(dir, &st) == 0) {
        if (require_trusted) return verify_trusted_dir(dir, canon_dir, err);
        if (S_ISDIR(st.st_mode) || (stat(dir, &st) == 0 && S_ISDIR(st.st_mode))) {
            if (canon_dir && !realpath(dir, canon_dir)) snprintf(canon_dir, PATH_MAX, "%s", dir);
            return 0;
        }
        if (err) *err = dfmt("not a directory: %s", dir);
        return -1;
    }
    if (errno != ENOENT) {
        if (err) *err = dfmt("cannot inspect directory %s: %s", dir, strerror(errno));
        return -1;
    }

    /* Find the nearest existing ancestor and collect missing trailing components BEFORE any mutation. */
    char anc[PATH_MAX];
    snprintf(anc, sizeof anc, "%s", dir);
    char *segs[256];
    int nsegs = 0;
    int cur_fd = -1;
    int rc = -1;
    for (;;) {
        size_t alen = strlen(anc);
        while (alen > 1 && anc[alen - 1] == '/') anc[--alen] = '\0';
        if (lstat(anc, &st) == 0) break;
        if (errno != ENOENT) {
            if (err) *err = dfmt("cannot inspect directory %s: %s", anc, strerror(errno));
            goto cleanup;
        }
        if (nsegs >= 256) {
            if (err) *err = dfmt("directory path too deep: %s", dir);
            goto cleanup;
        }
        char *sl = strrchr(anc, '/');
        const char *seg = sl ? sl + 1 : anc;
        if (!*seg || strcmp(seg, ".") == 0 || strcmp(seg, "..") == 0) {
            if (err) *err = dfmt("invalid missing path component in %s", dir);
            goto cleanup;
        }
        segs[nsegs++] = strdup(seg);
        if (!sl) {
            snprintf(anc, sizeof anc, ".");
            break;
        }
        if (sl == anc) {
            anc[1] = '\0';
            break;
        }
        *sl = '\0';
    }

    /* Canonicalize and validate the nearest existing ancestor BEFORE creating any directory. */
    char cur_canon[PATH_MAX];
    if (require_trusted) {
        if (verify_trusted_chain(anc, 1, cur_canon, err) != 0) goto cleanup;
    } else {
        if (!realpath(anc, cur_canon)) {
            if (err) *err = dfmt("cannot resolve ancestor %s: %s", anc, strerror(errno));
            goto cleanup;
        }
    }

    cur_fd = open(cur_canon, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (cur_fd < 0) {
        if (err) *err = dfmt("cannot open ancestor directory %s: %s", cur_canon, strerror(errno));
        goto cleanup;
    }
    uid_t me = geteuid();
    if (fstat(cur_fd, &st) != 0 || !S_ISDIR(st.st_mode)) {
        if (err) *err = dfmt("ancestor %s is not a directory", cur_canon);
        goto cleanup;
    }
    if (require_trusted) {
        int gw = (st.st_mode & (S_IWGRP | S_IWOTH)) != 0;
        if ((st.st_uid != me && st.st_uid != 0) || (gw && !(st.st_uid == 0 && (st.st_mode & S_ISVTX) != 0))) {
            if (err) *err = dfmt("socket ancestor directory %s failed trust verification", cur_canon);
            goto cleanup;
        }
    }

    /* Create each missing component directory-relative via mkdirat + fchmodat + openat(O_NOFOLLOW|O_DIRECTORY) + fstat. */
    for (int i = nsegs - 1; i >= 0; i--) {
        const char *seg = segs[i];
        int is_last = (i == 0);
        mode_t mode = is_last ? 0700 : 0755;

        /* Never create components inside a group/world-writable or foreign-owned parent (even sticky
         * root-owned dirs like /tmp, and even when require_trusted is false): under this invariant
         * no other user can swap the just-created entry between mkdirat, fchmodat, openat, and rollback unlinkat. */
        struct stat pst;
        if (fstat(cur_fd, &pst) != 0 || !S_ISDIR(pst.st_mode)) {
            if (err) *err = dfmt("parent %s is not a directory", cur_canon);
            goto cleanup;
        }
        if (pst.st_uid != me && pst.st_uid != 0) {
            if (err) *err = dfmt("refusing to create directory under parent %s not owned by current user or root",
                                 cur_canon);
            goto cleanup;
        }
        if ((pst.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
            if (err) *err = dfmt("refusing to create directory under group/world-writable parent %s (mode %04o)",
                                 cur_canon, (unsigned)(pst.st_mode & 07777));
            goto cleanup;
        }

        int created = 0;
        if (mkdirat(cur_fd, seg, mode) == 0) {
            created = 1;
        } else if (errno != EEXIST) {
            if (err) *err = dfmt("cannot create directory %s/%s: %s", cur_canon, seg, strerror(errno));
            goto cleanup;
        }

        if (created) {
            /* Invariant enforced above: cur_fd is owned by me/root and is not group/world-writable,
             * so no other user can replace `seg` in cur_fd between mkdirat, fchmodat, openat, and
             * rollback unlinkat. Restore owner rwx bits before openat(O_RDONLY) so restrictive
             * process umasks (e.g. 0277 / 0477) do not block opening the newly created directory. */
#ifdef __APPLE__
            int ch_rc = fchmodat(cur_fd, seg, mode, AT_SYMLINK_NOFOLLOW);
#else
            int ch_rc = -1;
            struct stat cst;
            if (fstatat(cur_fd, seg, &cst, AT_SYMLINK_NOFOLLOW) == 0) {
                if (S_ISDIR(cst.st_mode) && cst.st_uid == me) {
                    ch_rc = fchmodat(cur_fd, seg, mode, 0);
                } else {
                    errno = ELOOP;
                }
            }
#endif
            if (ch_rc != 0) {
                int e = errno;
                (void)unlinkat(cur_fd, seg, AT_REMOVEDIR);
                if (err) *err = dfmt("cannot chmod directory %s/%s: %s", cur_canon, seg, strerror(e));
                goto cleanup;
            }
        }

        int next_fd = openat(cur_fd, seg, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next_fd < 0) {
            int e = errno;
            if (created) (void)unlinkat(cur_fd, seg, AT_REMOVEDIR);
            if (err) *err = dfmt("cannot open directory %s/%s: %s", cur_canon, seg, strerror(e));
            goto cleanup;
        }

        char next_canon[PATH_MAX];
        int n = strcmp(cur_canon, "/") == 0
                    ? snprintf(next_canon, sizeof next_canon, "/%s", seg)
                    : snprintf(next_canon, sizeof next_canon, "%s/%s", cur_canon, seg);
        if (n < 0 || n >= (int)sizeof next_canon) {
            close(next_fd);
            if (created) (void)unlinkat(cur_fd, seg, AT_REMOVEDIR);
            if (err) *err = dfmt("directory path too long: %s/%s", cur_canon, seg);
            goto cleanup;
        }

        if (fstat(next_fd, &st) != 0 || !S_ISDIR(st.st_mode)) {
            close(next_fd);
            if (created) (void)unlinkat(cur_fd, seg, AT_REMOVEDIR);
            if (err) *err = dfmt("not a directory: %s", next_canon);
            goto cleanup;
        }
        if (created && (st.st_mode & 07777) != mode) {
            if (fchmod(next_fd, mode) != 0 || fstat(next_fd, &st) != 0) {
                int e = errno;
                close(next_fd);
                (void)unlinkat(cur_fd, seg, AT_REMOVEDIR);
                if (err) *err = dfmt("cannot chmod directory %s: %s", next_canon, strerror(e));
                goto cleanup;
            }
        }
        if (require_trusted) {
            if (st.st_uid != me) {
                close(next_fd);
                if (created) (void)unlinkat(cur_fd, seg, AT_REMOVEDIR);
                if (err) *err = dfmt("socket directory %s is not owned by current user", next_canon);
                goto cleanup;
            }
            if ((st.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
                close(next_fd);
                if (created) (void)unlinkat(cur_fd, seg, AT_REMOVEDIR);
                if (err) *err = dfmt("socket directory %s must not be group/world writable (mode %04o)",
                                     next_canon, (unsigned)(st.st_mode & 07777));
                goto cleanup;
            }
        }
        close(cur_fd);
        cur_fd = next_fd;
        snprintf(cur_canon, sizeof cur_canon, "%s", next_canon);
    }
    if (canon_dir) snprintf(canon_dir, PATH_MAX, "%s", cur_canon);
    rc = 0;

cleanup:
    if (cur_fd >= 0) close(cur_fd);
    for (int i = 0; i < nsegs; i++) free(segs[i]);
    return rc;
}

static int ensure_parent_dir(const char *file_path, int require_trusted, char **err) {
    return ensure_parent_dir_canon(file_path, require_trusted, NULL, err);
}

static const char *path_basename_ptr(const char *p) {
    const char *sl = strrchr(p, '/');
    return sl ? sl + 1 : p;
}

/* Canonicalize and validate socket parent directory + all ancestors once.
 * Returns 0 on success (canon_sock & canon_lock filled), 1 if !create_missing and dir does not exist, -1 on error. */
static int resolve_trusted_sock_paths(const char *raw_sock, int create_missing,
                                      char canon_sock[PATH_MAX], char canon_lock[PATH_MAX], char **err) {
    const char *base = path_basename_ptr(raw_sock);
    if (!*base || strcmp(base, ".") == 0 || strcmp(base, "..") == 0) {
        if (err) *err = dfmt("invalid code socket path: %s", raw_sock);
        return -1;
    }
    char dir[PATH_MAX], canon_dir[PATH_MAX];
    if (parent_dir_of(raw_sock, dir, err) != 0) return -1;

    if (!create_missing) {
        struct stat st;
        if (stat(dir, &st) != 0) {
            if (errno == ENOENT || errno == ENOTDIR) return 1;
            if (err) *err = dfmt("cannot stat socket directory %s: %s", dir, strerror(errno));
            return -1;
        }
        if (verify_trusted_dir(dir, canon_dir, err) != 0) return -1;
    } else {
        if (ensure_parent_dir_canon(raw_sock, 1, canon_dir, err) != 0) return -1;
    }

    int n = strcmp(canon_dir, "/") == 0
                ? snprintf(canon_sock, PATH_MAX, "/%s", base)
                : snprintf(canon_sock, PATH_MAX, "%s/%s", canon_dir, base);
    size_t max_sun = sizeof(((struct sockaddr_un *)0)->sun_path);
    if (n < 0 || n >= PATH_MAX || (size_t)n >= max_sun) {
        if (err) *err = dfmt("canonical code socket path too long (%d >= %zu bytes): %s/%s; set CNTCTR_CODE_SOCK to a shorter path",
                             n, max_sun, canon_dir, base);
        return -1;
    }
    if (canon_lock && code_lock_path_for(canon_sock, canon_lock, err) != 0) return -1;
    return 0;
}

static int open_verified_dir_fd(const char *canon_dir, char **err) {
    int dfd = open(canon_dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (dfd < 0) {
        if (err) *err = dfmt("cannot open verified socket directory %s: %s", canon_dir, strerror(errno));
        return -1;
    }
    struct stat st;
    if (fstat(dfd, &st) != 0) {
        int e = errno;
        close(dfd);
        if (err) *err = dfmt("cannot fstat socket directory %s: %s", canon_dir, strerror(e));
        return -1;
    }
    if (!S_ISDIR(st.st_mode) || st.st_uid != geteuid() || (st.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        close(dfd);
        if (err) *err = dfmt("socket directory %s failed trust verification", canon_dir);
        return -1;
    }
    return dfd;
}

static int open_verified_lock(const char *lock_path, char **err) {
    char canon_dir[PATH_MAX];
    if (ensure_parent_dir_canon(lock_path, 1, canon_dir, err) != 0) return -1;
    int dfd = open_verified_dir_fd(canon_dir, err);
    if (dfd < 0) return -1;

    const char *base = path_basename_ptr(lock_path);
    int fd = -1, open_err = 0;
    /* Retry transient ENOENT on concurrent O_CREAT|O_NOFOLLOW creation (observed on macOS APFS VFS). */
    for (int attempt = 0; attempt < 8; attempt++) {
        fd = openat(dfd, base, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd >= 0) break;
        open_err = errno;
        if (open_err != ENOENT && open_err != EINTR) break;
    }
    close(dfd);
    if (fd < 0) {
        if (err) *err = dfmt("cannot open lockfile %s: %s", lock_path, strerror(open_err));
        return -1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        int e = errno;
        close(fd);
        if (err) *err = dfmt("cannot fstat lockfile %s: %s", lock_path, strerror(e));
        return -1;
    }
    if (!S_ISREG(st.st_mode)) {
        close(fd);
        if (err) *err = dfmt("refusing untrusted lockfile %s (not a regular file)", lock_path);
        return -1;
    }
    if (st.st_uid != geteuid()) {
        close(fd);
        if (err) *err = dfmt("refusing untrusted lockfile %s (wrong owner)", lock_path);
        return -1;
    }
    if ((st.st_mode & 07777) != 0600 && fchmod(fd, 0600) != 0) {
        int e = errno;
        close(fd);
        if (err) *err = dfmt("cannot chmod lockfile %s: %s", lock_path, strerror(e));
        return -1;
    }
    return fd;
}

/* Caller MUST hold code.lock. Verifies path via verified dir fd + fstatat (same-UID socket, optional inode) before unlinkat. */
static int unlink_verified_stale_sock(const char *sock_path, const struct stat *expected_st, char **err) {
    char dir[PATH_MAX], canon_dir[PATH_MAX];
    if (parent_dir_of(sock_path, dir, err) != 0) return -1;
    if (verify_trusted_dir(dir, canon_dir, err) != 0) return -1;
    int dfd = open_verified_dir_fd(canon_dir, err);
    if (dfd < 0) return -1;

    const char *base = path_basename_ptr(sock_path);
    struct stat cur;
    if (fstatat(dfd, base, &cur, AT_SYMLINK_NOFOLLOW) != 0) {
        int e = errno;
        close(dfd);
        if (e == ENOENT) return 0;
        if (err) *err = dfmt("cannot stat socket %s: %s", sock_path, strerror(e));
        return -1;
    }
    if (!S_ISSOCK(cur.st_mode)) {
        close(dfd);
        if (err) *err = dfmt("refusing to unlink non-socket at %s", sock_path);
        return -1;
    }
    if (cur.st_uid != geteuid()) {
        close(dfd);
        if (err) *err = dfmt("refusing to unlink socket %s owned by another user", sock_path);
        return -1;
    }
    if (expected_st && (cur.st_dev != expected_st->st_dev || cur.st_ino != expected_st->st_ino)) {
        close(dfd);
        return 0; /* already replaced by a newer daemon */
    }
    if (unlinkat(dfd, base, 0) != 0 && errno != ENOENT) {
        int e = errno;
        close(dfd);
        if (err) *err = dfmt("cannot unlink stale socket %s: %s", sock_path, strerror(e));
        return -1;
    }
    close(dfd);
    return 0;
}

/* ---- Peer credentials & RSS ---- */

#ifdef __APPLE__
static int check_peer_uid(int fd) {
    uid_t euid = (uid_t)-1;
    gid_t egid = (gid_t)-1;
    if (getpeereid(fd, &euid, &egid) != 0) return -1;
    return euid == geteuid() ? 0 : -1;
}
#else
static int check_peer_uid(int fd) {
    struct ucred cred;
    socklen_t clen = sizeof cred;
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &clen) != 0) return -1;
    if (clen != sizeof cred) return -1;
    return cred.uid == geteuid() ? 0 : -1;
}
#endif

static long long daemon_rss_bytes(void) {
#ifdef __APPLE__
    struct proc_taskinfo pti;
    int r = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &pti, (int)sizeof pti);
    if (r == (int)sizeof pti && pti.pti_resident_size > 0)
        return (long long)pti.pti_resident_size;
    struct rusage ru;
    if (getrusage(RUSAGE_SELF, &ru) == 0 && ru.ru_maxrss > 0)
        return (long long)ru.ru_maxrss;
    return 0;
#else
    FILE *f = fopen("/proc/self/statm", "r");
    if (f) {
        unsigned long long size_pages = 0, rss_pages = 0;
        int n = fscanf(f, "%llu %llu", &size_pages, &rss_pages);
        fclose(f);
        long pg = sysconf(_SC_PAGESIZE);
        if (n == 2 && pg > 0) return (long long)(rss_pages * (unsigned long long)pg);
    }
    struct rusage ru;
    if (getrusage(RUSAGE_SELF, &ru) == 0 && ru.ru_maxrss > 0)
        return (long long)ru.ru_maxrss * 1024LL;
    return 0;
#endif
}

/* ---- Budgeted nonblocking IPC I/O ---- */

struct io_budget {
    long long deadline_ms; /* 0 = unbounded */
    code_cancelled_fn is_cancelled;
    void *ctx;
    size_t max_line;
};

static struct io_budget make_budget(int timeout_ms, code_cancelled_fn is_cancelled, void *ctx, size_t max_line) {
    struct io_budget b;
    b.deadline_ms = timeout_ms > 0 ? now_ms() + (long long)timeout_ms : 0;
    b.is_cancelled = is_cancelled;
    b.ctx = ctx;
    b.max_line = max_line;
    return b;
}

static struct io_budget cap_budget_ms(const struct io_budget *base, int cap_ms) {
    struct io_budget b = *base;
    if (cap_ms > 0) {
        long long d = now_ms() + (long long)cap_ms;
        if (b.deadline_ms == 0 || d < b.deadline_ms) b.deadline_ms = d;
    }
    return b;
}

/* Returns poll slice in ms (>0), or -2 if cancelled, -3 if timed out. */
static int budget_slice(const struct io_budget *b, int max_slice_ms, char **err, const char *what) {
    if (b && b->is_cancelled && b->is_cancelled(b->ctx)) {
        if (err) *err = dfmt("cancelled");
        return -2;
    }
    int slice = max_slice_ms > 0 ? max_slice_ms : 200;
    if (b && b->deadline_ms > 0) {
        long long left = b->deadline_ms - now_ms();
        if (left <= 0) {
            if (err) *err = dfmt("timed out %s", what ? what : "waiting for code daemon");
            return -3;
        }
        if (left < slice) slice = (int)left;
    }
    return slice;
}

struct line_reader {
    int fd;
    char *buf;
    size_t len;
    size_t cap;
    size_t max_line;
};

static void lr_init(struct line_reader *lr, int fd, size_t max_line) {
    memset(lr, 0, sizeof *lr);
    lr->fd = fd;
    lr->max_line = max_line;
}

static void lr_free(struct line_reader *lr) {
    free(lr->buf);
    lr->buf = NULL;
    lr->len = lr->cap = 0;
}

/* Returns 0 on line (*line_out malloc'd, without '\n'), 1 on EOF/reset, -2 on cancel, -3 on timeout, -1 on error. */
static int lr_read_line(struct line_reader *lr, const struct io_budget *b, char **line_out, char **err) {
    *line_out = NULL;
    for (;;) {
        if (lr->len > 0) {
            char *nl = memchr(lr->buf, '\n', lr->len);
            if (nl) {
                size_t llen = (size_t)(nl - lr->buf);
                size_t clean = (llen > 0 && lr->buf[llen - 1] == '\r') ? llen - 1 : llen;
                char *out = malloc(clean + 1);
                if (!out) abort();
                memcpy(out, lr->buf, clean);
                out[clean] = '\0';
                size_t rem = lr->len - (llen + 1);
                if (rem > 0) memmove(lr->buf, nl + 1, rem);
                lr->len = rem;
                *line_out = out;
                return 0;
            }
            if (lr->len >= lr->max_line) {
                if (err) *err = dfmt("IPC message exceeds line limit (%zu bytes)", lr->max_line);
                return -1;
            }
        }

        int slice = budget_slice(b, 200, err, "waiting for code daemon response");
        if (slice < 0) return slice;

        struct pollfd pfd = { .fd = lr->fd, .events = POLLIN, .revents = 0 };
        int pr = poll(&pfd, 1, slice);
        if (pr < 0) {
            if (errno == EINTR) continue;
            if (err) *err = dfmt("poll error: %s", strerror(errno));
            return -1;
        }
        if (pr == 0) continue;

        if (lr->cap - lr->len < 4096) {
            size_t ncap = lr->cap ? lr->cap * 2 : 4096;
            if (ncap > lr->max_line + 1) ncap = lr->max_line + 1;
            if (ncap <= lr->len) {
                if (err) *err = dfmt("IPC message exceeds line limit (%zu bytes)", lr->max_line);
                return -1;
            }
            char *nb = realloc(lr->buf, ncap);
            if (!nb) abort();
            lr->buf = nb;
            lr->cap = ncap;
        }
        ssize_t n = read(lr->fd, lr->buf + lr->len, lr->cap - lr->len);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) continue;
            if (errno == ECONNRESET || errno == EPIPE) return 1;
            if (err) *err = dfmt("read error: %s", strerror(errno));
            return -1;
        }
        if (n == 0) return 1;
        lr->len += (size_t)n;
    }
}

/* Returns 0 on success, -2 on cancel, -3 on timeout, -4 on peer disconnect (EPIPE/ECONNRESET), -1 on other write error. */
static int write_all_budget(int fd, const char *data, size_t len, const struct io_budget *b, char **err) {
    size_t off = 0;
    while (off < len) {
        /* Always check cancel/deadline BEFORE every transfer (including after EINTR). */
        int slice = budget_slice(b, 200, err, "writing to code daemon");
        if (slice < 0) return slice;

        ssize_t n = write(fd, data + off, len - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                struct pollfd pfd = { .fd = fd, .events = POLLOUT, .revents = 0 };
                int pr = poll(&pfd, 1, slice);
                if (pr < 0 && errno != EINTR) {
                    if (err) *err = dfmt("poll write error: %s", strerror(errno));
                    return -1;
                }
                continue;
            }
            if (errno == EPIPE || errno == ECONNRESET) {
                if (err) *err = dfmt("write error: %s", strerror(errno));
                return -4;
            }
            if (err) *err = dfmt("write error: %s", strerror(errno));
            return -1;
        }
        if (n == 0) {
            if (err) *err = dfmt("short write to code daemon");
            return -1;
        }
        off += (size_t)n;
    }
    return 0;
}

/* Returns 0 on success, -2 on cancel, -3 on timeout, -4 on peer disconnect, -1 on error (incl. serialization/frame limit). */
static int write_json_line(int fd, pthread_mutex_t *write_mu, json_object *obj,
                           const struct io_budget *b, char **err) {
    const char *s = json_object_to_json_string_ext(obj, JSON_C_TO_STRING_PLAIN);
    if (!s) {
        if (err) *err = dfmt("failed to serialize JSON frame");
        return -1;
    }
    size_t slen = strlen(s);
    size_t max_line = (b && b->max_line > 0) ? b->max_line : code_line_cap();
    if (slen + 1 > max_line) {
        if (err) *err = dfmt("outbound IPC frame exceeds line limit (%zu > %zu bytes)", slen + 1, max_line);
        return -1;
    }
    char *buf = malloc(slen + 1);
    if (!buf) abort();
    memcpy(buf, s, slen);
    buf[slen] = '\n';
    if (write_mu) pthread_mutex_lock(write_mu);
    int rc = write_all_budget(fd, buf, slen + 1, b, err);
    if (write_mu) pthread_mutex_unlock(write_mu);
    free(buf);
    return rc;
}

/* Nonblocking connect with monotonic deadline, cancellation, AF_UNIX EAGAIN retry, and peer-UID check. Leaves fd O_NONBLOCK. */
static int unix_connect_budget(const char *sock_path, const struct io_budget *b, int *saved_errno, char **err) {
    if (saved_errno) *saved_errno = 0;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        if (saved_errno) *saved_errno = errno;
        return -1;
    }
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    fcntl(fd, F_SETFL, O_NONBLOCK);

    struct sockaddr_un sa;
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    if (strlen(sock_path) >= sizeof sa.sun_path) {
        close(fd);
        if (saved_errno) *saved_errno = ENAMETOOLONG;
        return -1;
    }
    snprintf(sa.sun_path, sizeof sa.sun_path, "%s", sock_path);

    for (;;) {
        int slice = budget_slice(b, 200, err, "connecting to code daemon");
        if (slice < 0) {
            close(fd);
            if (saved_errno) *saved_errno = (slice == -2) ? ECANCELED : ETIMEDOUT;
            return -1;
        }
        int rc = connect(fd, (struct sockaddr *)&sa, sizeof sa);
        if (rc == 0) break;
        int e = errno;
        if (e == EINTR) continue;
        if (e == EAGAIN) {
            /* On AF_UNIX, EAGAIN means the listen backlog is transiently full: retry connect() within budget. */
            sleep_ms(slice > 15 ? 15 : slice);
            continue;
        }
        if (e == EINPROGRESS) {
            for (;;) {
                int pslice = budget_slice(b, 200, err, "connecting to code daemon");
                if (pslice < 0) {
                    close(fd);
                    if (saved_errno) *saved_errno = (pslice == -2) ? ECANCELED : ETIMEDOUT;
                    return -1;
                }
                struct pollfd pfd = { .fd = fd, .events = POLLOUT, .revents = 0 };
                int pr = poll(&pfd, 1, pslice);
                if (pr < 0) {
                    if (errno == EINTR) continue;
                    e = errno;
                    close(fd);
                    if (saved_errno) *saved_errno = e;
                    return -1;
                }
                if (pr == 0) continue;
                int so_err = 0;
                socklen_t slen = sizeof so_err;
                if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &so_err, &slen) != 0) so_err = errno;
                if (so_err != 0) {
                    close(fd);
                    if (saved_errno) *saved_errno = so_err;
                    return -1;
                }
                break;
            }
            break;
        }
        close(fd);
        if (saved_errno) *saved_errno = e;
        return -1;
    }
    if (check_peer_uid(fd) != 0) {
        close(fd);
        if (saved_errno) *saved_errno = EPERM;
        return -1;
    }
    return fd;
}

/* ---- Scrubbed double-fork + setsid + execve launcher (transfers startup lock fd=3 to grandchild) ---- */

static char **build_scrubbed_envp(int pass_lock_fd3) {
    static const char *const ALLOW[] = {
        "HOME", "USER", "PATH", "LANG", "LC_ALL", "TMPDIR", "SHELL",
        "CNTCTR_DB", "CNTCTR_CODE_SOCK",
        "CNTCTR_CODE_MAX_SERVERS", "CNTCTR_CODE_IDLE_SEC",
        "CNTCTR_CODE_DAEMON_IDLE_SEC", "CNTCTR_CODE_DRAIN_GRACE_SEC",
        "CNTCTR_CODE_MAX_RUNS", "CNTCTR_CODE_DAEMON_QUEUE_BYTES",
        "CNTCTR_CODE_MAX_MB", "CNTCTR_CODE_CALL_SEC", "CNTCTR_CODE_RUN_TTL_SEC",
#ifdef CNTCTR_TEST_HOOKS
        "CNTCTR_TEST_DAEMON_VERSION", "CNTCTR_TEST_DAEMON_PRE_BIND_BARRIER",
        "ASAN_OPTIONS", "LSAN_OPTIONS", "UBSAN_OPTIONS",
#endif
        NULL
    };
    size_t count = 0;
    while (ALLOW[count]) count++;
    char **envp = calloc(count + 2, sizeof(char *));
    if (!envp) abort();
    size_t k = 0;
    for (size_t i = 0; i < count; i++) {
        const char *v = getenv(ALLOW[i]);
        if (v) envp[k++] = dfmt("%s=%s", ALLOW[i], v);
    }
    if (pass_lock_fd3) envp[k++] = strdup("CNTCTR_CODE_LOCK_FD=3");
    envp[k] = NULL;
    return envp;
}

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
    /* Also scan currently open fds before fork() so any fd opened before a soft RLIMIT_NOFILE
     * reduction is always covered by the child's close loop. */
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

/* Takes ownership of *lfd_ptr on success (closes parent dup without flock(LOCK_UN) so grandchild holds
 * the startup lock reservation across bind()+listen()). On failure, unlocks and closes *lfd_ptr. */
static int spawn_code_daemon(const char *sock_path, const char *canon_db, int *lfd_ptr, char **err) {
    int lfd = lfd_ptr ? *lfd_ptr : -1;
    if (!*g_exe_path) {
        if (err) *err = dfmt("cannot spawn code daemon: cntctr executable path unknown");
        return -1;
    }
    if (lfd < 0) {
        if (err) *err = dfmt("cannot spawn code daemon: startup lock not held");
        return -1;
    }

    /* Build argv, scrubbed envp, and maxfd strictly BEFORE fork(). */
    char *argv[5] = { g_exe_path, "_code-daemon", (char *)sock_path, (char *)canon_db, NULL };
    char **envp = build_scrubbed_envp(1);
    int maxfd = compute_max_fd();

    if (g_fork_mu) pthread_mutex_lock(g_fork_mu);
    pid_t p1 = fork();
    int fork_err = errno;
    if (p1 == 0) {
        /* Async-signal-safe calls only between fork and execve. */
        pid_t p2 = fork();
        if (p2 < 0) _exit(127);
        if (p2 > 0) _exit(0);
        if (setsid() < 0) _exit(127);

        /* Move inherited lock fd clear of 0..3 before redirecting stdio. */
        int safe_lfd = fcntl(lfd, F_DUPFD, 10);
        if (safe_lfd < 0) _exit(127);

        int devnull = open("/dev/null", O_RDWR);
        if (devnull < 0) _exit(127);
        if (dup2(devnull, 0) < 0 || dup2(devnull, 1) < 0 || dup2(devnull, 2) < 0) _exit(127);
        if (devnull > 2) close(devnull);

        /* Put startup lock on fd 3 (dup2 clears FD_CLOEXEC so execve inherits it intentionally). */
        if (dup2(safe_lfd, 3) < 0) _exit(127);
        if (safe_lfd != 3) close(safe_lfd);

        int closed_range = 0;
#if defined(__linux__) && defined(SYS_close_range)
        if (syscall(SYS_close_range, 4U, ~0U, 0U) == 0) closed_range = 1;
#endif
        if (!closed_range) {
            for (int fd = 4; fd <= maxfd; fd++) close(fd);
        }

        signal(SIGPIPE, SIG_DFL);
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        execve(argv[0], argv, envp);
        _exit(127);
    }
    if (g_fork_mu) pthread_mutex_unlock(g_fork_mu);
    free_strv(envp);

    if (p1 < 0) {
        if (err) *err = dfmt("cannot fork code daemon: %s", strerror(fork_err));
        return -1;
    }

    int st = 0;
    pid_t wrc;
    while ((wrc = waitpid(p1, &st, 0)) < 0 && errno == EINTR) {}
    if (wrc < 0 || !WIFEXITED(st) || WEXITSTATUS(st) != 0) {
        /* Intermediate child failed to spawn grandchild: unlock and close our lock fd. */
        (void)flock(lfd, LOCK_UN);
        close(lfd);
        *lfd_ptr = -1;
        if (err) {
            if (wrc < 0) *err = dfmt("failed to reap code daemon launcher: %s", strerror(errno));
            else *err = dfmt("code daemon launcher intermediate child failed (status %d)", st);
        }
        return -1;
    }

    /* Hand off startup lock ownership to grandchild: close parent dup WITHOUT flock(LOCK_UN). */
    close(lfd);
    *lfd_ptr = -1;
    return 0;
}

/* ---- Daemon server implementation ---- */

static volatile sig_atomic_t g_daemon_sig_stop = 0;
static int g_daemon_sig_wake_fd = -1;

static void daemon_sig_handler(int sig) {
    (void)sig;
    int saved = errno;
    g_daemon_sig_stop = 1;
    if (g_daemon_sig_wake_fd >= 0) {
        char b = 's';
        ssize_t n = write(g_daemon_sig_wake_fd, &b, 1);
        (void)n;
    }
    errno = saved;
}

struct active_run {
    int cancelled;
    char reason[128];
    int wake_fd; /* write end of per-run pipe (-1 if unused) */
    struct code_run_cancel *cancel; /* optional QuickJS run cancel token */
    struct active_run *next;
};

struct drain_waiter {
    int fd;
    struct drain_waiter *next;
};

struct worker_conn {
    struct daemon_state *d;
    int fd; /* -1 once closed or handed to drain_waiters; guarded by d->mu */
    struct worker_conn *next;
};

struct daemon_state {
    char sock_path[PATH_MAX];
    char lock_path[PATH_MAX];
    char db_path[PATH_MAX];
    char version[64];
    struct stat sock_stat;
    int have_sock_stat;

    long long start_mono_ms;
    int listen_fd;
    int wake_pipe[2];
    size_t line_cap;

    int max_servers;
    int idle_sec;
    int daemon_idle_sec;
    int drain_grace_sec;
    int max_runs;
    int call_sec;
    int run_ttl_sec;
    size_t daemon_queue_bytes;

    struct code_pool *pool;
    time_t last_sweep;
    uint64_t run_seq;

    pthread_mutex_t mu;
    pthread_cond_t cv;
    int draining;
    int drain_is_upgrade;
    int drain_cancelled_sent;
    long long drain_deadline_ms;
    int active_runs;
    int active_work;    /* active work RPCs (excludes status/handshake so they never postpone idle exit) */
    int active_conns;   /* all live worker threads (used for safe shutdown synchronization) */
    int pending_drains;
    int live_servers;
    int exiting;
    long long last_activity_ms;

    struct active_run *runs;
    struct drain_waiter *waiters;
    struct worker_conn *workers;
};

static void daemon_wake(struct daemon_state *d) {
    char b = 'w';
    ssize_t n = write(d->wake_pipe[1], &b, 1);
    (void)n;
}

static void daemon_drain_wake_pipe(struct daemon_state *d) {
    char tmp[64];
    while (read(d->wake_pipe[0], tmp, sizeof tmp) > 0) {}
}

static json_object *make_err_resp(json_object *id_obj, const char *err_msg, int retryable) {
    json_object *resp = json_object_new_object();
    if (id_obj) json_object_object_add(resp, "id", json_object_get(id_obj));
    json_object_object_add(resp, "ok", json_object_new_boolean(0));
    json_object_object_add(resp, "error", json_object_new_string(err_msg ? err_msg : "error"));
    if (retryable) json_object_object_add(resp, "retryable", json_object_new_boolean(1));
    return resp;
}

static int daemon_write_json(int fd, pthread_mutex_t *write_mu, json_object *obj, size_t max_line) {
    struct io_budget wb = make_budget(5000, NULL, NULL, max_line);
    char *werr = NULL;
    int rc = write_json_line(fd, write_mu, obj, &wb, &werr);
    free(werr);
    return rc;
}

static json_object *build_status_resp(struct daemon_state *d, json_object *id_obj) {
    long long rss = daemon_rss_bytes();
    int daemon_rss_mb = (int)((rss + (512 * 1024)) / (1024 * 1024));
    long long up_sec = (now_ms() - d->start_mono_ms) / 1000LL;
    if (up_sec < 0) up_sec = 0;

    long pool_mb = 0;
    int nprojs = 0;
    json_object *srvs = d->pool ? code_pool_status_json(d->pool, &pool_mb, &nprojs) : json_object_new_array();
    int sc = (int)json_object_array_length(srvs);
    int total_mb = daemon_rss_mb + (int)pool_mb;
    long long total_bytes = rss + (long long)pool_mb * 1024LL * 1024LL;

    pthread_mutex_lock(&d->mu);
    int draining = d->draining;
    int active_runs = d->active_runs;
    pthread_mutex_unlock(&d->mu);

    json_object *resp = json_object_new_object();
    if (id_obj) json_object_object_add(resp, "id", json_object_get(id_obj));
    json_object_object_add(resp, "ok", json_object_new_boolean(1));
    json_object_object_add(resp, "pid", json_object_new_int64((int64_t)getpid()));
    json_object_object_add(resp, "version", json_object_new_string(d->version));
    json_object_object_add(resp, "proto", json_object_new_int(CODE_PROTO_VERSION));
    json_object_object_add(resp, "db", json_object_new_string(d->db_path));
    json_object_object_add(resp, "sock", json_object_new_string(d->sock_path));
    json_object_object_add(resp, "draining", json_object_new_boolean(draining));
    json_object_object_add(resp, "uptime_sec", json_object_new_int64(up_sec));
    json_object_object_add(resp, "servers", srvs);
    json_object_object_add(resp, "server_count", json_object_new_int(sc));
    json_object_object_add(resp, "active_runs", json_object_new_int(active_runs));
    json_object_object_add(resp, "project_count", json_object_new_int(nprojs));
    json_object_object_add(resp, "rss_bytes", json_object_new_int64(total_bytes));
    json_object_object_add(resp, "rss_mb", json_object_new_int(total_mb));
    return resp;
}

#ifdef CNTCTR_TEST_HOOKS
static void handle_test_hold(struct daemon_state *d, int fd, pthread_mutex_t *write_mu,
                             json_object *id_obj, json_object *req) {
    json_object *jms = NULL, *jrf = NULL;
    int hold_ms = 1000;
    if (json_object_object_get_ex(req, "ms", &jms) &&
        (json_object_is_type(jms, json_type_int) || json_object_is_type(jms, json_type_double))) {
        hold_ms = json_object_get_int(jms);
        if (hold_ms < 0) hold_ms = 0;
        if (hold_ms > 60000) hold_ms = 60000;
    }
    const char *ready_file = NULL;
    if (json_object_object_get_ex(req, "ready_file", &jrf) && json_object_is_type(jrf, json_type_string))
        ready_file = json_object_get_string(jrf);

    int rpipe[2] = {-1, -1};
    if (pipe(rpipe) != 0) {
        json_object *resp = make_err_resp(id_obj, "pipe failed", 0);
        daemon_write_json(fd, write_mu, resp, d->line_cap);
        json_object_put(resp);
        return;
    }
    fcntl(rpipe[0], F_SETFD, FD_CLOEXEC);
    fcntl(rpipe[1], F_SETFD, FD_CLOEXEC);
    fcntl(rpipe[0], F_SETFL, O_NONBLOCK);
    fcntl(rpipe[1], F_SETFL, O_NONBLOCK);

    struct active_run run;
    memset(&run, 0, sizeof run);
    run.wake_fd = rpipe[1];

    pthread_mutex_lock(&d->mu);
    if (d->draining) {
        pthread_mutex_unlock(&d->mu);
        close(rpipe[0]);
        close(rpipe[1]);
        json_object *resp = make_err_resp(id_obj, "cntctr is upgrading; retry in a few seconds", 1);
        daemon_write_json(fd, write_mu, resp, d->line_cap);
        json_object_put(resp);
        return;
    }
    if (d->active_runs >= d->max_runs) {
        pthread_mutex_unlock(&d->mu);
        close(rpipe[0]);
        close(rpipe[1]);
        json_object *resp = make_err_resp(id_obj, "max concurrent runs reached", 1);
        daemon_write_json(fd, write_mu, resp, d->line_cap);
        json_object_put(resp);
        return;
    }
    d->active_runs++;
    run.next = d->runs;
    d->runs = &run;
    pthread_mutex_unlock(&d->mu);

    if (ready_file && *ready_file) {
        char tmp_path[PATH_MAX];
        snprintf(tmp_path, sizeof tmp_path, "%s.tmp.%ld", ready_file, (long)getpid());
        int rfd = open(tmp_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
        if (rfd >= 0) {
            char pidbuf[32];
            int pn = snprintf(pidbuf, sizeof pidbuf, "%ld\n", (long)getpid());
            struct io_budget fb = make_budget(2000, NULL, NULL, 1024);
            if (pn > 0) (void)write_all_budget(rfd, pidbuf, (size_t)pn, &fb, NULL);
            close(rfd);
            (void)rename(tmp_path, ready_file);
        }
    }

    long long deadline = now_ms() + hold_ms;
    int cancelled = 0;
    char reason[128] = "";
    int client_gone = 0;

    for (;;) {
        pthread_mutex_lock(&d->mu);
        if (run.cancelled) {
            cancelled = 1;
            snprintf(reason, sizeof reason, "%s", run.reason);
        }
        pthread_mutex_unlock(&d->mu);
        if (cancelled) break;

        long long left = deadline - now_ms();
        if (left <= 0) break;

        struct pollfd pf[2] = {
            { .fd = rpipe[0], .events = POLLIN, .revents = 0 },
            { .fd = fd, .events = POLLIN, .revents = 0 },
        };
        int pr = poll(pf, 2, left > 200 ? 200 : (int)left);
        if (pr < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (pf[0].revents & POLLIN) {
            char drainb[16];
            while (read(rpipe[0], drainb, sizeof drainb) > 0) {}
            continue;
        }
        if (pf[1].revents & (POLLHUP | POLLERR | POLLNVAL)) {
            client_gone = 1;
            break;
        }
        if (pf[1].revents & POLLIN) {
            char peek;
            ssize_t n = recv(fd, &peek, 1, MSG_PEEK | MSG_DONTWAIT);
            if (n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
                client_gone = 1;
                break;
            }
        }
    }

    if (!client_gone) {
        json_object *resp;
        if (cancelled) {
            resp = make_err_resp(id_obj, *reason ? reason : "daemon upgrading; rerun", 0);
            json_object_object_add(resp, "cancelled", json_object_new_boolean(1));
        } else {
            resp = json_object_new_object();
            if (id_obj) json_object_object_add(resp, "id", json_object_get(id_obj));
            json_object_object_add(resp, "ok", json_object_new_boolean(1));
            json_object_object_add(resp, "held_ms", json_object_new_int(hold_ms));
            json_object_object_add(resp, "cancelled", json_object_new_boolean(0));
            json_object_object_add(resp, "pid", json_object_new_int64((int64_t)getpid()));
        }
        daemon_write_json(fd, write_mu, resp, d->line_cap);
        json_object_put(resp);
    }

    pthread_mutex_lock(&d->mu);
    struct active_run **pp = &d->runs;
    while (*pp) {
        if (*pp == &run) {
            *pp = run.next;
            break;
        }
        pp = &(*pp)->next;
    }
    d->active_runs--;
    d->last_activity_ms = now_ms();
    daemon_wake(d);
    pthread_cond_broadcast(&d->cv);
    pthread_mutex_unlock(&d->mu);

    close(rpipe[0]);
    close(rpipe[1]);
}
#endif

/* ---- Virtual "cntctr" allowlist & Phase 5 RPC handlers (discover, restart, reload, find, expand, run) ---- */

struct cntctr_vtool {
    const char *name;
    const char *description;
    enum code_class base_class;
    const char *schema_json;
};

static const struct cntctr_vtool CNTCTR_VTOOLS[] = {
    { "list",    "List active agents in this project", CODE_READ,  "{\"type\":\"object\",\"properties\":{}}" },
    { "recall",  "Search or list shared knowledge store", CODE_READ, "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"},\"layer\":{\"type\":\"string\"},\"scope\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\"}}}" },
    { "read",    "Read one knowledge entry in full", CODE_READ, "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}" },
    { "board",   "Read project board posts or mail", CODE_READ, "{\"type\":\"object\",\"properties\":{\"mode\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\"}}}" },
    { "project", "Get current project key (read-only)", CODE_READ, "{\"type\":\"object\",\"properties\":{}}" },
    { "note",    "Store durable knowledge entry", CODE_WRITE, "{\"type\":\"object\",\"properties\":{\"layer\":{\"type\":\"string\"},\"title\":{\"type\":\"string\"},\"summary\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"},\"scope\":{\"type\":\"string\"}},\"required\":[\"layer\",\"title\",\"summary\"]}" },
    { "post",    "Post short-lived news to project board", CODE_WRITE, "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"},\"urgent\":{\"type\":\"boolean\"}},\"required\":[\"text\"]}" },
    { "send",    "Send message to another agent (wait forced false)", CODE_WRITE, "{\"type\":\"object\",\"properties\":{\"to\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"},\"re\":{\"type\":\"string\"}},\"required\":[\"to\",\"text\"]}" },
    { "reply",   "Reply to a received agent message", CODE_WRITE, "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"}},\"required\":[\"id\",\"text\"]}" },
};

size_t code_cntctr_tool_count(void) { return sizeof CNTCTR_VTOOLS / sizeof CNTCTR_VTOOLS[0]; }
const char *code_cntctr_tool_name(size_t i) { return i < code_cntctr_tool_count() ? CNTCTR_VTOOLS[i].name : NULL; }
int code_cntctr_tool_class(const char *name, enum code_class *cls) {
    for (size_t i = 0; name && i < code_cntctr_tool_count(); i++)
        if (strcmp(CNTCTR_VTOOLS[i].name, name) == 0) { if (cls) *cls = CNTCTR_VTOOLS[i].base_class; return 1; }
    return 0;
}

static const char *daemon_class_str(enum code_class c) {
    if (c == CODE_READ) return "read";
    if (c == CODE_WRITE) return "write";
    return "destructive";
}

static enum code_class daemon_parse_class(const char *s) {
    if (!s) return CODE_WRITE;
    if (strcmp(s, "read") == 0) return CODE_READ;
    if (strcmp(s, "destructive") == 0) return CODE_DESTRUCTIVE;
    return CODE_WRITE;
}

static int ci_contains(const char *hay, const char *needle) {
    if (!needle || !*needle) return 1;
    if (!hay || !*hay) return 0;
    size_t nlen = strlen(needle);
    for (const char *p = hay; *p; p++) {
        size_t i = 0;
        while (i < nlen && p[i] && tolower((unsigned char)p[i]) == tolower((unsigned char)needle[i])) i++;
        if (i == nlen) return 1;
    }
    return 0;
}

static const char *req_str(json_object *req, const char *key, const char *def) {
    json_object *v = NULL;
    if (json_object_object_get_ex(req, key, &v) && v && json_object_is_type(v, json_type_string))
        return json_object_get_string(v);
    return def;
}

static int req_int(json_object *req, const char *key, int def) {
    json_object *v = NULL;
    if (json_object_object_get_ex(req, key, &v) && v &&
        (json_object_is_type(v, json_type_int) || json_object_is_type(v, json_type_double)))
        return json_object_get_int(v);
    return def;
}

static int64_t req_i64(json_object *req, const char *key, int64_t def) {
    json_object *v = NULL;
    if (json_object_object_get_ex(req, key, &v) && v &&
        (json_object_is_type(v, json_type_int) || json_object_is_type(v, json_type_double)))
        return json_object_get_int64(v);
    return def;
}

static int64_t req_clamped_i64(json_object *req, const char *key, int64_t def, int64_t minv, int64_t maxv) {
    int64_t x = req_i64(req, key, def);
    if (x < minv) return minv;
    if (x > maxv) return maxv;
    return x;
}

static void handle_rpc_discover(struct daemon_state *d, int fd, pthread_mutex_t *write_mu,
                                json_object *id_obj, json_object *req) {
    const char *project = req_str(req, "project", "");
    const char *server = req_str(req, "server", "");
    if (!*server) {
        json_object *er = make_err_resp(id_obj, "discover requires server name", 0);
        daemon_write_json(fd, write_mu, er, d->line_cap);
        json_object_put(er);
        return;
    }
    char *tools_json = NULL, *err = NULL;
    long long meta_gen = 0;
    if (code_pool_discover(d->pool, project, server, &tools_json, &meta_gen, &err) != 0) {
        json_object *er = make_err_resp(id_obj, err ? err : "discover failed", 0);
        free(err);
        daemon_write_json(fd, write_mu, er, d->line_cap);
        json_object_put(er);
        return;
    }
    json_object *tools = tools_json ? json_tokener_parse(tools_json) : NULL;
    free(tools_json);
    if (!tools || !json_object_is_type(tools, json_type_array)) {
        if (tools) json_object_put(tools);
        tools = json_object_new_array();
    }
    json_object *resp = json_object_new_object();
    if (id_obj) json_object_object_add(resp, "id", json_object_get(id_obj));
    json_object_object_add(resp, "ok", json_object_new_boolean(1));
    json_object_object_add(resp, "server", json_object_new_string(server));
    json_object_object_add(resp, "meta_gen", json_object_new_int64(meta_gen));
    json_object_object_add(resp, "tools", tools);
    daemon_write_json(fd, write_mu, resp, d->line_cap);
    json_object_put(resp);
}

static void handle_rpc_restart(struct daemon_state *d, int fd, pthread_mutex_t *write_mu,
                               json_object *id_obj, json_object *req) {
    const char *project = req_str(req, "project", "");
    const char *server = req_str(req, "server", "");
    const char *want_reg = req_str(req, "reg_id", "");
    const char *errmsg = NULL;
    if (!*project || !*server) errmsg = "restart requires project and server";
    char *kerr = NULL;
    sqlite3 *db = errmsg ? NULL : kb_open_timeout(d->db_path, &kerr, 5000);
    free(kerr);
    if (!errmsg && !db) errmsg = "restart: database unavailable";
    if (!errmsg) {
        /* The registration is re-read here; the instance to stop is exactly (its reg_id, its owner). */
        struct code_server_row srv;
        if (kb_code_server_get(db, project, server, &srv) != 0) {
            errmsg = "restart: unknown server";
        } else if (*want_reg && strcmp(want_reg, srv.reg_id) != 0) {
            errmsg = "restart: server registration changed; retry";
            kb_code_server_free(&srv);
        } else {
            const char *owner = code_owner_project(&srv, project);
            char owner_buf[PATH_MAX];
            snprintf(owner_buf, sizeof owner_buf, "%s", owner ? owner : "");
            code_pool_stop_inst(d->pool, srv.reg_id, owner_buf);
            code_pool_reset_crashes_inst(d->pool, srv.reg_id, owner_buf);
            kb_code_server_free(&srv);
        }
    }
    if (db) sqlite3_close(db);
    json_object *resp = errmsg ? make_err_resp(id_obj, errmsg, 0) : json_object_new_object();
    if (!errmsg) {
        if (id_obj) json_object_object_add(resp, "id", json_object_get(id_obj));
        json_object_object_add(resp, "ok", json_object_new_boolean(1));
    }
    daemon_write_json(fd, write_mu, resp, d->line_cap);
    json_object_put(resp);
}

/* A registration was replaced or removed: stop that registration's instances (by its OLD reg_id) and nothing else. */
static void handle_rpc_reload(struct daemon_state *d, int fd, pthread_mutex_t *write_mu,
                              json_object *id_obj, json_object *req) {
    const char *reg_id = req_str(req, "reg_id", "");
    json_object *resp;
    if (!*reg_id) {
        resp = make_err_resp(id_obj, "reload requires reg_id", 0);
    } else {
        code_pool_stop_reg(d->pool, reg_id);
        resp = json_object_new_object();
        if (id_obj) json_object_object_add(resp, "id", json_object_get(id_obj));
        json_object_object_add(resp, "ok", json_object_new_boolean(1));
    }
    daemon_write_json(fd, write_mu, resp, d->line_cap);
    json_object_put(resp);
}

static void handle_rpc_find(struct daemon_state *d, int fd, pthread_mutex_t *write_mu,
                            json_object *id_obj, json_object *req) {
    const char *project = req_str(req, "project", "");
    const char *query = req_str(req, "query", "");
    const char *filter_srv = req_str(req, "server", "");
    const char *filter_tool = req_str(req, "tool", "");

    char *kerr = NULL;
    sqlite3 *db = kb_open_timeout(d->db_path, &kerr, 5000);
    if (!db) {
        json_object *er = make_err_resp(id_obj, kerr ? kerr : "database unavailable", 0);
        free(kerr);
        daemon_write_json(fd, write_mu, er, d->line_cap);
        json_object_put(er);
        return;
    }

    json_object *matches = json_object_new_array();
    json_object *schemas = json_object_new_array();
    json_object *uncat = json_object_new_array();

    /* 1. Registered servers (passive DB read only, never spawns servers). */
    char *slist_str = kb_code_server_list_json(db, project);
    json_object *slist = slist_str ? json_tokener_parse(slist_str) : NULL;
    free(slist_str);
    if (slist && json_object_is_type(slist, json_type_array)) {
        size_t ns = json_object_array_length(slist);
        for (size_t i = 0; i < ns; i++) {
            json_object *srow = json_object_array_get_idx(slist, i);
            const char *sname = req_str(srow, "name", "");
            const char *reg_id = req_str(srow, "reg_id", "");
            const char *scope_proj = req_str(srow, "scope_project", "");
            json_object *jiso = NULL;
            int isolated = (json_object_object_get_ex(srow, "isolated", &jiso) && jiso && json_object_get_boolean(jiso));
            if (*filter_srv && strcmp(filter_srv, sname) != 0) continue;

            const char *owner = *scope_proj ? scope_proj : (isolated ? project : "");
            char *tjson = NULL;
            long long gen = 0;
            if (kb_code_catalog_get(db, reg_id, owner, &tjson, &gen) != 0 || !tjson || !*tjson) {
                free(tjson);
                json_object_array_add(uncat, json_object_new_string(sname));
                continue;
            }
            json_object *tarr = json_tokener_parse(tjson);
            free(tjson);
            if (!tarr || !json_object_is_type(tarr, json_type_array)) {
                if (tarr) json_object_put(tarr);
                json_object_array_add(uncat, json_object_new_string(sname));
                continue;
            }
            size_t nt = json_object_array_length(tarr);
            for (size_t j = 0; j < nt; j++) {
                json_object *t = json_object_array_get_idx(tarr, j);
                const char *tname = req_str(t, "name", "");
                const char *tdesc = req_str(t, "description", "");
                const char *tcls_s = req_str(t, "class", req_str(t, "base_class", "write"));
                if (!*tname) continue;
                if (*filter_tool && strcmp(filter_tool, tname) != 0) continue;
                if (*query && !ci_contains(sname, query) && !ci_contains(tname, query) && !ci_contains(tdesc, query))
                    continue;

                enum code_class base = daemon_parse_class(tcls_s);
                enum code_class eff = base;
                int granted = (*project && kb_code_check_grant(db, project, reg_id, tname, base, &eff, NULL) == 0);

                json_object *item = json_object_new_object();
                json_object_object_add(item, "server", json_object_new_string(sname));
                json_object_object_add(item, "name", json_object_new_string(tname));
                json_object_object_add(item, "description", json_object_new_string(tdesc));
                json_object_object_add(item, "class", json_object_new_string(daemon_class_str(eff)));
                json_object_object_add(item, "granted", json_object_new_boolean(granted));
                json_object_array_add(matches, item);

                json_object *jschema = NULL;
                if (json_object_object_get_ex(t, "inputSchema", &jschema) && jschema)
                    json_object_array_add(schemas, json_object_get(jschema));
                else
                    json_object_array_add(schemas, json_object_new_object());
            }
            json_object_put(tarr);
        }
    }
    if (slist) json_object_put(slist);

    /* 2. Virtual "cntctr" allowlist. */
    if (!*filter_srv || strcmp(filter_srv, "cntctr") == 0) {
        size_t nv = sizeof CNTCTR_VTOOLS / sizeof *CNTCTR_VTOOLS;
        for (size_t i = 0; i < nv; i++) {
            const struct cntctr_vtool *vt = &CNTCTR_VTOOLS[i];
            if (*filter_tool && strcmp(filter_tool, vt->name) != 0) continue;
            if (*query && !ci_contains("cntctr", query) && !ci_contains(vt->name, query) && !ci_contains(vt->description, query))
                continue;
            enum code_class eff = vt->base_class;
            int granted = (*project && kb_code_check_grant(db, project, "cntctr", vt->name, vt->base_class, &eff, NULL) == 0);
            json_object *item = json_object_new_object();
            json_object_object_add(item, "server", json_object_new_string("cntctr"));
            json_object_object_add(item, "name", json_object_new_string(vt->name));
            json_object_object_add(item, "description", json_object_new_string(vt->description));
            json_object_object_add(item, "class", json_object_new_string(daemon_class_str(eff)));
            json_object_object_add(item, "granted", json_object_new_boolean(granted));
            json_object_array_add(matches, item);

            json_object *sc = json_tokener_parse(vt->schema_json);
            json_object_array_add(schemas, sc ? sc : json_object_new_object());
        }
    }
    sqlite3_close(db);

    /* Attach full inputSchema ONLY when a single tool is matched or explicitly requested. */
    if (json_object_array_length(matches) == 1 || *filter_tool) {
        size_t nm = json_object_array_length(matches);
        for (size_t i = 0; i < nm; i++) {
            json_object *item = json_object_array_get_idx(matches, i);
            json_object *sc = json_object_array_get_idx(schemas, i);
            if (item && sc) json_object_object_add(item, "inputSchema", json_object_get(sc));
        }
    }
    json_object_put(schemas);

    json_object *resp = json_object_new_object();
    if (id_obj) json_object_object_add(resp, "id", json_object_get(id_obj));
    json_object_object_add(resp, "ok", json_object_new_boolean(1));
    json_object_object_add(resp, "tools", matches);
    json_object_object_add(resp, "uncatalogued", uncat);
    daemon_write_json(fd, write_mu, resp, d->line_cap);
    json_object_put(resp);
}

static void handle_rpc_expand(struct daemon_state *d, int fd, pthread_mutex_t *write_mu,
                              json_object *id_obj, json_object *req) {
    const char *project = req_str(req, "project", "");
    const char *run_id = req_str(req, "run_id", req_str(req, "run", ""));
    const char *part = req_str(req, "part", "result");
    int64_t off_i = req_i64(req, "offset", 0);
    int64_t lim_i = req_i64(req, "limit", 65536);
    if (off_i < 0) off_i = 0;
    if (lim_i <= 0 || lim_i > 65536) lim_i = 65536;

    if (!*project || !*run_id) {
        json_object *er = make_err_resp(id_obj, "expand requires project and run_id", 0);
        daemon_write_json(fd, write_mu, er, d->line_cap);
        json_object_put(er);
        return;
    }

    char *kerr = NULL;
    sqlite3 *db = kb_open_timeout(d->db_path, &kerr, 5000);
    if (!db) {
        json_object *er = make_err_resp(id_obj, kerr ? kerr : "database unavailable", 0);
        free(kerr);
        daemon_write_json(fd, write_mu, er, d->line_cap);
        json_object_put(er);
        return;
    }

    char *slice = NULL;
    size_t total_len = 0;
    int retained_capped = 0;
    int rc = kb_code_run_expand(db, project, run_id, part, (size_t)off_i, (size_t)lim_i,
                                &slice, &total_len, &retained_capped, NULL);
    sqlite3_close(db);

    if (rc == -2) {
        free(slice);
        json_object *er = make_err_resp(id_obj, "run store unavailable", 0);
        daemon_write_json(fd, write_mu, er, d->line_cap);
        json_object_put(er);
        return;
    }
    if (rc == 1) {
        free(slice);
        json_object *er = make_err_resp(id_obj, "run expired", 0);
        daemon_write_json(fd, write_mu, er, d->line_cap);
        json_object_put(er);
        return;
    }
    if (rc != 0) {
        free(slice);
        json_object *er = make_err_resp(id_obj, "run not found", 0);
        daemon_write_json(fd, write_mu, er, d->line_cap);
        json_object_put(er);
        return;
    }

    json_object *resp = json_object_new_object();
    if (id_obj) json_object_object_add(resp, "id", json_object_get(id_obj));
    json_object_object_add(resp, "ok", json_object_new_boolean(1));
    json_object_object_add(resp, "run_id", json_object_new_string(run_id));
    json_object_object_add(resp, "part", json_object_new_string(part));
    json_object_object_add(resp, "offset", json_object_new_int64(off_i));
    json_object_object_add(resp, "total_len", json_object_new_int64((int64_t)total_len));
    json_object_object_add(resp, "retained_capped", json_object_new_boolean(retained_capped != 0));
    json_object_object_add(resp, "slice", json_object_new_string(slice ? slice : ""));
    free(slice);
    daemon_write_json(fd, write_mu, resp, d->line_cap);
    json_object_put(resp);
}

/* ---- `run` RPC: passive catalog load, QuickJS run thread, concurrent conn_fd reader & reverse RPC ---- */

struct pending_rev {
    int64_t id;
    struct code_call_handle *h;
    struct pending_rev *next;
};

struct run_bridge_ctx {
    struct daemon_state *d;
    const char *project;
    int conn_fd;
    pthread_mutex_t *write_mu;
    pthread_mutex_t rev_mu;
    int64_t next_rev_id;
    int conn_closed;
    struct pending_rev *revs;
};

static void run_bridge_dispatch(void *opaque, const char *server, const char *reg_id, long long meta_gen,
                                const char *tool, json_object *args_owned, int timeout_ms,
                                struct code_call_handle *h) {
    struct run_bridge_ctx *b = (struct run_bridge_ctx *)opaque;
    if (strcmp(server, "cntctr") == 0) {
        struct pending_rev *pr = calloc(1, sizeof *pr);
        if (!pr) abort();
        pthread_mutex_lock(&b->rev_mu);
        if (b->conn_closed) {
            pthread_mutex_unlock(&b->rev_mu);
            free(pr);
            if (args_owned) json_object_put(args_owned);
            code_js_complete(h, CODE_CALL_ERROR, "client disconnected", 0, NULL);
            code_call_handle_unref(h);
            return;
        }
        int64_t rid = b->next_rev_id++;
        pr->id = rid;
        pr->h = h;
        pr->next = b->revs;
        b->revs = pr;
        pthread_mutex_unlock(&b->rev_mu);

        json_object *rreq = json_object_new_object();
        json_object_object_add(rreq, "id", json_object_new_int64(rid));
        json_object_object_add(rreq, "method", json_object_new_string("rev_call"));
        json_object_object_add(rreq, "tool", json_object_new_string(tool ? tool : ""));
        json_object_object_add(rreq, "args", args_owned ? args_owned : json_object_new_object());

        struct io_budget wb = make_budget(timeout_ms > 0 && timeout_ms < 5000 ? timeout_ms : 5000,
                                          NULL, NULL, b->d->line_cap);
        char *werr = NULL;
        int wrc = write_json_line(b->conn_fd, b->write_mu, rreq, &wb, &werr);
        json_object_put(rreq);
        if (wrc != 0) {
            struct code_call_handle *reclaimed = NULL;
            pthread_mutex_lock(&b->rev_mu);
            struct pending_rev **pp = &b->revs;
            while (*pp) {
                if (*pp == pr) {
                    *pp = pr->next;
                    reclaimed = pr->h;
                    free(pr);
                    break;
                }
                pp = &(*pp)->next;
            }
            pthread_mutex_unlock(&b->rev_mu);
            if (reclaimed) {
                code_js_complete(reclaimed, CODE_CALL_ERROR, werr ? werr : "reverse RPC write failed", 0, NULL);
                code_call_handle_unref(reclaimed);
            }
        }
        free(werr);
        return;
    }

    code_pool_dispatch(b->d->pool, b->project, server, reg_id, meta_gen, tool, args_owned, timeout_ms, h);
}

static void run_bridge_cancel(void *opaque, struct code_call_handle *h) {
    struct run_bridge_ctx *b = (struct run_bridge_ctx *)opaque;
    struct code_call_handle *reclaimed = NULL;
    pthread_mutex_lock(&b->rev_mu);
    struct pending_rev **pp = &b->revs;
    while (*pp) {
        if ((*pp)->h == h) {
            struct pending_rev *cur = *pp;
            *pp = cur->next;
            reclaimed = cur->h;
            free(cur);
            break;
        }
        pp = &(*pp)->next;
    }
    pthread_mutex_unlock(&b->rev_mu);
    if (reclaimed) {
        code_call_handle_unref(reclaimed);
        return;
    }
    code_pool_cancel_call(b->d->pool, h);
}

struct run_exec_args {
    struct code_run_opts opts;
    struct code_run_out out;
    int done_wfd;
    int rc;
};

static void *run_exec_thread_main(void *arg) {
    struct run_exec_args *ea = (struct run_exec_args *)arg;
    ea->rc = code_js_run(&ea->opts, &ea->out);
    char b = 'd';
    ssize_t n = write(ea->done_wfd, &b, 1);
    (void)n;
    return NULL;
}

static void free_loaded_catalog(struct code_tool_meta *cat, size_t ncat,
                                struct code_server_hint *srvs, size_t nsrvs) {
    for (size_t i = 0; i < ncat; i++) {
        free(cat[i].server);
        free(cat[i].reg_id);
        free(cat[i].name);
        free(cat[i].description);
        if (cat[i].input_schema) json_object_put(cat[i].input_schema);
    }
    free(cat);
    for (size_t i = 0; i < nsrvs; i++) {
        free(srvs[i].name);
        free(srvs[i].reg_id);
    }
    free(srvs);
}

/* Passive DB load of server hints & cached catalogs for project (never starts servers!). */
static int load_passive_catalog(const char *db_path, const char *project,
                                struct code_tool_meta **cat_out, size_t *ncat_out,
                                struct code_server_hint **srvs_out, size_t *nsrvs_out, char **err) {
    *cat_out = NULL;
    *ncat_out = 0;
    *srvs_out = NULL;
    *nsrvs_out = 0;

    sqlite3 *db = kb_open_timeout(db_path, err, 5000);
    if (!db) return -1;

    struct code_tool_meta *cat = NULL;
    size_t ncat = 0, ccap = 0;
    struct code_server_hint *srvs = NULL;
    size_t nsrvs = 0, scap = 0;

    char *slist_str = kb_code_server_list_json(db, project);
    json_object *slist = slist_str ? json_tokener_parse(slist_str) : NULL;
    free(slist_str);

    if (slist && json_object_is_type(slist, json_type_array)) {
        size_t ns = json_object_array_length(slist);
        for (size_t i = 0; i < ns; i++) {
            json_object *srow = json_object_array_get_idx(slist, i);
            const char *sname = req_str(srow, "name", "");
            const char *reg_id = req_str(srow, "reg_id", "");
            const char *scope_proj = req_str(srow, "scope_project", "");
            json_object *jiso = NULL;
            int isolated = (json_object_object_get_ex(srow, "isolated", &jiso) && jiso && json_object_get_boolean(jiso));
            if (!*sname || !*reg_id) continue;

            const char *owner = *scope_proj ? scope_proj : (isolated ? project : "");
            char *tjson = NULL;
            long long gen = 0;
            int has_cat = 0;
            if (kb_code_catalog_get(db, reg_id, owner, &tjson, &gen) == 0 && tjson && *tjson) {
                json_object *tarr = json_tokener_parse(tjson);
                if (tarr && json_object_is_type(tarr, json_type_array)) {
                    has_cat = 1;
                    size_t nt = json_object_array_length(tarr);
                    for (size_t j = 0; j < nt; j++) {
                        json_object *t = json_object_array_get_idx(tarr, j);
                        const char *tname = req_str(t, "name", "");
                        if (!*tname) continue;
                        const char *tdesc = req_str(t, "description", "");
                        const char *tcls = req_str(t, "class", req_str(t, "base_class", "write"));
                        json_object *jschema = NULL;
                        json_object_object_get_ex(t, "inputSchema", &jschema);

                        if (ncat >= ccap) {
                            ccap = ccap ? ccap * 2 : 16;
                            cat = realloc(cat, ccap * sizeof *cat);
                            if (!cat) abort();
                        }
                        cat[ncat].server = strdup(sname);
                        cat[ncat].reg_id = strdup(reg_id);
                        cat[ncat].name = strdup(tname);
                        cat[ncat].description = strdup(tdesc);
                        cat[ncat].meta_gen = gen;
                        cat[ncat].base_class = daemon_parse_class(tcls);
                        cat[ncat].input_schema = (jschema && json_object_is_type(jschema, json_type_object))
                                                     ? json_object_get(jschema)
                                                     : NULL;
                        ncat++;
                    }
                }
                if (tarr) json_object_put(tarr);
            }
            free(tjson);

            if (nsrvs >= scap) {
                scap = scap ? scap * 2 : 8;
                srvs = realloc(srvs, scap * sizeof *srvs);
                if (!srvs) abort();
            }
            srvs[nsrvs].name = strdup(sname);
            srvs[nsrvs].reg_id = strdup(reg_id);
            srvs[nsrvs].has_catalog = has_cat;
            nsrvs++;
        }
    }
    if (slist) json_object_put(slist);
    sqlite3_close(db);

    /* Virtual "cntctr" server + static allowlist tools. */
    if (nsrvs >= scap) {
        scap = scap ? scap * 2 : 8;
        srvs = realloc(srvs, scap * sizeof *srvs);
        if (!srvs) abort();
    }
    srvs[nsrvs].name = strdup("cntctr");
    srvs[nsrvs].reg_id = strdup("cntctr");
    srvs[nsrvs].has_catalog = 1;
    nsrvs++;

    size_t nv = sizeof CNTCTR_VTOOLS / sizeof *CNTCTR_VTOOLS;
    for (size_t i = 0; i < nv; i++) {
        const struct cntctr_vtool *vt = &CNTCTR_VTOOLS[i];
        if (ncat >= ccap) {
            ccap = ccap ? ccap * 2 : 16;
            cat = realloc(cat, ccap * sizeof *cat);
            if (!cat) abort();
        }
        cat[ncat].server = strdup("cntctr");
        cat[ncat].reg_id = strdup("cntctr");
        cat[ncat].name = strdup(vt->name);
        cat[ncat].description = strdup(vt->description);
        cat[ncat].meta_gen = 1;
        cat[ncat].base_class = vt->base_class;
        cat[ncat].input_schema = json_tokener_parse(vt->schema_json);
        ncat++;
    }

    *cat_out = cat;
    *ncat_out = ncat;
    *srvs_out = srvs;
    *nsrvs_out = nsrvs;
    return 0;
}

static void script_fnv1a_hex(const char *s, char out[17]) {
    uint64_t h = 14695981039346656037ULL;
    if (s) {
        for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
            h ^= (uint64_t)*p;
            h *= 1099511628211ULL;
        }
    }
    snprintf(out, 17, "%016llx", (unsigned long long)h);
}

static void handle_rev_line_during_run(struct run_bridge_ctx *b, struct code_run_cancel *cancel, const char *line) {
    json_object *msg = json_tokener_parse(line);
    if (!msg || !json_object_is_type(msg, json_type_object)) {
        if (msg) json_object_put(msg);
        return;
    }
    json_object *jm = NULL;
    if (json_object_object_get_ex(msg, "method", &jm) && jm && json_object_is_type(jm, json_type_string)) {
        if (strcmp(json_object_get_string(jm), "cancel") == 0) {
            code_run_cancel_signal(cancel, "cancelled by client");
        }
        json_object_put(msg);
        return;
    }

    json_object *jid = NULL;
    if (json_object_object_get_ex(msg, "id", &jid) && jid &&
        (json_object_is_type(jid, json_type_int) || json_object_is_type(jid, json_type_double))) {
        int64_t rid = json_object_get_int64(jid);
        struct code_call_handle *h = NULL;
        pthread_mutex_lock(&b->rev_mu);
        struct pending_rev **pp = &b->revs;
        while (*pp) {
            if ((*pp)->id == rid) {
                struct pending_rev *cur = *pp;
                *pp = cur->next;
                h = cur->h;
                free(cur);
                break;
            }
            pp = &(*pp)->next;
        }
        pthread_mutex_unlock(&b->rev_mu);
        if (h) {
            json_object *jok = NULL, *jres = NULL, *jerr = NULL;
            int ok = (json_object_object_get_ex(msg, "ok", &jok) && jok && json_object_get_boolean(jok));
            if (ok && json_object_object_get_ex(msg, "result", &jres) && jres) {
                if (json_object_is_type(jres, json_type_string)) {
                    code_js_complete(h, CODE_CALL_OK, json_object_get_string(jres), 0, NULL);
                } else {
                    const char *rs = json_object_to_json_string_ext(jres, JSON_C_TO_STRING_PLAIN);
                    code_js_complete(h, CODE_CALL_OK, rs ? rs : "null", 1, NULL);
                }
            } else {
                const char *es = (json_object_object_get_ex(msg, "error", &jerr) && jerr &&
                                  json_object_is_type(jerr, json_type_string))
                                     ? json_object_get_string(jerr)
                                     : "reverse RPC failed";
                code_js_complete(h, CODE_CALL_ERROR, es, 0, NULL);
            }
            code_call_handle_unref(h);
        }
    }
    json_object_put(msg);
}

static void handle_rpc_run(struct daemon_state *d, int fd, struct line_reader *lr,
                           pthread_mutex_t *write_mu, json_object *id_obj, json_object *req) {
    const char *project = req_str(req, "project", "");
    const char *caller = req_str(req, "caller", "agent");
    const char *script = req_str(req, "script", "");
    if (!*project || !*script) {
        json_object *er = make_err_resp(id_obj, "run requires project and script", 0);
        daemon_write_json(fd, write_mu, er, d->line_cap);
        json_object_put(er);
        return;
    }

    int done_pipe[2] = {-1, -1};
    if (pipe(done_pipe) != 0) {
        json_object *er = make_err_resp(id_obj, "pipe failed", 0);
        daemon_write_json(fd, write_mu, er, d->line_cap);
        json_object_put(er);
        return;
    }
    (void)fcntl(done_pipe[0], F_SETFD, FD_CLOEXEC);
    (void)fcntl(done_pipe[1], F_SETFD, FD_CLOEXEC);
    (void)fcntl(done_pipe[0], F_SETFL, O_NONBLOCK);
    (void)fcntl(done_pipe[1], F_SETFL, O_NONBLOCK);

    struct code_run_cancel *cancel = code_run_cancel_new();
    if (!cancel) {
        close(done_pipe[0]);
        close(done_pipe[1]);
        json_object *er = make_err_resp(id_obj, "out of memory", 0);
        daemon_write_json(fd, write_mu, er, d->line_cap);
        json_object_put(er);
        return;
    }

    struct active_run ar;
    memset(&ar, 0, sizeof ar);
    ar.wake_fd = -1;
    ar.cancel = cancel;

    uint64_t rseq = 0;
    pthread_mutex_lock(&d->mu);
    if (d->draining) {
        pthread_mutex_unlock(&d->mu);
        code_run_cancel_free(cancel);
        close(done_pipe[0]);
        close(done_pipe[1]);
        json_object *er = make_err_resp(id_obj, "cntctr is upgrading; retry in a few seconds", 1);
        daemon_write_json(fd, write_mu, er, d->line_cap);
        json_object_put(er);
        return;
    }
    if (d->active_runs >= d->max_runs) {
        int cur = d->active_runs, mx = d->max_runs;
        pthread_mutex_unlock(&d->mu);
        code_run_cancel_free(cancel);
        close(done_pipe[0]);
        close(done_pipe[1]);
        char *em = dfmt("max concurrent runs reached (%d/%d; raise CNTCTR_CODE_MAX_RUNS)", cur, mx);
        json_object *er = make_err_resp(id_obj, em, 1);
        free(em);
        daemon_write_json(fd, write_mu, er, d->line_cap);
        json_object_put(er);
        return;
    }
    d->active_runs++;
    rseq = ++d->run_seq;
    ar.next = d->runs;
    d->runs = &ar;
    pthread_mutex_unlock(&d->mu);

    /* Passive catalog load from code_catalogs (never spawns tool servers up front). */
    struct code_tool_meta *cat = NULL;
    struct code_server_hint *srvs = NULL;
    size_t ncat = 0, nsrvs = 0;
    char *lerr = NULL;
    if (load_passive_catalog(d->db_path, project, &cat, &ncat, &srvs, &nsrvs, &lerr) != 0) {
        pthread_mutex_lock(&d->mu);
        struct active_run **pp = &d->runs;
        while (*pp) {
            if (*pp == &ar) { *pp = ar.next; break; }
            pp = &(*pp)->next;
        }
        d->active_runs--;
        daemon_wake(d);
        pthread_cond_broadcast(&d->cv);
        pthread_mutex_unlock(&d->mu);
        code_run_cancel_free(cancel);
        close(done_pipe[0]);
        close(done_pipe[1]);
        json_object *er = make_err_resp(id_obj, lerr ? lerr : "failed to load catalog", 0);
        free(lerr);
        daemon_write_json(fd, write_mu, er, d->line_cap);
        json_object_put(er);
        return;
    }

    /* Extract optional scope array. */
    const char **scope_arr = NULL;
    size_t nscope = 0;
    json_object *jscope = NULL;
    if (json_object_object_get_ex(req, "scope", &jscope) && jscope && json_object_is_type(jscope, json_type_array)) {
        size_t sl = json_object_array_length(jscope);
        if (sl > 0) {
            scope_arr = calloc(sl, sizeof *scope_arr);
            if (!scope_arr) abort();
            for (size_t i = 0; i < sl; i++) {
                json_object *el = json_object_array_get_idx(jscope, i);
                if (el && json_object_is_type(el, json_type_string))
                    scope_arr[nscope++] = json_object_get_string(el);
            }
        }
    }

    struct run_bridge_ctx bctx;
    memset(&bctx, 0, sizeof bctx);
    bctx.d = d;
    bctx.project = project;
    bctx.conn_fd = fd;
    bctx.write_mu = write_mu;
    pthread_mutex_init(&bctx.rev_mu, NULL);
    bctx.next_rev_id = 1000;

    struct run_exec_args ea;
    memset(&ea, 0, sizeof ea);
    ea.done_wfd = done_pipe[1];
    ea.opts.db_path = d->db_path;
    ea.opts.project = project;
    ea.opts.script = script;
    ea.opts.scope = scope_arr;
    ea.opts.nscope = nscope;
    ea.opts.catalog = cat;
    ea.opts.ncatalog = ncat;
    ea.opts.servers = srvs;
    ea.opts.nservers = nsrvs;
    ea.opts.max_mb = (size_t)req_clamped_i64(req, "max_mb", (int64_t)env_size("CNTCTR_CODE_MAX_MB", 64, 4, 256), 4, 256);
    ea.opts.cpu_sec = (int)req_clamped_i64(req, "cpu_sec", env_int("CNTCTR_CODE_CPU_SEC", 10, 1, 60), 1, 60);
    int64_t def_wall = req_i64(req, "wall_sec", env_int("CNTCTR_CODE_WALL_SEC", 300, 1, 1800));
    ea.opts.wall_sec = (int)req_clamped_i64(req, "timeout", def_wall, 1, 1800);
    ea.opts.call_sec = (int)req_clamped_i64(req, "call_sec", d->call_sec, 1, 300);
    ea.opts.max_inflight = (int)req_clamped_i64(req, "max_inflight", env_int("CNTCTR_CODE_MAX_INFLIGHT", 16, 1, 64), 1, 64);
    ea.opts.max_queue_bytes = (size_t)req_clamped_i64(req, "max_queue_bytes", (int64_t)env_size("CNTCTR_CODE_MAX_QUEUE_BYTES", 8388608, 4096, 67108864), 4096, 67108864);
    ea.opts.result_cap_bytes = (size_t)req_clamped_i64(req, "result_cap_bytes", (int64_t)env_size("CNTCTR_CODE_RESULT_BYTES", 16384, 256, 262144), 256, 262144);
    ea.opts.calls_preview_bytes = (size_t)req_clamped_i64(req, "calls_preview_bytes", 8192, 256, 65536);
    ea.opts.max_log_bytes = (size_t)req_clamped_i64(req, "max_log_bytes", (int64_t)env_size("CNTCTR_CODE_MAX_LOG_BYTES", 1048576, 1024, 16777216), 1024, 16777216);
    ea.opts.cancel = cancel;
    ea.opts.dispatch = run_bridge_dispatch;
    ea.opts.cancel_call = run_bridge_cancel;
    ea.opts.dispatch_ctx = &bctx;

    pthread_t exec_tid;
    int client_gone = 0;
    if (pthread_create(&exec_tid, NULL, run_exec_thread_main, &ea) != 0) {
        free(scope_arr);
        free_loaded_catalog(cat, ncat, srvs, nsrvs);
        pthread_mutex_destroy(&bctx.rev_mu);
        pthread_mutex_lock(&d->mu);
        struct active_run **pp = &d->runs;
        while (*pp) {
            if (*pp == &ar) { *pp = ar.next; break; }
            pp = &(*pp)->next;
        }
        d->active_runs--;
        daemon_wake(d);
        pthread_cond_broadcast(&d->cv);
        pthread_mutex_unlock(&d->mu);
        code_run_cancel_free(cancel);
        close(done_pipe[0]);
        close(done_pipe[1]);
        json_object *er = make_err_resp(id_obj, "failed to start run execution thread", 0);
        daemon_write_json(fd, write_mu, er, d->line_cap);
        json_object_put(er);
        return;
    }

    /* Concurrently poll conn_fd (reverse-RPC replies & client disconnect/cancel) and done_pipe[0]. */
    for (;;) {
        /* Drain any complete lines already buffered in lr before polling. */
        while (!client_gone && lr->len > 0) {
            char *nl = memchr(lr->buf, '\n', lr->len);
            if (!nl) break;
            size_t llen = (size_t)(nl - lr->buf);
            size_t clean = (llen > 0 && lr->buf[llen - 1] == '\r') ? llen - 1 : llen;
            char *line = malloc(clean + 1);
            if (!line) abort();
            memcpy(line, lr->buf, clean);
            line[clean] = '\0';
            size_t rem = lr->len - (llen + 1);
            if (rem > 0) memmove(lr->buf, nl + 1, rem);
            lr->len = rem;
            handle_rev_line_during_run(&bctx, cancel, line);
            free(line);
        }

        struct pollfd pf[2];
        int nfds = 0;
        pf[nfds].fd = done_pipe[0];
        pf[nfds].events = POLLIN;
        pf[nfds].revents = 0;
        nfds++;
        int conn_idx = -1;
        if (!client_gone) {
            conn_idx = nfds;
            pf[nfds].fd = fd;
            pf[nfds].events = POLLIN;
            pf[nfds].revents = 0;
            nfds++;
        }

        int pr = poll(pf, (nfds_t)nfds, 200);
        if (pr < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (pf[0].revents & (POLLIN | POLLHUP)) break;

        if (conn_idx >= 0 && (pf[conn_idx].revents & (POLLHUP | POLLERR | POLLNVAL))) {
            client_gone = 1;
            pthread_mutex_lock(&bctx.rev_mu);
            bctx.conn_closed = 1;
            pthread_mutex_unlock(&bctx.rev_mu);
            code_run_cancel_signal(cancel, "client disconnected");
            continue;
        }
        if (conn_idx >= 0 && (pf[conn_idx].revents & POLLIN)) {
            if (lr->cap - lr->len < 4096) {
                size_t nc = lr->cap ? lr->cap * 2 : 4096;
                if (nc > lr->max_line + 1) nc = lr->max_line + 1;
                if (nc <= lr->len) {
                    client_gone = 1;
                    pthread_mutex_lock(&bctx.rev_mu);
                    bctx.conn_closed = 1;
                    pthread_mutex_unlock(&bctx.rev_mu);
                    code_run_cancel_signal(cancel, "IPC line limit exceeded");
                    continue;
                }
                char *nb = realloc(lr->buf, nc);
                if (!nb) abort();
                lr->buf = nb;
                lr->cap = nc;
            }
            ssize_t rn = read(fd, lr->buf + lr->len, lr->cap - lr->len);
            if (rn == 0 || (rn < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)) {
                client_gone = 1;
                pthread_mutex_lock(&bctx.rev_mu);
                bctx.conn_closed = 1;
                pthread_mutex_unlock(&bctx.rev_mu);
                code_run_cancel_signal(cancel, "client disconnected");
            } else if (rn > 0) {
                lr->len += (size_t)rn;
            }
        }
    }

    pthread_join(exec_tid, NULL);

    /* Clean up any remaining reverse-RPC handles. */
    struct pending_rev *rem_revs = NULL;
    pthread_mutex_lock(&bctx.rev_mu);
    bctx.conn_closed = 1;
    rem_revs = bctx.revs;
    bctx.revs = NULL;
    pthread_mutex_unlock(&bctx.rev_mu);
    while (rem_revs) {
        struct pending_rev *nx = rem_revs->next;
        if (rem_revs->h) code_call_handle_unref(rem_revs->h);
        free(rem_revs);
        rem_revs = nx;
    }
    pthread_mutex_destroy(&bctx.rev_mu);

    /* Persist run result/logs/calls/denied in code_runs. */
    char run_id[64];
    snprintf(run_id, sizeof run_id, "r-%llx-%ld-%llu",
             (unsigned long long)time(NULL), (long)getpid(), (unsigned long long)rseq);
    char shash[17];
    script_fnv1a_hex(script, shash);
    {
        char *kerr = NULL;
        sqlite3 *db = kb_open_timeout(d->db_path, &kerr, 5000);
        free(kerr);
        if (db) {
            (void)kb_code_run_save(db, run_id, project, caller, shash,
                                   ea.out.result, ea.out.logs, ea.out.calls, ea.out.denied,
                                   ea.out.retained_capped, d->run_ttl_sec);
            sqlite3_close(db);
        }
    }

    if (!client_gone) {
        json_object *resp = json_object_new_object();
        if (id_obj) json_object_object_add(resp, "id", json_object_get(id_obj));
        json_object_object_add(resp, "ok", json_object_new_boolean(1));
        json_object_object_add(resp, "run_id", json_object_new_string(run_id));
        json_object_object_add(resp, "is_error", json_object_new_boolean(ea.out.is_error != 0));
        json_object_object_add(resp, "retained_capped", json_object_new_boolean(ea.out.retained_capped != 0));
        json_object_object_add(resp, "result", json_object_new_string(ea.out.result_preview ? ea.out.result_preview : ""));
        json_object_object_add(resp, "logs", json_object_new_string(ea.out.logs_preview ? ea.out.logs_preview : ""));
        json_object_object_add(resp, "calls", json_object_new_string(ea.out.calls_preview ? ea.out.calls_preview : ""));
        json_object_object_add(resp, "denied", json_object_new_string(ea.out.denied_preview ? ea.out.denied_preview : ""));
        daemon_write_json(fd, write_mu, resp, d->line_cap);
        json_object_put(resp);
    }

    code_run_out_free(&ea.out);
    free(scope_arr);
    free_loaded_catalog(cat, ncat, srvs, nsrvs);

    pthread_mutex_lock(&d->mu);
    struct active_run **pp = &d->runs;
    while (*pp) {
        if (*pp == &ar) {
            *pp = ar.next;
            break;
        }
        pp = &(*pp)->next;
    }
    d->active_runs--;
    d->last_activity_ms = now_ms();
    daemon_wake(d);
    pthread_cond_broadcast(&d->cv);
    pthread_mutex_unlock(&d->mu);

    code_run_cancel_free(cancel);
    close(done_pipe[0]);
    close(done_pipe[1]);
}

static void *daemon_conn_thread(void *arg) {
    struct worker_conn *wc = arg;
    struct daemon_state *d = wc->d;
    int fd = wc->fd;

    pthread_mutex_t write_mu;
    pthread_mutex_init(&write_mu, NULL);
    struct line_reader lr;
    lr_init(&lr, fd, d->line_cap);

    int hello_done = 0;
    int version_mismatched = 0;
    int client_proto = 0;
    int client_semver_dir = 0; /* semver_cmp(client_ver, daemon_ver) */
    int handed_to_waiters = 0;
    int did_work = 0;

    for (;;) {
        pthread_mutex_lock(&d->mu);
        int is_exiting = d->exiting;
        pthread_mutex_unlock(&d->mu);
        if (is_exiting) break;

        struct io_budget rb = make_budget(hello_done ? 30000 : 5000, NULL, NULL, d->line_cap);
        char *line = NULL, *rerr = NULL;
        int rr = lr_read_line(&lr, &rb, &line, &rerr);
        free(rerr);
        if (rr != 0) {
            free(line);
            break;
        }
        json_object *req = json_tokener_parse(line);
        free(line);
        if (!req || !json_object_is_type(req, json_type_object)) {
            if (req) json_object_put(req);
            json_object *er = make_err_resp(NULL, "malformed JSON request", 0);
            daemon_write_json(fd, &write_mu, er, d->line_cap);
            json_object_put(er);
            break;
        }
        json_object *jid = NULL, *jm = NULL;
        json_object_object_get_ex(req, "id", &jid);
        json_object_object_get_ex(req, "method", &jm);
        const char *method = (jm && json_object_is_type(jm, json_type_string)) ? json_object_get_string(jm) : "";

        if (!hello_done) {
            if (strcmp(method, "hello") != 0) {
                json_object *er = make_err_resp(jid, "expected hello", 0);
                daemon_write_json(fd, &write_mu, er, d->line_cap);
                json_object_put(er);
                json_object_put(req);
                break;
            }
            json_object *jdb = NULL, *jver = NULL, *jproto = NULL;
            json_object_object_get_ex(req, "db", &jdb);
            json_object_object_get_ex(req, "version", &jver);
            json_object_object_get_ex(req, "proto", &jproto);
            const char *cdb = (jdb && json_object_is_type(jdb, json_type_string)) ? json_object_get_string(jdb) : "";
            const char *cver = (jver && json_object_is_type(jver, json_type_string)) ? json_object_get_string(jver) : "";
            int cproto = (jproto && json_object_is_type(jproto, json_type_int)) ? json_object_get_int(jproto) : 0;

            if (strcmp(cdb, d->db_path) != 0) {
                json_object *er = json_object_new_object();
                if (jid) json_object_object_add(er, "id", json_object_get(jid));
                json_object_object_add(er, "ok", json_object_new_boolean(0));
                json_object_object_add(er, "error", json_object_new_string("db_mismatch"));
                json_object_object_add(er, "daemon_db", json_object_new_string(d->db_path));
                json_object_object_add(er, "client_db", json_object_new_string(cdb));
                daemon_write_json(fd, &write_mu, er, d->line_cap);
                json_object_put(er);
                json_object_put(req);
                break;
            }

            pthread_mutex_lock(&d->mu);
            int draining = d->draining;
            pthread_mutex_unlock(&d->mu);

            hello_done = 1;
            client_proto = cproto;
            client_semver_dir = semver_cmp(cver, d->version);
            if (cproto != CODE_PROTO_VERSION || client_semver_dir != 0) {
                version_mismatched = 1;
                json_object *er = json_object_new_object();
                if (jid) json_object_object_add(er, "id", json_object_get(jid));
                json_object_object_add(er, "ok", json_object_new_boolean(0));
                json_object_object_add(er, "error", json_object_new_string("version_mismatch"));
                json_object_object_add(er, "daemon_version", json_object_new_string(d->version));
                json_object_object_add(er, "daemon_proto", json_object_new_int(CODE_PROTO_VERSION));
                json_object_object_add(er, "draining", json_object_new_boolean(draining));
                daemon_write_json(fd, &write_mu, er, d->line_cap);
                json_object_put(er);
                json_object_put(req);
                /* Keep connection open so a newer upgrader or compatible status/stop can proceed. */
                continue;
            }

            json_object *ok_resp = json_object_new_object();
            if (jid) json_object_object_add(ok_resp, "id", json_object_get(jid));
            json_object_object_add(ok_resp, "ok", json_object_new_boolean(1));
            json_object_object_add(ok_resp, "proto", json_object_new_int(CODE_PROTO_VERSION));
            json_object_object_add(ok_resp, "version", json_object_new_string(d->version));
            json_object_object_add(ok_resp, "pid", json_object_new_int64((int64_t)getpid()));
            json_object_object_add(ok_resp, "draining", json_object_new_boolean(draining));
            daemon_write_json(fd, &write_mu, ok_resp, d->line_cap);
            json_object_put(ok_resp);
            json_object_put(req);
            continue;
        }

        /* `status` is always allowed (including while draining or after version_mismatch). */
        if (strcmp(method, "status") == 0) {
            json_object *resp = build_status_resp(d, jid);
            daemon_write_json(fd, &write_mu, resp, d->line_cap);
            json_object_put(resp);
            json_object_put(req);
            continue;
        }

        /* `drain` (upgrade) and `stop` (explicit compatible CLI stop) enforce version/protocol direction. */
        if (strcmp(method, "drain") == 0 || strcmp(method, "stop") == 0) {
            int is_stop = (strcmp(method, "stop") == 0);
            pthread_mutex_lock(&d->mu);
            int already_draining = d->draining;
            int admitted = 0;
            if (is_stop) {
                admitted = (client_proto == CODE_PROTO_VERSION && client_semver_dir >= 0);
            } else {
                /* Upgrade drain: require strictly newer client (or newer protocol with non-older version),
                 * or same-version/compatible waiter attaching to an already-draining daemon. */
                if (client_proto == CODE_PROTO_VERSION && client_semver_dir > 0) admitted = 1;
                else if (client_proto > CODE_PROTO_VERSION && client_semver_dir >= 0) admitted = 1;
                else if (already_draining && client_proto == CODE_PROTO_VERSION && client_semver_dir == 0) admitted = 1;
            }
            if (!admitted) {
                pthread_mutex_unlock(&d->mu);
                json_object *er = make_err_resp(jid,
                    is_stop ? "version_mismatch: cannot stop newer or incompatible daemon"
                            : "version_mismatch: cannot drain newer or equal daemon",
                    0);
                daemon_write_json(fd, &write_mu, er, d->line_cap);
                json_object_put(er);
                json_object_put(req);
                break;
            }
            if (!d->draining) {
                d->draining = 1;
                d->drain_is_upgrade = is_stop ? 0 : 1;
                d->drain_deadline_ms = now_ms() + (long long)d->drain_grace_sec * 1000LL;
            }
            d->pending_drains++;
            pthread_mutex_unlock(&d->mu);

            json_object *ack = json_object_new_object();
            if (jid) json_object_object_add(ack, "id", json_object_get(jid));
            json_object_object_add(ack, "ok", json_object_new_boolean(1));
            json_object_object_add(ack, "draining", json_object_new_boolean(1));
            int wrc = daemon_write_json(fd, &write_mu, ack, d->line_cap);
            json_object_put(ack);
            json_object_put(req);

            pthread_mutex_lock(&d->mu);
            d->pending_drains--;
            if (wrc == 0 && !d->exiting) {
                struct drain_waiter *w = malloc(sizeof *w);
                if (!w) abort();
                w->fd = fd;
                w->next = d->waiters;
                d->waiters = w;
                wc->fd = -1;
                handed_to_waiters = 1;
            }
            daemon_wake(d);
            pthread_cond_broadcast(&d->cv);
            pthread_mutex_unlock(&d->mu);
            break;
        }

        /* Reject work RPCs after version_mismatch or while draining. */
        if (version_mismatched) {
            json_object *er = make_err_resp(jid, "version_mismatch", 0);
            daemon_write_json(fd, &write_mu, er, d->line_cap);
            json_object_put(er);
            json_object_put(req);
            break;
        }

        pthread_mutex_lock(&d->mu);
        if (d->draining) {
            pthread_mutex_unlock(&d->mu);
            json_object *er = make_err_resp(jid, "cntctr is upgrading; retry in a few seconds", 1);
            daemon_write_json(fd, &write_mu, er, d->line_cap);
            json_object_put(er);
            json_object_put(req);
            break;
        }
        d->active_work++;
        d->last_activity_ms = now_ms();
        pthread_mutex_unlock(&d->mu);
        did_work = 1;

        int work_break = 0;
        if (strcmp(method, "ping") == 0) {
            char *kberr = NULL;
            sqlite3 *db = kb_open_timeout(d->db_path, &kberr, 5000);
            if (!db) {
                json_object *er = make_err_resp(jid, kberr ? kberr : "knowledge store unavailable", 0);
                free(kberr);
                daemon_write_json(fd, &write_mu, er, d->line_cap);
                json_object_put(er);
            } else {
                sqlite3_close(db);
                json_object *resp = json_object_new_object();
                if (jid) json_object_object_add(resp, "id", json_object_get(jid));
                json_object_object_add(resp, "ok", json_object_new_boolean(1));
                json_object_object_add(resp, "pong", json_object_new_boolean(1));
                json_object_object_add(resp, "pid", json_object_new_int64((int64_t)getpid()));
                json_object_object_add(resp, "version", json_object_new_string(d->version));
                daemon_write_json(fd, &write_mu, resp, d->line_cap);
                json_object_put(resp);
            }
        } else if (strcmp(method, "discover") == 0) {
            handle_rpc_discover(d, fd, &write_mu, jid, req);
        } else if (strcmp(method, "restart") == 0) {
            handle_rpc_restart(d, fd, &write_mu, jid, req);
        } else if (strcmp(method, "reload") == 0) {
            handle_rpc_reload(d, fd, &write_mu, jid, req);
        } else if (strcmp(method, "find") == 0) {
            handle_rpc_find(d, fd, &write_mu, jid, req);
        } else if (strcmp(method, "expand") == 0) {
            handle_rpc_expand(d, fd, &write_mu, jid, req);
        } else if (strcmp(method, "run") == 0) {
            handle_rpc_run(d, fd, &lr, &write_mu, jid, req);
            pthread_mutex_lock(&d->mu);
            if (d->draining) work_break = 1;
            pthread_mutex_unlock(&d->mu);
        }
#ifdef CNTCTR_TEST_HOOKS
        else if (strcmp(method, "test_hold") == 0) {
            handle_test_hold(d, fd, &write_mu, jid, req);
            pthread_mutex_lock(&d->mu);
            if (d->draining) work_break = 1;
            pthread_mutex_unlock(&d->mu);
        } else if (strcmp(method, "test_env") == 0) {
            json_object *jk = NULL;
            const char *key = (json_object_object_get_ex(req, "key", &jk) && json_object_is_type(jk, json_type_string))
                                  ? json_object_get_string(jk)
                                  : "";
            const char *val = *key ? getenv(key) : NULL;
            json_object *resp = json_object_new_object();
            if (jid) json_object_object_add(resp, "id", json_object_get(jid));
            json_object_object_add(resp, "ok", json_object_new_boolean(1));
            json_object_object_add(resp, "present", json_object_new_boolean(val != NULL));
            if (val) json_object_object_add(resp, "value", json_object_new_string(val));
            daemon_write_json(fd, &write_mu, resp, d->line_cap);
            json_object_put(resp);
        }
#endif
        else {
            json_object *er = make_err_resp(jid, "unknown method", 0);
            daemon_write_json(fd, &write_mu, er, d->line_cap);
            json_object_put(er);
        }
        json_object_put(req);

        pthread_mutex_lock(&d->mu);
        d->active_work--;
        d->last_activity_ms = now_ms();
        daemon_wake(d);
        pthread_cond_broadcast(&d->cv);
        pthread_mutex_unlock(&d->mu);
        if (work_break) break;
    }

    lr_free(&lr);
    pthread_mutex_destroy(&write_mu);

    pthread_mutex_lock(&d->mu);
    int close_fd = -1;
    if (!handed_to_waiters && wc->fd >= 0) {
        close_fd = wc->fd;
        wc->fd = -1;
    }
    struct worker_conn **wpp = &d->workers;
    while (*wpp) {
        if (*wpp == wc) {
            *wpp = wc->next;
            break;
        }
        wpp = &(*wpp)->next;
    }
    if (did_work) d->last_activity_ms = now_ms();
    /* Wake main loop BEFORE final counted departure so d cannot be destroyed during daemon_wake. */
    daemon_wake(d);
    d->active_conns--;
    pthread_cond_broadcast(&d->cv);
    pthread_mutex_unlock(&d->mu);

    if (close_fd >= 0) close(close_fd);
    free(wc);
    return NULL;
}

static int acquire_startup_lock(const char *lock_path, char **err) {
    int inherited = -1;
    const char *env_fd = getenv("CNTCTR_CODE_LOCK_FD");
    if (env_fd && *env_fd) {
        char *end = NULL;
        long v = strtol(env_fd, &end, 10);
        if (end && !*end && v >= 3 && v < 1024) inherited = (int)v;
        unsetenv("CNTCTR_CODE_LOCK_FD");
    }
    if (ensure_parent_dir(lock_path, 1, err) != 0) {
        if (inherited >= 0) close(inherited);
        return -1;
    }
    if (inherited >= 0) {
        struct stat fst, lst;
        int ok_fd = (fcntl(inherited, F_SETFD, FD_CLOEXEC) == 0 &&
                     fstat(inherited, &fst) == 0 && S_ISREG(fst.st_mode) && fst.st_uid == geteuid() &&
                     lstat(lock_path, &lst) == 0 && fst.st_dev == lst.st_dev && fst.st_ino == lst.st_ino);
        if (ok_fd) {
            /* Prove the reservation is actually held (or acquire it nonblockingly) on this open-file description. */
            int fr;
            while ((fr = flock(inherited, LOCK_EX | LOCK_NB)) < 0 && errno == EINTR) {}
            if (fr == 0) return inherited;
        }
        close(inherited);
    }
    int lfd = open_verified_lock(lock_path, err);
    if (lfd < 0) return -1;
    while (flock(lfd, LOCK_EX) < 0) {
        if (errno == EINTR) continue;
        int e = errno;
        close(lfd);
        if (err) *err = dfmt("flock %s failed: %s", lock_path, strerror(e));
        return -1;
    }
    return lfd;
}

int code_daemon_main(const char *sock_path, const char *db_path) {
    signal(SIGPIPE, SIG_IGN);
    umask(0077);

    if (!sock_path || !*sock_path || !db_path || !*db_path) return 2;
    if (strlen(sock_path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        fprintf(stderr, "code daemon: socket path too long (%zu >= %zu bytes); set CNTCTR_CODE_SOCK\n",
                strlen(sock_path), sizeof(((struct sockaddr_un *)0)->sun_path));
        return 1;
    }

    struct daemon_state d;
    memset(&d, 0, sizeof d);
    d.listen_fd = -1;
    d.wake_pipe[0] = d.wake_pipe[1] = -1;
    snprintf(d.db_path, sizeof d.db_path, "%s", db_path);
    snprintf(d.version, sizeof d.version, "%s", daemon_version_str());
    d.start_mono_ms = now_ms();
    d.last_activity_ms = d.start_mono_ms;
    d.line_cap = code_line_cap();

    d.max_servers = env_int("CNTCTR_CODE_MAX_SERVERS", 6, 1, 64);
    d.idle_sec = env_int("CNTCTR_CODE_IDLE_SEC", 900, 1, 86400);
    d.daemon_idle_sec = env_int("CNTCTR_CODE_DAEMON_IDLE_SEC", 60, 1, 86400);
    d.drain_grace_sec = env_int("CNTCTR_CODE_DRAIN_GRACE_SEC", 30, 1, 600);
    d.max_runs = env_int("CNTCTR_CODE_MAX_RUNS", 8, 1, 64);
    d.call_sec = env_int("CNTCTR_CODE_CALL_SEC", 30, 1, 300);
    d.run_ttl_sec = env_int("CNTCTR_CODE_RUN_TTL_SEC", 86400, 1, 86400 * 30);
    d.daemon_queue_bytes = env_size("CNTCTR_CODE_DAEMON_QUEUE_BYTES", 33554432, 65536, 268435456);
    d.last_sweep = time(NULL);

    char *err = NULL;
    int startup_lock_fd = -1;
    int exit_rc = 1;

    /* Canonicalize and validate socket dir + all ancestors once; use canonical paths for all subsequent ops. */
    if (resolve_trusted_sock_paths(sock_path, 1, d.sock_path, d.lock_path, &err) != 0) {
        fprintf(stderr, "code daemon: %s\n", err ? err : "untrusted socket path");
        free(err);
        return 1;
    }
    sock_path = d.sock_path;

    /* Hold/verify startup lock reservation (inherited from launcher or acquired directly) through listen(). */
    startup_lock_fd = acquire_startup_lock(d.lock_path, &err);
    if (startup_lock_fd < 0) {
        fprintf(stderr, "code daemon: %s\n", err ? err : "failed to acquire startup lock");
        free(err);
        return 1;
    }
    if (ensure_parent_dir(db_path, 0, &err) != 0) {
        fprintf(stderr, "code daemon: %s\n", err);
        free(err);
        (void)flock(startup_lock_fd, LOCK_UN);
        close(startup_lock_fd);
        return 1;
    }

    sqlite3 *init_db = kb_open_timeout(db_path, &err, 5000);
    if (!init_db) {
        fprintf(stderr, "code daemon: db init failed: %s\n", err ? err : "unknown");
        free(err);
        (void)flock(startup_lock_fd, LOCK_UN);
        close(startup_lock_fd);
        return 1;
    }
    sqlite3_close(init_db);

    if (pipe(d.wake_pipe) != 0) {
        (void)flock(startup_lock_fd, LOCK_UN);
        close(startup_lock_fd);
        return 1;
    }
    fcntl(d.wake_pipe[0], F_SETFD, FD_CLOEXEC);
    fcntl(d.wake_pipe[1], F_SETFD, FD_CLOEXEC);
    fcntl(d.wake_pipe[0], F_SETFL, O_NONBLOCK);
    fcntl(d.wake_pipe[1], F_SETFL, O_NONBLOCK);

    pthread_mutex_init(&d.mu, NULL);
    pthread_cond_init(&d.cv, NULL);

    g_daemon_sig_stop = 0;
    g_daemon_sig_wake_fd = d.wake_pipe[1];
    struct sigaction sa_sig;
    memset(&sa_sig, 0, sizeof sa_sig);
    sa_sig.sa_handler = daemon_sig_handler;
    sigemptyset(&sa_sig.sa_mask);
    sigaction(SIGTERM, &sa_sig, NULL);
    sigaction(SIGINT, &sa_sig, NULL);

    /* Under startup_lock_fd: probe existing socket; if live, exit 0; if stale same-UID socket, unlink it. */
#ifdef CNTCTR_TEST_HOOKS
    {
        const char *bar = getenv("CNTCTR_TEST_DAEMON_PRE_BIND_BARRIER");
        if (bar && *bar) {
            char rpath[PATH_MAX], gpath[PATH_MAX], tpath[PATH_MAX];
            snprintf(rpath, sizeof rpath, "%s.ready", bar);
            snprintf(gpath, sizeof gpath, "%s.go", bar);
            snprintf(tpath, sizeof tpath, "%s.ready.tmp.%ld", bar, (long)getpid());
            int rfd = open(tpath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
            if (rfd >= 0) {
                char pb_buf[32];
                int pn = snprintf(pb_buf, sizeof pb_buf, "%ld\n", (long)getpid());
                struct io_budget fb = make_budget(2000, NULL, NULL, 1024);
                if (pn > 0) (void)write_all_budget(rfd, pb_buf, (size_t)pn, &fb, NULL);
                close(rfd);
                (void)rename(tpath, rpath);
            }
            long long bdl = now_ms() + 5000LL;
            struct stat gst;
            while (stat(gpath, &gst) != 0 && now_ms() < bdl) sleep_ms(15);
        }
    }
#endif
    struct io_budget pb = make_budget(1000, NULL, NULL, d.line_cap);
    int probe_err = 0;
    int probe_fd = unix_connect_budget(sock_path, &pb, &probe_err, NULL);
    if (probe_fd >= 0) {
        close(probe_fd);
        exit_rc = 0;
        goto cleanup_early;
    }
    if (probe_err == ECONNREFUSED) {
        if (unlink_verified_stale_sock(sock_path, NULL, &err) != 0) {
            fprintf(stderr, "code daemon: %s\n", err ? err : "cannot unlink stale socket");
            free(err);
            goto cleanup_early;
        }
    } else if (probe_err != ENOENT) {
        /* If a non-socket (e.g. regular file) sits at sock_path, connect returns ECONNREFUSED or ENOTSOCK/EPROTOTYPE;
         * verify we never overwrite or unlink non-sockets. */
        struct stat est;
        if (lstat(sock_path, &est) == 0 && !S_ISSOCK(est.st_mode)) {
            fprintf(stderr, "code daemon: refusing non-socket at %s\n", sock_path);
            goto cleanup_early;
        }
    }

    d.listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (d.listen_fd < 0) goto cleanup_early;
    fcntl(d.listen_fd, F_SETFD, FD_CLOEXEC);

    struct sockaddr_un sun;
    memset(&sun, 0, sizeof sun);
    sun.sun_family = AF_UNIX;
    snprintf(sun.sun_path, sizeof sun.sun_path, "%s", sock_path);
    if (bind(d.listen_fd, (struct sockaddr *)&sun, sizeof sun) != 0) {
        goto cleanup_early;
    }
    (void)chmod(sock_path, 0600);
    if (lstat(sock_path, &d.sock_stat) == 0) {
        d.have_sock_stat = 1;
    }
    if (listen(d.listen_fd, 64) != 0) {
        if (d.have_sock_stat) (void)unlink_verified_stale_sock(sock_path, &d.sock_stat, NULL);
        goto cleanup_early;
    }
    fcntl(d.listen_fd, F_SETFL, O_NONBLOCK);

    /* Socket is bound and listening: release startup lock reservation now. */
    (void)flock(startup_lock_fd, LOCK_UN);
    close(startup_lock_fd);
    startup_lock_fd = -1;

    d.pool = code_pool_new(d.db_path, d.max_servers, d.idle_sec, d.call_sec, d.line_cap, d.daemon_queue_bytes);
    if (!d.pool) goto cleanup_early;
    exit_rc = 0;

    /* Main accept + idle + drain coordination loop. */
    for (;;) {
        if (g_daemon_sig_stop) {
            pthread_mutex_lock(&d.mu);
            if (!d.draining) {
                d.draining = 1;
                d.drain_is_upgrade = 0;
                d.drain_deadline_ms = now_ms() + (long long)d.drain_grace_sec * 1000LL;
            }
            pthread_mutex_unlock(&d.mu);
        }

        time_t now_ep = time(NULL);
        int live_srvs = code_pool_tick(d.pool, now_ep);
        if (now_ep - d.last_sweep >= 60) {
            d.last_sweep = now_ep;
            sqlite3 *sdb = kb_open_timeout(d.db_path, NULL, 1000);
            if (sdb) {
                (void)kb_code_run_sweep(sdb, now_ep);
                sqlite3_close(sdb);
            }
        }

        int timeout_ms = 250;
        int should_exit = 0;

        pthread_mutex_lock(&d.mu);
        if (d.live_servers > 0 && live_srvs == 0) {
            d.last_activity_ms = now_ms();
        }
        d.live_servers = live_srvs;
        if (d.draining) {
            if (d.active_runs == 0 && d.pending_drains == 0) {
                should_exit = 1;
            } else if (d.active_runs > 0) {
                long long now = now_ms();
                if (!d.drain_cancelled_sent && now >= d.drain_deadline_ms) {
                    d.drain_cancelled_sent = 1;
                    for (struct active_run *r = d.runs; r; r = r->next) {
                        r->cancelled = 1;
                        snprintf(r->reason, sizeof r->reason, "daemon upgrading; rerun");
                        if (r->wake_fd >= 0) {
                            char b = 'c';
                            ssize_t n = write(r->wake_fd, &b, 1);
                            (void)n;
                        }
                        if (r->cancel) code_run_cancel_signal(r->cancel, r->reason);
                    }
                    timeout_ms = 100;
                } else if (!d.drain_cancelled_sent) {
                    long long left = d.drain_deadline_ms - now;
                    timeout_ms = (left > 200) ? 200 : (left > 1 ? (int)left : 1);
                } else {
                    if (now >= d.drain_deadline_ms + 5000LL) should_exit = 1;
                    timeout_ms = 100;
                }
            } else {
                timeout_ms = 20;
            }
        } else {
            /* Idle exit depends only on active runs, active work RPCs, and live servers (not status/idle conns). */
            if (d.active_runs == 0 && d.active_work == 0 && d.live_servers == 0) {
                long long left = (d.last_activity_ms + (long long)d.daemon_idle_sec * 1000LL) - now_ms();
                if (left <= 0) {
                    d.draining = 1;
                    d.drain_is_upgrade = 0;
                    should_exit = 1;
                } else {
                    timeout_ms = (left > 1000) ? 1000 : (int)left;
                }
            } else {
                timeout_ms = 250;
            }
        }
        pthread_mutex_unlock(&d.mu);

        if (should_exit) break;

        struct pollfd pf[2] = {
            { .fd = d.listen_fd, .events = POLLIN, .revents = 0 },
            { .fd = d.wake_pipe[0], .events = POLLIN, .revents = 0 },
        };
        int pr = poll(pf, 2, timeout_ms);
        if (pr < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (pf[1].revents & POLLIN) daemon_drain_wake_pipe(&d);
        if (pf[0].revents & POLLIN) {
            for (;;) {
                int cfd = accept(d.listen_fd, NULL, NULL);
                if (cfd < 0) {
                    if (errno == EINTR) continue;
                    break;
                }
                if (check_peer_uid(cfd) != 0) {
                    close(cfd);
                    continue;
                }
                fcntl(cfd, F_SETFD, FD_CLOEXEC);
                fcntl(cfd, F_SETFL, O_NONBLOCK);
                struct worker_conn *wc = malloc(sizeof *wc);
                if (!wc) abort();
                wc->d = &d;
                wc->fd = cfd;

                pthread_mutex_lock(&d.mu);
                wc->next = d.workers;
                d.workers = wc;
                d.active_conns++;
                pthread_mutex_unlock(&d.mu);

                pthread_t th;
                pthread_attr_t attr;
                pthread_attr_init(&attr);
                pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
                if (pthread_create(&th, &attr, daemon_conn_thread, wc) != 0) {
                    pthread_mutex_lock(&d.mu);
                    struct worker_conn **wpp = &d.workers;
                    while (*wpp) {
                        if (*wpp == wc) { *wpp = wc->next; break; }
                        wpp = &(*wpp)->next;
                    }
                    d.active_conns--;
                    pthread_mutex_unlock(&d.mu);
                    free(wc);
                    close(cfd);
                }
                pthread_attr_destroy(&attr);
            }
        }
    }

    /* Final shutdown sequence:
     * 1. Close listen_fd FIRST so any client holding code.lock in the kernel backlog gets immediate ECONNRESET.
     * 2. Stop all downstream tool servers cleanly (no zombies, no leaked child processes).
     * 3. Acquire verified code.lock ONLY for inode-verified unlink + drain-waiter close (skip unlink if lock fails).
     * 4. Shut down all tracked worker sockets and wait for active_conns == 0 before destroying pool/stack state;
     *    on hard shutdown deadline with live workers remaining, _exit(0) without unwinding live thread state. */
    close(d.listen_fd);
    d.listen_fd = -1;

    if (d.pool) code_pool_stop(d.pool, NULL, NULL);

    int lfd = open_verified_lock(d.lock_path, NULL);
    int locked = 0;
    if (lfd >= 0) {
        int fr;
        while ((fr = flock(lfd, LOCK_EX)) < 0 && errno == EINTR) {}
        if (fr == 0) locked = 1;
    }

    if (locked && d.have_sock_stat) {
        (void)unlink_verified_stale_sock(d.sock_path, &d.sock_stat, NULL);
    }

    pthread_mutex_lock(&d.mu);
    d.exiting = 1;
    struct drain_waiter *w = d.waiters;
    d.waiters = NULL;
    for (struct worker_conn *wc = d.workers; wc; wc = wc->next) {
        if (wc->fd >= 0) (void)shutdown(wc->fd, SHUT_RDWR);
    }
    for (struct active_run *r = d.runs; r; r = r->next) {
        r->cancelled = 1;
        if (!*r->reason) snprintf(r->reason, sizeof r->reason, "daemon shutting down");
        if (r->wake_fd >= 0) {
            char b = 'c';
            ssize_t n = write(r->wake_fd, &b, 1);
            (void)n;
        }
        if (r->cancel) code_run_cancel_signal(r->cancel, r->reason);
    }
    pthread_cond_broadcast(&d.cv);
    pthread_mutex_unlock(&d.mu);

    while (w) {
        struct drain_waiter *next = w->next;
        close(w->fd);
        free(w);
        w = next;
    }

    if (lfd >= 0) {
        if (locked) (void)flock(lfd, LOCK_UN);
        close(lfd);
    }

    long long join_deadline = now_ms() + 2000LL;
    pthread_mutex_lock(&d.mu);
    while (d.active_conns > 0 && now_ms() < join_deadline) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_nsec += 20000000L;
        if (ts.tv_nsec >= 1000000000L) {
            ts.tv_sec++;
            ts.tv_nsec -= 1000000000L;
        }
        pthread_cond_timedwait(&d.cv, &d.mu, &ts);
    }
    if (d.active_conns > 0) {
        /* Hard shutdown deadline reached with workers still blocked (e.g. slow DB/IO):
         * exit process directly without destroying mutex/condvar or unwinding stack state. */
        _exit(0);
    }
    pthread_mutex_unlock(&d.mu);

cleanup_early:
    if (d.pool) {
        code_pool_free(d.pool);
        d.pool = NULL;
    }
    if (startup_lock_fd >= 0) {
        (void)flock(startup_lock_fd, LOCK_UN);
        close(startup_lock_fd);
    }
    g_daemon_sig_wake_fd = -1;
    if (d.listen_fd >= 0) close(d.listen_fd);
    if (d.wake_pipe[0] >= 0) close(d.wake_pipe[0]);
    if (d.wake_pipe[1] >= 0) close(d.wake_pipe[1]);
    pthread_cond_destroy(&d.cv);
    pthread_mutex_destroy(&d.mu);
    return exit_rc;
}

/* ---- Client handshake, drain, refcounted reverse-RPC, and RPC ---- */

enum hello_result {
    HELLO_OK = 0,
    HELLO_DRAINING,
    HELLO_NEED_UPGRADE,
    HELLO_OLDER_CLIENT,
    HELLO_DB_MISMATCH,
    HELLO_EOF,
    HELLO_ERR,
};

struct hello_info {
    enum hello_result res;
    int daemon_proto;
    char daemon_ver[64];
    int draining;
    char *err;
};

static void hello_info_free(struct hello_info *hi) {
    free(hi->err);
    hi->err = NULL;
}

static void client_do_hello(int fd, struct line_reader *lr, pthread_mutex_t *write_mu,
                            const char *canon_db, const struct io_budget *b,
                            struct hello_info *hi) {
    memset(hi, 0, sizeof *hi);
    struct io_budget hb = cap_budget_ms(b, 5000);
    const char *cver = client_version_str();
    json_object *req = json_object_new_object();
    json_object_object_add(req, "id", json_object_new_int(0));
    json_object_object_add(req, "method", json_object_new_string("hello"));
    json_object_object_add(req, "proto", json_object_new_int(CODE_PROTO_VERSION));
    json_object_object_add(req, "version", json_object_new_string(cver));
    json_object_object_add(req, "db", json_object_new_string(canon_db));
    char *werr = NULL;
    int wrc = write_json_line(fd, write_mu, req, &hb, &werr);
    json_object_put(req);
    if (wrc != 0) {
        if (wrc == -4) {
            free(werr);
            hi->res = HELLO_EOF;
        } else {
            hi->res = HELLO_ERR;
            hi->err = werr ? werr : dfmt("hello write failed");
        }
        return;
    }

    char *line = NULL, *rerr = NULL;
    int rr = lr_read_line(lr, &hb, &line, &rerr);
    if (rr == 1) {
        free(rerr);
        hi->res = HELLO_EOF;
        return;
    }
    if (rr != 0) {
        hi->res = HELLO_ERR;
        hi->err = rerr ? rerr : dfmt("hello failed");
        return;
    }
    json_object *resp = json_tokener_parse(line);
    free(line);
    if (!resp || !json_object_is_type(resp, json_type_object)) {
        if (resp) json_object_put(resp);
        hi->res = HELLO_ERR;
        hi->err = dfmt("malformed hello response from code daemon");
        return;
    }

    json_object *jok = NULL, *jerr = NULL, *jdr = NULL, *jproto = NULL, *jver = NULL;
    json_object_object_get_ex(resp, "ok", &jok);
    json_object_object_get_ex(resp, "error", &jerr);
    json_object_object_get_ex(resp, "draining", &jdr);
    json_object_object_get_ex(resp, "proto", &jproto);
    json_object_object_get_ex(resp, "version", &jver);
    hi->draining = (jdr && json_object_get_boolean(jdr)) ? 1 : 0;

    if (jok && json_object_get_boolean(jok)) {
        hi->daemon_proto = (jproto && json_object_is_type(jproto, json_type_int))
                               ? json_object_get_int(jproto)
                               : CODE_PROTO_VERSION;
        if (jver && json_object_is_type(jver, json_type_string))
            snprintf(hi->daemon_ver, sizeof hi->daemon_ver, "%s", json_object_get_string(jver));
        hi->res = hi->draining ? HELLO_DRAINING : HELLO_OK;
        json_object_put(resp);
        return;
    }

    const char *ename = (jerr && json_object_is_type(jerr, json_type_string)) ? json_object_get_string(jerr) : "";
    if (strcmp(ename, "db_mismatch") == 0) {
        json_object *jddb = NULL;
        json_object_object_get_ex(resp, "daemon_db", &jddb);
        const char *ddb = (jddb && json_object_is_type(jddb, json_type_string)) ? json_object_get_string(jddb) : "?";
        hi->res = HELLO_DB_MISMATCH;
        hi->err = dfmt("db_mismatch: daemon uses %s, client uses %s; check CNTCTR_DB or CNTCTR_CODE_SOCK",
                       ddb, canon_db);
        json_object_put(resp);
        return;
    }
    if (strcmp(ename, "version_mismatch") == 0) {
        json_object *jdv = NULL, *jdp = NULL;
        json_object_object_get_ex(resp, "daemon_version", &jdv);
        json_object_object_get_ex(resp, "daemon_proto", &jdp);
        const char *dv = (jdv && json_object_is_type(jdv, json_type_string)) ? json_object_get_string(jdv) : "0.0.0";
        int dp = (jdp && json_object_is_type(jdp, json_type_int)) ? json_object_get_int(jdp) : 0;
        hi->daemon_proto = dp;
        snprintf(hi->daemon_ver, sizeof hi->daemon_ver, "%s", dv);

        /* Check SemVer direction and protocol compatibility separately. */
        int vcmp = semver_cmp(cver, dv);
        if (dp != CODE_PROTO_VERSION) {
            if (CODE_PROTO_VERSION > dp && vcmp >= 0) {
                hi->res = HELLO_NEED_UPGRADE;
            } else {
                hi->res = HELLO_OLDER_CLIENT;
                hi->err = dfmt("version_mismatch: daemon (%s, proto %d) is newer/incompatible with client (%s, proto %d); restart your harness",
                               dv, dp, cver, CODE_PROTO_VERSION);
            }
        } else if (vcmp > 0) {
            hi->res = HELLO_NEED_UPGRADE;
        } else if (vcmp < 0) {
            hi->res = HELLO_OLDER_CLIENT;
            hi->err = dfmt("version_mismatch: daemon (%s) is newer than client (%s); restart your harness", dv, cver);
        } else {
            hi->res = HELLO_ERR;
            hi->err = dfmt("version_mismatch: daemon (%s) rejected equal-precedence client (%s)", dv, cver);
        }
        json_object_put(resp);
        return;
    }

    hi->res = HELLO_ERR;
    hi->err = dfmt("hello rejected: %s", *ename ? ename : "unknown error");
    json_object_put(resp);
}

static int acquire_code_lock_budget(const char *lock_path, const struct io_budget *b, char **err) {
    int lfd = open_verified_lock(lock_path, err);
    if (lfd < 0) return -1;
    for (;;) {
        if (flock(lfd, LOCK_EX | LOCK_NB) == 0) return lfd;
        if (errno == EINTR) continue;
        if (errno != EWOULDBLOCK && errno != EAGAIN) {
            int e = errno;
            close(lfd);
            if (err) *err = dfmt("flock %s failed: %s", lock_path, strerror(e));
            return -1;
        }
        int slice = budget_slice(b, 20, err, "acquiring code.lock");
        if (slice < 0) {
            close(lfd);
            return -1;
        }
        sleep_ms(slice);
    }
}

enum drain_result {
    DRAIN_EOF = 0,
    DRAIN_ERR = -1,
    DRAIN_CANCELLED = -2,
    DRAIN_TIMEOUT = -3,
};

static enum drain_result wait_drain_eof_budget(int fd, const struct io_budget *b, char **err) {
    for (;;) {
        int slice = budget_slice(b, 200, err, "waiting for code daemon drain");
        if (slice == -2) return DRAIN_CANCELLED;
        if (slice == -3) return DRAIN_TIMEOUT;

        struct pollfd pfd = { .fd = fd, .events = POLLIN, .revents = 0 };
        int pr = poll(&pfd, 1, slice);
        if (pr < 0) {
            if (errno == EINTR) continue;
            if (err) *err = dfmt("poll error while waiting for daemon drain: %s", strerror(errno));
            return DRAIN_ERR;
        }
        if (pr == 0) continue;
        char tmp[256];
        ssize_t n = read(fd, tmp, sizeof tmp);
        if (n == 0) return DRAIN_EOF;
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
            if (errno == ECONNRESET || errno == EPIPE) return DRAIN_EOF;
            if (err) *err = dfmt("read error while waiting for daemon drain: %s", strerror(errno));
            return DRAIN_ERR;
        }
    }
}

static enum drain_result client_send_drain_and_release_lock(int fd, struct line_reader *lr,
                                                            pthread_mutex_t *write_mu,
                                                            int *lfd_ptr, const char *method,
                                                            const struct io_budget *b, char **err) {
    struct io_budget ab = cap_budget_ms(b, 5000);
    json_object *dreq = json_object_new_object();
    json_object_object_add(dreq, "id", json_object_new_int(1));
    json_object_object_add(dreq, "method", json_object_new_string(method ? method : "drain"));
    char *werr = NULL;
    int wrc = write_json_line(fd, write_mu, dreq, &ab, &werr);
    json_object_put(dreq);

    int ack_state = 0; /* 1 = valid ack, 2 = verified peer disconnect/EOF (already exited), <0 = error/rejected */
    char *aerr = NULL;
    if (wrc != 0) {
        if (wrc == -4) {
            free(werr);
            ack_state = 2;
        } else {
            ack_state = (wrc == -2 || wrc == -3) ? wrc : -1;
            aerr = werr ? werr : dfmt("failed writing drain request");
        }
    } else {
        char *line = NULL, *rerr = NULL;
        int rr = lr_read_line(lr, &ab, &line, &rerr);
        if (rr == 1) {
            free(rerr);
            ack_state = 2;
        } else if (rr != 0) {
            ack_state = (rr == -2 || rr == -3) ? rr : -1;
            aerr = rerr ? rerr : dfmt("failed reading drain ack");
        } else {
            json_object *resp = json_tokener_parse(line);
            free(line);
            if (!resp || !json_object_is_type(resp, json_type_object)) {
                if (resp) json_object_put(resp);
                ack_state = -1;
                aerr = dfmt("malformed drain ack from code daemon");
            } else {
                json_object *jok = NULL, *jdr = NULL, *jerr = NULL;
                json_object_object_get_ex(resp, "ok", &jok);
                json_object_object_get_ex(resp, "draining", &jdr);
                json_object_object_get_ex(resp, "error", &jerr);
                if (jok && json_object_get_boolean(jok) && jdr && json_object_get_boolean(jdr)) {
                    ack_state = 1;
                } else {
                    const char *es = (jerr && json_object_is_type(jerr, json_type_string))
                                         ? json_object_get_string(jerr)
                                         : "daemon rejected drain request";
                    ack_state = -1;
                    aerr = dfmt("%s", es);
                }
                json_object_put(resp);
            }
        }
    }

    /* CRITICAL: release code.lock BEFORE waiting for daemon EOF so the daemon can take code.lock to unlink. */
    if (lfd_ptr && *lfd_ptr >= 0) {
        (void)flock(*lfd_ptr, LOCK_UN);
        close(*lfd_ptr);
        *lfd_ptr = -1;
    }

    if (ack_state == 2) {
        /* Daemon closed right between hello and drain: brief yield for final unlink, treat as EOF. */
        sleep_ms(20);
        return DRAIN_EOF;
    }
    if (ack_state < 0) {
        if (err) *err = aerr;
        else free(aerr);
        return ack_state == -2 ? DRAIN_CANCELLED : ack_state == -3 ? DRAIN_TIMEOUT : DRAIN_ERR;
    }

    int grace = env_int("CNTCTR_CODE_DRAIN_GRACE_SEC", 30, 1, 600);
    struct io_budget wb = cap_budget_ms(b, (grace + 5) * 1000);
    return wait_drain_eof_budget(fd, &wb, err);
}

/* Refcounted connection state shared between code_client_rpc and async reverse-RPC reply callbacks. */
struct rpc_conn_shared {
    pthread_mutex_t mu;
    pthread_mutex_t write_mu;
    int fd;
    int closed;
    int refcount;
    size_t max_line;
    long long deadline_ms; /* inherited outer call deadline (0 = unbounded) */
};

struct rev_reply_token {
    struct rpc_conn_shared *conn;
};

static struct rpc_conn_shared *rpc_conn_new(int fd, size_t max_line, long long deadline_ms) {
    struct rpc_conn_shared *c = calloc(1, sizeof *c);
    if (!c) abort();
    pthread_mutex_init(&c->mu, NULL);
    pthread_mutex_init(&c->write_mu, NULL);
    c->fd = fd;
    c->refcount = 1;
    c->max_line = max_line;
    c->deadline_ms = deadline_ms;
    return c;
}

static void rpc_conn_ref(struct rpc_conn_shared *c) {
    pthread_mutex_lock(&c->mu);
    c->refcount++;
    pthread_mutex_unlock(&c->mu);
}

static void rpc_conn_unref(struct rpc_conn_shared *c) {
    pthread_mutex_lock(&c->mu);
    int last = (--c->refcount == 0);
    pthread_mutex_unlock(&c->mu);
    if (last) {
        if (c->fd >= 0) close(c->fd);
        pthread_mutex_destroy(&c->write_mu);
        pthread_mutex_destroy(&c->mu);
        free(c);
    }
}

static int rpc_conn_is_closed_cb(void *ctx) {
    struct rpc_conn_shared *c = ctx;
    pthread_mutex_lock(&c->mu);
    int cl = c->closed;
    pthread_mutex_unlock(&c->mu);
    return cl;
}

static void rpc_conn_close(struct rpc_conn_shared *c) {
    /* Signal socket shutdown BEFORE waiting on write_mu so any blocked reverse-reply writer wakes immediately. */
    pthread_mutex_lock(&c->mu);
    c->closed = 1;
    int sfd = c->fd;
    pthread_mutex_unlock(&c->mu);
    if (sfd >= 0) (void)shutdown(sfd, SHUT_RDWR);

    pthread_mutex_lock(&c->write_mu);
    pthread_mutex_lock(&c->mu);
    int cfd = c->fd;
    c->fd = -1;
    pthread_mutex_unlock(&c->mu);
    if (cfd >= 0) close(cfd);
    pthread_mutex_unlock(&c->write_mu);
}

static void client_rev_reply_cb(void *rctx, json_object *resp) {
    struct rev_reply_token *tok = rctx;
    if (!tok) return;
    struct rpc_conn_shared *c = tok->conn;
    free(tok);
    if (!c) return;

    if (resp) {
        pthread_mutex_lock(&c->write_mu);
        pthread_mutex_lock(&c->mu);
        int closed = c->closed;
        int wfd = c->fd;
        pthread_mutex_unlock(&c->mu);
        if (!closed && wfd >= 0) {
            struct io_budget wb;
            wb.deadline_ms = now_ms() + 5000LL;
            if (c->deadline_ms > 0 && c->deadline_ms < wb.deadline_ms) wb.deadline_ms = c->deadline_ms;
            wb.is_cancelled = rpc_conn_is_closed_cb;
            wb.ctx = c;
            wb.max_line = c->max_line;
            char *werr = NULL;
            (void)write_json_line(wfd, NULL, resp, &wb, &werr);
            free(werr);
        }
        pthread_mutex_unlock(&c->write_mu);
    }
    rpc_conn_unref(c);
}

/* Connect (and autostart / upgrade if autostart != 0). Returns fd >= 0 with lr initialized, or -1. */
static int client_connect_ready(const char *sock_path, const char *lock_path, const char *canon_db,
                                int autostart, const struct io_budget *b,
                                struct line_reader *lr, pthread_mutex_t *write_mu, char **err) {
    size_t lcap = b->max_line;

    /* Fast path (unlocked). */
    {
        int ce = 0;
        char *cerr = NULL;
        int fd = unix_connect_budget(sock_path, b, &ce, &cerr);
        if (fd >= 0) {
            free(cerr);
            lr_init(lr, fd, lcap);
            struct hello_info hi;
            client_do_hello(fd, lr, write_mu, canon_db, b, &hi);
            if (hi.res == HELLO_OK) {
                hello_info_free(&hi);
                return fd;
            }
            if (hi.res == HELLO_DRAINING && !autostart) {
                hello_info_free(&hi);
                return fd;
            }
            if (hi.res == HELLO_DB_MISMATCH || hi.res == HELLO_OLDER_CLIENT || hi.res == HELLO_ERR) {
                if (err) *err = hi.err;
                else free(hi.err);
                lr_free(lr);
                close(fd);
                return -1;
            }
            if (hi.res == HELLO_NEED_UPGRADE && !autostart) {
                if (err) *err = dfmt("version_mismatch: daemon (%s) differs from client (%s)",
                                     hi.daemon_ver, client_version_str());
                hello_info_free(&hi);
                lr_free(lr);
                close(fd);
                return -1;
            }
            /* HELLO_NEED_UPGRADE, HELLO_DRAINING (with autostart), or HELLO_EOF -> enter locked path. */
            hello_info_free(&hi);
            lr_free(lr);
            close(fd);
        } else {
            if (ce == ECANCELED || ce == ETIMEDOUT) {
                if (err) *err = cerr ? cerr : dfmt(ce == ECANCELED ? "cancelled" : "timed out connecting to code daemon");
                else free(cerr);
                return -1;
            }
            free(cerr);
            if (!autostart) {
                if (err) *err = dfmt("code daemon is not running (%s)", strerror(ce));
                return -1;
            }
        }
    }

    /* Locked spawn / upgrade path. */
    for (int iter = 0; iter < 5; iter++) {
        int lfd = acquire_code_lock_budget(lock_path, b, err);
        if (lfd < 0) return -1;

        int ce = 0;
        char *cerr = NULL;
        int fd = unix_connect_budget(sock_path, b, &ce, &cerr);
        if (fd >= 0) {
            free(cerr);
            lr_init(lr, fd, lcap);
            struct hello_info hi;
            client_do_hello(fd, lr, write_mu, canon_db, b, &hi);
            if (hi.res == HELLO_OK) {
                hello_info_free(&hi);
                (void)flock(lfd, LOCK_UN);
                close(lfd);
                return fd;
            }
            if (hi.res == HELLO_DB_MISMATCH || hi.res == HELLO_OLDER_CLIENT || hi.res == HELLO_ERR) {
                if (err) *err = hi.err;
                else free(hi.err);
                lr_free(lr);
                close(fd);
                (void)flock(lfd, LOCK_UN);
                close(lfd);
                return -1;
            }
            if (hi.res == HELLO_NEED_UPGRADE || hi.res == HELLO_DRAINING) {
                hello_info_free(&hi);
                char *derr = NULL;
                enum drain_result dr = client_send_drain_and_release_lock(fd, lr, write_mu, &lfd, "drain", b, &derr);
                lr_free(lr);
                close(fd);
                if (dr != DRAIN_EOF) {
                    if (err) *err = derr ? derr : dfmt("code daemon drain failed");
                    else free(derr);
                    return -1;
                }
                free(derr);
                continue;
            }
            /* HELLO_EOF: daemon closed right as we connected; release lock briefly and retry. */
            hello_info_free(&hi);
            lr_free(lr);
            close(fd);
            (void)flock(lfd, LOCK_UN);
            close(lfd);
            int slice = budget_slice(b, 20, err, "retrying after daemon EOF");
            if (slice < 0) return -1;
            sleep_ms(slice);
            continue;
        }
        if (ce == ECANCELED || ce == ETIMEDOUT) {
            (void)flock(lfd, LOCK_UN);
            close(lfd);
            if (err) *err = cerr ? cerr : dfmt(ce == ECANCELED ? "cancelled" : "timed out");
            else free(cerr);
            return -1;
        }
        free(cerr);

        /* Verify sock_path is not an untrusted non-socket before launching. */
        if (ce != ENOENT) {
            struct stat est;
            if (lstat(sock_path, &est) == 0 && !S_ISSOCK(est.st_mode)) {
                (void)flock(lfd, LOCK_UN);
                close(lfd);
                if (err) *err = dfmt("refusing to launch: non-socket exists at %s", sock_path);
                return -1;
            }
        }

        /* Transfer startup lock ownership to grandchild through bind()+listen(). */
        if (spawn_code_daemon(sock_path, canon_db, &lfd, err) != 0) {
            if (lfd >= 0) {
                (void)flock(lfd, LOCK_UN);
                close(lfd);
            }
            return -1;
        }

        /* Wait until grandchild releases the startup lock (right after listen() succeeds or on child exit). */
        struct io_budget sb = cap_budget_ms(b, 5000);
        int wait_lfd = acquire_code_lock_budget(lock_path, &sb, err);
        if (wait_lfd < 0) return -1;

        int wce = 0;
        char *wcerr = NULL;
        int wfd = unix_connect_budget(sock_path, &sb, &wce, &wcerr);
        if (wfd >= 0) {
            free(wcerr);
            lr_init(lr, wfd, lcap);
            struct hello_info hi;
            client_do_hello(wfd, lr, write_mu, canon_db, &sb, &hi);
            (void)flock(wait_lfd, LOCK_UN);
            close(wait_lfd);
            if (hi.res == HELLO_OK) {
                hello_info_free(&hi);
                return wfd;
            }
            if (hi.res == HELLO_DB_MISMATCH || hi.res == HELLO_OLDER_CLIENT || hi.res == HELLO_ERR) {
                if (err) *err = hi.err;
                else free(hi.err);
                lr_free(lr);
                close(wfd);
                return -1;
            }
            hello_info_free(&hi);
            lr_free(lr);
            close(wfd);
            continue;
        }
        (void)flock(wait_lfd, LOCK_UN);
        close(wait_lfd);
        if (err) *err = wcerr ? wcerr : dfmt("code daemon failed to start (socket %s: %s)", sock_path, strerror(wce));
        else free(wcerr);
        return -1;
    }

    if (err) *err = dfmt("failed to connect to code daemon after retries");
    return -1;
}

int code_client_rpc(json_object *req, int autostart, json_object **resp,
                    code_rev_fn rev, code_cancelled_fn is_cancelled, void *ctx, int timeout_ms, char **err) {
    if (resp) *resp = NULL;
    if (err) *err = NULL;
    if (!req || !json_object_is_type(req, json_type_object)) {
        if (err) *err = dfmt("invalid RPC request");
        return -1;
    }

    char raw_sock[PATH_MAX], sock_path[PATH_MAX], lock_path[PATH_MAX], canon_db[PATH_MAX];
    if (code_sock_path(raw_sock, err) != 0) return -1;
    if (code_canon_db(canon_db, err) != 0) return -1;
    int rpr = resolve_trusted_sock_paths(raw_sock, autostart != 0, sock_path, lock_path, err);
    if (rpr < 0) return -1;
    if (rpr == 1) {
        if (err) *err = dfmt("code daemon is not running");
        return -1;
    }

    size_t lcap = code_line_cap();
    struct io_budget b = make_budget(timeout_ms, is_cancelled, ctx, lcap);

    /* Ensure request has an "id" field and pre-check outbound frame size before even connecting/spawning. */
    json_object *wire_req = json_object_get(req);
    json_object *jid = NULL;
    if (!json_object_object_get_ex(wire_req, "id", &jid)) {
        json_object_object_add(wire_req, "id", json_object_new_int(1));
    }
    const char *pre_s = json_object_to_json_string_ext(wire_req, JSON_C_TO_STRING_PLAIN);
    if (!pre_s || strlen(pre_s) + 1 > lcap) {
        if (err) *err = dfmt("outbound IPC frame exceeds line limit (%zu > %zu bytes)",
                             pre_s ? strlen(pre_s) + 1 : 0, lcap);
        json_object_put(wire_req);
        return -1;
    }

    pthread_mutex_t init_write_mu;
    pthread_mutex_init(&init_write_mu, NULL);

    int rc = -1;
    struct line_reader lr;
    memset(&lr, 0, sizeof lr);
    char *cerr = NULL;
    int fd = client_connect_ready(sock_path, lock_path, canon_db, autostart, &b, &lr, &init_write_mu, &cerr);
    pthread_mutex_destroy(&init_write_mu);

    if (fd < 0) {
        if (err) *err = cerr;
        else free(cerr);
        json_object_put(wire_req);
        return -1;
    }

    struct rpc_conn_shared *conn = rpc_conn_new(fd, lcap, b.deadline_ms);
    char *werr = NULL;
    if (write_json_line(fd, &conn->write_mu, wire_req, &b, &werr) != 0) {
        if (err) *err = werr ? werr : dfmt("failed to write request to code daemon");
        else free(werr);
    } else {
        for (;;) {
            char *line = NULL, *rerr = NULL;
            int rr = lr_read_line(&lr, &b, &line, &rerr);
            if (rr == 1) {
                free(rerr);
                if (err) *err = dfmt("code daemon closed connection unexpectedly");
                break;
            }
            if (rr != 0) {
                if (err) *err = rerr ? rerr : dfmt("code daemon read failed");
                else free(rerr);
                break;
            }
            json_object *msg = json_tokener_parse(line);
            free(line);
            if (!msg || !json_object_is_type(msg, json_type_object)) {
                if (msg) json_object_put(msg);
                if (err) *err = dfmt("malformed JSON response from code daemon");
                break;
            }

            json_object *jmeth = NULL;
            if (json_object_object_get_ex(msg, "method", &jmeth) && json_object_is_type(jmeth, json_type_string)) {
                if (rev) {
                    struct rev_reply_token *tok = malloc(sizeof *tok);
                    if (!tok) abort();
                    rpc_conn_ref(conn);
                    tok->conn = conn;
                    rev(ctx, msg, client_rev_reply_cb, tok);
                } else {
                    json_object *rid = NULL;
                    json_object_object_get_ex(msg, "id", &rid);
                    json_object *er = make_err_resp(rid, "reverse RPC not supported", 0);
                    char *re = NULL;
                    (void)write_json_line(fd, &conn->write_mu, er, &b, &re);
                    free(re);
                    json_object_put(er);
                }
                json_object_put(msg);
                continue;
            }

            if (resp) *resp = msg;
            else json_object_put(msg);
            rc = 0;
            break;
        }
    }

    lr_free(&lr);
    rpc_conn_close(conn);
    rpc_conn_unref(conn);
    json_object_put(wire_req);
    return rc;
}

/* Single socket connect probe (never autostarts, never shows stale "on"). */
int code_client_probe(json_object **status_out, char **err) {
    if (status_out) *status_out = NULL;
    if (err) *err = NULL;

    char raw_sock[PATH_MAX], sock_path[PATH_MAX], canon_db[PATH_MAX];
    if (code_sock_path(raw_sock, err) != 0) return -1;
    if (code_canon_db(canon_db, err) != 0) return -1;
    int rpr = resolve_trusted_sock_paths(raw_sock, 0, sock_path, NULL, err);
    if (rpr < 0) return -1;
    if (rpr == 1) return 0; /* socket parent dir does not exist -> daemon is off */

    struct io_budget b = make_budget(5000, NULL, NULL, code_line_cap());
    int ce = 0;
    int fd = unix_connect_budget(sock_path, &b, &ce, NULL);
    if (fd < 0) {
        if (ce == ENOENT || ce == ECONNREFUSED || ce == ECONNRESET || ce == ENOTDIR) return 0;
        if (err) *err = dfmt("cannot connect to %s: %s", sock_path, strerror(ce));
        return -1;
    }

    pthread_mutex_t write_mu;
    pthread_mutex_init(&write_mu, NULL);
    struct line_reader lr;
    lr_init(&lr, fd, b.max_line);

    struct hello_info hi;
    client_do_hello(fd, &lr, &write_mu, canon_db, &b, &hi);
    if (hi.res == HELLO_DB_MISMATCH || hi.res == HELLO_ERR) {
        if (err) *err = hi.err;
        else free(hi.err);
        lr_free(&lr);
        close(fd);
        pthread_mutex_destroy(&write_mu);
        return -1;
    }
    if (hi.res == HELLO_EOF) {
        hello_info_free(&hi);
        lr_free(&lr);
        close(fd);
        pthread_mutex_destroy(&write_mu);
        return 0;
    }
    hello_info_free(&hi);

    json_object *req = json_object_new_object();
    json_object_object_add(req, "id", json_object_new_int(1));
    json_object_object_add(req, "method", json_object_new_string("status"));
    int wrc = write_json_line(fd, &write_mu, req, &b, NULL);
    json_object_put(req);
    if (wrc != 0) {
        lr_free(&lr);
        close(fd);
        pthread_mutex_destroy(&write_mu);
        return 0;
    }

    char *line = NULL, *rerr = NULL;
    int rr = lr_read_line(&lr, &b, &line, &rerr);
    lr_free(&lr);
    close(fd);
    pthread_mutex_destroy(&write_mu);

    if (rr == 1) {
        free(rerr);
        return 0;
    }
    if (rr != 0) {
        if (err) *err = rerr;
        else free(rerr);
        return -1;
    }
    json_object *resp = json_tokener_parse(line);
    free(line);
    if (!resp || !json_object_is_type(resp, json_type_object)) {
        if (resp) json_object_put(resp);
        if (err) *err = dfmt("malformed status response from code daemon");
        return -1;
    }
    if (status_out) *status_out = resp;
    else json_object_put(resp);
    return 0;
}

/* ---- CLI: `cntctr code status [--short|--verbose]` and `cntctr code stop` ---- */

static void format_uptime(long long sec, char out[32]) {
    if (sec < 60) snprintf(out, 32, "%llds", sec);
    else if (sec < 3600) snprintf(out, 32, "%lldm", sec / 60);
    else if (sec < 86400) snprintf(out, 32, "%lldh", sec / 3600);
    else snprintf(out, 32, "%lldd", sec / 86400);
}

static int code_stop_cmd(void) {
    char raw_sock[PATH_MAX], sock_path[PATH_MAX], canon_db[PATH_MAX], *err = NULL;
    if (code_sock_path(raw_sock, &err) != 0 || code_canon_db(canon_db, &err) != 0) {
        fprintf(stderr, "%s\n", err ? err : "invalid socket/db path");
        free(err);
        return 1;
    }
    int rpr = resolve_trusted_sock_paths(raw_sock, 0, sock_path, NULL, &err);
    if (rpr < 0) {
        fprintf(stderr, "%s\n", err ? err : "untrusted socket path");
        free(err);
        return 1;
    }
    if (rpr == 1) return 0; /* socket parent dir does not exist -> daemon is off */
    int grace = env_int("CNTCTR_CODE_DRAIN_GRACE_SEC", 30, 1, 600);
    struct io_budget b = make_budget((grace + 5) * 1000, NULL, NULL, code_line_cap());

    int ce = 0;
    int fd = unix_connect_budget(sock_path, &b, &ce, NULL);
    if (fd < 0) {
        if (ce == ENOENT || ce == ECONNREFUSED || ce == ECONNRESET || ce == ENOTDIR) return 0;
        fprintf(stderr, "code stop: cannot connect to %s: %s\n", sock_path, strerror(ce));
        return 1;
    }

    pthread_mutex_t write_mu;
    pthread_mutex_init(&write_mu, NULL);
    struct line_reader lr;
    lr_init(&lr, fd, b.max_line);

    struct hello_info hi;
    client_do_hello(fd, &lr, &write_mu, canon_db, &b, &hi);
    if (hi.res == HELLO_DB_MISMATCH || hi.res == HELLO_OLDER_CLIENT || hi.res == HELLO_ERR) {
        fprintf(stderr, "%s\n", hi.err ? hi.err : "hello failed");
        hello_info_free(&hi);
        lr_free(&lr);
        close(fd);
        pthread_mutex_destroy(&write_mu);
        return 1;
    }
    if (hi.res == HELLO_EOF) {
        hello_info_free(&hi);
        lr_free(&lr);
        close(fd);
        pthread_mutex_destroy(&write_mu);
        return 0;
    }
    if (hi.daemon_proto != CODE_PROTO_VERSION) {
        fprintf(stderr, "code stop: incompatible daemon protocol %d (client %d)\n",
                hi.daemon_proto, CODE_PROTO_VERSION);
        hello_info_free(&hi);
        lr_free(&lr);
        close(fd);
        pthread_mutex_destroy(&write_mu);
        return 1;
    }
    hello_info_free(&hi);

    /* Never hold code.lock on stop; send explicit compatible `stop` and require clean EOF. */
    char *derr = NULL;
    enum drain_result dr = client_send_drain_and_release_lock(fd, &lr, &write_mu, NULL, "stop", &b, &derr);
    lr_free(&lr);
    close(fd);
    pthread_mutex_destroy(&write_mu);
    if (dr != DRAIN_EOF) {
        fprintf(stderr, "code stop: %s\n", derr ? derr : "failed to stop daemon");
        free(derr);
        return 1;
    }
    free(derr);
    return 0;
}

int code_status_cmd(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: cntctr code status [--short|--verbose] | stop\n");
        return 2;
    }
    if (strcmp(argv[2], "stop") == 0) {
        if (argc != 3) {
            fprintf(stderr, "usage: cntctr code stop\n");
            return 2;
        }
        return code_stop_cmd();
    }
    if (strcmp(argv[2], "status") != 0) {
        fprintf(stderr, "usage: cntctr code status [--short|--verbose] | stop\n");
        return 2;
    }

    int short_mode = 0, verbose_mode = 0;
    for (int i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--short") == 0) short_mode = 1;
        else if (strcmp(argv[i], "--verbose") == 0) verbose_mode = 1;
        else {
            fprintf(stderr, "usage: cntctr code status [--short|--verbose]\n");
            return 2;
        }
    }
    if (short_mode && verbose_mode) {
        fprintf(stderr, "usage: cntctr code status [--short|--verbose]\n");
        return 2;
    }

    json_object *st = NULL;
    char *err = NULL;
    if (code_client_probe(&st, &err) != 0) {
        fprintf(stderr, "%s\n", err ? err : "code status failed");
        free(err);
        return 1;
    }
    if (!st) {
        if (short_mode) printf("code \xe2\x97\x8b\n"); /* code ○ */
        else printf("code: off\n");
        return 0;
    }

    json_object *jpid = NULL, *jsc = NULL, *jmb = NULL, *jpc = NULL, *jup = NULL;
    json_object *jver = NULL, *jsock = NULL, *jdb = NULL, *jruns = NULL, *jdr = NULL;
    json_object_object_get_ex(st, "pid", &jpid);
    json_object_object_get_ex(st, "server_count", &jsc);
    json_object_object_get_ex(st, "rss_mb", &jmb);
    json_object_object_get_ex(st, "project_count", &jpc);
    json_object_object_get_ex(st, "uptime_sec", &jup);
    json_object_object_get_ex(st, "version", &jver);
    json_object_object_get_ex(st, "sock", &jsock);
    json_object_object_get_ex(st, "db", &jdb);
    json_object_object_get_ex(st, "active_runs", &jruns);
    json_object_object_get_ex(st, "draining", &jdr);

    long long pid = jpid ? json_object_get_int64(jpid) : 0;
    int sc = jsc ? json_object_get_int(jsc) : 0;
    int mb = jmb ? json_object_get_int(jmb) : 0;
    int pc = jpc ? json_object_get_int(jpc) : 0;
    long long up = jup ? json_object_get_int64(jup) : 0;

    if (short_mode) {
        printf("code \xe2\x97\x8f%d\n", sc); /* code ●N */
    } else {
        char upbuf[32];
        format_uptime(up, upbuf);
        printf("code: on \xc2\xb7 pid %lld \xc2\xb7 %d %s \xc2\xb7 %d MB \xc2\xb7 %d %s \xc2\xb7 up %s\n",
               pid, sc, sc == 1 ? "server" : "servers", mb, pc, pc == 1 ? "project" : "projects", upbuf);
        if (verbose_mode) {
            printf("  version: %s\n", jver ? json_object_get_string(jver) : "?");
            printf("  sock: %s\n", jsock ? json_object_get_string(jsock) : "?");
            printf("  db: %s\n", jdb ? json_object_get_string(jdb) : "?");
            printf("  active_runs: %d\n", jruns ? json_object_get_int(jruns) : 0);
            if (jdr && json_object_get_boolean(jdr)) printf("  draining: true\n");
            json_object *jsrvs = NULL;
            if (json_object_object_get_ex(st, "servers", &jsrvs) && jsrvs && json_object_is_type(jsrvs, json_type_array)) {
                size_t ns = json_object_array_length(jsrvs);
                for (size_t i = 0; i < ns; i++) {
                    json_object *so = json_object_array_get_idx(jsrvs, i);
                    printf("  server: %s state=%s pid=%lld rss=%dMB owner=%s\n",
                           req_str(so, "name", "?"), req_str(so, "state", "?"),
                           (long long)req_i64(so, "pid", 0), req_int(so, "rss_mb", 0),
                           req_str(so, "owner_project", "shared"));
                }
            }
        }
    }
    json_object_put(st);
    return 0;
}

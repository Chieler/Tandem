/* QuickJS script runner on a sized pthread with refcounted async tool bridge. */
#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#include "code_js.h"
#include "code_schema.h"
#include "quickjs.h"
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define CODE_DEFAULT_MAX_MB            64
#define CODE_CEIL_MAX_MB               256
#define CODE_DEFAULT_STACK_BYTES       (1024 * 1024)
#define CODE_STACK_HEADROOM_BYTES      (8 * 1024 * 1024)
#define CODE_DEFAULT_CPU_SEC           10
#define CODE_CEIL_CPU_SEC              60
#define CODE_DEFAULT_WALL_SEC          300
#define CODE_CEIL_WALL_SEC             1800
#define CODE_DEFAULT_CALL_SEC          30
#define CODE_CEIL_CALL_SEC             300
#define CODE_DEFAULT_MAX_INFLIGHT      16
#define CODE_DEFAULT_MAX_QUEUE_BYTES   (8 * 1024 * 1024)
#define CODE_DEFAULT_RESULT_PREVIEW    16384
#define CODE_DEFAULT_CALLS_PREVIEW     8192
#define CODE_DEFAULT_MAX_LOG_BYTES     (1024 * 1024)
#define CODE_MAX_RETAINED_RESULT       (4 * 1024 * 1024)
#define CODE_MAX_RETAINED_CALLS        (256 * 1024)
#define CODE_MAX_RETAINED_DENIED       (256 * 1024)

static char *jsfmt(const char *fmt_str, ...) {
    va_list ap;
    char *s = NULL;
    va_start(ap, fmt_str);
    if (vasprintf(&s, fmt_str, ap) < 0) s = strdup("");
    va_end(ap);
    return s;
}

static uint64_t clock_now_ns(clockid_t clk) {
    struct timespec ts;
    if (clock_gettime(clk, &ts) != 0) return 0;
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static int glob_match(const char *pat, const char *str) {
    const char *p = pat, *s = str, *star = NULL, *match = NULL;
    while (*s) {
        if (*p == '?' || *p == *s) { p++; s++; }
        else if (*p == '*') { star = p++; match = s; }
        else if (star) { p = star + 1; s = ++match; }
        else return 0;
    }
    while (*p == '*') p++;
    return *p == '\0';
}

static const char *class_name(enum code_class c) {
    if (c == CODE_READ) return "read";
    if (c == CODE_WRITE) return "write";
    return "destructive";
}

/* POSIX single-quote escaping ('...' with '\'' for embedded single quotes). */
static char *code_shell_quote(const char *s) {
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

/* ---- Refcounted run synchronization object shared with call handles ---- */
struct code_run_sync {
    pthread_mutex_t mu;
    pthread_cond_t cv;
    atomic_int refcount;
    int run_alive;
    int ready_count;
    int cancel_signalled;
};

static struct code_run_sync *run_sync_new(void) {
    struct code_run_sync *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    pthread_mutex_init(&s->mu, NULL);
#ifndef __APPLE__
    pthread_condattr_t cattr;
    pthread_condattr_init(&cattr);
    pthread_condattr_setclock(&cattr, CLOCK_MONOTONIC);
    pthread_cond_init(&s->cv, &cattr);
    pthread_condattr_destroy(&cattr);
#else
    pthread_cond_init(&s->cv, NULL);
#endif
    atomic_init(&s->refcount, 1);
    s->run_alive = 1;
    return s;
}

static struct code_run_sync *run_sync_ref(struct code_run_sync *s) {
    atomic_fetch_add_explicit(&s->refcount, 1, memory_order_relaxed);
    return s;
}

static void run_sync_unref(struct code_run_sync *s) {
    if (!s) return;
    if (atomic_fetch_sub_explicit(&s->refcount, 1, memory_order_acq_rel) == 1) {
        pthread_cond_destroy(&s->cv);
        pthread_mutex_destroy(&s->mu);
        free(s);
    }
}

/* ---- External cancellation token ---- */
struct code_run_cancel {
    pthread_mutex_t mu;
    int cancelled;
    char *reason;
    /* Attached run wake target (protected by mu; never acquire mu while holding sync->mu). */
    struct code_run_sync *wake_sync;
    atomic_int *wake_flag;
};

struct code_run_cancel *code_run_cancel_new(void) {
    struct code_run_cancel *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    pthread_mutex_init(&c->mu, NULL);
    return c;
}

void code_run_cancel_signal(struct code_run_cancel *c, const char *reason) {
    if (!c) return;
    pthread_mutex_lock(&c->mu);
    c->cancelled = 1;
    if (!c->reason && reason && *reason) c->reason = strdup(reason);
    if (c->wake_flag) atomic_store_explicit(c->wake_flag, 1, memory_order_release);
    if (c->wake_sync) {
        pthread_mutex_lock(&c->wake_sync->mu);
        c->wake_sync->cancel_signalled = 1;
        pthread_cond_broadcast(&c->wake_sync->cv);
        pthread_mutex_unlock(&c->wake_sync->mu);
    }
    pthread_mutex_unlock(&c->mu);
}

void code_run_cancel_free(struct code_run_cancel *c) {
    if (!c) return;
    pthread_mutex_destroy(&c->mu);
    free(c->reason);
    free(c);
}

/* ---- Refcounted call completion handle ---- */
enum call_handle_state { CALL_PENDING = 0, CALL_COMPLETED = 1, CALL_DETACHED = 2, CALL_TIMED_OUT = 3 };

struct code_call_handle {
    struct code_run_sync *sync;
    int refcount;                 /* protected by sync->mu; starts at 2 (run + dispatcher) */
    enum call_handle_state state; /* protected by sync->mu */
    enum code_call_status status;
    uint64_t deadline_mono_ns;    /* immutable after creation; checked under sync->mu */
    uint64_t completed_mono_ns;   /* monotonic timestamp sampled under sync->mu */
    char *payload_text;
    int is_json;
    char *grant_cmd;
};

static struct code_call_handle *call_handle_new(struct code_run_sync *sync, uint64_t deadline_mono_ns) {
    struct code_call_handle *h = calloc(1, sizeof *h);
    if (!h) return NULL;
    h->sync = run_sync_ref(sync);
    h->refcount = 2;
    h->state = CALL_PENDING;
    h->deadline_mono_ns = deadline_mono_ns;
    return h;
}

void code_call_handle_unref(struct code_call_handle *h) {
    if (!h) return;
    struct code_run_sync *sync = h->sync;
    pthread_mutex_lock(&sync->mu);
    int rc = --h->refcount;
    pthread_mutex_unlock(&sync->mu);
    if (rc == 0) {
        free(h->payload_text);
        free(h->grant_cmd);
        free(h);
        run_sync_unref(sync);
    }
}

void code_js_complete(struct code_call_handle *h, enum code_call_status status,
                      const char *payload_text, int is_json, const char *grant_cmd_or_null) {
    if (!h) return;
    struct code_run_sync *sync = h->sync;
    pthread_mutex_lock(&sync->mu);
    if (h->state != CALL_PENDING || !sync->run_alive) {
        if (h->state == CALL_PENDING) h->state = CALL_DETACHED;
        pthread_mutex_unlock(&sync->mu);
        return;
    }
    /* Single linearization point shared with check_call_timeouts under sync->mu. */
    uint64_t comp_ns = clock_now_ns(CLOCK_MONOTONIC);
    h->completed_mono_ns = comp_ns;
    if (comp_ns >= h->deadline_mono_ns) {
        h->state = CALL_TIMED_OUT;
        sync->ready_count++;
        pthread_cond_signal(&sync->cv);
        pthread_mutex_unlock(&sync->mu);
        return;
    }
    h->state = CALL_COMPLETED;
    h->status = status;
    h->payload_text = payload_text ? strdup(payload_text) : strdup("");
    h->is_json = is_json ? 1 : 0;
    h->grant_cmd = (grant_cmd_or_null && *grant_cmd_or_null) ? strdup(grant_cmd_or_null) : NULL;
    sync->ready_count++;
    pthread_cond_signal(&sync->cv);
    pthread_mutex_unlock(&sync->mu);
}

/* ---- Bounded append buffer (for logs, calls, denied) ---- */
struct cap_buf {
    char *data;
    size_t len, cap, max_bytes;
    size_t dropped;
    int capped;
};

static void cap_buf_init(struct cap_buf *b, size_t max_bytes) {
    memset(b, 0, sizeof *b);
    b->max_bytes = max_bytes;
}

static void cap_buf_free(struct cap_buf *b) {
    free(b->data);
    memset(b, 0, sizeof *b);
}

static void cap_buf_append(struct cap_buf *b, const char *s, size_t n) {
    const size_t reserve = 64;
    if (b->capped || b->max_bytes <= reserve || b->len + n + reserve > b->max_bytes) {
        b->capped = 1;
        b->dropped++;
        return;
    }
    if (b->len + n + 1 > b->cap) {
        size_t ncap = b->cap ? b->cap * 2 : 512;
        while (ncap < b->len + n + 1) ncap *= 2;
        if (ncap > b->max_bytes + 1) ncap = b->max_bytes + 1;
        char *p = realloc(b->data, ncap);
        if (!p) { b->capped = 1; b->dropped++; return; }
        b->data = p;
        b->cap = ncap;
    }
    memcpy(b->data + b->len, s, n);
    b->len += n;
    b->data[b->len] = '\0';
}

static void cap_buf_append_str(struct cap_buf *b, const char *s) {
    if (s) cap_buf_append(b, s, strlen(s));
}

static char *cap_buf_finish(struct cap_buf *b, const char *drop_unit) {
    if (b->dropped > 0) {
        char note[96];
        int nn = snprintf(note, sizeof note, "... (%zu %s dropped)\n", b->dropped, drop_unit);
        if (nn > 0 && b->len + (size_t)nn <= b->max_bytes) {
            if (b->len + (size_t)nn + 1 > b->cap) {
                char *p = realloc(b->data, b->len + (size_t)nn + 1);
                if (p) { b->data = p; b->cap = b->len + (size_t)nn + 1; }
            }
            if (b->data && b->cap >= b->len + (size_t)nn + 1) {
                memcpy(b->data + b->len, note, (size_t)nn);
                b->len += (size_t)nn;
                b->data[b->len] = '\0';
            }
        }
    }
    char *res = b->data ? b->data : strdup("");
    b->data = NULL;
    b->len = b->cap = 0;
    return res;
}

static size_t utf8_truncate_pos(const char *s, size_t max_bytes) {
    size_t len = strlen(s);
    if (len <= max_bytes) return len;
    size_t cut = max_bytes;
    while (cut > 0 && (((unsigned char)s[cut]) & 0xC0) == 0x80) cut--;
    return cut;
}

static char *build_preview(const char *full, size_t preview_cap, const char *part_name) {
    if (!full) return strdup("");
    size_t len = strlen(full);
    if (len <= preview_cap) return strdup(full);
    if (preview_cap == 0) return strdup("");

    /* Try full expand footer first, strictly budgeting total length <= preview_cap. */
    size_t cut = preview_cap;
    for (int iter = 0; iter < 3; iter++) {
        int flen = snprintf(NULL, 0,
            "\n... (truncated: %zu of %zu bytes shown; code_expand part=%s offset=%zu)",
            cut, len, part_name, cut);
        if (flen <= 0 || (size_t)flen >= preview_cap) { cut = 0; break; }
        size_t ncut = utf8_truncate_pos(full, preview_cap - (size_t)flen);
        if (ncut == cut) break;
        cut = ncut;
    }
    {
        int flen = snprintf(NULL, 0,
            "\n... (truncated: %zu of %zu bytes shown; code_expand part=%s offset=%zu)",
            cut, len, part_name, cut);
        if (flen > 0 && cut + (size_t)flen <= preview_cap) {
            return jsfmt("%.*s\n... (truncated: %zu of %zu bytes shown; code_expand part=%s offset=%zu)",
                         (int)cut, full, cut, len, part_name, cut);
        }
    }

    /* Fall back to compact offset footer if it fits within preview_cap. */
    cut = preview_cap;
    for (int iter = 0; iter < 3; iter++) {
        int flen = snprintf(NULL, 0, "\n... (offset=%zu)", cut);
        if (flen <= 0 || (size_t)flen >= preview_cap) { cut = 0; break; }
        size_t ncut = utf8_truncate_pos(full, preview_cap - (size_t)flen);
        if (ncut == cut) break;
        cut = ncut;
    }
    {
        int flen = snprintf(NULL, 0, "\n... (offset=%zu)", cut);
        if (flen > 0 && cut + (size_t)flen <= preview_cap) {
            return jsfmt("%.*s\n... (offset=%zu)", (int)cut, full, cut);
        }
    }

    /* Cap is too small for any footer: omit footer and return UTF-8 aligned prefix <= preview_cap. */
    cut = utf8_truncate_pos(full, preview_cap);
    return jsfmt("%.*s", (int)cut, full);
}

/* ---- Per-run state (owned strictly by run thread except sync & cancel_flag) ---- */
enum abort_kind {
    ABORT_NONE = 0,
    ABORT_CPU = 1,
    ABORT_WALL = 2,
    ABORT_CANCEL = 3,
    ABORT_OOM = 4
};

struct pending_call {
    struct code_call_handle *h;
    JSValue resolve_fn;
    JSValue reject_fn;
    char *server;
    char *tool;
    enum code_class eff_class;
    uint64_t start_mono_ns;
    uint64_t deadline_mono_ns;
    size_t args_bytes;
    struct pending_call *next;
};

struct run_state {
    const struct code_run_opts *opts;
    struct code_run_out *out;
    struct code_run_sync *sync;
    atomic_int cancel_flag;

    sqlite3 *db;
    JSRuntime *rt;
    JSContext *ctx;

    /* Clamped limits */
    size_t max_mb, max_stack_bytes, result_preview_cap, calls_preview_cap, max_log_bytes, max_queue_bytes;
    int cpu_sec, wall_sec, call_sec, max_inflight;

    /* Clocks */
    uint64_t cpu_start_ns, cpu_budget_ns;
    uint64_t wall_start_ns, wall_deadline_ns;

    /* Abort tracking */
    enum abort_kind abort_kind;
    uint64_t cpu_used_ns;
    uint64_t wall_used_ns;

    /* Pending calls (owned only by run thread) */
    struct pending_call *pending;
    int inflight_count;
    size_t queued_bytes;

    /* Output buffers */
    struct cap_buf logs_buf;
    struct cap_buf calls_buf;
    struct cap_buf denied_buf;
    int rc;
};

static int remaining_wall_ms(struct run_state *r) {
    uint64_t now = clock_now_ns(CLOCK_MONOTONIC);
    if (now >= r->wall_deadline_ns) return 0;
    uint64_t rem = (r->wall_deadline_ns - now) / 1000000ULL;
    if (rem > (uint64_t)INT_MAX) return INT_MAX;
    return rem == 0 ? 1 : (int)rem;
}

static int check_limits(struct run_state *r) {
    if (r->abort_kind != ABORT_NONE) return 1;
    if (atomic_load_explicit(&r->cancel_flag, memory_order_acquire)) {
        r->abort_kind = ABORT_CANCEL;
        return 1;
    }
    uint64_t cpu_now = clock_now_ns(CLOCK_THREAD_CPUTIME_ID);
    uint64_t cpu_used = cpu_now >= r->cpu_start_ns ? (cpu_now - r->cpu_start_ns) : 0;
    if (cpu_used >= r->cpu_budget_ns) {
        r->cpu_used_ns = cpu_used;
        r->abort_kind = ABORT_CPU;
        return 1;
    }
    uint64_t mono_now = clock_now_ns(CLOCK_MONOTONIC);
    if (mono_now >= r->wall_deadline_ns) {
        r->wall_used_ns = mono_now >= r->wall_start_ns ? (mono_now - r->wall_start_ns) : 0;
        r->abort_kind = ABORT_WALL;
        return 1;
    }
    return 0;
}

static int js_interrupt_cb(JSContext *ctx, void *opaque) {
    (void)ctx;
    return check_limits((struct run_state *)opaque);
}

static int db_progress_cb(void *opaque) {
    struct run_state *r = (struct run_state *)opaque;
    if (atomic_load_explicit(&r->cancel_flag, memory_order_acquire)) {
        r->abort_kind = ABORT_CANCEL;
        return 1;
    }
    if (clock_now_ns(CLOCK_MONOTONIC) >= r->wall_deadline_ns) {
        r->abort_kind = ABORT_WALL;
        return 1;
    }
    return 0;
}

static void sleep_cancelable_ms(struct run_state *r, int ms) {
    if (ms <= 0) return;
    pthread_mutex_lock(&r->sync->mu);
    if (!r->sync->cancel_signalled &&
        !atomic_load_explicit(&r->cancel_flag, memory_order_acquire)) {
#ifdef __APPLE__
        struct timespec rel = { ms / 1000, (ms % 1000) * 1000000L };
        pthread_cond_timedwait_relative_np(&r->sync->cv, &r->sync->mu, &rel);
#else
        uint64_t target_ns = clock_now_ns(CLOCK_MONOTONIC) + (uint64_t)ms * 1000000ULL;
        struct timespec abs_ts = {
            (time_t)(target_ns / 1000000000ULL),
            (long)(target_ns % 1000000000ULL)
        };
        pthread_cond_timedwait(&r->sync->cv, &r->sync->mu, &abs_ts);
#endif
    }
    pthread_mutex_unlock(&r->sync->mu);
}

/* Cancel- and deadline-aware SQLite busy handler (wakes immediately on code_run_cancel_signal). */
static int db_busy_cb(void *opaque, int count) {
    struct run_state *r = (struct run_state *)opaque;
    if (check_limits(r)) return 0;
    int rem = remaining_wall_ms(r);
    if (rem <= 0) {
        r->abort_kind = ABORT_WALL;
        return 0;
    }
    int slice = (count < 5) ? 5 : (count < 20 ? 15 : 25);
    if (slice > rem) slice = rem;
    sleep_cancelable_ms(r, slice);
    return check_limits(r) ? 0 : 1;
}

static int schema_abort_cb(void *opaque) {
    return check_limits((struct run_state *)opaque);
}

/* Hostile-JS-proof conversion of JSValue to malloc'd C string. Never leaves a pending exception. */
static char *safe_js_to_string(JSContext *ctx, JSValueConst val) {
    if (JS_IsUndefined(val)) return strdup("undefined");
    if (JS_IsNull(val)) return strdup("null");
    if (JS_IsBool(val)) return strdup(JS_ToBool(ctx, val) ? "true" : "false");
    if (JS_IsString(val)) {
        size_t len = 0;
        const char *s = JS_ToCStringLen(ctx, &len, val);
        if (!s) {
            JS_FreeValue(ctx, JS_GetException(ctx));
            return strdup("");
        }
        char *out = malloc(len + 1);
        if (out) { memcpy(out, s, len); out[len] = '\0'; }
        JS_FreeCString(ctx, s);
        return out ? out : strdup("");
    }
    if (JS_IsNumber(val)) {
        double d = 0;
        if (JS_ToFloat64(ctx, &d, val) == 0) return jsfmt("%.15g", d);
        JS_FreeValue(ctx, JS_GetException(ctx));
        return strdup("NaN");
    }
    if (JS_IsBigInt(val)) {
        int64_t bi = 0;
        if (JS_ToBigInt64(ctx, &bi, val) == 0) return jsfmt("%lldn", (long long)bi);
        JS_FreeValue(ctx, JS_GetException(ctx));
        return strdup("[BigInt]");
    }
    if (JS_IsError(val)) {
        char *name_s = NULL, *msg_s = NULL;
        JSValue nv = JS_GetPropertyStr(ctx, val, "name");
        if (JS_IsException(nv)) {
            JS_FreeValue(ctx, JS_GetException(ctx));
        } else {
            if (JS_IsString(nv)) name_s = safe_js_to_string(ctx, nv);
            JS_FreeValue(ctx, nv);
        }
        JSValue mv = JS_GetPropertyStr(ctx, val, "message");
        if (JS_IsException(mv)) {
            JS_FreeValue(ctx, JS_GetException(ctx));
        } else {
            if (JS_IsString(mv)) msg_s = safe_js_to_string(ctx, mv);
            JS_FreeValue(ctx, mv);
        }
        char *out = NULL;
        if (name_s && msg_s && *msg_s) out = jsfmt("%s: %s", name_s, msg_s);
        else if (msg_s && *msg_s) out = strdup(msg_s);
        else if (name_s && *name_s) out = strdup(name_s);
        else out = strdup("[Error]");
        free(name_s);
        free(msg_s);
        return out;
    }
    JSValue jv = JS_JSONStringify(ctx, val, JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(jv)) {
        JS_FreeValue(ctx, JS_GetException(ctx));
        return strdup("[Object]");
    }
    if (JS_IsString(jv)) {
        char *out = safe_js_to_string(ctx, jv);
        JS_FreeValue(ctx, jv);
        return out;
    }
    JS_FreeValue(ctx, jv);
    return strdup("[Object]");
}

/* Detect literal NUL bytes or JSON \u0000 escapes inside JSON string literals (keys or values). */
static int json_text_has_nul(const char *s, size_t len) {
    if (memchr(s, '\0', len) != NULL) return 1;
    int in_str = 0;
    for (size_t i = 0; i < len; i++) {
        char c = s[i];
        if (!in_str) {
            if (c == '"') in_str = 1;
            continue;
        }
        if (c == '"') { in_str = 0; continue; }
        if (c == '\\') {
            if (i + 5 < len && (s[i + 1] == 'u' || s[i + 1] == 'U') &&
                s[i + 2] == '0' && s[i + 3] == '0' && s[i + 4] == '0' && s[i + 5] == '0') {
                return 1;
            }
            if (i + 1 < len) i++; /* skip escaped char so \\u0000 is NOT treated as \u0000 */
        }
    }
    return 0;
}

static int json_obj_has_nul(json_object *obj, int depth) {
    if (!obj || depth > 32) return 0;
    switch (json_object_get_type(obj)) {
        case json_type_string: {
            int l = json_object_get_string_len(obj);
            const char *s = json_object_get_string(obj);
            return l > 0 && memchr(s, '\0', (size_t)l) != NULL;
        }
        case json_type_array: {
            size_t n = json_object_array_length(obj);
            for (size_t i = 0; i < n; i++) {
                if (json_obj_has_nul(json_object_array_get_idx(obj, i), depth + 1)) return 1;
            }
            return 0;
        }
        case json_type_object: {
            json_object_object_foreach(obj, k, v) {
                (void)k;
                if (json_obj_has_nul(v, depth + 1)) return 1;
            }
            return 0;
        }
        default: return 0;
    }
}

static JSValue make_rejected_error(JSContext *ctx, const char *msg) {
    JSValue err = JS_NewError(ctx);
    if (!JS_IsException(err)) {
        JS_DefinePropertyValueStr(ctx, err, "message",
                                  JS_NewString(ctx, msg ? msg : "error"),
                                  JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
    }
    JSValue p = JS_NewSettledPromise(ctx, true, err);
    JS_FreeValue(ctx, err);
    return p;
}

static void record_call_line(struct run_state *r, const char *server, const char *tool,
                             const char *cls, long long dur_ms, const char *outcome) {
    char *line = jsfmt("%s.%s %s %lldms %s\n", server, tool, cls, dur_ms, outcome);
    cap_buf_append_str(&r->calls_buf, line);
    free(line);
}

static void record_denied_line(struct run_state *r, const char *server, const char *tool,
                               const char *cls, const char *reason, const char *grant_cmd) {
    char *line = (grant_cmd && *grant_cmd)
        ? jsfmt("%s.%s (%s): %s — %s\n", server, tool, cls, reason ? reason : "denied", grant_cmd)
        : jsfmt("%s.%s (%s): %s\n", server, tool, cls, reason ? reason : "denied");
    cap_buf_append_str(&r->denied_buf, line);
    free(line);
}

static char *build_grant_cmd(const char *project, const char *server, const char *tool, enum code_class eff, int user_scoped) {
    char *qroot = code_shell_quote(project ? project : "");
    char *target = (eff == CODE_READ) ? jsfmt("%s.*", server) : jsfmt("%s.%s", server, tool);
    char *qtarget = code_shell_quote(target);
    const char *lvl = (eff == CODE_READ) ? "read" : "allow";
    char *cmd = jsfmt("cd %s && cntctr code grant %s %s", qroot, qtarget, lvl);
    if (eff == CODE_READ && user_scoped && strcmp(server, "cntctr") != 0) {   /* a read grant can also be user-wide, but only for a user-scoped server */
        char *all = jsfmt("%s (all projects: cntctr code grant --all-projects %s read)", cmd, qtarget);
        free(cmd);
        cmd = all;
    }
    free(qroot);
    free(target);
    free(qtarget);
    return cmd;
}

static int scope_permits(const struct code_run_opts *opts, const char *server, const char *tool) {
    if (!opts->scope || opts->nscope == 0) return 1;
    char *full = jsfmt("%s.%s", server, tool);
    int ok = 0;
    for (size_t i = 0; i < opts->nscope; i++) {
        if (opts->scope[i] && glob_match(opts->scope[i], full)) { ok = 1; break; }
    }
    free(full);
    return ok;
}

/* Fail-closed scan for any matching access deny rule on (project, reg_id, tool). */
static int check_static_deny(struct run_state *r, const char *reg_id, const char *tool, char **why_out) {
    if (why_out) *why_out = NULL;
    if (!r->db || !r->opts->project || !*r->opts->project || !reg_id || !*reg_id) {
        if (why_out) *why_out = strdup("grant database unavailable");
        return 1;
    }
    if (check_limits(r)) {
        if (why_out) *why_out = strdup("run aborted");
        return 1;
    }
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(r->db,
            "SELECT tool_pattern, reason FROM code_grants"
            " WHERE project IN (?1, '" KB_CODE_ALL_PROJECTS "') AND reg_id = ?2 AND kind = 'access' AND level = 'deny'",
            -1, &st, NULL) != SQLITE_OK) {
        if (why_out) *why_out = strdup("grant lookup failed");
        return 1;
    }
    if (sqlite3_bind_text(st, 1, r->opts->project, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_bind_text(st, 2, reg_id, -1, SQLITE_TRANSIENT) != SQLITE_OK) {
        sqlite3_finalize(st);
        if (why_out) *why_out = strdup("grant lookup failed");
        return 1;
    }
    int step_rc, denied = 0;
    while ((step_rc = sqlite3_step(st)) == SQLITE_ROW) {
        const char *pat = (const char *)sqlite3_column_text(st, 0);
        const char *reason = (const char *)sqlite3_column_text(st, 1);
        if (pat && glob_match(pat, tool)) {
            denied = 1;
            if (why_out) {
                *why_out = (reason && *reason)
                    ? jsfmt("denied by rule %s (%s)", pat, reason)
                    : jsfmt("denied by rule %s", pat);
            }
            break;
        }
    }
    sqlite3_finalize(st);
    if (!denied && step_rc != SQLITE_DONE) {
        if (why_out) *why_out = strdup("grant lookup interrupted or failed");
        return 1;
    }
    return denied;
}

static const struct code_server_hint *find_server_hint(const struct code_run_opts *opts, const char *server) {
    for (size_t i = 0; i < opts->nservers; i++) {
        if (opts->servers[i].name && strcmp(opts->servers[i].name, server) == 0)
            return &opts->servers[i];
    }
    return NULL;
}

static int server_has_catalog(const struct code_run_opts *opts, const char *server) {
    for (size_t i = 0; i < opts->ncatalog; i++) {
        if (opts->catalog[i].server && strcmp(opts->catalog[i].server, server) == 0)
            return 1;
    }
    const struct code_server_hint *h = find_server_hint(opts, server);
    return h && h->has_catalog;
}

static const struct code_tool_meta *find_tool_meta(const struct code_run_opts *opts,
                                                   const char *server, const char *tool) {
    for (size_t i = 0; i < opts->ncatalog; i++) {
        if (opts->catalog[i].server && opts->catalog[i].name &&
            strcmp(opts->catalog[i].server, server) == 0 &&
            strcmp(opts->catalog[i].name, tool) == 0)
            return &opts->catalog[i];
    }
    return NULL;
}

/* Convert JS call argument to owned json_object * (object only, no NUL bytes, single-arg cap).
 * Live queued_bytes and limits are re-checked AFTER serialization because JS getters/toJSON can re-enter. */
static int convert_js_args(JSContext *ctx, int argc, JSValueConst *argv, size_t max_queue_bytes,
                           json_object **out_obj, size_t *out_bytes, char **err) {
    *out_obj = NULL;
    *out_bytes = 2;
    *err = NULL;
    if (argc == 0 || JS_IsUndefined(argv[0])) {
        if (2 > max_queue_bytes) {
            *err = jsfmt("queued argument bytes limit exceeded (2 > %zu; raise CNTCTR_CODE_MAX_QUEUE_BYTES)",
                         max_queue_bytes);
            return -1;
        }
        *out_obj = json_object_new_object();
        return 0;
    }
    if (JS_IsBigInt(argv[0])) {
        *err = strdup("tool arguments cannot contain BigInt");
        return -1;
    }
    if (!JS_IsObject(argv[0]) || JS_IsArray(argv[0]) || JS_IsFunction(ctx, argv[0])) {
        *err = strdup("tool arguments must be a plain JSON object");
        return -1;
    }
    JSValue jstr = JS_JSONStringify(ctx, argv[0], JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(jstr)) {
        JSValue exc = JS_GetException(ctx);
        char *m = safe_js_to_string(ctx, exc);
        JS_FreeValue(ctx, exc);
        *err = jsfmt("invalid tool arguments: %s", m);
        free(m);
        return -1;
    }
    if (!JS_IsString(jstr)) {
        JS_FreeValue(ctx, jstr);
        *err = strdup("tool arguments must be JSON-serializable");
        return -1;
    }
    size_t len = 0;
    const char *raw = JS_ToCStringLen(ctx, &len, jstr);
    if (!raw) {
        JS_FreeValue(ctx, JS_GetException(ctx));
        JS_FreeValue(ctx, jstr);
        *err = strdup("failed to encode tool arguments");
        return -1;
    }
    if (len > (size_t)INT_MAX || len > max_queue_bytes) {
        JS_FreeCString(ctx, raw);
        JS_FreeValue(ctx, jstr);
        *err = jsfmt("queued argument bytes limit exceeded (%zu > %zu; raise CNTCTR_CODE_MAX_QUEUE_BYTES)",
                     len, max_queue_bytes);
        return -1;
    }
    if (json_text_has_nul(raw, len)) {
        JS_FreeCString(ctx, raw);
        JS_FreeValue(ctx, jstr);
        *err = strdup("tool arguments must not contain NUL bytes");
        return -1;
    }
    struct json_tokener *tok = json_tokener_new();
    json_object *obj = tok ? json_tokener_parse_ex(tok, raw, (int)len) : NULL;
    enum json_tokener_error jerr = tok ? json_tokener_get_error(tok) : json_tokener_error_parse_unexpected;
    if (tok) json_tokener_free(tok);
    JS_FreeCString(ctx, raw);
    JS_FreeValue(ctx, jstr);

    if (!obj || jerr != json_tokener_success || !json_object_is_type(obj, json_type_object)) {
        if (obj) json_object_put(obj);
        *err = strdup("tool arguments must be a JSON object");
        return -1;
    }
    if (json_obj_has_nul(obj, 0)) {
        json_object_put(obj);
        *err = strdup("tool arguments must not contain NUL bytes");
        return -1;
    }
    *out_obj = obj;
    *out_bytes = len;
    return 0;
}

/* ---- Bridge call entrypoint: tools.<server>.<tool>(args) ---- */
static JSValue js_bridge_call(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv,
                              int magic, JSValue *func_data) {
    (void)this_val;
    (void)magic;
    struct run_state *r = (struct run_state *)JS_GetContextOpaque(ctx);
    if (!r) return make_rejected_error(ctx, "internal runner error");
    if (check_limits(r)) return JS_ThrowInternalError(ctx, "interrupted");

    const char *server = JS_ToCString(ctx, func_data[0]);
    const char *tool = JS_ToCString(ctx, func_data[1]);
    if (!server || !tool) {
        if (server) JS_FreeCString(ctx, server);
        if (tool) JS_FreeCString(ctx, tool);
        return make_rejected_error(ctx, "invalid tool reference");
    }

    char *srv_copy = strdup(server);
    char *tool_copy = strdup(tool);
    JS_FreeCString(ctx, server);
    JS_FreeCString(ctx, tool);

    const struct code_run_opts *opts = r->opts;
    const struct code_server_hint *shint = find_server_hint(opts, srv_copy);
    int has_cat = server_has_catalog(opts, srv_copy);

    if (!shint && !has_cat) {
        /* Unknown server: suggest closest known servers */
        size_t cap = opts->nservers + opts->ncatalog;
        const char **cands = cap ? calloc(cap, sizeof *cands) : NULL;
        size_t nc = 0;
        for (size_t i = 0; i < opts->nservers; i++) {
            if (opts->servers[i].name) cands[nc++] = opts->servers[i].name;
        }
        for (size_t i = 0; i < opts->ncatalog; i++) {
            const char *sn = opts->catalog[i].server;
            if (!sn) continue;
            int dup = 0;
            for (size_t j = 0; j < nc; j++) if (strcmp(cands[j], sn) == 0) { dup = 1; break; }
            if (!dup) cands[nc++] = sn;
        }
        char *sug = code_suggest_names(srv_copy, cands, nc);
        free(cands);
        char *msg = sug ? jsfmt("unknown server '%s'; did you mean: %s?", srv_copy, sug)
                        : jsfmt("unknown server '%s'", srv_copy);
        free(sug);
        record_call_line(r, srv_copy, tool_copy, "unknown", 0, "error");
        JSValue ret = make_rejected_error(ctx, msg);
        free(msg);
        free(srv_copy);
        free(tool_copy);
        return ret;
    }

    const struct code_tool_meta *meta = NULL;
    const char *reg_id = NULL;
    long long meta_gen = 0;
    enum code_class eff_class = CODE_WRITE;

    if (has_cat) {
        meta = find_tool_meta(opts, srv_copy, tool_copy);
        if (!meta) {
            const char **cands = opts->ncatalog ? calloc(opts->ncatalog, sizeof *cands) : NULL;
            size_t nc = 0;
            for (size_t i = 0; i < opts->ncatalog; i++) {
                if (opts->catalog[i].server && opts->catalog[i].name &&
                    strcmp(opts->catalog[i].server, srv_copy) == 0)
                    cands[nc++] = opts->catalog[i].name;
            }
            char *sug = code_suggest_names(tool_copy, cands, nc);
            free(cands);
            char *msg = sug ? jsfmt("unknown tool %s.%s; did you mean: %s?", srv_copy, tool_copy, sug)
                            : jsfmt("unknown tool %s.%s", srv_copy, tool_copy);
            free(sug);
            record_call_line(r, srv_copy, tool_copy, "unknown", 0, "error");
            JSValue ret = make_rejected_error(ctx, msg);
            free(msg);
            free(srv_copy);
            free(tool_copy);
            return ret;
        }
        reg_id = meta->reg_id;
        meta_gen = meta->meta_gen;
        eff_class = meta->base_class;

        /* 1. Scope check (only narrows) */
        if (!scope_permits(opts, srv_copy, tool_copy)) {
            char *msg = jsfmt("tool %s.%s is outside run scope", srv_copy, tool_copy);
            record_call_line(r, srv_copy, tool_copy, class_name(eff_class), 0, "denied");
            record_denied_line(r, srv_copy, tool_copy, class_name(eff_class), msg, NULL);
            JSValue ret = make_rejected_error(ctx, msg);
            free(msg);
            free(srv_copy);
            free(tool_copy);
            return ret;
        }

        /* 2. Grant check (cancel/deadline-aware busy handler + fail closed) */
        if (check_limits(r)) {
            free(srv_copy);
            free(tool_copy);
            return JS_ThrowInternalError(ctx, "interrupted");
        }
        char *why = NULL;
        int grc = kb_code_check_grant(r->db, opts->project, reg_id, tool_copy,
                                      meta->base_class, &eff_class, &why);
        if (check_limits(r)) {
            free(why);
            free(srv_copy);
            free(tool_copy);
            return JS_ThrowInternalError(ctx, "interrupted");
        }
        if (grc != 0) {
            char *gcmd = build_grant_cmd(opts->project, srv_copy, tool_copy, eff_class, kb_code_reg_user_scoped(r->db, reg_id));
            const char *w = why ? why : "denied";
            char *msg = jsfmt("%s.%s (%s) denied: %s; grant with: %s",
                              srv_copy, tool_copy, class_name(eff_class), w, gcmd);
            record_call_line(r, srv_copy, tool_copy, class_name(eff_class), 0, "denied");
            record_denied_line(r, srv_copy, tool_copy, class_name(eff_class), w, gcmd);
            JSValue ret = make_rejected_error(ctx, msg);
            free(why);
            free(gcmd);
            free(msg);
            free(srv_copy);
            free(tool_copy);
            return ret;
        }
        free(why);
    } else {
        /* Uncatalogued server: check scope, statically decidable deny, and non-deny grant BEFORE lazy dispatch */
        reg_id = shint->reg_id;
        meta_gen = 0;
        eff_class = CODE_READ;

        if (!scope_permits(opts, srv_copy, tool_copy)) {
            char *msg = jsfmt("tool %s.%s is outside run scope", srv_copy, tool_copy);
            record_call_line(r, srv_copy, tool_copy, "unknown", 0, "denied");
            record_denied_line(r, srv_copy, tool_copy, "unknown", msg, NULL);
            JSValue ret = make_rejected_error(ctx, msg);
            free(msg);
            free(srv_copy);
            free(tool_copy);
            return ret;
        }

        char *deny_why = NULL;
        int sdeny = check_static_deny(r, reg_id, tool_copy, &deny_why);
        if (check_limits(r)) {
            free(deny_why);
            free(srv_copy);
            free(tool_copy);
            return JS_ThrowInternalError(ctx, "interrupted");
        }
        if (sdeny) {
            const char *w = deny_why ? deny_why : "denied";
            char *msg = jsfmt("%s.%s denied: %s", srv_copy, tool_copy, w);
            record_call_line(r, srv_copy, tool_copy, "unknown", 0, "denied");
            record_denied_line(r, srv_copy, tool_copy, "unknown", w, NULL);
            JSValue ret = make_rejected_error(ctx, msg);
            free(deny_why);
            free(msg);
            free(srv_copy);
            free(tool_copy);
            return ret;
        }
        free(deny_why);

        int has_nd = kb_code_has_non_deny_grant(r->db, opts->project, reg_id);
        if (check_limits(r)) {
            free(srv_copy);
            free(tool_copy);
            return JS_ThrowInternalError(ctx, "interrupted");
        }
        if (!has_nd) {
            char *gcmd = build_grant_cmd(opts->project, srv_copy, tool_copy, CODE_READ, kb_code_reg_user_scoped(r->db, reg_id));
            char *msg = jsfmt("%s.%s denied: no grant for server %s; grant with: %s",
                              srv_copy, tool_copy, srv_copy, gcmd);
            record_call_line(r, srv_copy, tool_copy, "unknown", 0, "denied");
            record_denied_line(r, srv_copy, tool_copy, "unknown", "no grant for server", gcmd);
            JSValue ret = make_rejected_error(ctx, msg);
            free(gcmd);
            free(msg);
            free(srv_copy);
            free(tool_copy);
            return ret;
        }
    }

    /* 3. Convert & validate JS args (defaults omitted/undefined to {}, rejects BigInt/circular/NUL) */
    json_object *args_obj = NULL;
    size_t args_bytes = 0;
    char *arg_err = NULL;
    if (convert_js_args(ctx, argc, argv, r->max_queue_bytes,
                        &args_obj, &args_bytes, &arg_err) != 0) {
        if (check_limits(r)) {
            free(arg_err);
            free(srv_copy);
            free(tool_copy);
            return JS_ThrowInternalError(ctx, "interrupted");
        }
        record_call_line(r, srv_copy, tool_copy, class_name(eff_class), 0, "error");
        JSValue ret = make_rejected_error(ctx, arg_err ? arg_err : "invalid arguments");
        free(arg_err);
        free(srv_copy);
        free(tool_copy);
        return ret;
    }

    /* Re-check deadline/cancel immediately after JS serialization (getters/toJSON may have run). */
    if (check_limits(r)) {
        json_object_put(args_obj);
        free(srv_copy);
        free(tool_copy);
        return JS_ThrowInternalError(ctx, "interrupted");
    }

    /* 4. Schema validation with work budget & abort checks (catalogued tools) */
    if (meta && meta->input_schema) {
        char *serr = NULL;
        struct code_schema_budget sb = { 10000, 0, 0, schema_abort_cb, r };
        int vrc = code_schema_validate_budget(meta->input_schema, args_obj, &sb, &serr);
        if (vrc < 0 || check_limits(r)) {
            json_object_put(args_obj);
            free(serr);
            free(srv_copy);
            free(tool_copy);
            return JS_ThrowInternalError(ctx, "interrupted");
        }
        if (vrc != 0) {
            json_object_put(args_obj);
            char *msg = jsfmt("%s.%s invalid arguments: %s", srv_copy, tool_copy, serr ? serr : "schema mismatch");
            free(serr);
            record_call_line(r, srv_copy, tool_copy, class_name(eff_class), 0, "error");
            JSValue ret = make_rejected_error(ctx, msg);
            free(msg);
            free(srv_copy);
            free(tool_copy);
            return ret;
        }
        free(serr);
    }

    /* 5. Re-check live limits, inflight cap, and queued_bytes (overflow-safe subtraction) immediately before enqueue */
    if (check_limits(r)) {
        json_object_put(args_obj);
        free(srv_copy);
        free(tool_copy);
        return JS_ThrowInternalError(ctx, "interrupted");
    }
    if (r->queued_bytes > r->max_queue_bytes || args_bytes > r->max_queue_bytes - r->queued_bytes) {
        json_object_put(args_obj);
        char *msg = jsfmt("queued argument bytes limit exceeded (%zu + %zu > %zu; raise CNTCTR_CODE_MAX_QUEUE_BYTES)",
                          r->queued_bytes, args_bytes, r->max_queue_bytes);
        record_call_line(r, srv_copy, tool_copy, class_name(eff_class), 0, "error");
        JSValue ret = make_rejected_error(ctx, msg);
        free(msg);
        free(srv_copy);
        free(tool_copy);
        return ret;
    }
    if (r->inflight_count >= r->max_inflight) {
        json_object_put(args_obj);
        char *msg = jsfmt("in-flight call limit reached (%d / %d; raise CNTCTR_CODE_MAX_INFLIGHT)",
                          r->inflight_count, r->max_inflight);
        record_call_line(r, srv_copy, tool_copy, class_name(eff_class), 0, "error");
        JSValue ret = make_rejected_error(ctx, msg);
        free(msg);
        free(srv_copy);
        free(tool_copy);
        return ret;
    }

    if (!opts->dispatch) {
        json_object_put(args_obj);
        record_call_line(r, srv_copy, tool_copy, class_name(eff_class), 0, "error");
        JSValue ret = make_rejected_error(ctx, "no dispatcher configured");
        free(srv_copy);
        free(tool_copy);
        return ret;
    }

    /* 6. Create Promise + refcounted handle and dispatch */
    JSValue resolving[2] = { JS_UNDEFINED, JS_UNDEFINED };
    JSValue promise = JS_NewPromiseCapability(ctx, resolving);
    if (JS_IsException(promise)) {
        json_object_put(args_obj);
        free(srv_copy);
        free(tool_copy);
        return promise;
    }

    uint64_t now_ns = clock_now_ns(CLOCK_MONOTONIC);
    uint64_t call_dl = now_ns + (uint64_t)r->call_sec * 1000000000ULL;
    if (call_dl > r->wall_deadline_ns) call_dl = r->wall_deadline_ns;
    int timeout_ms = call_dl > now_ns ? (int)((call_dl - now_ns) / 1000000ULL) : 1;
    if (timeout_ms <= 0) timeout_ms = 1;

    struct code_call_handle *h = call_handle_new(r->sync, call_dl);
    struct pending_call *pc = calloc(1, sizeof *pc);
    if (!h || !pc) {
        if (h) { code_call_handle_unref(h); code_call_handle_unref(h); }
        free(pc);
        json_object_put(args_obj);
        JS_FreeValue(ctx, resolving[0]);
        JS_FreeValue(ctx, resolving[1]);
        JS_FreeValue(ctx, promise);
        free(srv_copy);
        free(tool_copy);
        return JS_ThrowOutOfMemory(ctx);
    }

    pc->h = h;
    pc->resolve_fn = resolving[0];
    pc->reject_fn = resolving[1];
    pc->server = srv_copy;
    pc->tool = tool_copy;
    pc->eff_class = eff_class;
    pc->start_mono_ns = now_ns;
    pc->deadline_mono_ns = call_dl;
    pc->args_bytes = args_bytes;
    pc->next = r->pending;
    r->pending = pc;
    r->inflight_count++;
    r->queued_bytes += args_bytes;

    /* Hand owned args_obj and dispatcher's ref of h to dispatch callback */
    opts->dispatch(opts->dispatch_ctx, pc->server, reg_id ? reg_id : "", meta_gen,
                   pc->tool, args_obj, timeout_ms, h);
    return promise;
}

/* ---- Proxy traps for tools.<server>.<tool> ---- */
static int is_reserved_prop(const char *p) {
    return strcmp(p, "then") == 0 || strcmp(p, "toJSON") == 0 ||
           strcmp(p, "toString") == 0 || strcmp(p, "valueOf") == 0 ||
           strcmp(p, "constructor") == 0 || strcmp(p, "inspect") == 0;
}

static JSValue js_server_proxy_get(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv,
                                   int magic, JSValue *func_data) {
    (void)this_val;
    (void)magic;
    if (argc < 2 || !JS_IsString(argv[1])) return JS_UNDEFINED;
    const char *prop = JS_ToCString(ctx, argv[1]);
    if (!prop) { JS_FreeValue(ctx, JS_GetException(ctx)); return JS_UNDEFINED; }
    if (is_reserved_prop(prop)) {
        JS_FreeCString(ctx, prop);
        return JS_UNDEFINED;
    }
    JSValue data[2] = { func_data[0], argv[1] };
    JSValue fn = JS_NewCFunctionData(ctx, js_bridge_call, 1, 0, 2, data);
    JS_FreeCString(ctx, prop);
    return fn;
}

static JSValue js_tools_proxy_get(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 2 || !JS_IsString(argv[1])) return JS_UNDEFINED;
    const char *prop = JS_ToCString(ctx, argv[1]);
    if (!prop) { JS_FreeValue(ctx, JS_GetException(ctx)); return JS_UNDEFINED; }
    if (is_reserved_prop(prop)) {
        JS_FreeCString(ctx, prop);
        return JS_UNDEFINED;
    }
    JSValue target = JS_NewObject(ctx);
    JSValue handler = JS_NewObject(ctx);
    JSValue data[1] = { argv[1] };
    JSValue get_fn = JS_NewCFunctionData(ctx, js_server_proxy_get, 3, 0, 1, data);
    JS_SetPropertyStr(ctx, handler, "get", get_fn);
    JSValue proxy = JS_NewProxy(ctx, target, handler);
    JS_FreeValue(ctx, target);
    JS_FreeValue(ctx, handler);
    JS_FreeCString(ctx, prop);
    return proxy;
}

/* ---- console.log capture (incremental bounded rendering within remaining log budget) ---- */
static int append_bytes_bounded(char **buf, size_t *pos, size_t *cap, size_t limit,
                                const char *src, size_t n) {
    if (n > limit - *pos) return -1;
    if (*pos + n + 1 > *cap) {
        size_t ncap = *cap ? *cap * 2 : 128;
        while (ncap < *pos + n + 1) ncap *= 2;
        if (ncap > limit + 1) ncap = limit + 1;
        char *p = realloc(*buf, ncap);
        if (!p) return -1;
        *buf = p;
        *cap = ncap;
    }
    if (n > 0) memcpy(*buf + *pos, src, n);
    *pos += n;
    (*buf)[*pos] = '\0';
    return 0;
}

/* Escape embedded NUL bytes as \u0000 while enforcing the remaining log budget before allocating. */
static int append_bytes_escaped_bounded(char **buf, size_t *pos, size_t *cap, size_t limit,
                                        const char *src, size_t n) {
    size_t rem = limit - *pos;
    if (n > rem) return -1;
    size_t out_len = 0;
    int has_nul = 0;
    for (size_t i = 0; i < n; i++) {
        size_t add = (src[i] == '\0') ? 6 : 1;
        if (src[i] == '\0') has_nul = 1;
        if (add > rem - out_len) return -1;
        out_len += add;
    }
    if (!has_nul) return append_bytes_bounded(buf, pos, cap, limit, src, n);
    if (*pos + out_len + 1 > *cap) {
        size_t ncap = *cap ? *cap * 2 : 128;
        while (ncap < *pos + out_len + 1) ncap *= 2;
        if (ncap > limit + 1) ncap = limit + 1;
        char *p = realloc(*buf, ncap);
        if (!p) return -1;
        *buf = p;
        *cap = ncap;
    }
    char *dst = *buf + *pos;
    for (size_t i = 0; i < n; i++) {
        if (src[i] == '\0') {
            memcpy(dst, "\\u0000", 6);
            dst += 6;
        } else {
            *dst++ = src[i];
        }
    }
    *pos += out_len;
    (*buf)[*pos] = '\0';
    return 0;
}

static int append_js_string_bounded(JSContext *ctx, JSValueConst val,
                                    char **buf, size_t *pos, size_t *cap, size_t limit) {
    size_t len = 0;
    const char *s = JS_ToCStringLen(ctx, &len, val);
    if (!s) {
        JS_FreeValue(ctx, JS_GetException(ctx));
        return 0;
    }
    int rc = append_bytes_escaped_bounded(buf, pos, cap, limit, s, len);
    JS_FreeCString(ctx, s);
    return rc;
}

static int append_js_val_bounded_depth(JSContext *ctx, JSValueConst val,
                                       char **buf, size_t *pos, size_t *cap, size_t limit, int depth) {
    if (JS_IsUndefined(val)) return append_bytes_bounded(buf, pos, cap, limit, "undefined", 9);
    if (JS_IsNull(val)) return append_bytes_bounded(buf, pos, cap, limit, "null", 4);
    if (JS_IsBool(val)) {
        const char *s = JS_ToBool(ctx, val) ? "true" : "false";
        return append_bytes_bounded(buf, pos, cap, limit, s, strlen(s));
    }
    if (JS_IsString(val)) {
        return append_js_string_bounded(ctx, val, buf, pos, cap, limit);
    }
    if (JS_IsNumber(val)) {
        double d = 0;
        char num[64];
        if (JS_ToFloat64(ctx, &d, val) == 0) {
            int nn = snprintf(num, sizeof num, "%.15g", d);
            return nn > 0 ? append_bytes_bounded(buf, pos, cap, limit, num, (size_t)nn) : 0;
        }
        JS_FreeValue(ctx, JS_GetException(ctx));
        return append_bytes_bounded(buf, pos, cap, limit, "NaN", 3);
    }
    if (JS_IsBigInt(val)) {
        int64_t bi = 0;
        char num[64];
        if (JS_ToBigInt64(ctx, &bi, val) == 0) {
            int nn = snprintf(num, sizeof num, "%lldn", (long long)bi);
            return nn > 0 ? append_bytes_bounded(buf, pos, cap, limit, num, (size_t)nn) : 0;
        }
        JS_FreeValue(ctx, JS_GetException(ctx));
        return append_bytes_bounded(buf, pos, cap, limit, "[BigInt]", 8);
    }
    if (JS_IsError(val)) {
        if (depth >= 2) return append_bytes_bounded(buf, pos, cap, limit, "[Error]", 7);
        size_t start_pos = *pos;
        JSValue nv = JS_GetPropertyStr(ctx, val, "name");
        if (JS_IsException(nv)) {
            JS_FreeValue(ctx, JS_GetException(ctx));
            nv = JS_UNDEFINED;
        }
        int rc = 0;
        if (JS_IsUndefined(nv)) {
            rc = append_bytes_bounded(buf, pos, cap, limit, "Error", 5);
        } else if (JS_IsString(nv)) {
            rc = append_js_string_bounded(ctx, nv, buf, pos, cap, limit);
        } else {
            rc = append_js_val_bounded_depth(ctx, nv, buf, pos, cap, limit, depth + 1);
        }
        JS_FreeValue(ctx, nv);
        if (rc != 0) return -1;
        int has_name = (*pos > start_pos);

        JSValue mv = JS_GetPropertyStr(ctx, val, "message");
        if (JS_IsException(mv)) {
            JS_FreeValue(ctx, JS_GetException(ctx));
            mv = JS_UNDEFINED;
        }
        if (!JS_IsUndefined(mv)) {
            if (JS_IsString(mv)) {
                size_t mlen = 0;
                const char *ms = JS_ToCStringLen(ctx, &mlen, mv);
                if (!ms) {
                    JS_FreeValue(ctx, JS_GetException(ctx));
                } else {
                    if (mlen > 0) {
                        if (has_name) rc = append_bytes_bounded(buf, pos, cap, limit, ": ", 2);
                        if (rc == 0) rc = append_bytes_escaped_bounded(buf, pos, cap, limit, ms, mlen);
                    }
                    JS_FreeCString(ctx, ms);
                }
            } else if (!JS_IsNull(mv)) {
                if (has_name) rc = append_bytes_bounded(buf, pos, cap, limit, ": ", 2);
                if (rc == 0) rc = append_js_val_bounded_depth(ctx, mv, buf, pos, cap, limit, depth + 1);
            }
        }
        JS_FreeValue(ctx, mv);
        return rc;
    }
    JSValue jv = JS_JSONStringify(ctx, val, JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(jv)) {
        JS_FreeValue(ctx, JS_GetException(ctx));
        return append_bytes_bounded(buf, pos, cap, limit, "[Object]", 8);
    }
    if (JS_IsString(jv)) {
        int rc = append_js_string_bounded(ctx, jv, buf, pos, cap, limit);
        JS_FreeValue(ctx, jv);
        return rc;
    }
    JS_FreeValue(ctx, jv);
    return append_bytes_bounded(buf, pos, cap, limit, "[Object]", 8);
}

static int append_js_val_bounded(JSContext *ctx, JSValueConst val,
                                 char **buf, size_t *pos, size_t *cap, size_t limit) {
    return append_js_val_bounded_depth(ctx, val, buf, pos, cap, limit, 0);
}

static JSValue js_console_log(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    struct run_state *r = (struct run_state *)JS_GetContextOpaque(ctx);
    if (!r) return JS_UNDEFINED;
    if (check_limits(r)) return JS_ThrowInternalError(ctx, "interrupted");

    const size_t reserve = 64;
    if (r->logs_buf.capped || r->logs_buf.max_bytes <= reserve ||
        r->logs_buf.len + reserve + 1 > r->logs_buf.max_bytes) {
        r->logs_buf.capped = 1;
        r->logs_buf.dropped++;
        return JS_UNDEFINED;
    }
    size_t rem = r->logs_buf.max_bytes - reserve - r->logs_buf.len; /* includes trailing '\n' */
    size_t body_limit = rem - 1;

    char *line = NULL;
    size_t pos = 0, cap = 0;
    int overflow = 0;
    for (int i = 0; i < argc; i++) {
        if (check_limits(r)) {
            free(line);
            return JS_ThrowInternalError(ctx, "interrupted");
        }
        if (i > 0 && append_bytes_bounded(&line, &pos, &cap, body_limit, " ", 1) != 0) {
            overflow = 1;
            break;
        }
        if (append_js_val_bounded(ctx, argv[i], &line, &pos, &cap, body_limit) != 0) {
            overflow = 1;
            break;
        }
    }
    if (overflow || append_bytes_bounded(&line, &pos, &cap, rem, "\n", 1) != 0) {
        free(line);
        r->logs_buf.capped = 1;
        r->logs_buf.dropped++;
        return JS_UNDEFINED;
    }
    cap_buf_append(&r->logs_buf, line, pos);
    free(line);
    return JS_UNDEFINED;
}

static int install_sandbox_globals(struct run_state *r) {
    JSContext *ctx = r->ctx;
    JSValue global = JS_GetGlobalObject(ctx);

    /* console */
    JSValue cons = JS_NewObject(ctx);
    static const char *const CMETHODS[] = { "log", "info", "warn", "error", "debug" };
    for (size_t i = 0; i < sizeof CMETHODS / sizeof *CMETHODS; i++) {
        JS_SetPropertyStr(ctx, cons, CMETHODS[i], JS_NewCFunction(ctx, js_console_log, CMETHODS[i], 0));
    }
    JS_SetPropertyStr(ctx, global, "console", cons);

    /* tools Proxy */
    JSValue target = JS_NewObject(ctx);
    JSValue handler = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, handler, "get", JS_NewCFunction(ctx, js_tools_proxy_get, "get", 3));
    JSValue tools_proxy = JS_NewProxy(ctx, target, handler);
    JS_FreeValue(ctx, target);
    JS_FreeValue(ctx, handler);
    JS_SetPropertyStr(ctx, global, "tools", tools_proxy);

    JS_FreeValue(ctx, global);
    return 0;
}

/* ---- Event loop helpers ---- */
static void free_pending_call(JSContext *ctx, struct pending_call *pc) {
    if (!JS_IsUndefined(pc->resolve_fn)) JS_FreeValue(ctx, pc->resolve_fn);
    if (!JS_IsUndefined(pc->reject_fn)) JS_FreeValue(ctx, pc->reject_fn);
    code_call_handle_unref(pc->h);
    free(pc->server);
    free(pc->tool);
    free(pc);
}

static void settle_call(struct run_state *r, struct pending_call *pc, enum code_call_status status,
                        const char *payload, int is_json, const char *grant_cmd) {
    JSContext *ctx = r->ctx;
    uint64_t now_ns = clock_now_ns(CLOCK_MONOTONIC);
    long long dur_ms = now_ns >= pc->start_mono_ns ? (long long)((now_ns - pc->start_mono_ns) / 1000000ULL) : 0;

    if (status == CODE_CALL_OK) {
        record_call_line(r, pc->server, pc->tool, class_name(pc->eff_class), dur_ms, "ok");
        JSValue val = JS_UNDEFINED;
        if (is_json && payload && *payload) {
            val = JS_ParseJSON(ctx, payload, strlen(payload), "<tool_result>");
            if (JS_IsException(val)) {
                JSValue exc = JS_GetException(ctx);
                char *em = safe_js_to_string(ctx, exc);
                int is_oom = JS_IsNull(exc) || (em && strstr(em, "out of memory"));
                JS_FreeValue(ctx, exc);
                free(em);
                if (is_oom) {
                    r->abort_kind = ABORT_OOM;
                    val = JS_UNDEFINED;
                } else {
                    val = JS_NewString(ctx, payload);
                }
            }
        } else {
            val = JS_NewString(ctx, payload ? payload : "");
        }
        JSValue cr = JS_Call(ctx, pc->resolve_fn, JS_UNDEFINED, 1, &val);
        if (JS_IsException(cr)) JS_FreeValue(ctx, JS_GetException(ctx));
        else JS_FreeValue(ctx, cr);
        JS_FreeValue(ctx, val);
    } else if (status == CODE_CALL_DENIED) {
        const char *reason = (payload && *payload) ? payload : "denied";
        record_call_line(r, pc->server, pc->tool, class_name(pc->eff_class), dur_ms, "denied");
        record_denied_line(r, pc->server, pc->tool, class_name(pc->eff_class), reason, grant_cmd);
        char *msg = (grant_cmd && *grant_cmd)
            ? jsfmt("%s.%s (%s) denied: %s; grant with: %s",
                    pc->server, pc->tool, class_name(pc->eff_class), reason, grant_cmd)
            : jsfmt("%s.%s (%s) denied: %s",
                    pc->server, pc->tool, class_name(pc->eff_class), reason);
        JSValue err = JS_NewError(ctx);
        if (!JS_IsException(err)) {
            JS_DefinePropertyValueStr(ctx, err, "message", JS_NewString(ctx, msg),
                                      JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
        }
        JSValue cr = JS_Call(ctx, pc->reject_fn, JS_UNDEFINED, 1, &err);
        if (JS_IsException(cr)) JS_FreeValue(ctx, JS_GetException(ctx));
        else JS_FreeValue(ctx, cr);
        JS_FreeValue(ctx, err);
        free(msg);
    } else {
        const char *reason = (payload && *payload) ? payload : "tool call failed";
        record_call_line(r, pc->server, pc->tool, class_name(pc->eff_class), dur_ms, "error");
        JSValue err = JS_NewError(ctx);
        if (!JS_IsException(err)) {
            JS_DefinePropertyValueStr(ctx, err, "message", JS_NewString(ctx, reason),
                                      JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
        }
        JSValue cr = JS_Call(ctx, pc->reject_fn, JS_UNDEFINED, 1, &err);
        if (JS_IsException(cr)) JS_FreeValue(ctx, JS_GetException(ctx));
        else JS_FreeValue(ctx, cr);
        JS_FreeValue(ctx, err);
    }
}

static void drain_completed_calls(struct run_state *r) {
    for (;;) {
        struct pending_call *done = NULL;
        enum code_call_status st = CODE_CALL_ERROR;
        int timed_out = 0;
        char *payload = NULL, *gcmd = NULL;
        int is_json = 0;

        pthread_mutex_lock(&r->sync->mu);
        struct pending_call **pp = &r->pending;
        while (*pp) {
            struct pending_call *cur = *pp;
            if (cur->h->state == CALL_COMPLETED || cur->h->state == CALL_TIMED_OUT) {
                *pp = cur->next;
                cur->next = NULL;
                done = cur;
                timed_out = (cur->h->state == CALL_TIMED_OUT);
                st = cur->h->status;
                payload = cur->h->payload_text;
                cur->h->payload_text = NULL;
                is_json = cur->h->is_json;
                gcmd = cur->h->grant_cmd;
                cur->h->grant_cmd = NULL;
                if (r->sync->ready_count > 0) r->sync->ready_count--;
                break;
            }
            pp = &(*pp)->next;
        }
        pthread_mutex_unlock(&r->sync->mu);

        if (!done) break;
        r->inflight_count--;
        if (r->queued_bytes >= done->args_bytes) r->queued_bytes -= done->args_bytes;
        else r->queued_bytes = 0;

        if (timed_out) {
            char *msg = jsfmt("%s.%s timed out after %ds (raise CNTCTR_CODE_CALL_SEC)",
                              done->server, done->tool, r->call_sec);
            settle_call(r, done, CODE_CALL_ERROR, msg, 0, NULL);
            free(msg);
        } else {
            settle_call(r, done, st, payload, is_json, gcmd);
        }
        free(payload);
        free(gcmd);
        free_pending_call(r->ctx, done);
    }
}

static void check_call_timeouts(struct run_state *r) {
    for (;;) {
        struct pending_call *expired = NULL;
        pthread_mutex_lock(&r->sync->mu);
        /* Sample clock under sync->mu to share one linearization point with code_js_complete. */
        uint64_t now_ns = clock_now_ns(CLOCK_MONOTONIC);
        struct pending_call **pp = &r->pending;
        while (*pp) {
            struct pending_call *cur = *pp;
            if (cur->h->state == CALL_PENDING && now_ns >= cur->deadline_mono_ns) {
                cur->h->state = CALL_DETACHED;
                *pp = cur->next;
                cur->next = NULL;
                expired = cur;
                break;
            }
            pp = &(*pp)->next;
        }
        pthread_mutex_unlock(&r->sync->mu);

        if (!expired) break;
        r->inflight_count--;
        if (r->queued_bytes >= expired->args_bytes) r->queued_bytes -= expired->args_bytes;
        else r->queued_bytes = 0;

        if (r->opts->cancel_call) r->opts->cancel_call(r->opts->dispatch_ctx, expired->h);
        char *msg = jsfmt("%s.%s timed out after %ds (raise CNTCTR_CODE_CALL_SEC)",
                          expired->server, expired->tool, r->call_sec);
        settle_call(r, expired, CODE_CALL_ERROR, msg, 0, NULL);
        free(msg);
        free_pending_call(r->ctx, expired);
    }
}

static void drain_jobs(struct run_state *r) {
    while (JS_IsJobPending(r->rt)) {
        if (check_limits(r)) break;
        JSContext *jctx = NULL;
        int jrc = JS_ExecutePendingJob(r->rt, &jctx);
        if (jrc < 0) {
            if (jctx) {
                JSValue exc = JS_GetException(jctx);
                JS_FreeValue(jctx, exc);
            }
            if (check_limits(r)) break;
        }
        if (jrc == 0) break;
    }
}

static void wait_for_event(struct run_state *r) {
    uint64_t now_ns = clock_now_ns(CLOCK_MONOTONIC);
    uint64_t next_dl = r->wall_deadline_ns;
    for (struct pending_call *p = r->pending; p; p = p->next) {
        if (p->deadline_mono_ns < next_dl) next_dl = p->deadline_mono_ns;
    }
    if (now_ns >= next_dl) return;

    pthread_mutex_lock(&r->sync->mu);
    if (r->sync->ready_count == 0 && !r->sync->cancel_signalled &&
        !atomic_load_explicit(&r->cancel_flag, memory_order_acquire)) {
#ifdef __APPLE__
        uint64_t wait_ns = next_dl - now_ns;
        struct timespec rel;
        rel.tv_sec = (time_t)(wait_ns / 1000000000ULL);
        rel.tv_nsec = (long)(wait_ns % 1000000000ULL);
        pthread_cond_timedwait_relative_np(&r->sync->cv, &r->sync->mu, &rel);
#else
        struct timespec abs_ts;
        abs_ts.tv_sec = (time_t)(next_dl / 1000000000ULL);
        abs_ts.tv_nsec = (long)(next_dl % 1000000000ULL);
        pthread_cond_timedwait(&r->sync->cv, &r->sync->mu, &abs_ts);
#endif
    }
    pthread_mutex_unlock(&r->sync->mu);
}

static void cancel_all_pending(struct run_state *r) {
    struct pending_call *list = NULL;
    pthread_mutex_lock(&r->sync->mu);
    r->sync->run_alive = 0;
    list = r->pending;
    r->pending = NULL;
    for (struct pending_call *p = list; p; p = p->next) {
        if (p->h->state == CALL_PENDING) p->h->state = CALL_DETACHED;
    }
    pthread_mutex_unlock(&r->sync->mu);

    while (list) {
        struct pending_call *next = list->next;
        if (r->opts->cancel_call) r->opts->cancel_call(r->opts->dispatch_ctx, list->h);
        free_pending_call(r->ctx, list);
        list = next;
    }
    r->inflight_count = 0;
    r->queued_bytes = 0;
}

static char *format_js_exception(struct run_state *r, JSValueConst exc) {
    if (r->abort_kind == ABORT_CPU) {
        return jsfmt("CPU budget exceeded (%.2fs / %ds; raise CNTCTR_CODE_CPU_SEC)",
                     (double)r->cpu_used_ns / 1e9, r->cpu_sec);
    }
    if (r->abort_kind == ABORT_WALL) {
        return jsfmt("wall time limit exceeded (%.2fs / %ds; raise CNTCTR_CODE_WALL_SEC)",
                     (double)r->wall_used_ns / 1e9, r->wall_sec);
    }
    if (r->abort_kind == ABORT_CANCEL) {
        char *reason = NULL;
        if (r->opts->cancel) {
            pthread_mutex_lock(&r->opts->cancel->mu);
            if (r->opts->cancel->reason) reason = strdup(r->opts->cancel->reason);
            pthread_mutex_unlock(&r->opts->cancel->mu);
        }
        char *out = reason ? jsfmt("run cancelled: %s", reason) : strdup("run cancelled");
        free(reason);
        return out;
    }
    if (r->abort_kind == ABORT_OOM) {
        JSMemoryUsage mu;
        JS_ComputeMemoryUsage(r->rt, &mu);
        return jsfmt("memory limit exceeded (%lld / %zu bytes; raise CNTCTR_CODE_MAX_MB)",
                     (long long)mu.malloc_size, r->max_mb * 1024 * 1024);
    }
    char *msg = safe_js_to_string(r->ctx, exc);
    int is_oom = JS_IsNull(exc) || (msg && strstr(msg, "out of memory") != NULL);
    if (is_oom) {
        JSMemoryUsage mu;
        JS_ComputeMemoryUsage(r->rt, &mu);
        free(msg);
        return jsfmt("memory limit exceeded (%lld / %zu bytes; raise CNTCTR_CODE_MAX_MB)",
                     (long long)mu.malloc_size, r->max_mb * 1024 * 1024);
    }
    return msg;
}

static void *run_thread_main(void *arg) {
    struct run_state *r = (struct run_state *)arg;
    const struct code_run_opts *opts = r->opts;
    struct code_run_out *out = r->out;

    r->cpu_start_ns = clock_now_ns(CLOCK_THREAD_CPUTIME_ID);
    r->wall_start_ns = clock_now_ns(CLOCK_MONOTONIC);
    r->cpu_budget_ns = (uint64_t)r->cpu_sec * 1000000000ULL;
    r->wall_deadline_ns = r->wall_start_ns + (uint64_t)r->wall_sec * 1000000000ULL;

    /* Attach external cancel token */
    if (opts->cancel) {
        pthread_mutex_lock(&opts->cancel->mu);
        opts->cancel->wake_sync = r->sync;
        opts->cancel->wake_flag = &r->cancel_flag;
        if (opts->cancel->cancelled) {
            atomic_store_explicit(&r->cancel_flag, 1, memory_order_release);
            pthread_mutex_lock(&r->sync->mu);
            r->sync->cancel_signalled = 1;
            pthread_mutex_unlock(&r->sync->mu);
        }
        pthread_mutex_unlock(&opts->cancel->mu);
    }

    /* Open per-run SQLite handle with cancel- and deadline-aware bounded retries + busy handler */
    if (opts->db_path && *opts->db_path) {
        char *dberr = NULL;
        while (!r->db) {
            if (check_limits(r)) {
                out->is_error = 1;
                out->result = format_js_exception(r, JS_UNDEFINED);
                free(dberr);
                goto finish;
            }
            int rem = remaining_wall_ms(r);
            int slice = rem > 25 ? 25 : (rem > 0 ? rem : 1);
            free(dberr);
            dberr = NULL;
            r->db = kb_open_timeout(opts->db_path, &dberr, slice);
            if (r->db) break;
            if (!dberr || (!strstr(dberr, "locked") && !strstr(dberr, "busy"))) {
                out->is_error = 1;
                out->result = jsfmt("failed to open kb database: %s", dberr ? dberr : "unknown");
                free(dberr);
                goto finish;
            }
            sleep_cancelable_ms(r, slice);
        }
        free(dberr);
        sqlite3_busy_handler(r->db, db_busy_cb, r);
        sqlite3_progress_handler(r->db, 1000, db_progress_cb, r);
    }

    /* Create QuickJS runtime & context on this sized pthread */
    r->rt = JS_NewRuntime();
    if (!r->rt) {
        out->is_error = 1;
        out->result = strdup("failed to create QuickJS runtime");
        goto finish;
    }
    JS_SetMemoryLimit(r->rt, r->max_mb * 1024 * 1024);
    JS_SetMaxStackSize(r->rt, r->max_stack_bytes);
    JS_SetCanBlock(r->rt, false);
    JS_SetInterruptHandler(r->rt, js_interrupt_cb, r);

    r->ctx = JS_NewContext(r->rt);
    if (!r->ctx) {
        out->is_error = 1;
        out->result = strdup("failed to create QuickJS context");
        goto finish;
    }
    JS_SetContextOpaque(r->ctx, r);
    install_sandbox_globals(r);

    /* Compile script as AsyncFunction body so top-level await & return work cleanly */
    const char *ctor_src = "(async function(){}).constructor";
    JSValue async_ctor = JS_Eval(r->ctx, ctor_src, strlen(ctor_src), "<bootstrap>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(async_ctor)) {
        JSValue exc = JS_GetException(r->ctx);
        out->is_error = 1;
        out->result = format_js_exception(r, exc);
        JS_FreeValue(r->ctx, exc);
        goto finish;
    }

    JSValue src_val = JS_NewString(r->ctx, opts->script ? opts->script : "");
    JSValue script_fn = JS_Call(r->ctx, async_ctor, JS_UNDEFINED, 1, &src_val);
    JS_FreeValue(r->ctx, src_val);
    JS_FreeValue(r->ctx, async_ctor);
    if (JS_IsException(script_fn)) {
        JSValue exc = JS_GetException(r->ctx);
        out->is_error = 1;
        out->result = format_js_exception(r, exc);
        JS_FreeValue(r->ctx, exc);
        goto finish;
    }

    JSValue main_promise = JS_Call(r->ctx, script_fn, JS_UNDEFINED, 0, NULL);
    JS_FreeValue(r->ctx, script_fn);
    if (JS_IsException(main_promise)) {
        JSValue exc = JS_GetException(r->ctx);
        out->is_error = 1;
        out->result = format_js_exception(r, exc);
        JS_FreeValue(r->ctx, exc);
        goto finish;
    }

    /* Micro-event-loop: drain jobs, settle completed calls, enforce wall/CPU/call deadlines */
    while (r->abort_kind == ABORT_NONE) {
        drain_completed_calls(r);
        drain_jobs(r);
        if (check_limits(r)) break;

        check_call_timeouts(r);
        drain_jobs(r);
        if (check_limits(r)) break;

        JSPromiseStateEnum st = JS_PromiseState(r->ctx, main_promise);
        if (st == JS_PROMISE_FULFILLED || st == JS_PROMISE_REJECTED) break;
        if (r->inflight_count == 0 && !JS_IsJobPending(r->rt)) break;

        wait_for_event(r);
        check_limits(r);
    }

    /* Extract final outcome */
    if (r->abort_kind != ABORT_NONE) {
        out->is_error = 1;
        out->result = format_js_exception(r, JS_UNDEFINED);
    } else {
        JSPromiseStateEnum st = JS_PromiseState(r->ctx, main_promise);
        if (st == JS_PROMISE_FULFILLED) {
            JSValue res_val = JS_PromiseResult(r->ctx, main_promise);
            if (JS_IsUndefined(res_val)) {
                out->is_error = 0;
                out->result = strdup("null");
            } else {
                JSValue jstr = JS_JSONStringify(r->ctx, res_val, JS_UNDEFINED, JS_UNDEFINED);
                if (JS_IsException(jstr)) {
                    JSValue exc = JS_GetException(r->ctx);
                    out->is_error = 1;
                    char *em = format_js_exception(r, exc);
                    out->result = jsfmt("failed to serialize script result: %s", em);
                    free(em);
                    JS_FreeValue(r->ctx, exc);
                } else if (JS_IsString(jstr)) {
                    out->is_error = 0;
                    out->result = safe_js_to_string(r->ctx, jstr);
                } else {
                    out->is_error = 0;
                    out->result = strdup("null");
                }
                JS_FreeValue(r->ctx, jstr);
            }
            JS_FreeValue(r->ctx, res_val);
        } else if (st == JS_PROMISE_REJECTED) {
            JSValue reason = JS_PromiseResult(r->ctx, main_promise);
            out->is_error = 1;
            out->result = format_js_exception(r, reason);
            JS_FreeValue(r->ctx, reason);
        } else {
            out->is_error = 1;
            out->result = strdup("script promise never settled");
        }
    }

    JS_FreeValue(r->ctx, main_promise);

finish:
    /* Cancel & detach all remaining pending calls BEFORE freeing JSContext/JSRuntime */
    cancel_all_pending(r);

    /* Detach external cancel token before run_sync is released */
    if (opts->cancel) {
        pthread_mutex_lock(&opts->cancel->mu);
        opts->cancel->wake_sync = NULL;
        opts->cancel->wake_flag = NULL;
        pthread_mutex_unlock(&opts->cancel->mu);
    }

    if (r->ctx) { JS_FreeContext(r->ctx); r->ctx = NULL; }
    if (r->rt) { JS_FreeRuntime(r->rt); r->rt = NULL; }
    if (r->db) { sqlite3_close(r->db); r->db = NULL; }

    /* Cap retained result at 4 MiB (UTF-8 aligned) */
    if (!out->result) out->result = strdup("");
    if (strlen(out->result) > CODE_MAX_RETAINED_RESULT) {
        size_t cut = utf8_truncate_pos(out->result, CODE_MAX_RETAINED_RESULT);
        out->result[cut] = '\0';
        out->retained_capped = 1;
    }

    if (r->logs_buf.capped || r->calls_buf.capped || r->denied_buf.capped)
        out->retained_capped = 1;

    out->logs = cap_buf_finish(&r->logs_buf, "log lines");
    out->calls = cap_buf_finish(&r->calls_buf, "call entries");
    out->denied = cap_buf_finish(&r->denied_buf, "denied entries");

    out->result_preview = build_preview(out->result, r->result_preview_cap, "result");
    out->logs_preview = build_preview(out->logs, r->result_preview_cap, "logs");
    out->calls_preview = build_preview(out->calls, r->calls_preview_cap, "calls");
    out->denied_preview = build_preview(out->denied, r->calls_preview_cap, "denied");
    r->rc = 0;
    return NULL;
}

void code_run_out_free(struct code_run_out *o) {
    if (!o) return;
    free(o->result);
    free(o->logs);
    free(o->calls);
    free(o->denied);
    free(o->result_preview);
    free(o->logs_preview);
    free(o->calls_preview);
    free(o->denied_preview);
    memset(o, 0, sizeof *o);
}

int code_js_run(const struct code_run_opts *opts, struct code_run_out *out) {
    if (!opts || !out) return -1;
    memset(out, 0, sizeof *out);

    struct run_state r;
    memset(&r, 0, sizeof r);
    r.opts = opts;
    r.out = out;
    r.sync = run_sync_new();
    if (!r.sync) return -1;
    atomic_init(&r.cancel_flag, 0);

    r.max_mb = opts->max_mb ? opts->max_mb : CODE_DEFAULT_MAX_MB;
    if (r.max_mb > CODE_CEIL_MAX_MB) r.max_mb = CODE_CEIL_MAX_MB;

    r.max_stack_bytes = opts->max_stack_bytes ? opts->max_stack_bytes : CODE_DEFAULT_STACK_BYTES;

    r.cpu_sec = opts->cpu_sec > 0 ? opts->cpu_sec : CODE_DEFAULT_CPU_SEC;
    if (r.cpu_sec > CODE_CEIL_CPU_SEC) r.cpu_sec = CODE_CEIL_CPU_SEC;

    r.wall_sec = opts->wall_sec > 0 ? opts->wall_sec : CODE_DEFAULT_WALL_SEC;
    if (r.wall_sec > CODE_CEIL_WALL_SEC) r.wall_sec = CODE_CEIL_WALL_SEC;

    r.call_sec = opts->call_sec > 0 ? opts->call_sec : CODE_DEFAULT_CALL_SEC;
    if (r.call_sec > CODE_CEIL_CALL_SEC) r.call_sec = CODE_CEIL_CALL_SEC;

    r.max_inflight = opts->max_inflight > 0 ? opts->max_inflight : CODE_DEFAULT_MAX_INFLIGHT;
    r.max_queue_bytes = opts->max_queue_bytes ? opts->max_queue_bytes : CODE_DEFAULT_MAX_QUEUE_BYTES;
    r.result_preview_cap = opts->result_cap_bytes ? opts->result_cap_bytes : CODE_DEFAULT_RESULT_PREVIEW;
    r.calls_preview_cap = opts->calls_preview_bytes ? opts->calls_preview_bytes : CODE_DEFAULT_CALLS_PREVIEW;
    r.max_log_bytes = opts->max_log_bytes ? opts->max_log_bytes : CODE_DEFAULT_MAX_LOG_BYTES;

    cap_buf_init(&r.logs_buf, r.max_log_bytes);
    cap_buf_init(&r.calls_buf, CODE_MAX_RETAINED_CALLS);
    cap_buf_init(&r.denied_buf, CODE_MAX_RETAINED_DENIED);

    /* Always execute on a dedicated pthread with stack >= max_stack_bytes + 8 MiB */
    pthread_attr_t attr;
    if (pthread_attr_init(&attr) != 0) {
        cap_buf_free(&r.logs_buf);
        cap_buf_free(&r.calls_buf);
        cap_buf_free(&r.denied_buf);
        run_sync_unref(r.sync);
        return -1;
    }
    size_t stack_size = r.max_stack_bytes + CODE_STACK_HEADROOM_BYTES;
    long page = sysconf(_SC_PAGESIZE);
    if (page > 0) stack_size = ((stack_size + (size_t)page - 1) / (size_t)page) * (size_t)page;
#ifdef PTHREAD_STACK_MIN
    if (stack_size < (size_t)PTHREAD_STACK_MIN) stack_size = (size_t)PTHREAD_STACK_MIN;
#endif
    int ssrc = pthread_attr_setstacksize(&attr, stack_size);
    pthread_t tid;
    int crc = (ssrc == 0) ? pthread_create(&tid, &attr, run_thread_main, &r) : ssrc;
    pthread_attr_destroy(&attr);
    if (crc != 0) {
        cap_buf_free(&r.logs_buf);
        cap_buf_free(&r.calls_buf);
        cap_buf_free(&r.denied_buf);
        run_sync_unref(r.sync);
        out->is_error = 1;
        out->result = jsfmt("failed to spawn run thread (errno %d)", crc);
        return -1;
    }
    pthread_join(tid, NULL);

    /* Release run's own ref on sync (any detached call handles still hold their refs safely) */
    run_sync_unref(r.sync);
    return r.rc;
}

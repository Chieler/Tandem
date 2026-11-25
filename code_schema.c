/* Tri-state recursive JSON Schema validator over json-c and Levenshtein name suggestions. */
#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#include "code_schema.h"
#include <float.h>
#include <limits.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SCHEMA_MAX_DEPTH           16
#define SCHEMA_DEFAULT_WORK_BUDGET 10000
#define SCHEMA_BYTES_PER_STEP      64
#define SCHEMA_SCAN_CHUNK_BYTES    4096

static char *sfmt(const char *fmt_str, ...) {
    va_list ap;
    char *s = NULL;
    va_start(ap, fmt_str);
    if (vasprintf(&s, fmt_str, ap) < 0) s = strdup("schema error");
    va_end(ap);
    return s;
}

static void set_err(char **err, const char *fmt_str, ...) {
    if (!err) return;
    free(*err);
    *err = NULL;
    va_list ap;
    va_start(ap, fmt_str);
    if (vasprintf(err, fmt_str, ap) < 0) *err = strdup("schema validation failed");
    va_end(ap);
}

static const char *disp_path(const char *path) {
    return (path && *path) ? path : "$";
}

/* Returns 0 ok, 1 work budget exhausted (INDETERMINATE), -1 aborted by callback. */
static int budget_charge(struct code_schema_budget *b, size_t steps) {
    if (!b) return 0;
    if (b->aborted) return -1;
    if (steps == 0) steps = 1;
    if (b->abort_fn && ((b->steps_left & 31) == 0 || steps >= 32 || steps >= b->steps_left)) {
        if (b->abort_fn(b->abort_ctx)) {
            b->aborted = 1;
            return -1;
        }
    }
    if (steps > b->steps_left) {
        b->steps_left = 0;
        b->budget_exhausted = 1;
        return 1;
    }
    b->steps_left -= steps;
    return 0;
}

static int budget_tick(struct code_schema_budget *b) {
    return budget_charge(b, 1);
}

static int budget_charge_bytes(struct code_schema_budget *b, size_t nbytes) {
    size_t steps = (nbytes + SCHEMA_BYTES_PER_STEP - 1) / SCHEMA_BYTES_PER_STEP;
    if (steps == 0) steps = 1;
    return budget_charge(b, steps);
}

static int budget_check_abort_now(struct code_schema_budget *b) {
    if (!b) return 0;
    if (b->aborted) return 1;
    if (b->abort_fn && b->abort_fn(b->abort_ctx)) {
        b->aborted = 1;
        return 1;
    }
    return 0;
}

static const char *json_type_name(json_object *val) {
    if (!val) return "null";
    switch (json_object_get_type(val)) {
        case json_type_null: return "null";
        case json_type_boolean: return "boolean";
        case json_type_int: return "integer";
        case json_type_double: return "number";
        case json_type_string: return "string";
        case json_type_array: return "array";
        case json_type_object: return "object";
    }
    return "unknown";
}

static int is_json_number(json_object *val) {
    if (!val) return 0;
    enum json_type t = json_object_get_type(val);
    return t == json_type_int || t == json_type_double;
}

/* Exact extraction of json-c integer across [INT64_MIN, UINT64_MAX]. */
struct exact_int {
    int is_neg;
    int64_t s;
    uint64_t u;
};

static struct exact_int get_exact_int(json_object *obj) {
    struct exact_int r;
    int64_t s = json_object_get_int64(obj);
    if (s < 0) {
        r.is_neg = 1;
        r.s = s;
        r.u = 0;
    } else {
        r.is_neg = 0;
        r.s = s;
        r.u = json_object_get_uint64(obj);
    }
    return r;
}

static int cmp_exact_ints(struct exact_int a, struct exact_int b) {
    if (a.is_neg != b.is_neg) return a.is_neg ? -1 : 1;
    if (a.is_neg) return a.s < b.s ? -1 : (a.s > b.s ? 1 : 0);
    return a.u < b.u ? -1 : (a.u > b.u ? 1 : 0);
}

static int exact_int_fits_double(struct exact_int a) {
    const int64_t min_exact = -(1LL << 53);
    const uint64_t max_exact = (1ULL << 53);
    if (a.is_neg) return a.s >= min_exact;
    return a.u <= max_exact;
}

/* Extract an exact integer from json_type_int or an unrounded integral json_type_double (|d| <= 2^53). */
static int try_get_exact_int(json_object *obj, struct exact_int *out) {
    if (!obj) return 0;
    enum json_type t = json_object_get_type(obj);
    if (t == json_type_int) {
        *out = get_exact_int(obj);
        return 1;
    }
    if (t == json_type_double) {
        double d = json_object_get_double(obj);
        if (!isfinite(d) || trunc(d) != d || fabs(d) > 9007199254740992.0) return 0;
        if (d < 0.0) {
            out->is_neg = 1;
            out->s = (int64_t)d;
            out->u = 0;
        } else {
            out->is_neg = 0;
            out->s = 0;
            out->u = (uint64_t)d;
        }
        return 1;
    }
    return 0;
}

/* Thread-safe scalar formatting using pure numeric getters (never mutates json-c printbuf). */
static const char *fmt_json_number(json_object *obj, char buf[64]) {
    if (!obj) {
        snprintf(buf, 64, "null");
        return buf;
    }
    enum json_type t = json_object_get_type(obj);
    if (t == json_type_int) {
        struct exact_int ei = get_exact_int(obj);
        if (ei.is_neg) snprintf(buf, 64, "%lld", (long long)ei.s);
        else snprintf(buf, 64, "%llu", (unsigned long long)ei.u);
        return buf;
    }
    if (t == json_type_double) {
        snprintf(buf, 64, "%.17g", json_object_get_double(obj));
        return buf;
    }
    snprintf(buf, 64, "?");
    return buf;
}

/* Compare exact_int a against finite/infinite double d. Returns 0 on exact compare, -1 on NaN. */
static int cmp_int_double(struct exact_int a, double d, int *cmp_out) {
    if (isnan(d)) return -1;
    if (isinf(d)) {
        *cmp_out = d > 0.0 ? -1 : 1;
        return 0;
    }
    if (exact_int_fits_double(a)) {
        double da = a.is_neg ? (double)a.s : (double)a.u;
        *cmp_out = da < d ? -1 : (da > d ? 1 : 0);
        return 0;
    }
    /* |a| > 2^53. Compare against double range bounds [-2^63, 2^64). */
    if (d < -9223372036854775808.0) { *cmp_out = 1; return 0; }
    if (d >= 18446744073709551616.0) { *cmp_out = -1; return 0; }
    if (fabs(d) < 9007199254740992.0) {
        *cmp_out = a.is_neg ? -1 : 1;
        return 0;
    }
    /* For 2^53 <= |d| < 2^64, every IEEE-754 double is an exact integer. */
    struct exact_int db;
    if (d < 0.0) {
        db.is_neg = 1;
        db.s = (int64_t)d;
        db.u = 0;
    } else {
        db.is_neg = 0;
        db.s = 0;
        db.u = (uint64_t)d;
    }
    *cmp_out = cmp_exact_ints(a, db);
    return 0;
}

/* Exact comparison of two JSON numbers. Returns 0 with *cmp_out in {-1,0,1}, or -1 if indeterminate. */
static int cmp_json_numbers(json_object *a, json_object *b, int *cmp_out) {
    if (!is_json_number(a) || !is_json_number(b)) return -1;
    enum json_type ta = json_object_get_type(a);
    enum json_type tb = json_object_get_type(b);
    if (ta == json_type_int && tb == json_type_int) {
        *cmp_out = cmp_exact_ints(get_exact_int(a), get_exact_int(b));
        return 0;
    }
    if (ta == json_type_int && tb == json_type_double) {
        return cmp_int_double(get_exact_int(a), json_object_get_double(b), cmp_out);
    }
    if (ta == json_type_double && tb == json_type_int) {
        int c = 0;
        if (cmp_int_double(get_exact_int(b), json_object_get_double(a), &c) != 0) return -1;
        *cmp_out = -c;
        return 0;
    }
    double da = json_object_get_double(a);
    double db = json_object_get_double(b);
    if (isnan(da) || isnan(db)) return -1;
    *cmp_out = da < db ? -1 : (da > db ? 1 : 0);
    return 0;
}

static int matches_single_type(json_object *val, const char *want) {
    if (!want) return 0;
    enum json_type t = val ? json_object_get_type(val) : json_type_null;
    if (strcmp(want, "null") == 0) return t == json_type_null;
    if (strcmp(want, "boolean") == 0) return t == json_type_boolean;
    if (strcmp(want, "string") == 0) return t == json_type_string;
    if (strcmp(want, "array") == 0) return t == json_type_array;
    if (strcmp(want, "object") == 0) return t == json_type_object;
    if (strcmp(want, "number") == 0) return t == json_type_int || t == json_type_double;
    if (strcmp(want, "integer") == 0) {
        if (t == json_type_int) return 1;
        if (t == json_type_double) {
            double d = json_object_get_double(val);
            return isfinite(d) && floor(d) == d;
        }
        return 0;
    }
    return -1; /* unknown type name -> indeterminate */
}

/* Returns 1 equal, 0 not equal, -1 indeterminate/budget/aborted. */
static int json_equal_depth(json_object *a, json_object *b, int depth, struct code_schema_budget *bud) {
    int bt = budget_tick(bud);
    if (bt != 0) return -1;
    if (depth > 32) return -1;
    if (a == b) return 1;
    enum json_type ta = a ? json_object_get_type(a) : json_type_null;
    enum json_type tb = b ? json_object_get_type(b) : json_type_null;
    if (is_json_number(a) && is_json_number(b)) {
        int cmp = 0;
        if (cmp_json_numbers(a, b, &cmp) != 0) return -1;
        return cmp == 0 ? 1 : 0;
    }
    if (ta != tb) return 0;
    switch (ta) {
        case json_type_null: return 1;
        case json_type_boolean: return json_object_get_boolean(a) == json_object_get_boolean(b);
        case json_type_string: {
            int la = json_object_get_string_len(a);
            int lb = json_object_get_string_len(b);
            if (la != lb) return 0;
            if (la == 0) return 1;
            const char *sa = json_object_get_string(a);
            const char *sb = json_object_get_string(b);
            size_t total = (size_t)la;
            for (size_t off = 0; off < total; off += SCHEMA_SCAN_CHUNK_BYTES) {
                size_t chunk = total - off;
                if (chunk > SCHEMA_SCAN_CHUNK_BYTES) chunk = SCHEMA_SCAN_CHUNK_BYTES;
                if (budget_charge_bytes(bud, chunk) != 0) return -1;
                if (memcmp(sa + off, sb + off, chunk) != 0) return 0;
            }
            return 1;
        }
        case json_type_array: {
            size_t na = json_object_array_length(a);
            if (na != json_object_array_length(b)) return 0;
            for (size_t i = 0; i < na; i++) {
                int eq = json_equal_depth(json_object_array_get_idx(a, i),
                                          json_object_array_get_idx(b, i), depth + 1, bud);
                if (eq <= 0) return eq;
            }
            return 1;
        }
        case json_type_object: {
            if (json_object_object_length(a) != json_object_object_length(b)) return 0;
            json_object_object_foreach(a, k, va) {
                json_object *vb = NULL;
                if (!json_object_object_get_ex(b, k, &vb)) return 0;
                int eq = json_equal_depth(va, vb, depth + 1, bud);
                if (eq <= 0) return eq;
            }
            return 1;
        }
        default: return 0;
    }
}

/* Metered UTF-8 codepoint count. Returns 0 on success, non-zero on budget exhaustion/abort. */
static int utf8_codepoints_budget(const char *s, size_t len, struct code_schema_budget *bud, size_t *out) {
    size_t cp = 0;
    for (size_t off = 0; off < len; off += SCHEMA_SCAN_CHUNK_BYTES) {
        size_t chunk = len - off;
        if (chunk > SCHEMA_SCAN_CHUNK_BYTES) chunk = SCHEMA_SCAN_CHUNK_BYTES;
        if (budget_charge_bytes(bud, chunk) != 0) return 1;
        for (size_t i = 0; i < chunk; i++) {
            if (((unsigned char)s[off + i] & 0xC0) != 0x80) cp++;
        }
    }
    *out = cp;
    return 0;
}

static int hex_val(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* RFC 6901 section 6: percent-decode URI fragment before splitting and unescaping ~1 / ~0. */
static json_object *resolve_local_ref(json_object *root, const char *ref) {
    if (!root || !ref) return NULL;
    if (strcmp(ref, "#") == 0) return root;
    if (ref[0] != '#') return NULL;

    size_t rlen = strlen(ref + 1);
    char *decoded = malloc(rlen + 1);
    if (!decoded) return NULL;
    size_t dlen = 0;
    for (size_t i = 0; i < rlen; i++) {
        char c = ref[1 + i];
        if (c == '%') {
            if (i + 2 >= rlen) { free(decoded); return NULL; }
            int hi = hex_val(ref[1 + i + 1]);
            int lo = hex_val(ref[1 + i + 2]);
            if (hi < 0 || lo < 0) { free(decoded); return NULL; }
            unsigned char b = (unsigned char)((hi << 4) | lo);
            if (b == 0) { free(decoded); return NULL; }
            decoded[dlen++] = (char)b;
            i += 2;
        } else {
            decoded[dlen++] = c;
        }
    }
    decoded[dlen] = '\0';

    if (dlen == 0) { free(decoded); return root; }
    if (decoded[0] != '/') { free(decoded); return NULL; }

    json_object *cur = root;
    const char *p = decoded + 1;
    for (;;) {
        const char *slash = strchr(p, '/');
        size_t raw_len = slash ? (size_t)(slash - p) : strlen(p);
        char *seg = malloc(raw_len + 1);
        if (!seg) { free(decoded); return NULL; }
        size_t o = 0;
        for (size_t i = 0; i < raw_len; i++) {
            if (p[i] == '~' && i + 1 < raw_len) {
                if (p[i + 1] == '1') { seg[o++] = '/'; i++; continue; }
                if (p[i + 1] == '0') { seg[o++] = '~'; i++; continue; }
            }
            seg[o++] = p[i];
        }
        seg[o] = '\0';
        json_object *next = NULL;
        if (json_object_is_type(cur, json_type_object)) {
            if (!json_object_object_get_ex(cur, seg, &next)) { free(seg); free(decoded); return NULL; }
        } else if (json_object_is_type(cur, json_type_array)) {
            char *end = NULL;
            unsigned long idx = strtoul(seg, &end, 10);
            if (!*seg || !end || *end || idx >= json_object_array_length(cur)) {
                free(seg);
                free(decoded);
                return NULL;
            }
            next = json_object_array_get_idx(cur, idx);
        } else {
            free(seg);
            free(decoded);
            return NULL;
        }
        free(seg);
        cur = next;
        if (!slash) break;
        p = slash + 1;
    }
    free(decoded);
    return cur;
}

static int is_known_keyword(const char *k) {
    static const char *const KNOWN[] = {
        /* annotations / metadata / containers */
        "$schema", "$id", "id", "title", "description", "default", "examples",
        "$comment", "readOnly", "writeOnly", "deprecated", "$defs", "definitions",
        /* supported validation keywords (pattern/patternProperties intentionally fail open) */
        "$ref", "type", "const", "enum",
        "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
        "minLength", "maxLength",
        "minItems", "maxItems", "uniqueItems", "items",
        "minProperties", "maxProperties", "required", "properties", "additionalProperties",
        "allOf", "anyOf", "oneOf", "not"
    };
    for (size_t i = 0; i < sizeof KNOWN / sizeof *KNOWN; i++) {
        if (strcmp(k, KNOWN[i]) == 0) return 1;
    }
    return 0;
}

enum schema_res code_schema_eval_budget(json_object *root, json_object *schema, json_object *val,
                                        const char *path, int depth, struct code_schema_budget *bud, char **err) {
    if (err) *err = NULL;
    if (depth == 0 && budget_check_abort_now(bud)) return SCHEMA_INDETERMINATE;
    if (budget_tick(bud) != 0) return SCHEMA_INDETERMINATE;
    if (depth > SCHEMA_MAX_DEPTH) return SCHEMA_INDETERMINATE;
    if (!schema) return SCHEMA_VALID;

    enum json_type st = json_object_get_type(schema);
    if (st == json_type_boolean) {
        if (json_object_get_boolean(schema)) return SCHEMA_VALID;
        set_err(err, "%s: value disallowed by schema", disp_path(path));
        return SCHEMA_INVALID;
    }
    if (st != json_type_object) return SCHEMA_INDETERMINATE;

    int saw_indet = 0;
    int has_pattern_props = 0;

    /* Scan for unknown keywords first so we record indeterminacy, but still evaluate known rules
     * because INVALID overrides INDETERMINATE in a conjunction. */
    json_object_object_foreach(schema, key, kval) {
        (void)kval;
        if (budget_tick(bud) != 0) return SCHEMA_INDETERMINATE;
        if (strcmp(key, "patternProperties") == 0) has_pattern_props = 1;
        if (!is_known_keyword(key)) saw_indet = 1;
    }

    json_object *kw = NULL;

    /* $ref */
    if (json_object_object_get_ex(schema, "$ref", &kw)) {
        if (!kw || !json_object_is_type(kw, json_type_string)) {
            saw_indet = 1;
        } else {
            const char *rstr = json_object_get_string(kw);
            size_t rlen = (size_t)json_object_get_string_len(kw);
            if (budget_charge_bytes(bud, rlen) != 0) return SCHEMA_INDETERMINATE;
            json_object *target = resolve_local_ref(root, rstr);
            if (!target) {
                saw_indet = 1;
            } else {
                enum schema_res r = code_schema_eval_budget(root, target, val, path, depth + 1, bud, err);
                if (bud && (bud->aborted || bud->budget_exhausted)) return SCHEMA_INDETERMINATE;
                if (r == SCHEMA_INVALID) return SCHEMA_INVALID;
                if (r == SCHEMA_INDETERMINATE) saw_indet = 1;
            }
        }
    }

    /* type */
    if (json_object_object_get_ex(schema, "type", &kw) && kw) {
        if (json_object_is_type(kw, json_type_string)) {
            const char *want = json_object_get_string(kw);
            int m = matches_single_type(val, want);
            if (m < 0) saw_indet = 1;
            else if (m == 0) {
                set_err(err, "%s: expected %s, got %s", disp_path(path), want, json_type_name(val));
                return SCHEMA_INVALID;
            }
        } else if (json_object_is_type(kw, json_type_array)) {
            size_t n = json_object_array_length(kw);
            int matched = 0, unk = 0;
            for (size_t i = 0; i < n; i++) {
                if (budget_tick(bud) != 0) return SCHEMA_INDETERMINATE;
                json_object *it = json_object_array_get_idx(kw, i);
                if (!it || !json_object_is_type(it, json_type_string)) { unk = 1; continue; }
                int m = matches_single_type(val, json_object_get_string(it));
                if (m > 0) { matched = 1; break; }
                if (m < 0) unk = 1;
            }
            if (!matched) {
                if (unk) saw_indet = 1;
                else {
                    set_err(err, "%s: unexpected type %s", disp_path(path), json_type_name(val));
                    return SCHEMA_INVALID;
                }
            }
        } else {
            saw_indet = 1;
        }
    }

    /* const */
    if (json_object_object_get_ex(schema, "const", &kw)) {
        int eq = json_equal_depth(val, kw, 0, bud);
        if (bud && (bud->aborted || bud->budget_exhausted)) return SCHEMA_INDETERMINATE;
        if (eq < 0) saw_indet = 1;
        else if (eq == 0) {
            set_err(err, "%s: value does not match const", disp_path(path));
            return SCHEMA_INVALID;
        }
    }

    /* enum */
    if (json_object_object_get_ex(schema, "enum", &kw)) {
        if (!kw || !json_object_is_type(kw, json_type_array)) {
            saw_indet = 1;
        } else {
            size_t n = json_object_array_length(kw);
            int ok = 0, unk = 0;
            for (size_t i = 0; i < n; i++) {
                int eq = json_equal_depth(val, json_object_array_get_idx(kw, i), 0, bud);
                if (bud && (bud->aborted || bud->budget_exhausted)) return SCHEMA_INDETERMINATE;
                if (eq > 0) { ok = 1; break; }
                if (eq < 0) unk = 1;
            }
            if (!ok) {
                if (unk) saw_indet = 1;
                else {
                    set_err(err, "%s: value not in enum", disp_path(path));
                    return SCHEMA_INVALID;
                }
            }
        }
    }

    /* Numeric constraints (exact integer comparisons across [INT64_MIN, UINT64_MAX],
     * thread-safe stack-local numeric formatting without mutating json-c printbuf) */
    if (is_json_number(val)) {
        char vbuf[64], kbuf[64];
        if (json_object_object_get_ex(schema, "minimum", &kw) && is_json_number(kw)) {
            int cmp = 0;
            if (cmp_json_numbers(val, kw, &cmp) != 0) saw_indet = 1;
            else if (cmp < 0) {
                set_err(err, "%s: value %s is less than minimum %s", disp_path(path),
                        fmt_json_number(val, vbuf), fmt_json_number(kw, kbuf));
                return SCHEMA_INVALID;
            }
        }
        if (json_object_object_get_ex(schema, "maximum", &kw) && is_json_number(kw)) {
            int cmp = 0;
            if (cmp_json_numbers(val, kw, &cmp) != 0) saw_indet = 1;
            else if (cmp > 0) {
                set_err(err, "%s: value %s exceeds maximum %s", disp_path(path),
                        fmt_json_number(val, vbuf), fmt_json_number(kw, kbuf));
                return SCHEMA_INVALID;
            }
        }
        if (json_object_object_get_ex(schema, "exclusiveMinimum", &kw)) {
            if (is_json_number(kw)) {
                int cmp = 0;
                if (cmp_json_numbers(val, kw, &cmp) != 0) saw_indet = 1;
                else if (cmp <= 0) {
                    set_err(err, "%s: value %s must be > %s", disp_path(path),
                            fmt_json_number(val, vbuf), fmt_json_number(kw, kbuf));
                    return SCHEMA_INVALID;
                }
            } else {
                saw_indet = 1;
            }
        }
        if (json_object_object_get_ex(schema, "exclusiveMaximum", &kw)) {
            if (is_json_number(kw)) {
                int cmp = 0;
                if (cmp_json_numbers(val, kw, &cmp) != 0) saw_indet = 1;
                else if (cmp >= 0) {
                    set_err(err, "%s: value %s must be < %s", disp_path(path),
                            fmt_json_number(val, vbuf), fmt_json_number(kw, kbuf));
                    return SCHEMA_INVALID;
                }
            } else {
                saw_indet = 1;
            }
        }
        if (json_object_object_get_ex(schema, "multipleOf", &kw) && is_json_number(kw)) {
            struct exact_int iv, im;
            if (try_get_exact_int(val, &iv) && try_get_exact_int(kw, &im)) {
                if (im.is_neg || im.u == 0) {
                    saw_indet = 1;
                } else {
                    uint64_t mag = iv.is_neg ? ((uint64_t)(-(iv.s + 1)) + 1ULL) : iv.u;
                    if (mag % im.u != 0) {
                        set_err(err, "%s: value %s is not a multiple of %s", disp_path(path),
                                fmt_json_number(val, vbuf), fmt_json_number(kw, kbuf));
                        return SCHEMA_INVALID;
                    }
                }
            } else {
                int v_exact = (json_object_get_type(val) != json_type_int) || exact_int_fits_double(get_exact_int(val));
                int m_exact = (json_object_get_type(kw) != json_type_int) || exact_int_fits_double(get_exact_int(kw));
                if (!v_exact || !m_exact) {
                    saw_indet = 1;
                } else {
                    double v = json_object_get_double(val);
                    double m = json_object_get_double(kw);
                    const double underflow_floor = DBL_MIN / DBL_EPSILON;
                    if (!isfinite(v) || !isfinite(m) || m <= 0.0 ||
                        fpclassify(v) == FP_SUBNORMAL || fpclassify(m) == FP_SUBNORMAL ||
                        (v != 0.0 && fabs(v) < underflow_floor) || m < underflow_floor ||
                        fabs(v) > 9007199254740992.0 || m > 9007199254740992.0) {
                        saw_indet = 1;
                    } else {
                        double q = v / m;
                        if (!isfinite(q) || fpclassify(q) == FP_SUBNORMAL) {
                            saw_indet = 1;
                        } else {
                            double eps_q = 8.0 * DBL_EPSILON * fabs(q) + DBL_EPSILON;
                            if (eps_q < 0.01 && fabs(q - round(q)) > eps_q) {
                                set_err(err, "%s: value %s is not a multiple of %s", disp_path(path),
                                        fmt_json_number(val, vbuf), fmt_json_number(kw, kbuf));
                                return SCHEMA_INVALID;
                            }
                            /* Fractional multipleOf near an integer quotient is unreliable in binary64;
                             * fail open as INDETERMINATE rather than asserting VALID. */
                            saw_indet = 1;
                        }
                    }
                }
            }
        }
    }

    /* String constraints (pattern is intentionally excluded from KNOWN and fails open as INDETERMINATE) */
    if (val && json_object_is_type(val, json_type_string)) {
        const char *s = json_object_get_string(val);
        size_t blen = (size_t)json_object_get_string_len(val);
        json_object *min_kw = NULL, *max_kw = NULL;
        int has_min = json_object_object_get_ex(schema, "minLength", &min_kw) && is_json_number(min_kw);
        int has_max = json_object_object_get_ex(schema, "maxLength", &max_kw) && is_json_number(max_kw);
        if (has_min || has_max) {
            size_t cp = 0;
            if (utf8_codepoints_budget(s, blen, bud, &cp) != 0) return SCHEMA_INDETERMINATE;
            if (has_min) {
                int64_t lim = json_object_get_int64(min_kw);
                if (lim > 0 && cp < (size_t)lim) {
                    set_err(err, "%s: string length %zu is less than minLength %lld",
                            disp_path(path), cp, (long long)lim);
                    return SCHEMA_INVALID;
                }
            }
            if (has_max) {
                int64_t lim = json_object_get_int64(max_kw);
                if (lim >= 0 && cp > (size_t)lim) {
                    set_err(err, "%s: string length %zu exceeds maxLength %lld",
                            disp_path(path), cp, (long long)lim);
                    return SCHEMA_INVALID;
                }
            }
        }
    }

    /* Array constraints */
    if (val && json_object_is_type(val, json_type_array)) {
        size_t n = json_object_array_length(val);
        if (json_object_object_get_ex(schema, "minItems", &kw) && is_json_number(kw)) {
            int64_t lim = json_object_get_int64(kw);
            if (lim > 0 && n < (size_t)lim) {
                set_err(err, "%s: array has %zu items, minItems is %lld",
                        disp_path(path), n, (long long)lim);
                return SCHEMA_INVALID;
            }
        }
        if (json_object_object_get_ex(schema, "maxItems", &kw) && is_json_number(kw)) {
            int64_t lim = json_object_get_int64(kw);
            if (lim >= 0 && n > (size_t)lim) {
                set_err(err, "%s: array has %zu items, maxItems is %lld",
                        disp_path(path), n, (long long)lim);
                return SCHEMA_INVALID;
            }
        }
        if (json_object_object_get_ex(schema, "uniqueItems", &kw) && kw &&
            json_object_is_type(kw, json_type_boolean) && json_object_get_boolean(kw)) {
            if (n > 256) {
                saw_indet = 1;
            } else {
                for (size_t i = 0; i < n; i++) {
                    for (size_t j = i + 1; j < n; j++) {
                        int eq = json_equal_depth(json_object_array_get_idx(val, i),
                                                  json_object_array_get_idx(val, j), 0, bud);
                        if (bud && (bud->aborted || bud->budget_exhausted)) return SCHEMA_INDETERMINATE;
                        if (eq < 0) saw_indet = 1;
                        else if (eq > 0) {
                            set_err(err, "%s: array contains duplicate items", disp_path(path));
                            return SCHEMA_INVALID;
                        }
                    }
                }
            }
        }
        if (json_object_object_get_ex(schema, "items", &kw) && kw) {
            if (json_object_is_type(kw, json_type_object) || json_object_is_type(kw, json_type_boolean)) {
                for (size_t i = 0; i < n; i++) {
                    char *cpath = (path && *path) ? sfmt("%s[%zu]", path, i) : sfmt("[%zu]", i);
                    enum schema_res r = code_schema_eval_budget(root, kw, json_object_array_get_idx(val, i),
                                                                cpath, depth + 1, bud, err);
                    free(cpath);
                    if (bud && (bud->aborted || bud->budget_exhausted)) return SCHEMA_INDETERMINATE;
                    if (r == SCHEMA_INVALID) return SCHEMA_INVALID;
                    if (r == SCHEMA_INDETERMINATE) saw_indet = 1;
                }
            } else if (json_object_is_type(kw, json_type_array)) {
                size_t tn = json_object_array_length(kw);
                for (size_t i = 0; i < n && i < tn; i++) {
                    char *cpath = (path && *path) ? sfmt("%s[%zu]", path, i) : sfmt("[%zu]", i);
                    enum schema_res r = code_schema_eval_budget(root, json_object_array_get_idx(kw, i),
                                                                json_object_array_get_idx(val, i),
                                                                cpath, depth + 1, bud, err);
                    free(cpath);
                    if (bud && (bud->aborted || bud->budget_exhausted)) return SCHEMA_INDETERMINATE;
                    if (r == SCHEMA_INVALID) return SCHEMA_INVALID;
                    if (r == SCHEMA_INDETERMINATE) saw_indet = 1;
                }
            } else {
                saw_indet = 1;
            }
        }
    }

    /* Object constraints */
    if (val && json_object_is_type(val, json_type_object)) {
        size_t nprops = (size_t)json_object_object_length(val);
        if (json_object_object_get_ex(schema, "minProperties", &kw) && is_json_number(kw)) {
            int64_t lim = json_object_get_int64(kw);
            if (lim > 0 && nprops < (size_t)lim) {
                set_err(err, "%s: object has %zu properties, minProperties is %lld",
                        disp_path(path), nprops, (long long)lim);
                return SCHEMA_INVALID;
            }
        }
        if (json_object_object_get_ex(schema, "maxProperties", &kw) && is_json_number(kw)) {
            int64_t lim = json_object_get_int64(kw);
            if (lim >= 0 && nprops > (size_t)lim) {
                set_err(err, "%s: object has %zu properties, maxProperties is %lld",
                        disp_path(path), nprops, (long long)lim);
                return SCHEMA_INVALID;
            }
        }
        if (json_object_object_get_ex(schema, "required", &kw) && kw) {
            if (!json_object_is_type(kw, json_type_array)) {
                saw_indet = 1;
            } else {
                size_t rn = json_object_array_length(kw);
                for (size_t i = 0; i < rn; i++) {
                    if (budget_tick(bud) != 0) return SCHEMA_INDETERMINATE;
                    json_object *rk = json_object_array_get_idx(kw, i);
                    if (!rk || !json_object_is_type(rk, json_type_string)) { saw_indet = 1; continue; }
                    const char *rname = json_object_get_string(rk);
                    if (!json_object_object_get_ex(val, rname, NULL)) {
                        if (path && *path)
                            set_err(err, "%s.%s: missing required field", path, rname);
                        else
                            set_err(err, "%s: missing required field", rname);
                        return SCHEMA_INVALID;
                    }
                }
            }
        }
        json_object *props = NULL;
        int has_props = json_object_object_get_ex(schema, "properties", &props) &&
                        props && json_object_is_type(props, json_type_object);
        if (has_props) {
            json_object_object_foreach(val, k, v) {
                if (budget_tick(bud) != 0) return SCHEMA_INDETERMINATE;
                json_object *ps = NULL;
                if (json_object_object_get_ex(props, k, &ps)) {
                    char *cpath = (path && *path) ? sfmt("%s.%s", path, k) : strdup(k);
                    enum schema_res r = code_schema_eval_budget(root, ps, v, cpath, depth + 1, bud, err);
                    free(cpath);
                    if (bud && (bud->aborted || bud->budget_exhausted)) return SCHEMA_INDETERMINATE;
                    if (r == SCHEMA_INVALID) return SCHEMA_INVALID;
                    if (r == SCHEMA_INDETERMINATE) saw_indet = 1;
                }
            }
        }
        json_object *addp = NULL;
        if (json_object_object_get_ex(schema, "additionalProperties", &addp) && addp) {
            if (has_pattern_props) {
                saw_indet = 1;
            } else if (json_object_is_type(addp, json_type_boolean)) {
                if (!json_object_get_boolean(addp)) {
                    json_object_object_foreach(val, k, v) {
                        (void)v;
                        if (budget_tick(bud) != 0) return SCHEMA_INDETERMINATE;
                        if (!has_props || !json_object_object_get_ex(props, k, NULL)) {
                            if (path && *path)
                                set_err(err, "%s.%s: additional property not allowed", path, k);
                            else
                                set_err(err, "%s: additional property not allowed", k);
                            return SCHEMA_INVALID;
                        }
                    }
                }
            } else if (json_object_is_type(addp, json_type_object)) {
                json_object_object_foreach(val, k, v) {
                    if (budget_tick(bud) != 0) return SCHEMA_INDETERMINATE;
                    if (!has_props || !json_object_object_get_ex(props, k, NULL)) {
                        char *cpath = (path && *path) ? sfmt("%s.%s", path, k) : strdup(k);
                        enum schema_res r = code_schema_eval_budget(root, addp, v, cpath, depth + 1, bud, err);
                        free(cpath);
                        if (bud && (bud->aborted || bud->budget_exhausted)) return SCHEMA_INDETERMINATE;
                        if (r == SCHEMA_INVALID) return SCHEMA_INVALID;
                        if (r == SCHEMA_INDETERMINATE) saw_indet = 1;
                    }
                }
            } else {
                saw_indet = 1;
            }
        }
    }

    /* Combinators: allOf, anyOf, oneOf, not */
    if (json_object_object_get_ex(schema, "allOf", &kw) && kw) {
        if (!json_object_is_type(kw, json_type_array)) {
            saw_indet = 1;
        } else {
            size_t n = json_object_array_length(kw);
            for (size_t i = 0; i < n; i++) {
                enum schema_res r = code_schema_eval_budget(root, json_object_array_get_idx(kw, i),
                                                            val, path, depth + 1, bud, err);
                if (bud && (bud->aborted || bud->budget_exhausted)) return SCHEMA_INDETERMINATE;
                if (r == SCHEMA_INVALID) return SCHEMA_INVALID;
                if (r == SCHEMA_INDETERMINATE) saw_indet = 1;
            }
        }
    }

    if (json_object_object_get_ex(schema, "anyOf", &kw) && kw) {
        if (!json_object_is_type(kw, json_type_array)) {
            saw_indet = 1;
        } else {
            size_t n = json_object_array_length(kw);
            int any_valid = 0, any_indet = 0;
            char *first_err = NULL;
            for (size_t i = 0; i < n; i++) {
                char *sub_err = NULL;
                enum schema_res r = code_schema_eval_budget(root, json_object_array_get_idx(kw, i),
                                                            val, path, depth + 1, bud, &sub_err);
                if (bud && (bud->aborted || bud->budget_exhausted)) {
                    free(sub_err);
                    free(first_err);
                    return SCHEMA_INDETERMINATE;
                }
                if (r == SCHEMA_VALID) {
                    any_valid = 1;
                    free(sub_err);
                    break;
                }
                if (r == SCHEMA_INDETERMINATE) {
                    any_indet = 1;
                    free(sub_err);
                } else {
                    if (!first_err && sub_err) first_err = sub_err;
                    else free(sub_err);
                }
            }
            if (!any_valid) {
                if (any_indet) {
                    free(first_err);
                    saw_indet = 1;
                } else {
                    if (err) {
                        free(*err);
                        *err = first_err ? first_err : sfmt("%s: did not match anyOf schema", disp_path(path));
                    } else {
                        free(first_err);
                    }
                    return SCHEMA_INVALID;
                }
            } else {
                free(first_err);
            }
        }
    }

    if (json_object_object_get_ex(schema, "oneOf", &kw) && kw) {
        if (!json_object_is_type(kw, json_type_array)) {
            saw_indet = 1;
        } else {
            size_t n = json_object_array_length(kw);
            size_t n_valid = 0, n_indet = 0;
            char *first_err = NULL;
            for (size_t i = 0; i < n; i++) {
                char *sub_err = NULL;
                enum schema_res r = code_schema_eval_budget(root, json_object_array_get_idx(kw, i),
                                                            val, path, depth + 1, bud, &sub_err);
                if (bud && (bud->aborted || bud->budget_exhausted)) {
                    free(sub_err);
                    free(first_err);
                    return SCHEMA_INDETERMINATE;
                }
                if (r == SCHEMA_VALID) {
                    n_valid++;
                    free(sub_err);
                    if (n_valid > 1) break;
                } else if (r == SCHEMA_INDETERMINATE) {
                    n_indet++;
                    free(sub_err);
                } else {
                    if (!first_err && sub_err) first_err = sub_err;
                    else free(sub_err);
                }
            }
            if (n_valid > 1) {
                free(first_err);
                set_err(err, "%s: matched %zu oneOf schemas (expected 1)", disp_path(path), n_valid);
                return SCHEMA_INVALID;
            }
            if (n_valid == 0 && n_indet == 0) {
                if (err) {
                    free(*err);
                    *err = first_err ? first_err : sfmt("%s: matched no oneOf schema", disp_path(path));
                } else {
                    free(first_err);
                }
                return SCHEMA_INVALID;
            }
            free(first_err);
            if (n_indet > 0) saw_indet = 1;
        }
    }

    if (json_object_object_get_ex(schema, "not", &kw) && kw) {
        char *sub_err = NULL;
        enum schema_res r = code_schema_eval_budget(root, kw, val, path, depth + 1, bud, &sub_err);
        free(sub_err);
        if (bud && (bud->aborted || bud->budget_exhausted)) return SCHEMA_INDETERMINATE;
        if (r == SCHEMA_VALID) {
            set_err(err, "%s: value must not match 'not' schema", disp_path(path));
            return SCHEMA_INVALID;
        }
        if (r == SCHEMA_INDETERMINATE) saw_indet = 1;
    }

    return saw_indet ? SCHEMA_INDETERMINATE : SCHEMA_VALID;
}

enum schema_res code_schema_eval(json_object *root, json_object *schema, json_object *val,
                                 const char *path, int depth, char **err) {
    struct code_schema_budget b = { SCHEMA_DEFAULT_WORK_BUDGET, 0, 0, NULL, NULL };
    return code_schema_eval_budget(root, schema, val, path, depth, &b, err);
}

int code_schema_validate_budget(json_object *schema, json_object *args,
                                struct code_schema_budget *b, char **err) {
    if (err) *err = NULL;
    if (!schema) return (b && budget_check_abort_now(b)) ? -1 : 0;
    struct code_schema_budget def = { SCHEMA_DEFAULT_WORK_BUDGET, 0, 0, NULL, NULL };
    struct code_schema_budget *bud = b ? b : &def;
    enum schema_res r = code_schema_eval_budget(schema, schema, args, "", 0, bud, err);
    if (bud->aborted) {
        if (err) { free(*err); *err = NULL; }
        return -1;
    }
    if (r == SCHEMA_INVALID) {
        if (err && !*err) *err = strdup("schema validation failed");
        return 1;
    }
    if (err) { free(*err); *err = NULL; }
    return 0;
}

int code_schema_validate(json_object *schema, json_object *args, char **err) {
    struct code_schema_budget b = { SCHEMA_DEFAULT_WORK_BUDGET, 0, 0, NULL, NULL };
    int rc = code_schema_validate_budget(schema, args, &b, err);
    return rc == 1 ? 1 : 0;
}

static size_t levenshtein(const char *a, const char *b) {
    size_t la = strlen(a), lb = strlen(b);
    if (la == 0) return lb;
    if (lb == 0) return la;
    if (la > 256) la = 256;
    if (lb > 256) lb = 256;
    size_t *prev = malloc((lb + 1) * sizeof *prev);
    size_t *curr = malloc((lb + 1) * sizeof *curr);
    if (!prev || !curr) { free(prev); free(curr); return la > lb ? la : lb; }
    for (size_t j = 0; j <= lb; j++) prev[j] = j;
    for (size_t i = 1; i <= la; i++) {
        curr[0] = i;
        for (size_t j = 1; j <= lb; j++) {
            size_t cost = (a[i - 1] == b[j - 1]) ? 0 : 1;
            size_t del = prev[j] + 1;
            size_t ins = curr[j - 1] + 1;
            size_t sub = prev[j - 1] + cost;
            size_t best = del < ins ? del : ins;
            if (sub < best) best = sub;
            curr[j] = best;
        }
        size_t *tmp = prev; prev = curr; curr = tmp;
    }
    size_t d = prev[lb];
    free(prev);
    free(curr);
    return d;
}

struct sug_item { const char *name; size_t dist; };

static int sug_cmp(const void *pa, const void *pb) {
    const struct sug_item *a = (const struct sug_item *)pa;
    const struct sug_item *b = (const struct sug_item *)pb;
    if (a->dist != b->dist) return a->dist < b->dist ? -1 : 1;
    return strcmp(a->name, b->name);
}

char *code_suggest_names(const char *typed, const char *const *candidates, size_t n) {
    if (!typed || !candidates || n == 0) return NULL;
    size_t max_d = strlen(typed) / 3;
    if (max_d < 2) max_d = 2;
    struct sug_item *items = malloc(n * sizeof *items);
    if (!items) return NULL;
    size_t m = 0;
    for (size_t i = 0; i < n; i++) {
        if (!candidates[i]) continue;
        size_t d = levenshtein(typed, candidates[i]);
        if (d <= max_d) {
            items[m].name = candidates[i];
            items[m].dist = d;
            m++;
        }
    }
    if (m == 0) { free(items); return NULL; }
    qsort(items, m, sizeof *items, sug_cmp);
    size_t keep = m < 3 ? m : 3;
    size_t cap = 1;
    for (size_t i = 0; i < keep; i++) cap += strlen(items[i].name) + 2;
    char *out = malloc(cap);
    if (!out) { free(items); return NULL; }
    out[0] = '\0';
    for (size_t i = 0; i < keep; i++) {
        if (i > 0) strcat(out, ", ");
        strcat(out, items[i].name);
    }
    free(items);
    return out;
}

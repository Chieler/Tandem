/* Tri-state recursive JSON Schema validator over json-c and Levenshtein name suggestions. */
#ifndef CODE_SCHEMA_H
#define CODE_SCHEMA_H

#include <stddef.h>
#include <json-c/json.h>

enum schema_res { SCHEMA_VALID = 0, SCHEMA_INVALID = 1, SCHEMA_INDETERMINATE = 2 };

typedef int (*code_schema_abort_fn)(void *ctx);

struct code_schema_budget {
    size_t steps_left;
    int aborted;
    int budget_exhausted;
    code_schema_abort_fn abort_fn;
    void *abort_ctx;
};

enum schema_res code_schema_eval(json_object *root, json_object *schema, json_object *val,
                                 const char *path, int depth, char **err);
enum schema_res code_schema_eval_budget(json_object *root, json_object *schema, json_object *val,
                                        const char *path, int depth, struct code_schema_budget *b, char **err);
/* Top-level gate: 0 pass (VALID or INDETERMINATE), 1 reject (INVALID, *err malloc'd). */
int code_schema_validate(json_object *schema, json_object *args, char **err);
/* Budgeted gate: 0 pass (VALID or INDETERMINATE), 1 reject (INVALID), -1 aborted. */
int code_schema_validate_budget(json_object *schema, json_object *args,
                                struct code_schema_budget *b, char **err);
char *code_suggest_names(const char *typed, const char *const *candidates, size_t n);

#endif

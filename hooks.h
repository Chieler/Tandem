#ifndef HOOKS_H
#define HOOKS_H
#include <json-c/json.h>
struct hook_event { const char *session, *kind, *prompt, *reason; int loop; };
enum hook_answer_kind { HOOK_NEUTRAL, HOOK_ATTACH, HOOK_BLOCK };
int hook_parse(const char *harness, const char *event, json_object *input, struct hook_event *out);
json_object *hook_answer(const char *harness, const char *event, enum hook_answer_kind kind, const char *text);
int hooks_admin(int argc, char **argv, int (*seen)(const char *harness));
#endif

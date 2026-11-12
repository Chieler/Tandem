#include "hooks.h"
#include <string.h>

static const char *string_field(json_object *input, const char *key) {
    json_object *v = NULL;
    return input && json_object_object_get_ex(input, key, &v) && json_object_is_type(v, json_type_string) ? json_object_get_string(v) : "";
}
static int int_field(json_object *input, const char *key) {
    json_object *v = NULL;
    return input && json_object_object_get_ex(input, key, &v) ? json_object_get_int(v) : 0;
}
int hook_parse(const char *harness, const char *event, json_object *input, struct hook_event *out) {
    int claude = !strcmp(harness, "claude"), agy = !strcmp(harness, "agy");
    if ((!claude && !agy) || !input || !json_object_is_type(input, json_type_object)) return 0;
    const char *const c[] = {"SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest", "PostToolUse", "PreToolUse", NULL};
    const char *const a[] = {"SessionStart", "PreInvocation", "Stop", "PostToolUse", NULL};
    const char *const *allowed = claude ? c : a;
    int known = 0;
    for (int i = 0; allowed[i]; i++) if (!strcmp(allowed[i], event)) known = 1;
    if (!known) return 0;
    out->session = string_field(input, claude ? "session_id" : "conversationId");
    out->kind = event;
    out->prompt = string_field(input, claude ? "prompt" : "lastUserInput");
    out->reason = agy ? string_field(input, "terminationReason") : "";
    out->loop = claude ? int_field(input, "stop_hook_active") != 0 :
        (!strcmp(event, "PreInvocation") ? int_field(input, "invocationNum") > 0 : int_field(input, "executionNum") > 0);
    return *out->session != 0;
}
json_object *hook_answer(const char *harness, const char *event, enum hook_answer_kind kind, const char *text) {
    json_object *out = json_object_new_object();
    int claude = !strcmp(harness, "claude"), agy = !strcmp(harness, "agy");
    if ((!claude && !agy) || !text || kind == HOOK_NEUTRAL) return out;
    if (kind == HOOK_BLOCK && !strcmp(event, "Stop")) {
        json_object_object_add(out, "decision", json_object_new_string(claude ? "block" : "continue"));
        json_object_object_add(out, "reason", json_object_new_string(text));
    } else if (kind == HOOK_ATTACH && claude && (!strcmp(event, "SessionStart") || !strcmp(event, "UserPromptSubmit"))) {
        json_object *specific = json_object_new_object();
        json_object_object_add(specific, "hookEventName", json_object_new_string(event));
        json_object_object_add(specific, "additionalContext", json_object_new_string(text));
        json_object_object_add(out, "hookSpecificOutput", specific);
    } else if (kind == HOOK_ATTACH && agy && (!strcmp(event, "SessionStart") || !strcmp(event, "PreInvocation"))) {
        json_object *array = json_object_new_array(), *step = json_object_new_object(), *message = json_object_new_object();
        json_object_object_add(message, "systemMessage", json_object_new_string(text));
        json_object_object_add(step, "systemMessage", message);
        json_object_array_add(array, step);
        json_object_object_add(out, "injectSteps", array);
    }
    if (strlen(json_object_to_json_string_ext(out, JSON_C_TO_STRING_PLAIN)) > (claude ? 8192U : 40960U)) {
        json_object_put(out);
        return json_object_new_object();
    }
    return out;
}

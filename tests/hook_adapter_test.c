#include "hooks.h"
#include <json-c/json.h>
#include <stdio.h>
#include <string.h>

struct fixture { const char *file, *harness, *event, *prompt, *reason; int loop; };
static const struct fixture fixtures[] = {
    {"claude-UserPromptSubmit-mail.json", "codex", "UserPromptSubmit", "[cntctr mail id=42] body attached; if you see none, call board", "", 0},
    {"claude-Stop-active.json", "codex", "Stop", "", "", 1},
    {"claude-SessionStart.json", "claude", "SessionStart", "", "", 0},
    {"claude-UserPromptSubmit-mail.json", "claude", "UserPromptSubmit", "[cntctr mail id=42] body attached; if you see none, call board", "", 0},
    {"claude-UserPromptSubmit-other.json", "claude", "UserPromptSubmit", "please look at [cntctr mail id=42] body attached; if you see none, call board", "", 0},
    {"claude-Stop.json", "claude", "Stop", "", "", 0},
    {"claude-Stop-active.json", "claude", "Stop", "", "", 1},
    {"claude-PermissionRequest.json", "claude", "PermissionRequest", "", "", 0},
    {"claude-PostToolUse.json", "claude", "PostToolUse", "", "", 0},
    {"agy-PreInvocation-first.json", "agy", "PreInvocation", "[cntctr mail id=42] body attached; if you see none, call board", "", 0},
    {"agy-PreInvocation-second.json", "agy", "PreInvocation", "[cntctr mail id=42] body attached; if you see none, call board", "", 1},
    {"agy-Stop.json", "agy", "Stop", "", "NO_TOOL_CALL", 0},
    {"agy-Stop-continued.json", "agy", "Stop", "", "NO_TOOL_CALL", 1},
    {"agy-Stop-error.json", "agy", "Stop", "", "ERROR", 0},
    {"agy-Stop-cancel.json", "agy", "Stop", "", "USER_CANCELED", 0},
};
int main(void) {
    int fail = 0;
    for (size_t i=0; i<sizeof fixtures/sizeof *fixtures; i++) {
        const struct fixture *f=&fixtures[i]; char path[512];
        snprintf(path,sizeof path,"fixtures/hooks/%s",f->file);
        json_object *input=json_object_from_file(path);
        struct hook_event e = {0};
        if (!input || !hook_parse(f->harness,f->event,input,&e) || strcmp(e.session,"SESSION-1") || strcmp(e.kind,f->event) || strcmp(e.prompt,f->prompt) || strcmp(e.reason,f->reason) || e.loop != f->loop) {
            fprintf(stderr,"FAIL adapter fields: %s\n",f->file); fail++;
        }
        json_object *neutral=hook_answer(f->harness,f->event,HOOK_NEUTRAL,NULL);
        if (!neutral || strcmp(json_object_to_json_string_ext(neutral,JSON_C_TO_STRING_PLAIN),"{}")) { fprintf(stderr,"FAIL adapter neutral: %s\n",f->file); fail++; }
        if (neutral) json_object_put(neutral);
        if (input) json_object_put(input);
    }
    struct answer_case { const char *h, *event, *text, *expected; enum hook_answer_kind kind; } answers[] = {
        {"codex", "UserPromptSubmit", "hello", "{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\",\"additionalContext\":\"hello\"}}", HOOK_ATTACH},
        {"codex", "Stop", "reminder", "{\"decision\":\"block\",\"reason\":\"reminder\"}", HOOK_BLOCK},
        {"codex", "Stop", "hello", "{}", HOOK_ATTACH},
        {"codex", "SessionStart", "hello", "{}", HOOK_ATTACH},
        {"claude", "SessionStart", "The session context code word is CRIMSON-FALCON.", "{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"The session context code word is CRIMSON-FALCON.\"}}", HOOK_ATTACH},
        {"claude", "UserPromptSubmit", "MANDATORY: State the first word and the last word of the body below immediately without running any tools or shell commands:\n<content of body.txt>", "{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\",\"additionalContext\":\"MANDATORY: State the first word and the last word of the body below immediately without running any tools or shell commands:\\n<content of body.txt>\"}}", HOOK_ATTACH},
        {"claude", "Stop", "You have mail. Run: cat /home/u/mail.txt and state the word.", "{\"decision\":\"block\",\"reason\":\"You have mail. Run: cat /home/u/mail.txt and state the word.\"}", HOOK_BLOCK},
        {"agy", "SessionStart", "Secret code word from session context: ZEPHYR-KANGAROO-981.", "{\"injectSteps\":[{\"systemMessage\":{\"systemMessage\":\"Secret code word from session context: ZEPHYR-KANGAROO-981.\"}}]}", HOOK_ATTACH},
        {"agy", "PreInvocation", "You have received an external message. Instructions: State the first word and the last word of this message.\n\n<body content>", "{\"injectSteps\":[{\"systemMessage\":{\"systemMessage\":\"You have received an external message. Instructions: State the first word and the last word of this message.\\n\\n<body content>\"}}]}", HOOK_ATTACH},
        {"agy", "Stop", "You have mail. Run: cat /home/u/mail.txt and state the word.", "{\"decision\":\"continue\",\"reason\":\"You have mail. Run: cat /home/u/mail.txt and state the word.\"}", HOOK_BLOCK},
    };
    for (size_t i=0; i<sizeof answers/sizeof *answers; i++) {
        struct answer_case *c = &answers[i];
        json_object *a=hook_answer(c->h,c->event,c->kind,c->text);
        json_object *want=json_tokener_parse(c->expected);
        if (!a || !want || !json_object_equal(a,want)) { fprintf(stderr,"FAIL adapter answer %zu\n",i); fail++; }
        if (a) json_object_put(a);
        if (want) json_object_put(want);
    }
    char oversized[9000];
    memset(oversized, 'x', sizeof oversized - 1); oversized[sizeof oversized - 1] = 0;
    json_object *large = hook_answer("codex", "UserPromptSubmit", HOOK_ATTACH, oversized);
    if (!large || json_object_object_length(large)) { fprintf(stderr, "FAIL codex size cap\n"); fail++; }
    if (large) json_object_put(large);
    printf("ADAPTER: %zu fixtures, %d failures\n",sizeof fixtures/sizeof *fixtures,fail);
    return fail != 0;
}

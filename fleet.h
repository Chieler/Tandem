/* fleet tool runner: runs a script in a sandbox with capped output, a deadline and a socket
 * back to cntctr on fd 3. Knows nothing about tmux, MCP or the knowledge store. */
#ifndef FLEET_H
#define FLEET_H

#include <pthread.h>

struct fleet_run {
    const char *name, *root, *interpreter, *script, *args_json, *db_path;
    int net, timeout, composed;
    long long deadline_ms;      /* absolute fleet_now_ms() deadline, 0: now + timeout. Nested runs pass the outer one */
    pthread_mutex_t *fork_mu;   /* held from pipe() to fork(), as in cntctr's run(); may be NULL */
    /* serve one composition request line, return malloc'd reply line; NULL serve: error reply */
    char *(*serve)(void *ctx, const char *line);
    void *ctx;
};

/* 0 ok, 1 tool error (non-zero exit, timeout, cap, no sandbox); *out is malloc'd result or error text */
long long fleet_now_ms(void);   /* the monotonic clock deadlines use */
int fleet_run(const struct fleet_run *r, char **out);
char *fleet_cache_dir(const char *root);   /* ~/.cache/cntctr/tools/<base>-<hash>/, created; caller frees */

#endif

/* fleet tool runner: runs a script in a sandbox with capped output, a deadline and a socket
 * back to cntctr on fd 3. Knows nothing about tmux, MCP or the knowledge store. */
#ifndef FLEET_H
#define FLEET_H

struct fleet_run {
    const char *name, *root, *interpreter, *script, *args_json, *db_path;
    int net, timeout;
    /* serve one composition request line, return malloc'd reply line; NULL serve: error reply */
    char *(*serve)(void *ctx, const char *line);
    void *ctx;
};

/* 0 ok, 1 tool error (non-zero exit, timeout, cap, no sandbox); *out is malloc'd result or error text */
int fleet_run(const struct fleet_run *r, char **out);
char *fleet_cache_dir(const char *root);   /* ~/.cache/cntctr/tools/<base>-<hash>/, created; caller frees */

#endif

#define _GNU_SOURCE
#include <dirent.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <json-c/json.h>

struct counts { long long in, read, write, out, denominator; };
struct model { char *name; struct counts c; struct model *next; };
struct seen { char *id, *model; struct counts c; struct seen *next; };
static struct model *models;
static struct seen *seen;
static time_t cutoff;
static const char *project;
static json_object *field(json_object *o, const char *k) { json_object *v = NULL; if (o) json_object_object_get_ex(o,k,&v); return v; }
static const char *str(json_object *o, const char *k) { json_object *v=field(o,k); return v && json_object_is_type(v,json_type_string) ? json_object_get_string(v) : ""; }
static long long num(json_object *o, const char *k) { json_object *v=field(o,k); return v ? json_object_get_int64(v) : 0; }
static void add(const char *name, struct counts c, int sign) {
    if (!*name) name="unknown";
    struct model *m; for (m=models; m && strcmp(m->name,name); m=m->next) {}
    if (!m) { m=calloc(1,sizeof *m); m->name=strdup(name); m->next=models; models=m; }
    m->c.in+=sign*c.in; m->c.read+=sign*c.read; m->c.write+=sign*c.write; m->c.out+=sign*c.out; m->c.denominator+=sign*c.denominator;
}
static int recent(json_object *o) {
    const char *s=str(o,"timestamp"); struct tm tm={0};
    return !*s || !strptime(s,"%Y-%m-%dT%H:%M:%S",&tm) || timegm(&tm)>=cutoff;
}
static void claude(const char *path) {
    FILE *f=fopen(path,"r"); if (!f) return;
    char *line=NULL; size_t cap=0;
    while (getline(&line,&cap,f)>0) {
        json_object *o=json_tokener_parse(line); if (!o) continue;
        json_object *msg=field(o,"message"), *u=field(msg,"usage");
        const char *id=str(msg,"id"), *name=str(msg,"model");
        if (!strcmp(str(o,"type"),"assistant") && *id && *name && u && recent(o)) {
            struct counts c={num(u,"input_tokens"),num(u,"cache_read_input_tokens"),num(u,"cache_creation_input_tokens"),num(u,"output_tokens"),0};
            c.denominator=c.in+c.read+c.write;
            struct seen *s; for (s=seen;s && strcmp(s->id,id);s=s->next) {}
            if (!s) { s=calloc(1,sizeof *s); s->id=strdup(id); s->next=seen; seen=s; }
            else { add(s->model,s->c,-1); free(s->model); }
            s->model=strdup(name); s->c=c; add(name,c,1);
        }
        json_object_put(o);
    }
    free(line); fclose(f);
}
static void codex(const char *path) {
    FILE *f=fopen(path,"r"); if (!f) return;
    char *line=NULL; size_t cap=0; char cwd[PATH_MAX]="", model[256]=""; struct counts c={0}; int got=0;
    while (getline(&line,&cap,f)>0) {
        json_object *o=json_tokener_parse(line); if (!o) continue;
        const char *type=str(o,"type"); json_object *p=field(o,"payload");
        if (!strcmp(type,"session_meta") || !strcmp(type,"turn_context")) {
            if (*str(p,"cwd")) snprintf(cwd,sizeof cwd,"%s",str(p,"cwd"));
            if (*str(p,"model")) snprintf(model,sizeof model,"%s",str(p,"model"));
        } else if (!strcmp(type,"event_msg") && !strcmp(str(p,"type"),"token_count") && recent(o)) {
            json_object *u=field(field(p,"info"),"total_token_usage");
            if (u) { c=(struct counts){num(u,"input_tokens"),num(u,"cached_input_tokens"),num(u,"cache_write_input_tokens"),num(u,"output_tokens"),num(u,"input_tokens")}; got=1; }
        }
        json_object_put(o);
    }
    size_t n=strlen(project);
    if (got && !strncmp(cwd,project,n) && (!cwd[n] || cwd[n]=='/')) add(model,c,1);
    free(line); fclose(f);
}
static void walk(const char *path, int is_codex, int depth) {
    DIR *d=opendir(path); if (!d) return; struct dirent *e;
    while ((e=readdir(d))) {
        if (e->d_name[0]=='.') continue;
        char *p=NULL; if (asprintf(&p,"%s/%s",path,e->d_name)<0) continue;
        struct stat st; if (!lstat(p,&st)) {
            if (S_ISDIR(st.st_mode) && depth>0) walk(p,is_codex,depth-1);
            else if (S_ISREG(st.st_mode) && st.st_mtime>=cutoff) {
                size_t n=strlen(e->d_name);
                if (n>6 && !strcmp(e->d_name+n-6,".jsonl") && (!is_codex || !strncmp(e->d_name,"rollout-",8)))
                    (is_codex ? codex : claude)(p);
            }
        }
        free(p);
    }
    closedir(d);
}
int usage_cmd(int argc, char **argv, const char *cwd) {
    long hours=24;
    if (argc>2) { char *end; if (argc!=4 || strcmp(argv[2],"--since")) goto bad; hours=strtol(argv[3],&end,10); if (!*argv[3] || *end || hours<0 || hours>INT_MAX/3600) goto bad; }
    cutoff=time(NULL)-hours*3600LL;
    const char *home=getenv("HOME"); if (!home) home=".";
    project=getenv("CNTCTR_USAGE_CWD"); if (!project || !*project) project=cwd;
    const char *cd=getenv("CNTCTR_USAGE_CLAUDE_DIR"), *xd=getenv("CNTCTR_USAGE_CODEX_DIR");
    char *cp=NULL,*xp=NULL;
    if (!cd || !*cd) { char *encoded=strdup(project); for (char *p=encoded;*p;p++) if (*p=='/') *p='-'; if (asprintf(&cp,"%s/.claude/projects/%s",home,encoded)<0) cp=NULL; free(encoded); cd=cp; }
    if (!xd || !*xd) { if (asprintf(&xp,"%s/.codex/sessions",home)<0) xp=NULL; xd=xp; }
    if (cd) walk(cd,0,0); if (xd) walk(xd,1,3);
    printf("%-28s %12s %12s %12s %12s %9s\n","model","input","cache read","cache write","output","hit %");
    for (struct model *m=models;m;m=m->next) {
        long long denom=m->c.denominator;
        /* Codex input already includes cached tokens. */
        printf("%-28s %12lld %12lld %12lld %12lld %8.1f%%\n",m->name,m->c.in,m->c.read,m->c.write,m->c.out,denom ? 100.0*m->c.read/denom : 0.0);
    }
    puts("agy: not counted"); free(cp); free(xp); return 0;
 bad: fprintf(stderr,"usage: cntctr usage [--since hours]\n"); return 2;
}

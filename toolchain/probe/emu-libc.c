/* TEST ONLY - never goes to the car. Fake "libc.so.3" for running the probe under qemu-arm
 * with glibc's ld.so standing in for ldqnx.so.2 (see toolchain/test/fakelibc.c). Adds what the
 * probe needs: dlopen/dlsym that hand back the fake libscreen / fake slot symbols, dladdr and
 * getenv. It NEEDs glibc's libc.so.6 only for dl_iterate_phdr (to implement dladdr). */
typedef void (*vfn)(void);
typedef unsigned u32;

static long sc(long n, long a, long b, long c)
{
    register long r7 __asm__("r7") = n;
    register long r0 __asm__("r0") = a;
    register long r1 __asm__("r1") = b;
    register long r2 __asm__("r2") = c;
    __asm__ volatile("svc 0" : "+r"(r0) : "r"(r7), "r"(r1), "r"(r2) : "memory");
    return r0;
}
int write(int fd, const void *b, unsigned n) { return (int)sc(4, fd, (long)b, (long)n); }

static vfn hooks[8]; static int nhooks;
static char **env;
void _init_libc(int argc, char **argv, char **envp, unsigned *auxv, vfn exitfn)
{ (void)argc; (void)argv; (void)auxv; (void)exitfn; env = envp; }
void _preinit_array(vfn *s, vfn *e) { while (s < e) (*s++)(); }
int atexit(vfn f) { if (nhooks < 8) hooks[nhooks++] = f; return 0; }
void _fini_array(vfn *s, vfn *e) { (void)s; (void)e; }
void _init_array(vfn *s, vfn *e) { while (s < e) (*s++)(); }
__attribute__((noreturn)) void exit(int c)
{
    while (nhooks) hooks[--nhooks]();
    sc(248, c, 0, 0);
    for (;;) {}
}

static int eq(const char *a, const char *b) { while (*a && *a == *b) { a++; b++; } return *a == *b; }
char *getenv(const char *n)
{
    int i;
    for (i = 0; env && env[i]; i++) {
        const char *e = env[i], *p = n;
        while (*p && *e == *p) { e++; p++; }
        if (!*p && *e == '=') return (char *)e + 1;
    }
    return 0;
}

/* Resolved by glibc's loader through the global scope: the fake libscreen.so.1 and the
 * fake (or chained) slot library. Weak so a missing library gives a null, not a load error. */
extern int screen_create_window(void) __attribute__((weak));
extern int screen_post_window(void) __attribute__((weak));
extern int diagnostics_async_base_logs(void) __attribute__((weak));
extern int forensics_logworthy_async(void) __attribute__((weak));
static const struct { const char *n; void *f; } tab[] = {
    { "screen_create_window", (void *)screen_create_window },
    { "screen_post_window", (void *)screen_post_window },
    { "diagnostics_async_base_logs", (void *)diagnostics_async_base_logs },
    { "forensics_logworthy_async", (void *)forensics_logworthy_async },
};
void *dlopen(const char *n, int f)
{
    (void)f;
    if (eq(n, "libscreen.so.1")) return (void *)1;
    if (eq(n, "libRCN_DiagnosticsLib.so")) return (void *)2;
    return 0;
}
void *dlsym(void *h, const char *n)
{
    unsigned i;
    if (!h) return 0;
    for (i = 0; i < sizeof tab / sizeof tab[0]; i++) if (eq(tab[i].n, n)) return tab[i].f;
    return 0;
}
const char *dlerror(void) { return "fake"; }

struct pinfo { u32 addr; const char *name; const u32 *phdr; unsigned short phnum; };
struct dl_info { const char *fname; void *fbase; const char *sname; void *saddr; };
extern int dl_iterate_phdr(int (*)(struct pinfo *, unsigned, void *), void *);
struct q { u32 a; struct dl_info *di; };
static int cb(struct pinfo *p, unsigned sz, void *arg)
{
    struct q *q = arg;
    unsigned i;
    (void)sz;
    for (i = 0; i < p->phnum; i++) {
        const u32 *ph = p->phdr + i * 8;      /* Elf32_Phdr = 8 words: type off vaddr paddr filesz memsz flags align */
        if (ph[0] == 1 && q->a >= p->addr + ph[2] && q->a < p->addr + ph[2] + ph[5]) {
            q->di->fname = p->name[0] ? p->name : "main-exe";
            q->di->fbase = (void *)(p->addr + ph[2]);
            return 1;
        }
    }
    return 0;
}
int dladdr(const void *a, struct dl_info *di)
{
    struct q q;
    q.a = (u32)a; q.di = di;
    di->sname = 0; di->saddr = 0;
    return dl_iterate_phdr(cb, &q);
}

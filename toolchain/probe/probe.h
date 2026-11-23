/* Shared helpers for slotprobe / libslotgot / libslotexp (loader probe, see
 * ../../docs/TESTING.md). Hand-declared like screen.h;
 * output goes to stdout (fd 1) because the radio script captures it as t*.out. */
#pragma clang diagnostic ignored "-Wunused-function"
typedef unsigned u32;
extern int write(int, const void *, unsigned);
extern void *dlopen(const char *, int);
extern void *dlsym(void *, const char *);
extern const char *dlerror(void);
/* Dl_info as in QNX/glibc: file name, base, nearest symbol name and address. */
typedef struct { const char *fname; void *fbase; const char *sname; void *saddr; } DlInfo;
extern int dladdr(const void *, DlInfo *);
#define RTLD_NOW_QNX 0x0202

typedef struct { int tag; u32 val; } Dyn;
typedef struct { u32 name, value, size; unsigned char info, other; unsigned short shndx; } Sym;
typedef struct { u32 off, info; } Rel;
typedef struct { const Dyn *dyn; const char *str; const Sym *sym; const Rel *jmp; u32 njmp; } DynView;

#define DT_NEEDED 1
#define DT_PLTRELSZ 2
#define DT_STRTAB 5
#define DT_SYMTAB 6
#define DT_JMPREL 23
#define R_ARM_JUMP_SLOT 22

static unsigned slen(const char *s) { unsigned n = 0; while (s[n]) n++; return n; }
static int seq(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}
static int sstarts(const char *s, const char *p)
{
    while (*p && *s == *p) { s++; p++; }
    return *p == 0;
}
static void put(const char *s) { write(1, s, slen(s)); }
static void puthex(u32 v)
{
    static const char d[] = "0123456789abcdef";
    char b[11]; int i;
    b[0] = '0'; b[1] = 'x'; b[10] = 0;
    for (i = 0; i < 8; i++) b[2 + i] = d[(v >> (28 - 4 * i)) & 15];
    put(b);
}
static void putu(u32 v)
{
    char b[12]; int i = 11; b[i] = 0;
    do { b[--i] = (char)('0' + v % 10); v /= 10; } while (v);
    put(b + i);
}

/* Read a dynamic section (the pointers are taken as absolute addresses, as in an
 * ET_EXEC; slotprobe prints them so the radio run shows whether that holds). */
static int dynview_init(DynView *v, const Dyn *d)
{
    v->dyn = d; v->str = 0; v->sym = 0; v->jmp = 0; v->njmp = 0;
    for (; d->tag; d++) {
        if (d->tag == DT_STRTAB) v->str = (const char *)d->val;
        else if (d->tag == DT_SYMTAB) v->sym = (const Sym *)d->val;
        else if (d->tag == DT_JMPREL) v->jmp = (const Rel *)d->val;
        else if (d->tag == DT_PLTRELSZ) v->njmp = d->val / sizeof(Rel);
    }
    return v->str && v->sym && v->jmp && v->njmp && v->njmp <= 64;
}
static int jis_slot(const DynView *v, u32 i) { return (v->jmp[i].info & 0xff) == R_ARM_JUMP_SLOT; }
static const char *jname(const DynView *v, u32 i) { return v->str + v->sym[v->jmp[i].info >> 8].name; }
static int has_needed(const DynView *v, const char *n)
{
    const Dyn *d;
    for (d = v->dyn; d->tag; d++)
        if (d->tag == DT_NEEDED && seq(v->str + d->val, n)) return 1;
    return 0;
}

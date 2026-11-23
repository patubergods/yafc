/* libslotgot.so: prototype of the export-free slot library (plan section 3).
 * Built under SONAME libRCN_DiagnosticsLib.so, NEEDs libc.so.3 and
 * libRCN_DiagnosticsOld.so. Defines no symbols; everything is static.
 *
 * The constructor acts on the main executable, found by content, not by name:
 *  1. dladdr(0x100000) succeeds and an ELF EXEC/ARM header is there;
 *  2. its dynamic section NEEDs libscreen.so.1 and has JUMP_SLOTs for both
 *     screen_create_window and screen_post_window;
 *  3. each slot value equals dlsym(dlopen("libscreen.so.1"), name): relocation is
 *     done and nothing else patched the slot.
 * Only when all hold does it replace the two slots with wrappers that call the real
 * function. Built with -DSLOTGOT_RO (libslotgot_ro.so) it stops after the report and
 * writes nothing. No env/file gate: libc may not be initialised when this runs.
 * Everything is reported on stdout. */
#include "probe.h"

static int (*real_create)(int, int, int, int);
static int (*real_post)(int, int, int, int, int);
static u32 ncalls;

static int wrap_create(int a, int b, int c, int d) { ncalls++; return real_create(a, b, c, d); }
static int wrap_post(int a, int b, int c, int d, int e) { ncalls++; return real_post(a, b, c, d, e); }

static int refuse(const char *why) { put("libslotgot: refuse: "); put(why); put("\n"); return 0; }

__attribute__((constructor))
static void slotgot_init(void)
{
    static const char *const names[2] = { "screen_create_window", "screen_post_window" };
    u32 want[2], idx[2], wrap[2], k, i, n;
    const unsigned char *e = (const unsigned char *)0x100000;
    const unsigned char *ph;
    const Dyn *dyn = 0;
    DlInfo di;
    DynView v;
    void *hs;
#ifdef SLOTGOT_RO
    const int patch = 0;
#else
    const int patch = 1;
#endif

    put("libslotgot: ctor ran\n");
    if (!dladdr(e, &di)) { refuse("nothing mapped at 0x100000"); return; }
    if (e[0] != 0x7f || e[1] != 'E' || e[2] != 'L' || e[3] != 'F' || e[16] != 2 || e[18] != 40) {
        refuse("0x100000 is not an ARM ET_EXEC header"); return;
    }
    put("libslotgot: main exe fname="); put(di.fname ? di.fname : "?"); put("\n");
    ph = e + *(const u32 *)(e + 28);
    n = *(const unsigned short *)(e + 44);
    for (i = 0; i < n; i++, ph += *(const unsigned short *)(e + 42))
        if (*(const u32 *)ph == 2) dyn = (const Dyn *)*(const u32 *)(ph + 8);
    if (!dyn || !dynview_init(&v, dyn)) { refuse("no usable PT_DYNAMIC in main exe"); return; }
    if (!has_needed(&v, "libscreen.so.1")) { refuse("main exe does not NEED libscreen.so.1"); return; }
    hs = dlopen("libscreen.so.1", RTLD_NOW_QNX);
    if (!hs) { refuse("dlopen libscreen.so.1 failed"); return; }
    for (k = 0; k < 2; k++) {
        idx[k] = 0xffffffffu;
        for (i = 0; i < v.njmp; i++)
            if (jis_slot(&v, i) && seq(jname(&v, i), names[k])) idx[k] = i;
        if (idx[k] == 0xffffffffu) { refuse("no JUMP_SLOT for a screen function"); return; }
        want[k] = (u32)dlsym(hs, names[k]);
        put("libslotgot: "); put(names[k]); put(" got="); puthex(v.jmp[idx[k]].off);
        put(" value="); puthex(*(const u32 *)v.jmp[idx[k]].off);
        put(" real="); puthex(want[k]);
        if (!want[k] || *(const u32 *)v.jmp[idx[k]].off != want[k]) {
            put(" relocated=no\n");
            refuse("slot value != dlsym (not relocated yet, or already patched)");
            return;
        }
        put(" relocated=yes\n");
    }
    if (!patch) { put("libslotgot: read-only build, slots left alone\n"); return; }
    real_create = (int (*)(int, int, int, int))want[0];
    real_post = (int (*)(int, int, int, int, int))want[1];
    wrap[0] = (u32)wrap_create;
    wrap[1] = (u32)wrap_post;
    for (k = 0; k < 2; k++) {
        u32 *slot = (u32 *)v.jmp[idx[k]].off;
        put("libslotgot: "); put(names[k]); put(" before="); puthex(*slot);
        *slot = wrap[k];
        put(" after="); puthex(*slot); put("\n");
    }
    put("libslotgot: patched 2 slots\n");
}

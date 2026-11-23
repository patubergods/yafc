/* slotprobe: ET_EXEC stand-in for SS_RVC's loader situation. NEEDED order is
 * libRCN_DiagnosticsLib.so, libscreen.so.1, libc.so.3 (SS_RVC's own relative order).
 * It imports four symbols as JUMP_SLOTs from a branch that never runs, so nothing
 * here calls Screen or creates a context. main walks its own _DYNAMIC and reports,
 * per slot: GOT address, current value, which object owns that value (dladdr), and
 * what dlsym on the library handle returns, for comparison. */
#include "probe.h"

extern Dyn _DYNAMIC[];
extern int diagnostics_async_base_logs(int, int, int);
extern int forensics_logworthy_async(int, int, int);
extern int screen_create_window(int, int);
extern int screen_post_window(int, int, int, int, int);

static void owner(u32 val)
{
    DlInfo di;
    if (val && dladdr((const void *)val, &di)) {
        put(" fname="); put(di.fname ? di.fname : "?");
        put(" sname="); put(di.sname ? di.sname : "?");
    } else put(" fname=? sname=?");
}

int main(int argc, char **argv)
{
    DynView v;
    const Dyn *d;
    DlInfo di;
    void *hs, *hd;
    u32 i;

    (void)argv;
    if (argc > 99) {    /* never taken: only makes the linker emit the four JUMP_SLOTs */
        diagnostics_async_base_logs(0, 0, 0);
        forensics_logworthy_async(0, 0, 0);
        screen_create_window(0, 0);
        screen_post_window(0, 0, 0, 0, 0);
    }
    put("slotprobe start\n");
    if (!dynview_init(&v, _DYNAMIC)) { put("slotprobe: bad _DYNAMIC\n"); return 2; }
    for (d = v.dyn; d->tag; d++)
        if (d->tag == DT_NEEDED) { put("needed "); put(v.str + d->val); put("\n"); }
    put("dyn jmprel="); puthex((u32)v.jmp); put(" symtab="); puthex((u32)v.sym);
    put(" strtab="); puthex((u32)v.str); put(" njmp="); putu(v.njmp); put("\n");
    if (dladdr((const void *)_DYNAMIC, &di)) {
        put("exe fname="); put(di.fname ? di.fname : "?");
        put(" fbase="); puthex((u32)di.fbase); put("\n");
    }
    hs = dlopen("libscreen.so.1", RTLD_NOW_QNX);
    hd = dlopen("libRCN_DiagnosticsLib.so", RTLD_NOW_QNX);
    put("dlopen libscreen="); puthex((u32)hs); put(" diaglib="); puthex((u32)hd); put("\n");
    for (i = 0; i < v.njmp; i++) {
        const char *n;
        u32 val, want;
        if (!jis_slot(&v, i)) continue;
        n = jname(&v, i);
        if (!sstarts(n, "screen_") && !sstarts(n, "diagnostics_") && !sstarts(n, "forensics_")) continue;
        val = *(const u32 *)v.jmp[i].off;
        want = (u32)dlsym(sstarts(n, "screen_") ? hs : hd, n);
        put("slot "); put(n);
        put(" got="); puthex(v.jmp[i].off);
        put(" val="); puthex(val);
        owner(val);
        put(" dlsym="); puthex(want);
        put(val == want ? " same=yes\n" : " same=no\n");
    }
    put("slotprobe done\n");
    return 0;
}

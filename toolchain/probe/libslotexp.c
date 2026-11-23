/* libslotexp.so: T1 control. Same slot SONAME/NEEDED chain as libslotgot, but it
 * EXPORTS screen_create_window / screen_post_window (forwarding to libscreen).
 * Run under slotprobe: if the Screen JUMP_SLOTs end up owned by this library, a
 * slot library listed ahead of libscreen wins symbol binding (broad scope: the
 * export design is a blast-radius risk); if libscreen owns them, the loader scope
 * is strict. No constructor. Nothing calls these in the probe. */
#include "probe.h"

static void *real(const char *n)
{
    void *h = dlopen("libscreen.so.1", RTLD_NOW_QNX);
    return h ? dlsym(h, n) : 0;
}
int screen_create_window(int a, int b)
{
    int (*f)(int, int) = (int (*)(int, int))real("screen_create_window");
    return f ? f(a, b) : -1;
}
int screen_post_window(int a, int b, int c, int d, int e)
{
    int (*f)(int, int, int, int, int) = (int (*)(int, int, int, int, int))real("screen_post_window");
    return f ? f(a, b, c, d, e) : -1;
}

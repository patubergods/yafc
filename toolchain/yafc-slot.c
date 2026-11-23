/* yafc-slot.c - the library-slot hook for the camera process.
 *
 * One source, two builds: -DYAFC_SLOT produces the library that takes the slot
 * in the camera's link path and patches that process's own Screen call slots;
 * without it the same code builds the LD_PRELOAD interposer that exports the two
 * Screen names instead. The slot build is the supported one.
 *
 * NOT a QNX header user. Every constant and prototype below is declared here
 * on purpose, matching toolchain/screen.h (which carries the evidence for each
 * number). Do not include system headers; the cross build is freestanding.
 */

/* WHAT IT DOES
 *   The camera process owns one Screen window, RVC_app. Its buffer is 720x1900
 *   UYVY and the live picture is the first 480 rows. This library interposes
 *   screen_create_window (to capture the camera's Screen context) and
 *   screen_post_window:
 *
 *     mode=pass     call the real post unchanged (default, safest)
 *     mode=diag     log the real buffer properties once, then pass through
 *     mode=compose  place the window by geometry (see below) and let the
 *                   compositor scale the picture; optionally add the 360 bay
 *
 *   Those are the only supported modes. `mode=probe` and the pixel-writing
 *   paths were removed 2026-11-20 (review branch): they wrote into buffer rows
 *   the capture engine owns. Any other mode value means pass.
 *
 * HOW PLACEMENT WORKS
 *   Set SOURCE_POSITION/SIZE to the region of the buffer to show, and
 *   POSITION/SIZE to where and how large to show it. There is NO destination
 *   property: the "destination rectangle" the radio's property dump prints is
 *   derived from POSITION + SIZE. The compositor does all scaling.
 *
 * THE BAY (the 360 panel) IS A CHILD WINDOW OF THE CAMERA WINDOW
 *   The camera window shows one region of the frame, the bay another region of
 *   the same buffer (screen_share_window_buffers). The bay used to be a second
 *   top-level window made visible once and never hidden; because SS_PLM, not
 *   SS_RVC, shows and hides RVC_app, nothing ever hid the bay when the camera
 *   closed, and it stayed on screen (black) over CarPlay until reboot.
 *   It is now created with screen_create_window_type(SCREEN_CHILD_WINDOW) and
 *   joined to a window group parented by the camera window. QNX: "Windows in a
 *   window group inherit the visibility ... of their parent" and "Child and
 *   embedded windows remain invisible until they're parented". So the bay hides
 *   with the camera, and if parenting fails it is destroyed - never left
 *   visible on its own. A child's POSITION is relative to its parent's.
 *
 * WHY WE DO NOT WRITE INTO THE BUFFER
 *   A previous version composed the layout into buffer rows 480..959. The
 *   capture engine writes there too (measured 2026-11-20: source rows 0..3 at
 *   buffer rows 483..486). Whether the buffer is a true multi-frame ring is not
 *   settled (the review's F1.5), but either way the rows are not ours.
 *   Do not reintroduce any pixel writes.
 *
 * COST ON THE CAMERA'S INTERRUPT THREAD
 *   screen_post_window runs on SS_RVC's IRQ-0x38 service thread (priority 100).
 *   Window properties are pushed only when a value changes, the config file is
 *   re-read every `reread` posts (default 60, 0 = never after start), and the
 *   only steady-state logging is the opt-in `stats=1` rate line every ~10 s.
 *
 * SAFETY
 *   Any missing Screen entry point skips the feature that needs it. If the real
 *   screen_post_window cannot be resolved at all there is nothing to call; that
 *   is logged ("init ... ready 0") so a dead camera is never silent.
 *
 * SLOT BUILD (-DYAFC_SLOT, libRCN_DiagnosticsLib.so)
 *   Defines no Screen symbols. Its constructor checks that the main executable
 *   is the stock SS_RVC (load address, segments, text hash), that no DISABLE
 *   file exists and that SS_RVC's own GOT slots for screen_post_window and
 *   screen_create_window equal libscreen's, then overwrites those two slots with
 *   static wrappers that call the real function first and return its result.
 *   Every refusal is logged. See ../docs/ARCHITECTURE.md.
 */

typedef unsigned int u32;

/* ---- Screen constants (see toolchain/screen.h) ---- */
#define SP_BUFFER_SIZE      5
#define SP_STRIDE           44
#define SP_POSITION         35   /* [D] QNX property enum; matches the dump */
#define SP_SIZE             40   /* [D] */
#define SP_SOURCE_POSITION  41
#define SP_SOURCE_SIZE      42
#define SP_VISIBLE          51
#define SP_ZORDER           54
#define SP_TRANSPARENCY     46   /* [screen.h] SCREEN_PROPERTY_TRANSPARENCY */
#define SP_SENSITIVITY      57   /* [screen.h] SCREEN_PROPERTY_SENSITIVITY */
#define SP_ID_STRING        20   /* [screen.h] SCREEN_PROPERTY_ID_STRING */
#define TRANSPARENCY_SOURCE 0    /* QNX screen_transparency_t: SOURCE = 0 (docs 7.1) */
#define SENSITIVITY_NEVER   2    /* [screen.h] SCREEN_SENSITIVITY_NEVER */

#define SCREEN_CHILD_WINDOW 1    /* [D] QNX Screen window types: APPLICATION 0, CHILD 1 */

/* Hook names. The LD_PRELOAD build exports the Screen names; the slot build keeps
 * its wrappers static and installs them into SS_RVC's GOT. */
#ifdef YAFC_SLOT
#define HOOK_POST   hook_post_window
#define HOOK_CREATE hook_create_window
#define HOOK_ATTR   static
#else
#define HOOK_POST   screen_post_window
#define HOOK_CREATE screen_create_window
#define HOOK_ATTR   __attribute__((visibility("default")))
#endif

#ifdef YAFC_SLOT
/* Identity of the camera binary: 294,564 B, sha256 0dd3c0cd..., read from a
 * copy of the radio's own binary. [E] readelf -l / -r on that file:
 * ET_EXEC, text LOAD 0x100000 filesz 0x43800 (R E), RW LOAD 0x144800 memsz
 * 0x3838, JUMP_SLOT screen_post_window 0x144d80, screen_create_window 0x144dd4.
 * The hash is FNV-1a 64 over the text LOAD. The host test overrides these. */
#ifndef SLOT_EXE_BASE
#define SLOT_EXE_BASE   0x100000UL
#define SLOT_TEXT_HASH  0xf3442ba773f7b837ULL
#define SLOT_GOT_POST   ((void **)0x144d80)
#define SLOT_GOT_CREATE ((void **)0x144dd4)
#endif
#define SLOT_TEXT_VADDR 0x100000u
#define SLOT_TEXT_SIZE  0x43800u
#define SLOT_RW_VADDR   0x144800u
#define SLOT_RW_MEMSZ   0x3838u
#define SLOT_MAX_STRIKES 3
#define SLOT_VERIFY_POSTS 60
#endif

#define CLOCK_MONOTONIC_QNX 2    /* as toolchain/winlist.c */

/* ---- libc / loader ---- */
extern void *dlopen(const char *path, int mode);
extern void *dlsym(void *handle, const char *name);
extern int   open(const char *path, int flags, ...);
extern long  read(int fd, void *buf, unsigned long n);
extern long  write(int fd, const void *buf, unsigned long n);
extern int   close(int fd);
extern int   getpid(void);
extern void  abort(void);
struct qnx_timespec { int tv_sec; int tv_nsec; };   /* as toolchain/winlist.c */
extern int   clock_gettime(int, struct qnx_timespec *);
extern int   unlink(const char *path);
#ifdef YAFC_SLOT
struct pc_phdr { u32 p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags, p_align; };
struct pc_dl_info {   /* leading fields of QNX/glibc struct dl_phdr_info */
    unsigned long dlpi_addr;
    const char *dlpi_name;
    const struct pc_phdr *dlpi_phdr;
    unsigned short dlpi_phnum;
};
extern int dl_iterate_phdr(int (*cb)(struct pc_dl_info *, unsigned long, void *), void *data);
#endif

/* ---- resolved Screen entry points ----
 * Prototypes from the QNX Screen reference (7.1/8.0, identical):
 *   screen_create_window_type(screen_window_t *pwin, screen_context_t ctx, int type)
 *   screen_create_window_group(screen_window_t win, const char *name)
 *   screen_join_window_group(screen_window_t win, const char *name)
 *   screen_share_window_buffers(screen_window_t win, screen_window_t share)
 *   screen_destroy_window(screen_window_t win)
 *   screen_flush_context(screen_context_t ctx, int flags)
 * An earlier build called join_group(&win, other_window) - a pointer-to-handle
 * as the window and a window handle as the name string. Undefined behaviour
 * inside a safety-critical process; do not reintroduce. */
typedef int (*f_post)(void *, void *, int, const int *, int);
typedef int (*f_create_win)(void **, void *);
typedef int (*f_create_type)(void **, void *, int);
typedef int (*f_group)(void *, const char *);
typedef int (*f_join)(void *, const char *);
typedef int (*f_share)(void *, void *);
typedef int (*f_destroy)(void *);
typedef int (*f_flush)(void *, int);
typedef int (*f_get_iv)(void *, int, int *);
typedef int (*f_set_iv)(void *, int, const int *);
typedef int (*f_set_cv)(void *, int, int, const char *);
typedef int (*f_get_cv)(void *, int, int, char *);
typedef int (*f_set_pv)(void *, int, void **);
typedef int (*f_get_pv)(void *, int, void **);

static f_post        real_post;
static f_create_win  real_create_window;
static f_create_type real_create_type;
static f_group       real_create_group;
static f_join        real_join_group;
static f_share       real_share_buffers;
static f_destroy     real_destroy_window;
static f_flush       real_flush;
static f_get_iv      get_buf_iv;
static f_set_iv      set_win_iv;
static f_set_cv      set_win_cv;
static f_get_iv      get_win_iv;   /* read back what we set, for the self-heal */

#ifdef YAFC_SLOT
static f_get_cv      get_win_cv;   /* read a window's ID_STRING */
/* 1 once the posting window has ID_STRING "RVC_app" (decided on a post, once,
 * by one thread); g_cam_win is the only window we ever touch. */
static volatile int g_is_cam, g_ident_busy;
static int   g_ident_done, g_ident_tries;
static void *g_cam_win;
static int   g_inflight;           /* strike marker written, not yet cleared */
static int   g_slot_dead;          /* marker unwritable: never apply the hero */
static char  g_boot_txt[16];       /* /fs/rwdata/.flags/boot_count, for the marker */
static int   g_boot_len;
#endif

/* The camera process's Screen context, captured by interposing
 * screen_create_window: a window exposes no context property. */
static void *g_ctx;

/* mode: 0 pass, 1 diag, 2 compose */
static int g_mode;
static int g_ready;
static volatile int g_resolved;      /* resolve() has finished; published last */
static int g_diag_done;
static int g_first_post_logged;
static int g_tick;
static int g_reread = 60;   /* posts between config re-reads; 0 = never */
/* Wall-clock minimum between re-reads. 1000 ms was too slow for a view switch:
 * the view buttons write the geometry into camera.conf and only then ask Ford for
 * the new view, so for up to a second Ford's own layout was on screen before ours
 * landed, so the previous layout stayed on screen for up to a second. 150 ms
 * bounds that to a couple of frames and costs ~7 small file reads
 * a second while a camera view is up. */
static int g_reread_ms = 150;
static int g_stats;         /* stats=1: log the post rate every ~10 s */
static int g_bay_id;        /* bay_id=1: set ID_STRING on the bay (default off) */
static long long g_last_read_ms; /* monotonic ms of the last read_config */

/* Whether the view currently selected actually COMBINES a camera with 360.
 * Default 1 keeps the behaviour from before the settings page offered a view
 * list: compose whenever the mode says so. */
static int g_view_compose = 1;

/* Rectangles, x,y,w,h. cam_dst and bay_dst are SCREEN coordinates (window
 * POSITION/SIZE), cam_src and bay_src are buffer coordinates. Overridden by
 * camera.conf. bay_dst with zero width or height disables the bay. */
static int g_cam_src[4] = {0, 0, 438, 480};
static int g_cam_dst[4] = {0, 71, 800, 527};
static int g_bay_src[4] = {448, 0, 272, 480};
static int g_bay_dst[4] = {0, 0, 0, 0};
/* sen_dst / tail_dst are still parsed so configs that carry them stay valid,
 * but nothing uses them since the pixel compose was removed. */
static int g_sen_dst[4];
static int g_tail_dst[4];

/* Set when the window geometry needs (re)applying: on start, when a rectangle
 * VALUE changes, and after a restore. Never merely because a file was read:
 * each set is a flushing call into the compositor on the IRQ thread. */
static int g_geo_dirty = 1;
/* 1 while the camera window carries our geometry, for the restore branch. */
static int g_geo_ours;
/* Counters for the stats line. */
static int g_geo_pushes;
/* Self-heal cadence and the bounded bay-retry budget (see the compose branch). */
static int g_geo_check_tick;
static int g_bay_retries;
/* The window's own geometry (position, size, source position, source size),
 * read before ours is first applied and restored exactly on every exit. */
static int g_orig[4][2];
static int g_orig_valid;
static int g_orig_tries;
static int g_restore_fail;
static int g_ours_posts;         /* posts seen while our geometry is applied */
static volatile int g_busy;      /* one thread at a time runs the logic */
static void *g_screen_h;

/* ---------------------------------------------------------------- utils */

static int starts_with(const char *s, const char *p)
{
    while (*p) if (*s++ != *p++) return 0;
    return 1;
}

/* The view names that mean "camera AND 360 in one picture". Only the 360 family
 * is composed here; single, wide, 360-only and split views pass through to stock
 * (see the long note in the git history of this function). */
static int view_is_combined(const char *v)
{
    return starts_with(v, "rear360") || starts_with(v, "front360");
}

static int rect_eq(const int *a, const int *b)
{
    return a[0] == b[0] && a[1] == b[1] && a[2] == b[2] && a[3] == b[3];
}

static void rect_copy(int *d, const int *s)
{
    d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = s[3];
}

/* --------------------------------------------------------------- diag */

#define LOG_PATH "/fs/rwdata/yafc/post.log"

static int put_num(char *line, unsigned i, int v)
{
    char num[12];
    int j = 0;
    unsigned u;
    if (v < 0) { line[i++] = '-'; u = (unsigned)(-(v + 1)) + 1u; }
    else u = (unsigned)v;
    do { num[j++] = (char)('0' + u % 10u); u /= 10u; } while (u);
    while (j) line[i++] = num[--j];
    return (int)i;
}

/* Appends "msg a b c\n". Bounded: the message is truncated to fit. */
static void diag_log(const char *msg, int a, int b, int c)
{
    char line[160];
    unsigned i = 0;
    int k, v;

    while (*msg && i < 110) line[i++] = *msg++;
    for (k = 0; k < 3; k++) {
        v = (k == 0) ? a : (k == 1) ? b : c;
        line[i++] = ' ';
        i = (unsigned)put_num(line, i, v);
    }
    line[i++] = '\n';
    {
        int fd = open(LOG_PATH, 0x109 /* O_WRONLY|O_CREAT|O_APPEND */, 0644);
        if (fd >= 0) { write(fd, line, i); close(fd); }
    }
}

/* ------------------------------------------------------------- config */

#define CONF_MAX 4096   /* M-14: a 4095-byte config must still parse */
#define CONF_PATH "/fs/rwdata/yafc/camera.conf"

/* Monotonic milliseconds, for the wall-clock config re-read gate. The radio's
 * clock_gettime uses the QNX timespec layout declared above. */
static long long now_ms(void)
{
    struct qnx_timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC_QNX, &ts) != 0) return 0;
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Parse "x,y,w,h" or "x y w h" into r[4]. Returns 0 on success. Negative
 * numbers are rejected (no window geometry here is negative). */
static int parse_rect(const char *v, int *r)
{
    int i, t[4];
    for (i = 0; i < 4; i++) {
        int n = 0, got = 0;
        while (*v == ',' || *v == ' ' || *v == '\t') v++;
        while (*v >= '0' && *v <= '9' && n < 100000) { n = n * 10 + (*v - '0'); v++; got = 1; }
        if (!got) return -1;
        t[i] = n;
    }
    rect_copy(r, t);
    return 0;
}

static int parse_int(const char *v, int dflt)
{
    int n = 0, got = 0;
    while (*v >= '0' && *v <= '9' && n < 100000) { n = n * 10 + (*v - '0'); v++; got = 1; }
    return got ? n : dflt;
}

/* Parse one rect key into tmp, and mark the geometry dirty only if the VALUE
 * differs from what is in force. */
static void take_rect(const char *v, int *cur)
{
    int t[4];
    if (parse_rect(v, t) != 0) return;
    if (!rect_eq(t, cur)) { rect_copy(cur, t); g_geo_dirty = 1; }
}

static void read_config(void)
{
    char buf[CONF_MAX];
    long n = 0;
    int fd, view_compose = 1, mode = 0, reread = 60, stats = 0, bay_id = 0;

    fd = open(CONF_PATH, 0 /* O_RDONLY */);
    if (fd < 0) fd = open("camera.conf", 0);   /* PC test / development fallback */
    if (fd < 0) return;
    n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return;
    /* M-14: a full buffer means the file is larger than we can parse safely.
     * A partial last line could silently drop a key; keep the last good config. */
    if (n >= (long)sizeof(buf) - 1) {
        diag_log("config too large/truncated", (int)n, 0, 0);
        return;
    }
    buf[n] = 0;

    /* Walk lines. No quoting, no spaces around '=', first match per line. The
     * file is the source of truth, so absent keys revert to their defaults. */
    {
        char *p = buf;
        while (*p) {
            char *end = p;
            while (*end && *end != '\n' && *end != '\r') end++;
            if (starts_with(p, "mode=")) {
                const char *v = p + 5;
                if (starts_with(v, "diag")) mode = 1;
                else if (starts_with(v, "compose")) mode = 2;
                else mode = 0;
            }
            if (starts_with(p, "view="))     view_compose = view_is_combined(p + 5);
            if (starts_with(p, "reread="))   reread = parse_int(p + 7, 60);
            if (starts_with(p, "stats="))    stats = (p[6] == '1');
            if (starts_with(p, "bay_id="))   bay_id = (p[7] == '1');
            if (starts_with(p, "cam_src="))  take_rect(p + 8,  g_cam_src);
            if (starts_with(p, "cam_dst="))  take_rect(p + 8,  g_cam_dst);
            if (starts_with(p, "bay_src="))  take_rect(p + 8,  g_bay_src);
            if (starts_with(p, "bay_dst="))  take_rect(p + 8,  g_bay_dst);
            if (starts_with(p, "sen_dst="))  parse_rect(p + 8,  g_sen_dst);
            if (starts_with(p, "tail_dst=")) parse_rect(p + 9,  g_tail_dst);
            if (*end == 0) break;
            p = end + 1;
        }
    }
    g_mode = mode;
    g_view_compose = view_compose;
    g_reread = reread;
    g_stats = stats;
    g_bay_id = bay_id;
    g_last_read_ms = now_ms();
}

/* ------------------------------------------------------------ resolve */

/* The hooks' own addresses, for the recursion guard below. */
HOOK_ATTR int HOOK_POST(void *win, void *buf, int count, const int *rects, int flags);
HOOK_ATTR int HOOK_CREATE(void **win, void *ctx);

/* Safe to run from several threads: results go to locals, the globals are
 * written with their final values, and g_resolved is published last. */
static void resolve(void)
{
    void *h;
    f_post p = 0;
    f_create_win c = 0;
    if (g_resolved) return;
    h = dlopen("libscreen.so.1", 0x0202 /* RTLD_NOW | RTLD_LOCAL, see scrprobe */);
    if (h) {
        p                   = (f_post)        dlsym(h, "screen_post_window");
        get_buf_iv          = (f_get_iv)      dlsym(h, "screen_get_buffer_property_iv");
        set_win_iv          = (f_set_iv)      dlsym(h, "screen_set_window_property_iv");
        c                   = (f_create_win)  dlsym(h, "screen_create_window");
        real_create_type    = (f_create_type) dlsym(h, "screen_create_window_type");
        real_create_group   = (f_group)       dlsym(h, "screen_create_window_group");
        real_join_group     = (f_join)        dlsym(h, "screen_join_window_group");
        real_share_buffers  = (f_share)       dlsym(h, "screen_share_window_buffers");
        real_destroy_window = (f_destroy)     dlsym(h, "screen_destroy_window");
        real_flush          = (f_flush)       dlsym(h, "screen_flush_context");
        set_win_cv          = (f_set_cv)      dlsym(h, "screen_set_window_property_cv");
        get_win_iv          = (f_get_iv)      dlsym(h, "screen_get_window_property_iv");
#ifdef YAFC_SLOT
        get_win_cv          = (f_get_cv)      dlsym(h, "screen_get_window_property_cv");
#endif
    }
    /* A leaked handle can hold our own definition; calling it would recurse. */
    if (p == (f_post)HOOK_POST) p = 0;
    if (c == (f_create_win)HOOK_CREATE) c = 0;
    /* M-16: RTLD_NEXT is the next definition in the lookup order. If dlopen
     * failed (or returned our own definition), this is the fallback. */
    if (!p) {
        p = (f_post) dlsym((void *) -1, "screen_post_window");
        if (p == (f_post)HOOK_POST) p = 0;
    }
    if (!c) {
        c = (f_create_win) dlsym((void *) -1, "screen_create_window");
        if (c == (f_create_win)HOOK_CREATE) c = 0;
    }
    g_screen_h = h;
    real_create_window = c;
    real_post = p;
    g_ready = p != 0;
    __sync_synchronize();
    g_resolved = 1;
#ifndef YAFC_SLOT
    diag_log("init ready/handle/pid", g_ready, h != 0, getpid());
#endif
}

/* ---------------------------------------------------- the bay child window */

static void *g_bay_win;
static int   g_bay_tried;      /* one attempt per (re)enable; reset on destroy */
static int   g_bay_shown;      /* the child is currently VISIBLE */
static int   g_group_made;     /* a window can parent only one group, ever */
static char  g_group_name[24];

static void make_group_name(void)
{
    /* "yafc-<pid>": unique per camera process, as the API requires. */
    const char *pre = "yafc-";
    unsigned i = 0;
    while (*pre) g_group_name[i++] = *pre++;
    i = (unsigned)put_num(g_group_name, i, getpid());
    g_group_name[i] = 0;
}

/* Hide, never destroy. Measured on the radio 2026-11-22: a child created and
 * joined AFTER the parent camera window has been posted reports every property
 * set as successful - post.log "bay child setfail/w/h 0 ..." with fail 0 - and is
 * still never painted. Only the first creation, the one at boot, paints. So that
 * creation is kept for the life of the process and the view changes only toggle
 * its VISIBLE property. Destroying it again would need a second creation that
 * cannot show. */
static void bay_hide(const char *why)
{
    int vis = 0, fail = 0;
    /* Called on every frame while the view is not ours, so it must be silent and
     * free when the bay is already hidden. */
    if (!g_bay_win || !g_bay_shown) return;
    if (set_win_iv) fail = set_win_iv(g_bay_win, SP_VISIBLE, &vis);
    if (real_flush && g_ctx) real_flush(g_ctx, 0);
    g_bay_shown = 0;
    diag_log(why, fail, 0, 0);
}

/* Convert a value in SCREEN pixels into the bay child's own units.
 *
 * A child window's rectangle is in its parent's SOURCE-content pixels, and the
 * compositor then applies the parent's own scale (SIZE / SOURCE_SIZE) on top
 * (measured as dump 400 on this radio family by an independent implementation,
 * rvc_layout.js win2Rect(); the parent does not clip the child). So a screen
 * offset or size DIVIDES by that scale - subtracting the parent's position is
 * not enough once the camera window is scaled (ours is 800x527 over 720x474,
 * ~1.11x). Scale 1 returns v unchanged. `ceil_` is for a width: the reference
 * rounds offsets and height but ceil()s width. */
static int to_parent_units(int v, int dst, int src, int ceil_)
{
    long long n;
    if (dst <= 0 || src <= 0) return v;
    n = (long long)v * src;              /* v / (dst/src) */
    if (ceil_) {
        long long q = n / dst;
        if (n % dst > 0) q++;
        return (int)q;
    }
    if (n >= 0) return (int)((n + dst / 2) / dst);
    return (int)(-(((-n) + (dst - 1) / 2) / dst));
}

/* Position the bay in its parent's content units. Returns a bit mask of failed
 * sets, logged once by the caller. */
static int bay_apply_geometry(void)
{
    int sp[2], ss[2], wp[2], ws[2], fail = 0;
    sp[0] = g_bay_src[0]; sp[1] = g_bay_src[1];
    ss[0] = g_bay_src[2]; ss[1] = g_bay_src[3];
    wp[0] = to_parent_units(g_bay_dst[0] - g_cam_dst[0], g_cam_dst[2], g_cam_src[2], 0);
    wp[1] = to_parent_units(g_bay_dst[1] - g_cam_dst[1], g_cam_dst[3], g_cam_src[3], 0);
    ws[0] = to_parent_units(g_bay_dst[2],                 g_cam_dst[2], g_cam_src[2], 1);
    ws[1] = to_parent_units(g_bay_dst[3],                 g_cam_dst[3], g_cam_src[3], 0);
    /* A positive requested size can round to zero child units when the parent
     * scale is large (1 screen px of a 1200-high parent is 0.4 of a 474-high
     * source). SIZE 0 is a window the compositor may never show, so an enabled
     * bay keeps at least one unit. */
    if (g_bay_dst[2] > 0 && ws[0] < 1) ws[0] = 1;
    if (g_bay_dst[3] > 0 && ws[1] < 1) ws[1] = 1;
    if (set_win_iv(g_bay_win, SP_SOURCE_POSITION, sp)) fail |= 1;
    if (set_win_iv(g_bay_win, SP_SOURCE_SIZE,     ss)) fail |= 2;
    if (set_win_iv(g_bay_win, SP_POSITION,        wp)) fail |= 4;
    if (set_win_iv(g_bay_win, SP_SIZE,            ws)) fail |= 8;
    {
        /* The child rect in parent units, so a wrong scale is visible in
         * post.log next to the screen rect above. */
        static int logged_units;
        if (!logged_units || fail) {
            logged_units = 1;
            diag_log("bay child units y/w/h", wp[1], ws[0], ws[1]);
        }
    }
    return fail;
}

static int bay_wanted(void)
{
    return g_bay_src[2] > 0 && g_bay_src[3] > 0 && g_bay_dst[2] > 0 && g_bay_dst[3] > 0;
}

static void ensure_bay_window(void *cam_win)
{
    void *w = 0;
    int z = 1, vis = 1, fail;

    if (g_bay_win) {
        /* Already created: show the SAME child again rather than making a second
         * one that can never paint (see bay_hide). Geometry is re-applied in case
         * the view change moved or resized it. */
        if (g_bay_shown) return;
        if (!set_win_iv) return;
        if (set_win_iv(g_bay_win, SP_VISIBLE, &vis)) {
            diag_log("bay show failed", 0, 0, 0);
            return;
        }
        bay_apply_geometry();
        if (real_flush && g_ctx) real_flush(g_ctx, 0);
        g_bay_shown = 1;
        diag_log("bay shown", g_bay_dst[2], g_bay_dst[3], 0);
        return;
    }
    if (g_bay_tried || !bay_wanted()) return;
    g_bay_tried = 1;

    if (!g_ctx || !set_win_iv || !real_create_type || !real_create_group ||
        !real_join_group || !real_share_buffers || !real_destroy_window) {
        diag_log("bay missing ctx/type/group", !!g_ctx, !!real_create_type, !!real_create_group);
        return;
    }

    if (!g_group_made) {
        make_group_name();
        if (real_create_group(cam_win, g_group_name) != 0) {
            diag_log("bay group create failed", 0, 0, 0);
            return;
        }
        g_group_made = 1;
    }

    if (real_create_type(&w, g_ctx, SCREEN_CHILD_WINDOW) != 0 || !w) {
        diag_log("bay create failed", 0, 0, 0);
        return;
    }
    /* Join before anything can make it visible: an unparented child stays
     * invisible, so every failure below leaves nothing on screen. */
    if (real_join_group(w, g_group_name) != 0) {
        real_destroy_window(w);
        diag_log("bay join failed", 0, 0, 0);
        return;
    }
    if (real_share_buffers(w, cam_win) != 0) {
        real_destroy_window(w);
        diag_log("bay share failed", 0, 0, 0);
        return;
    }
    g_bay_win = w;
    fail = bay_apply_geometry();
    {
        /* M-12: the bay shares the camera's buffer. SOURCE transparency is an
         * opaque blit (no blend); NEVER means it never takes input. The radio's
         * QNX 6.5-era libscreen may not know these properties; each set is
         * logged as a bitmask so a partial failure is visible. */
        int transp = TRANSPARENCY_SOURCE;
        int sens = SENSITIVITY_NEVER;
        if (set_win_iv(w, SP_TRANSPARENCY, &transp)) fail |= 64;
        if (set_win_iv(w, SP_SENSITIVITY, &sens))    fail |= 128;
    }
    if (set_win_iv(w, SP_ZORDER, &z))    fail |= 16;   /* relative to the parent */
    if (set_win_iv(w, SP_VISIBLE, &vis)) fail |= 32;   /* still controlled by parent */
    else g_bay_shown = 1;                              /* the one creation that paints */
    if (g_bay_id && set_win_cv) {
        /* "RVC_bay" + NUL = 8. Off by default: an unknown ID_STRING may confuse
         * a window manager that tracks camera windows by name. */
        if (set_win_cv(w, SP_ID_STRING, 8, "RVC_bay")) fail |= 256;
    }
    if (real_flush) real_flush(g_ctx, 0);
    /* No post for the bay, deliberately: only the buffer owner may post
     * (screen_share_window_buffers doc); measured live as "bay post failed -1". */
    diag_log("bay child setfail/w/h", fail, g_bay_dst[2], g_bay_dst[3]);
}

/* ----------------------------------------------------------- geometry */

/* 1 = the window still carries our geometry, 0 = something reset it, -1 = cannot
 * read. A read failure counts as "ours" (1/-1 are both not 0) so a Screen that
 * does not answer can never start a set storm. */
static int geometry_is_ours(void *win)
{
    int p[2] = {0, 0}, s[2] = {0, 0}, sp[2] = {0, 0}, ss[2] = {0, 0};
    if (!win || !get_win_iv) return -1;
    if (get_win_iv(win, SP_POSITION, p)) return -1;
    if (get_win_iv(win, SP_SIZE, s)) return -1;
    if (get_win_iv(win, SP_SOURCE_POSITION, sp)) return -1;
    if (get_win_iv(win, SP_SOURCE_SIZE, ss)) return -1;
    if (p[0] != g_cam_dst[0] || p[1] != g_cam_dst[1]) return 0;
    if (s[0] != g_cam_dst[2] || s[1] != g_cam_dst[3]) return 0;
    if (sp[0] != g_cam_src[0] || sp[1] != g_cam_src[1]) return 0;
    if (ss[0] != g_cam_src[2] || ss[1] != g_cam_src[3]) return 0;
    return 1;
}

static void apply_camera_geometry(void *win)
{
    int sp[2], ss[2], wp[2], ws[2], fail = 0;
    sp[0] = g_cam_src[0]; sp[1] = g_cam_src[1];
    ss[0] = g_cam_src[2]; ss[1] = g_cam_src[3];
    wp[0] = g_cam_dst[0]; wp[1] = g_cam_dst[1];
    ws[0] = g_cam_dst[2]; ws[1] = g_cam_dst[3];
    if (set_win_iv(win, SP_SOURCE_POSITION, sp)) fail |= 1;
    if (set_win_iv(win, SP_SOURCE_SIZE,     ss)) fail |= 2;
    if (set_win_iv(win, SP_POSITION,        wp)) fail |= 4;
    if (set_win_iv(win, SP_SIZE,            ws)) fail |= 8;
    g_geo_pushes++;
    g_geo_ours = 1;
    {
        static int logged;
        if (!logged || fail) { logged = 1; diag_log("geometry setfail/pushes", fail, g_geo_pushes, 0); }
    }
}

/* Read the four rectangles into r. Returns 0 only if every read worked and
 * the sizes are positive: a Screen that cannot tell us the window's own
 * geometry is a Screen we must not move the window on. */
static int read_geometry(void *win, int r[4][2])
{
    static const int props[4] = { SP_POSITION, SP_SIZE, SP_SOURCE_POSITION, SP_SOURCE_SIZE };
    int i, t[4][2];
    if (!win || !get_win_iv) return -1;
    for (i = 0; i < 4; i++) {
        t[i][0] = t[i][1] = 0;
        if (get_win_iv(win, props[i], t[i])) return -1;
    }
    if (t[1][0] <= 0 || t[1][1] <= 0 || t[3][0] <= 0 || t[3][1] <= 0) return -1;
    for (i = 0; i < 4; i++) { r[i][0] = t[i][0]; r[i][1] = t[i][1]; }
    return 0;
}

#ifdef YAFC_SLOT
#define SLOT_DIR       "/fs/rwdata/yafc/"
#define DISABLE_PATH   SLOT_DIR "DISABLE"
#define INFLIGHT_PATH  SLOT_DIR "slot-inflight"
#define STRIKES_PATH   SLOT_DIR "slot-strikes"
#define BOOT_PATH      "/fs/rwdata/.flags/boot_count"

/* Written before our first geometry change; a marker still there at the next
 * start means that run never reached SLOT_VERIFY_POSTS good posts. */
static int marker_write(void)
{
    long n;
    int fd = open(INFLIGHT_PATH, 0x101 /* O_WRONLY|O_CREAT */, 0644);
    if (fd < 0) return 0;
    n = write(fd, g_boot_txt, (unsigned long)g_boot_len);
    close(fd);
    g_ours_posts = 0;
    return n == g_boot_len;
}

static void marker_clear(void)
{
    if (!g_inflight) return;
    unlink(INFLIGHT_PATH);
    unlink(STRIKES_PATH);
    g_inflight = 0;
}
#else
#define marker_clear() ((void)0)
#endif

/* Put the window back exactly as the app had it. If something already reset
 * our geometry the app's own is in place and there is nothing to undo. */
static void restore_stock_geometry(void *win)
{
    int ok = 1;
    if (g_orig_valid && geometry_is_ours(win) != 0) {
        ok = set_win_iv(win, SP_SOURCE_POSITION, g_orig[2]) == 0;
        ok = set_win_iv(win, SP_SOURCE_SIZE,     g_orig[3]) == 0 && ok;
        ok = set_win_iv(win, SP_POSITION,        g_orig[0]) == 0 && ok;
        ok = set_win_iv(win, SP_SIZE,            g_orig[1]) == 0 && ok;
    }
    if (!ok && ++g_restore_fail < 5) return;   /* retry a few posts, never a storm */
    if (!ok) diag_log("restore failed; giving up", g_restore_fail, 0, 0);
    g_restore_fail = 0;
    g_geo_ours = 0;
    g_geo_dirty = 1;   /* re-apply ours when a combined view returns */
    if (ok) marker_clear();
}

/* ---------------------------------------------------------------- stats */

static int g_stat_posts, g_stat_t0;

static void stats_tick(void)
{
    struct qnx_timespec ts;
    if (!g_stats) { g_stat_t0 = 0; return; }
    g_stat_posts++;
    if (clock_gettime(CLOCK_MONOTONIC_QNX, &ts) != 0) return;
    if (!g_stat_t0) { g_stat_t0 = ts.tv_sec; g_stat_posts = 0; return; }
    if (ts.tv_sec - g_stat_t0 >= 10) {
        diag_log("rate posts/secs/geo", g_stat_posts, ts.tv_sec - g_stat_t0, g_geo_pushes);
        g_stat_t0 = ts.tv_sec;
        g_stat_posts = 0;
    }
}

/* ------------------------------------------------------- the post-time logic */

static void post_logic(void *win, void *buf)
{
    if (!g_first_post_logged) {
        g_first_post_logged = 1;
        diag_log("first post mode/view/ctx", g_mode, g_view_compose, !!g_ctx);
    }
    stats_tick();

    if (g_mode == 1 && !g_diag_done) {
        int size[2] = {0, 0}, stride = 0;
        g_diag_done = 1;
        if (get_buf_iv) {
            get_buf_iv(buf, SP_BUFFER_SIZE, size);
            get_buf_iv(buf, SP_STRIDE, &stride);
            diag_log("buf", size[0], size[1], stride);
        }
    }

    /* Live tuning, in every mode so that leaving compose (mode=pass) reverts
     * and entering it applies. M-14: the post count is a cheap gate; the wall
     * clock keeps a fast camera from reading the file hundreds of times a
     * second. */
    if (g_reread > 0 && ++g_tick >= g_reread) {
        g_tick = 0;
        if (now_ms() - g_last_read_ms >= g_reread_ms) read_config();
    }

    if (g_mode != 2 || !g_view_compose || !set_win_iv) {
        /* Not ours: hide the bay and hand the window back once. Never destroy
         * it - a re-created child cannot paint (see bay_hide). */
        bay_hide(g_mode == 2 ? "bay hidden: view not combined" : "bay hidden: mode not compose");
        if (g_geo_ours) restore_stock_geometry(win);
        return;
    }

#ifdef YAFC_SLOT
    if (g_slot_dead) return;
#endif
    if (!g_orig_valid) {
        /* The app's own geometry first; without it there is nothing to go back
         * to. Retried every 8th post, 30 times at most. */
        if (g_orig_tries >= 240 || (g_orig_tries++ & 7) != 0) return;
        if (read_geometry(win, g_orig) != 0) {
            if (g_orig_tries == 1) diag_log("window geometry unreadable; hero not applied", 0, 0, 0);
            return;
        }
        g_orig_valid = 1;
    }
    if (g_bay_win && !bay_wanted()) bay_hide("bay hidden: bay_dst off");
    /* Self-heal. SS_RVC re-asserts its own geometry at every session
     * start, and the bay's parent can come back without our bay, so
     * "apply once at start" left the composed view needing several view
     * changes before it settled, so it is now re-checked on a tick.
     * Checked every 8th post: cheap, and heals within ~150 ms. A read
     * that fails counts as ours, so this can never cause a set storm. */
    if ((++g_geo_check_tick & 7) == 0) {
        int own = geometry_is_ours(win);
        if (own == 0) {
            g_geo_dirty = 1;
            /* Logged every time: this is a real event (it means the app
             * re-asserted its own geometry), it is rare - at most once
             * per session - and without it a convergence problem is
             * invisible in post.log. */
            diag_log("geometry was reset; re-applying", g_geo_pushes, 0, 0);
        }
#ifdef YAFC_SLOT
        else if (own == 1 && g_inflight && g_ours_posts >= SLOT_VERIFY_POSTS) {
            diag_log("slot verified posts", g_ours_posts, 0, 0);
            marker_clear();
        }
#endif
        /* A missing bay is retried on the same tick, a bounded number of
         * times: the first attempt can land before the window manager is
         * ready, and one failure used to disable the bay until a destroy. */
        if (!g_bay_win && bay_wanted() && g_bay_retries < 30) {
            g_bay_retries++;
            g_bay_tried = 0;
        }
    }
    if (g_geo_dirty) {
#ifdef YAFC_SLOT
        if (!g_inflight) {
            if (!marker_write()) {
                diag_log("slot marker write failed; hero not applied", 0, 0, 0);
                g_slot_dead = 1;
                return;
            }
            g_inflight = 1;
        }
#endif
        g_geo_dirty = 0;
        apply_camera_geometry(win);
        if (g_bay_win) {
            int fail = bay_apply_geometry();
            if (real_flush) real_flush(g_ctx, 0);
            if (fail) diag_log("bay geometry setfail", fail, 0, 0);
        }
    }
    ensure_bay_window(win);
    if (g_geo_ours && g_ours_posts < 1000000) g_ours_posts++;
}

/* ------------------------------------------------------------ the hooks */

#ifdef YAFC_SLOT
/* Decide, once and on one thread, whether this process's posting window is the
 * camera's. Threads that arrive while another decides just pass through. */
static int slot_identify(void *win)
{
    char id[16];
    if (g_is_cam) return 1;
    if (g_ident_done) return 0;
    if (__sync_lock_test_and_set(&g_ident_busy, 1)) return 0;
    id[0] = 0; id[15] = 0;
    if (get_win_cv(win, SP_ID_STRING, sizeof id - 1, id) == 0 && starts_with(id, "RVC_app")) {
        g_cam_win = win;
        read_config();
        __sync_synchronize();
        g_is_cam = 1;
    } else if (++g_ident_tries >= 32) {
        g_ident_done = 1;
        diag_log("slot idle: no RVC_app window pid", getpid(), 0, 0);
    }
    __sync_lock_release(&g_ident_busy);
    return g_is_cam;
}
#endif

HOOK_ATTR int HOOK_CREATE(void **win, void *ctx)
{
    int rc;
    resolve();
    if (!real_create_window) return -1;   /* nothing to call */
    rc = real_create_window(win, ctx);
    if (rc == 0 && ctx) g_ctx = ctx;
    return rc;
}

/* The real post runs first and its result is returned untouched; everything
 * below is a side effect that may not change it. */
HOOK_ATTR int HOOK_POST(void *win, void *buf, int count, const int *rects, int flags)
{
    int rc;
    resolve();
    if (!g_ready) return -1;   /* logged at init; there is no real post to call */
    rc = real_post(win, buf, count, rects, flags);
    if (rc != 0) return rc;
#ifdef YAFC_SLOT
    if (!g_is_cam && !slot_identify(win)) return rc;
    __sync_synchronize();
    if (win != g_cam_win) return rc;
#endif
    if (__sync_lock_test_and_set(&g_busy, 1)) return rc;
    post_logic(win, buf);
    __sync_lock_release(&g_busy);
    return rc;
}

/* ------------------------------------------------------------- constructor */

#ifdef YAFC_SLOT
static int file_exists(const char *path)
{
    int fd = open(path, 0 /* O_RDONLY */);
    if (fd < 0) return 0;
    close(fd);
    return 1;
}

static void touch(const char *path)
{
    int fd = open(path, 0x101 /* O_WRONLY|O_CREAT */, 0644);
    if (fd >= 0) { write(fd, "x", 1); close(fd); }
}

/* One byte appended per strike; the file length is the count. */
static int strike_add(void)
{
    char b[8];
    int n = 0;
    int fd = open(STRIKES_PATH, 0x109 /* O_WRONLY|O_CREAT|O_APPEND */, 0644);
    if (fd >= 0) { write(fd, "x", 1); close(fd); }
    fd = open(STRIKES_PATH, 0);
    if (fd >= 0) {
        long r = read(fd, b, sizeof b);
        close(fd);
        if (r > 0) n = (int)r;
    }
    return n;
}

/* First object of dl_iterate_phdr is the main executable. */
static int exe_probe(struct pc_dl_info *info, unsigned long size, void *data)
{
    unsigned i;
    int text = 0, rw = 0;
    unsigned long base = 0;
    (void)size;
    for (i = 0; i < info->dlpi_phnum && i < 64; i++) {
        const struct pc_phdr *ph = &info->dlpi_phdr[i];
        if (ph->p_type != 1 /* PT_LOAD */) continue;
        if ((ph->p_flags & 3) == 1 && ph->p_vaddr == SLOT_TEXT_VADDR && ph->p_filesz == SLOT_TEXT_SIZE) {
            text = 1;
            base = info->dlpi_addr + ph->p_vaddr;
        } else if ((ph->p_flags & 2) && ph->p_vaddr == SLOT_RW_VADDR && ph->p_memsz == SLOT_RW_MEMSZ) {
            rw = 1;
        }
    }
    *(int *)data = text && rw && base == SLOT_EXE_BASE;
    return 1;
}

static int exe_text_ok(void)
{
    const unsigned char *p = (const unsigned char *)SLOT_EXE_BASE;
    unsigned long long h = 0xcbf29ce484222325ULL;
    unsigned i;
    for (i = 0; i < SLOT_TEXT_SIZE; i++) h = (h ^ p[i]) * 0x100000001b3ULL;
    return h == SLOT_TEXT_HASH;
}

static void slot_init(void)
{
    int pid = getpid(), ident = 0, strikes, fd, boot;
    long n;

    /* 1. identity. Memory at SLOT_EXE_BASE is read only after the program
     * headers say this is the stock layout: other processes never touch it. */
    dl_iterate_phdr(exe_probe, &ident);
    if (!ident || !exe_text_ok()) {
        diag_log("slot refused: not SS_RVC pid", pid, ident, 0);
        return;
    }
    /* 2. kill switch and strike counter */
    if (file_exists(DISABLE_PATH)) {
        diag_log("slot refused: DISABLE pid", pid, 0, 0);
        return;
    }
#ifdef YAFC_SLOT_LOG_ONLY
    diag_log("slot logging-only pid", pid, 0, 0);
    return;
#endif
    if (file_exists(INFLIGHT_PATH)) {   /* the previous run never verified */
        strikes = strike_add();
        unlink(INFLIGHT_PATH);
        if (strikes >= SLOT_MAX_STRIKES) {
            touch(DISABLE_PATH);
            unlink(STRIKES_PATH);
            diag_log("slot refused: strikes pid", pid, strikes, 0);
            return;
        }
        diag_log("slot strike pid", pid, strikes, 0);
    }
    /* 3. Screen, and the GOT slots must still hold libscreen's own addresses:
     * that proves relocation is done and nothing else patched them. */
    resolve();
    if (!g_screen_h || !g_ready || !real_create_window || !set_win_iv || !get_win_iv || !get_win_cv) {
        diag_log("slot refused: libscreen pid", pid, g_ready, g_screen_h != 0);
        return;
    }
    if (*SLOT_GOT_POST != (void *)real_post || *SLOT_GOT_CREATE != (void *)real_create_window) {
        diag_log("slot refused: GOT pid", pid, *SLOT_GOT_POST == (void *)real_post,
                 *SLOT_GOT_CREATE == (void *)real_create_window);
        return;
    }
    fd = open(BOOT_PATH, 0);
    n = -1;
    if (fd >= 0) { n = read(fd, g_boot_txt, sizeof g_boot_txt - 1); close(fd); }
    if (n <= 0) { g_boot_txt[0] = '?'; n = 1; }
    while (n > 1 && (g_boot_txt[n - 1] == '\n' || g_boot_txt[n - 1] == '\r')) n--;
    g_boot_txt[n] = 0;
    g_boot_len = (int)n;
    boot = parse_int(g_boot_txt, -1);
    __sync_synchronize();
    *SLOT_GOT_CREATE = (void *)HOOK_CREATE;
    *SLOT_GOT_POST = (void *)HOOK_POST;
    diag_log("slot active pid", pid, boot, 0);
}
#endif

__attribute__((constructor))
static void yafc_init(void)
{
#ifdef YAFC_SLOT
    /* Loaded by every consumer of libRCN_DiagnosticsLib.so: act only in the
     * stock camera. Never abort - a non-camera boot service must not be
     * killed by us. */
    slot_init();
#else
    read_config();
    resolve();
    /* M-16: a camera that cannot post is dead weight. In a non-pass mode the
     * boot hook's "did not start" path must be able to see that and restore
     * stock. Abort only here, before the window exists, so the process dies
     * cleanly rather than sitting silent. Pass mode changes nothing. */
    if (!g_ready && g_mode != 0) {
        diag_log("init unresolved in non-pass mode; aborting", g_mode, 0, 0);
        abort();
    }
#endif
}

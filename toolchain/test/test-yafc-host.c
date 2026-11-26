/* Host test for libyafc's state machine and the slot library's gates
 * (yafc-slot.c).
 *
 * Compiles yafc-slot.c into this program and drives the REAL hooks against
 * fake Screen functions that record every call. Proves call sequencing, the
 * config contract and every refusal path on the PC; it does not prove how the
 * radio's loader, libscreen or compositor behave.
 *
 * Two builds, run by run-host-test.sh:
 *   plain       the LD_PRELOAD interposer (exports screen_*)
 *   -DYAFC_SLOT  the slot library: no exports, the constructor patches SS_RVC's
 *               GOT. Here every Screen call goes through the (fake) GOT, in
 *               SS_RVC's own order: create, set ID_STRING, flush, set geometry,
 *               then N posts.
 *
 * Build:  cc -O1 -Wall -Wextra -pthread [-DYAFC_SLOT] -o test-yafc-host test-yafc-host.c
 * Run:    ./test-yafc-host            (needs a writable /tmp)
 * Optional: SS_RVC_STOCK=<path to the stock SS_RVC> also checks the recorded
 *           text hash against the real binary.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/stat.h>

/* ---- libc shims: the interposer uses QNX flag values and a QNX timespec ----
 * The library's constructor runs before main() moves into the temp dir, so
 * writes are dropped until g_in_sandbox is set; the radio paths map to the
 * working directory's basenames. */
static int g_in_sandbox;
static const char *map_path(const char *p)
{
    const char *slash = strrchr(p, '/');
    if (slash && !strncmp(p, "/fs/rwdata/", 11)) return slash + 1;
    return p;
}
static int fake_open(const char *p, int qflags, ...)
{
    int f = 0;
    if ((qflags & 3) == 1) {
        if (!g_in_sandbox) return -1;
        f |= O_WRONLY;
    }
    if (qflags & 0x100) f |= O_CREAT;     /* QNX O_CREAT */
    if (qflags & 0x08)  f |= O_APPEND;    /* QNX O_APPEND */
    return open(map_path(p), f, 0644);
}
__attribute__((unused)) static int fake_unlink(const char *p) { return unlink(map_path(p)); }
static int g_fake_pid = 4242;
static int fake_getpid(void) { return g_fake_pid; }
struct qnx_timespec;
static int g_now;
static int fake_clock(int c, struct qnx_timespec *t);
/* The interposer aborts deliberately when it cannot resolve libscreen in a
 * non-pass mode (M-16). Stub abort so the harness survives to assert it. */
static int g_aborted;
__attribute__((unused)) static void fake_abort(void) { g_aborted = 1; }
#define open fake_open
#define unlink fake_unlink
#define getpid fake_getpid
#define clock_gettime fake_clock
#define abort fake_abort

/* ---- fake loader + Screen ---- */
static int g_dlopen_ok = 1;
static int g_dlsym_ok = 1;   /* 0: dlsym also fails (the no-libscreen case) */
static int g_nocv;           /* 1: libscreen lacks screen_get_window_property_cv */
static void *g_self_post;    /* non-NULL: dlsym hands back this for screen_post_window */
static int g_slow_dlsym_us, g_slow_cv_us;
static int g_join_rc, g_group_rc, g_share_rc, g_set_rc, g_post_rc, g_create_rc;

#define MAXCALL 4096
static struct call { char fn[24]; void *win; int prop; int a, b; char str[32]; } calls[MAXCALL];
static int ncalls;
static pthread_mutex_t rec_mu = PTHREAD_MUTEX_INITIALIZER;
static void rec(const char *fn, void *win, int prop, int a, int b, const char *s)
{
    pthread_mutex_lock(&rec_mu);
    if (ncalls < MAXCALL) {
        snprintf(calls[ncalls].fn, sizeof calls[ncalls].fn, "%s", fn);
        calls[ncalls].win = win; calls[ncalls].prop = prop;
        calls[ncalls].a = a; calls[ncalls].b = b;
        snprintf(calls[ncalls].str, sizeof calls[ncalls].str, "%s", s ? s : "");
        ncalls++;
    }
    pthread_mutex_unlock(&rec_mu);
}
static int count(const char *fn, void *win)
{
    int i, n = 0;
    for (i = 0; i < ncalls; i++)
        if (!strcmp(calls[i].fn, fn) && (!win || calls[i].win == win)) n++;
    return n;
}
static struct call *last(const char *fn, void *win, int prop)
{
    int i;
    for (i = ncalls - 1; i >= 0; i--)
        if (!strcmp(calls[i].fn, fn) && (!win || calls[i].win == win) && (prop < 0 || calls[i].prop == prop))
            return &calls[i];
    return 0;
}

static char cam_obj, ctx_obj, buf_obj, child_objs[8];
__attribute__((unused)) static char other_obj;
static int nchild;
#define CAM ((void *)&cam_obj)
#define OTHER ((void *)&other_obj)

static struct { void *w; char id[16]; } ids[4];
static int nids;
static void set_id(void *w, const char *id)
{
    int i;
    for (i = 0; i < nids; i++) if (ids[i].w == w) { snprintf(ids[i].id, sizeof ids[i].id, "%s", id); return; }
    if (nids < 4) { ids[nids].w = w; snprintf(ids[nids].id, sizeof ids[nids].id, "%s", id); nids++; }
}

static int f_post_(void *w, void *b, int c, const int *r, int fl) { (void)b; (void)c; (void)r; (void)fl; rec("post", w, 0, 0, 0, 0); return g_post_rc; }
static int f_create_(void **w, void *c) { (void)c; *w = CAM; rec("create", CAM, 0, 0, 0, 0); return g_create_rc; }
static int f_create_type_(void **w, void *c, int t) { (void)c; *w = &child_objs[nchild++ & 7]; rec("create_type", *w, 0, t, 0, 0); return 0; }
static int f_group_(void *w, const char *n) { rec("group", w, 0, 0, 0, n); return g_group_rc; }
static int f_join_(void *w, const char *n) { rec("join", w, 0, 0, 0, n); return g_join_rc; }
static int f_share_(void *w, void *s) { rec("share", w, 0, s == CAM, 0, 0); return g_share_rc; }
static int f_destroy_(void *w) { rec("destroy", w, 0, 0, 0, 0); return 0; }
static int f_flush_(void *c, int fl) { (void)c; (void)fl; rec("flush", 0, 0, 0, 0, 0); return 0; }
static int f_get_iv_(void *b, int p, int *o) { (void)b; (void)p; o[0] = 720; o[1] = 1900; return 0; }
static int f_set_iv_(void *w, int p, const int *v);
static int f_get_win_iv_(void *w, int p, int *o);
static int f_get_cv_(void *w, int p, int len, char *o)
{
    int i;
    (void)p;
    if (g_slow_cv_us) usleep((unsigned)g_slow_cv_us);
    for (i = 0; i < nids; i++)
        if (ids[i].w == w) { snprintf(o, (size_t)len + 1, "%s", ids[i].id); return 0; }
    return -1;
}

void *dlopen(const char *p, int m) { (void)p; (void)m; return g_dlopen_ok ? (void *)&ctx_obj : 0; }
void *dlsym(void *h, const char *n)
{
    (void)h;
    if (g_slow_dlsym_us) usleep((unsigned)g_slow_dlsym_us);
    if (!g_dlsym_ok) return 0;
    if (g_self_post && !strcmp(n, "screen_post_window")) return g_self_post;
#define S(name, fn) if (!strcmp(n, name)) return (void *)fn;
    S("screen_post_window", f_post_)
    S("screen_create_window", f_create_)
    S("screen_create_window_type", f_create_type_)
    S("screen_create_window_group", f_group_)
    S("screen_join_window_group", f_join_)
    S("screen_share_window_buffers", f_share_)
    S("screen_destroy_window", f_destroy_)
    S("screen_flush_context", f_flush_)
    S("screen_get_buffer_property_iv", f_get_iv_)
    S("screen_set_window_property_iv", f_set_iv_)
    S("screen_get_window_property_iv", f_get_win_iv_)
    if (!g_nocv) S("screen_get_window_property_cv", f_get_cv_)
#undef S
    return 0;
}

#ifdef YAFC_SLOT
/* The fake main executable and its GOT. The library's identity constants are
 * overridden so a heap buffer can play the part of SS_RVC's text at 0x100000. */
static unsigned char g_text[0x43800];
static unsigned long long g_test_hash;
static void *g_got[2];
#define SLOT_EXE_BASE   ((unsigned long)g_text)
#define SLOT_TEXT_HASH  g_test_hash
#define SLOT_GOT_POST   (&g_got[0])
#define SLOT_GOT_CREATE (&g_got[1])
#endif

#ifdef LEGACY   /* red-check: build this test against the pre-slot-rewrite source */
struct pc_phdr { unsigned p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags, p_align; };
struct pc_dl_info { unsigned long dlpi_addr; const char *dlpi_name; const struct pc_phdr *dlpi_phdr; unsigned short dlpi_phnum; };
#endif

#include LIB_SRC

#ifdef LEGACY
#define HOOK_POST   screen_post_window
#define HOOK_CREATE screen_create_window
static volatile int g_ident_busy, g_busy; static int g_ident_done, g_ident_tries, g_inflight, g_slot_dead, g_boot_len;
static int g_orig_valid, g_orig_tries, g_restore_fail, g_ours_posts; static void *g_cam_win, *g_screen_h;
static volatile int g_is_cam; static int (*get_win_cv)(void *, int, int, char *);
#endif

/* What our own sets last left on a window, so the self-heal's read-back sees a
 * faithful Screen. A property that was never set answers -1 ("cannot read"),
 * which the library treats as "still ours" - exactly the radio's fallback. */
static struct wval { void *w; int prop; int a, b; } wvals[64];
static int nwvals;
static void wval_put(void *w, int p, int a, int b)
{
    int i;
    for (i = 0; i < nwvals; i++)
        if (wvals[i].w == w && wvals[i].prop == p) { wvals[i].a = a; wvals[i].b = b; return; }
    if (nwvals < 64) {
        wvals[nwvals].w = w; wvals[nwvals].prop = p;
        wvals[nwvals].a = a; wvals[nwvals].b = b; nwvals++;
    }
}
static int f_set_iv_(void *w, int p, const int *v)
{
    int pair = p == SP_POSITION || p == SP_SIZE ||
               p == SP_SOURCE_POSITION || p == SP_SOURCE_SIZE;
    wval_put(w, p, v[0], pair ? v[1] : 0);
    rec("set", w, p, v[0], pair ? v[1] : 0, 0);
    return g_set_rc;
}
static int f_get_win_iv_(void *w, int p, int *o)
{
    int i;
    for (i = 0; i < nwvals; i++)
        if (wvals[i].w == w && wvals[i].prop == p) { o[0] = wvals[i].a; o[1] = wvals[i].b; return 0; }
    return -1;
}

#undef open
#undef unlink
#undef getpid
#undef clock_gettime
#undef abort
static int fake_clock(int c, struct qnx_timespec *t) { (void)c; t->tv_sec = g_now; t->tv_nsec = 0; return 0; }

#ifdef YAFC_SLOT
static struct pc_phdr g_ph[3];
static int g_nph, g_phdr_present;
static unsigned long g_dlpi_addr;
int dl_iterate_phdr(int (*cb)(struct pc_dl_info *, unsigned long, void *), void *data)
{
    struct pc_dl_info info;
    if (!g_phdr_present) return 0;
    info.dlpi_addr = g_dlpi_addr; info.dlpi_name = ""; info.dlpi_phdr = g_ph;
    info.dlpi_phnum = (unsigned short)g_nph;
    return cb(&info, sizeof info, data);
}
static unsigned long long fnv64(const unsigned char *p, unsigned n)
{
    unsigned long long h = 0xcbf29ce484222325ULL;
    while (n--) h = (h ^ *p++) * 0x100000001b3ULL;
    return h;
}
/* A stock-looking SS_RVC: text LOAD 0x100000/0x43800 R E, RW LOAD 0x144800/0x3838. */
static void arm_slot(void)
{
    unsigned i;
    for (i = 0; i < sizeof g_text; i++) g_text[i] = (unsigned char)(i * 7 + (i >> 8));
    g_test_hash = fnv64(g_text, sizeof g_text);
    memset(g_ph, 0, sizeof g_ph);
    g_ph[0].p_type = 1; g_ph[0].p_flags = 5; g_ph[0].p_vaddr = 0x100000; g_ph[0].p_filesz = 0x43800; g_ph[0].p_memsz = 0x43800;
    g_ph[1].p_type = 1; g_ph[1].p_flags = 6; g_ph[1].p_vaddr = 0x144800; g_ph[1].p_filesz = 0x3684; g_ph[1].p_memsz = 0x3838;
    g_ph[2].p_type = 3; g_ph[2].p_flags = 4;   /* PT_INTERP, ignored */
    g_nph = 3; g_phdr_present = 1;
    g_dlpi_addr = (unsigned long)g_text - 0x100000UL;
    g_got[0] = (void *)f_post_;     /* what relocation left in SS_RVC's GOT */
    g_got[1] = (void *)f_create_;
}
#endif

/* ---- harness ---- */
static int failures;
static void check(const char *what, int ok)
{
    printf("%-72s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok) failures++;
}

static void write_file(const char *name, const char *s)
{
    FILE *f = fopen(name, "w");
    if (f) { fputs(s, f); fclose(f); }
}
static void write_conf(const char *s) { write_file("camera.conf", s); }
static int exists(const char *name) { struct stat st; return stat(name, &st) == 0; }
static int log_count(const char *s)
{
    char b[16384];
    size_t n;
    int c = 0;
    char *p;
    FILE *f = fopen("post.log", "r");
    if (!f) return 0;
    n = fread(b, 1, sizeof b - 1, f);
    fclose(f);
    b[n] = 0;
    for (p = b; (p = strstr(p, s)) != 0; p += strlen(s)) c++;
    return c;
}
static int log_has(const char *s) { return log_count(s) > 0; }

static int g_seed_geo;
static void seed_geometry(void *w, int px, int py, int sw, int sh, int sx, int sy, int ssw, int ssh)
{
    wval_put(w, SP_POSITION, px, py);
    wval_put(w, SP_SIZE, sw, sh);
    wval_put(w, SP_SOURCE_POSITION, sx, sy);
    wval_put(w, SP_SOURCE_SIZE, ssw, ssh);
}
static void reset_core(int keep_files)
{
    ncalls = 0; nchild = 0; nids = 0;
    g_mode = 0; g_ready = 0; g_resolved = 0; g_diag_done = 0; g_first_post_logged = 0;
    g_tick = 0; g_reread = 60; g_stats = 0; g_view_compose = 1;
    g_geo_dirty = 1; g_geo_ours = 0; g_geo_pushes = 0;
    g_geo_check_tick = 0; g_bay_retries = 0; nwvals = 0;
    g_bay_win = 0; g_bay_tried = 0; g_group_made = 0; g_ctx = 0;
    g_join_rc = g_group_rc = g_share_rc = g_set_rc = g_post_rc = g_create_rc = 0;
    g_dlopen_ok = 1;
    g_dlsym_ok = 1;
    g_nocv = 0; g_self_post = 0; g_slow_dlsym_us = g_slow_cv_us = 0;
    g_bay_dst[0] = g_bay_dst[1] = g_bay_dst[2] = g_bay_dst[3] = 0;
    real_post = 0; real_create_window = 0;
    get_buf_iv = 0; set_win_iv = 0; get_win_iv = 0; set_win_cv = 0;
    g_aborted = 0; g_busy = 0; g_screen_h = 0;
    g_orig_valid = 0; g_orig_tries = 0; g_restore_fail = 0; g_ours_posts = 0;
    g_seed_geo = 1;
    g_last_read_ms = 0;
#ifdef YAFC_SLOT
    g_is_cam = 0; g_ident_busy = 0; g_ident_done = 0; g_ident_tries = 0; g_cam_win = 0;
    g_inflight = 0; g_slot_dead = 0; g_boot_len = 0;
    get_win_cv = 0;
    arm_slot();
#endif
    unlink("post.log");
    if (!keep_files) { unlink("DISABLE"); unlink("slot-inflight"); unlink("slot-strikes"); }
}
#define reset_state() reset_core(0)

/* SS_RVC's order (SS_RVC.c:6004-6013): the library constructor has run, then
 * create, set ID_STRING, flush, set the app's geometry; posts follow. */
static int do_create(void **w, void *ctx)
{
#ifdef YAFC_SLOT
    /* a GOT slot somebody else patched points at code we do not own: the "app"
     * would run that; the test just falls back to the real function. */
    return ((f_create_win)(g_got[1] == (void *)0x1234 ? (void *)f_create_ : g_got[1]))(w, ctx);
#else
    return screen_create_window(w, ctx);
#endif
}
static int do_post(void *w)
{
#ifdef YAFC_SLOT
    return ((f_post)(g_got[0] == (void *)0x1234 ? (void *)f_post_ : g_got[0]))(w, &buf_obj, 1, 0, 0);
#else
    return screen_post_window(w, &buf_obj, 1, 0, 0);
#endif
}
static void start_with_id(const char *id)
{
    void *w = 0;
    yafc_init();
    do_create(&w, &ctx_obj);
    if (id) set_id(CAM, id);
    f_flush_(&ctx_obj, 0);
    if (g_seed_geo) seed_geometry(CAM, 0, 71, 800, 480, 0, 0, 720, 480);
}
static void start_camera(void) { start_with_id("RVC_app"); }
/* Each post advances the fake clock by 1 s. The config re-read gate is
 * wall-clock based (M-14), so a frozen clock silently stops every re-read and
 * makes the live-change cases fail for the wrong reason. */
static void posts(int n) { while (n--) { g_now += 1; do_post(CAM); } }

#define CONF_COMPOSE \
    "enabled=1\nlayout=stacked\nmode=compose\nview=rear360\nreread=1\n" \
    "cam_src=0,44,438,344\ncam_dst=0,0,800,555\n" \
    "bay_src=448,0,272,480\nbay_dst=0,571,445,675\n"

struct targ { int n, bad; };
static void *post_thread(void *a)
{
    struct targ *t = a;
    int i;
    for (i = 0; i < t->n; i++) if (HOOK_POST(CAM, &buf_obj, 1, 0, 0) != 0) t->bad++;
    return 0;
}

int main(void)
{
    char dir[] = "/tmp/yafc-test-XXXXXX", cwd[4096];
    if (!mkdtemp(dir) || !getcwd(cwd, sizeof cwd) || chdir(dir) != 0) { puts("setup failed"); return 1; }
    g_in_sandbox = 1;
    setvbuf(stdout, 0, _IOLBF, 0);   /* keep the last line visible if a case crashes */
#ifdef YAFC_SLOT
    puts("== slot build (-DYAFC_SLOT): every call goes through the patched GOT");
#else
    puts("== LD_PRELOAD build");
#endif

    /* ---- view names ---- */
    check("view rear360 composes",            view_is_combined("rear360"));
    check("view front360 composes",           view_is_combined("front360"));
    check("view rear does not compose",      !view_is_combined("rear"));
    check("view frontsplit does not compose",!view_is_combined("frontsplit"));
    check("view 360-only does not compose",  !view_is_combined("360"));

    /* ---- 1. start + first post: geometry once, bay as a parented child ---- */
    reset_state();
    write_conf(CONF_COMPOSE);
    start_camera();
#ifdef YAFC_SLOT
    check("slot activates and logs it", g_ready == 1 && log_has("slot active pid 4242"));
    check("GOT slots now hold our wrappers", g_got[0] == (void *)HOOK_POST && g_got[1] == (void *)HOOK_CREATE);
#else
    check("init resolves libscreen", g_ready == 1 && log_has("init ready/handle/pid 1 1 4242"));
#endif
    posts(1);
    check("camera geometry: 4 sets on first post", count("set", CAM) == 4);
    {
        struct call *c = last("set", CAM, SP_POSITION), *s = last("set", CAM, SP_SIZE);
        check("camera POSITION/SIZE are cam_dst", c && s && c->a == 0 && c->b == 0 && s->a == 800 && s->b == 555);
    }
    check("bay created as SCREEN_CHILD_WINDOW (type 1)",
          count("create_type", 0) == 1 && calls[0].fn[0] && last("create_type", 0, -1)->a == 1);
    {
        struct call *g = last("group", 0, -1), *j = last("join", 0, -1);
        void *bay = last("create_type", 0, -1)->win;
        check("group is parented by the camera window", g && g->win == CAM);
        check("group name is yafc-<pid>", g && !strcmp(g->str, "yafc-4242"));
        check("join(bay, same name) - correct ABI", j && j->win == bay && !strcmp(j->str, "yafc-4242"));
        check("bay shares the CAMERA's buffers", last("share", bay, -1) && last("share", bay, -1)->a == 1);
        {
            struct call *t = last("set", bay, SP_TRANSPARENCY);
            struct call *s = last("set", bay, SP_SENSITIVITY);
            check("bay scalar properties record no second value", t && s && t->b == 0 && s->b == 0);
        }
        {
            /* Parent scale is 800/438 (x) and 555/344 (y); the child rect divides
             * the screen rect by it (rvc_layout.js win2Rect). */
            struct call *bp = last("set", bay, SP_POSITION);
            struct call *bs = last("set", bay, SP_SIZE);
            check("bay POSITION in parent units (571*344/555)", bp && bp->a == 0 && bp->b == 354);
            check("bay SIZE in parent units (445*438/800, 675*344/555)",
                  bs && bs->a == 244 && bs->b == 418);
        }
        check("bay never posted (only the owner may post)", count("post", bay) == 0);
        check("bay log line records set failures", log_has("bay child setfail/w/h 0 445 675"));
    }

    /* ---- 2. steady state: no property traffic at all ---- */
    ncalls = 0;
    posts(120);   /* reread=1: the config is re-read on every one of these */
    check("identical re-reads push NO window properties (F1.2)", count("set", 0) == 0);
    check("all 120 frames reach the real post", count("post", CAM) == 120);
    check("no second bay is created", count("create_type", 0) == 0);

    /* ---- 2b. someone resets our geometry: it comes back on the next tick ---- */
    /* SS_RVC re-asserts its own geometry at every session start, through the real
     * Screen - which in this harness is the same setter the app would use. */
    {
        int stock[2] = {800, 1208};
        f_set_iv_(CAM, SP_SIZE, stock);
        ncalls = 0;               /* the app's own set is not ours to count */
    }
    posts(8);                     /* one self-heal tick fires every 8th post */
    check("geometry reset by the app is re-applied", count("set", CAM) == 4);
    check("the reset is logged", log_has("geometry was reset; re-applying"));
#ifdef YAFC_SLOT
    /* The same reset, one post: our geometry must go back BEFORE that post, so
     * the first frame after Ford's reset is already composed. */
    {
        int stock[2] = {800, 1208}, i, fs = -1, fp = -1;
        f_set_iv_(CAM, SP_SIZE, stock);
        ncalls = 0;
        posts(1);
        for (i = 0; i < ncalls; i++) {
            if (fs < 0 && !strcmp(calls[i].fn, "set") && calls[i].win == CAM) fs = i;
            if (fp < 0 && !strcmp(calls[i].fn, "post") && calls[i].win == CAM) fp = i;
        }
        check("reset geometry is re-applied BEFORE the next post", fs >= 0 && fp > fs);
    }
#endif

    /* ---- 3. live change of cam_dst moves camera AND bay ---- */
    write_conf("enabled=1\nlayout=stacked\nmode=compose\nview=rear360\nreread=1\n"
               "cam_src=0,44,438,344\ncam_dst=0,71,800,475\n"
               "bay_src=448,0,272,480\nbay_dst=0,556,445,675\n");
    ncalls = 0;
    posts(1);
    check("changed rect: camera re-applied once", count("set", CAM) == 4);
    {
        void *bay = g_bay_win;
        struct call *bp = last("set", bay, SP_POSITION);
        check("bay re-positioned in parent units ((556-71)*344/475)", bp && bp->b == 351);
    }

    /* ---- 4. view not combined: bay HIDDEN, never destroyed, and the APP's
     * geometry restored once ---- */
    void *bay4 = 0;   /* the child created in case 3; it must survive case 4 */
    write_conf("enabled=1\nmode=compose\nview=rear\nreread=1\n"
               "cam_src=0,44,438,344\ncam_dst=0,71,800,475\nbay_src=448,0,272,480\nbay_dst=0,556,445,675\n");
    bay4 = g_bay_win;
    ncalls = 0;
    posts(5);
    check("non-combined view hides the bay and keeps the same child",
          count("destroy", bay4) == 0 && g_bay_win == bay4
          && log_has("bay hidden: view not combined"));
    check("hidden bay is not re-hidden every frame", count("set", bay4) == 1);
    check("stock geometry restored exactly once", count("set", CAM) == 4);
    {
        struct call *s = last("set", CAM, SP_SIZE), *p = last("set", CAM, SP_POSITION);
        check("restored SIZE is the window's own 800x480 (not a constant)", s && s->a == 800 && s->b == 480);
        check("restored POSITION is the window's own 0,71", p && p->a == 0 && p->b == 71);
    }

    /* ---- 5. back to combined: geometry and the SAME bay return. This is the
     * regression case for the radio fault of 2026-11-22: the child used to be
     * destroyed and re-created here, and the re-created child, though every
     * property set reported success, was never painted on the radio. */
    write_conf(CONF_COMPOSE);
    ncalls = 0;
    posts(1);
    check("combined again: geometry re-applied", count("set", CAM) == 4);
    check("combined again: the SAME bay is shown, no second child",
          count("create_type", 0) == 0 && g_bay_win == bay4);
    {
        struct call *vs = last("set", bay4, SP_VISIBLE);
        check("combined again: the bay is made visible again",
              vs && vs->a == 1 && log_has("bay shown"));
    }
    check("group not re-created (a window parents one group)", count("group", 0) == 0);

    /* ---- 6. bay_dst=0 disables live ---- */
    write_conf("enabled=1\nmode=compose\nview=rear360\nreread=1\n"
               "cam_src=0,44,438,344\ncam_dst=0,0,800,555\nbay_src=448,0,272,480\nbay_dst=0,0,0,0\n");
    ncalls = 0;
    posts(3);
    check("bay_dst=0 hides the bay and keeps the child",
          count("destroy", 0) == 0 && g_bay_win != 0 && log_has("bay hidden: bay_dst off"));

    /* ---- 7. join failure: window destroyed, never left alive, no retry storm ---- */
    reset_state();
    write_conf(CONF_COMPOSE);
    g_join_rc = -1;
    start_camera();
    posts(50);
    check("failed join cleans up its child", count("destroy", 0) >= 1 && g_bay_win == 0);
    /* The bay is retried on the self-heal tick, a bounded number of times: a first
     * attempt that lands before the window manager is ready recovers without
     * needing a view change. Never per frame. */
    check("failed join is retried on the heal tick, not per frame",
          count("join", 0) > 1 && count("join", 0) <= 8);
    check("every failed attempt is destroyed", count("create_type", 0) == count("destroy", 0));
    check("failed join leaves no bay and no VISIBLE set", g_bay_win == 0 && !last("set", 0, SP_VISIBLE));
    check("failed join is logged", log_has("bay join failed"));

    /* ---- 8. group failure: no child is even created ---- */
    reset_state();
    write_conf(CONF_COMPOSE);
    g_group_rc = -1;
    start_camera();
    posts(10);
    check("failed group create: no child window", count("create_type", 0) == 0 && log_has("bay group create failed"));

    /* ---- 9. no libscreen: logged, never silent, never a hook ---- */
    reset_state();
    write_conf(CONF_COMPOSE);
    g_dlopen_ok = 0;
    g_dlsym_ok = 0;   /* M-16's RTLD_NEXT fallback must also find nothing */
    start_camera();
#ifdef YAFC_SLOT
    check("unresolved libscreen: slot refuses, logged", log_has("slot refused: libscreen pid 4242"));
    check("unresolved libscreen: GOT untouched",
          g_got[0] == (void *)f_post_ && g_got[1] == (void *)f_create_);
#else
    check("unresolved libscreen is logged as ready 0", log_has("init ready/handle/pid 0 0 4242"));
    check("unresolved libscreen in compose aborts (M-16)", g_aborted == 1);
    check("post returns -1 with nothing to call", do_post(CAM) == -1);
#endif

    /* ---- 10. pass mode touches nothing ---- */
    reset_state();
    write_conf("enabled=1\nmode=pass\nbay_dst=0,571,445,675\n");
    start_camera();
    posts(100);
    check("pass mode: zero property sets, zero windows", count("set", 0) == 0 && count("create_type", 0) == 0);
    check("pass mode: first post logged once", log_has("first post mode/view/ctx 0 1 1"));
    check("pass mode: no marker, no geometry read side effects", !exists("slot-inflight"));

    /* ---- 11. probe is gone: mode=probe means pass ---- */
    reset_state();
    write_conf("enabled=1\nmode=probe\n");
    start_camera();
    posts(5);
    check("mode=probe is pass (pixel paths removed)", g_mode == 0 && count("set", 0) == 0);

    /* ---- 12. spaces around '=' are not parsed (documented contract) ---- */
    reset_state();
    write_conf("mode = compose\n");
    start_camera();
    posts(1);
    check("'mode = compose' is not compose", g_mode == 0);

    /* ---- 13. reread=0 freezes the config after start ---- */
    reset_state();
    write_conf("enabled=1\nmode=compose\nview=rear360\nreread=0\ncam_dst=0,0,800,555\n");
    start_camera();
    posts(1);
    write_conf("enabled=1\nmode=compose\nview=rear360\nreread=0\ncam_dst=0,0,800,600\n");
    ncalls = 0;
    posts(200);
    check("reread=0: config not re-read, no pushes", count("set", 0) == 0);

    /* ---- 14. stats line ---- */
    reset_state();
    write_conf("enabled=1\nmode=compose\nview=rear360\nstats=1\nreread=1\n");
    g_now = 100;
    start_camera();
    posts(10);          /* t0 set on the first post */
    g_now = 110;
    posts(1);
    check("stats=1 logs posts per ~10 s", log_has("rate posts/secs/geo"));

    /* ---- 15. scale 1 (cam_src size == cam_dst size): no conversion ---- */
    reset_state();
    write_conf("enabled=1\nmode=compose\nview=rear360\nreread=1\n"
               "cam_src=0,0,720,480\ncam_dst=0,71,720,480\n"
               "bay_src=448,0,272,480\nbay_dst=0,300,200,480\n");
    start_camera();
    posts(1);
    {
        void *bay = g_bay_win;
        struct call *bp = last("set", bay, SP_POSITION);
        struct call *bs = last("set", bay, SP_SIZE);
        check("scale 1: child rect is the screen rect unchanged",
              bp && bp->a == 0 && bp->b == 229 && bs && bs->a == 200 && bs->b == 480);
    }

    /* ---- 16. negative half-offset follows JavaScript Math.round ---- */
    reset_state();
    write_conf("enabled=1\nmode=compose\nview=rear360\nreread=1\n"
               "cam_src=0,0,3,480\ncam_dst=1,0,2,480\n"
               "bay_src=0,0,1,480\nbay_dst=0,1,1,480\n");
    start_camera();
    posts(1);
    {
        struct call *bp = last("set", g_bay_win, SP_POSITION);
        check("negative half-offset rounds toward positive infinity", bp && bp->a == -1);
    }
    check("ceil handles both signs", to_parent_units(-3, 2, 1, 1) == -1 &&
          to_parent_units(3, 2, 1, 1) == 2 && to_parent_units(-4, 2, 1, 1) == -2);
    {
        int values[2] = { 7, 12345 };
        f_set_iv_(CAM, SP_TRANSPARENCY, values);
        f_set_iv_(CAM, SP_SENSITIVITY, values);
        check("scalar recording ignores a sentinel second value",
              last("set", CAM, SP_TRANSPARENCY)->b == 0 &&
              last("set", CAM, SP_SENSITIVITY)->b == 0);
    }

    /* ---- 17. mode switches revert and re-apply live ---- */
    reset_state();
    write_conf(CONF_COMPOSE);
    start_camera();
    posts(3);
    check("17a compose applied", g_geo_ours == 1 && g_bay_win != 0);
    write_conf("enabled=1\nmode=pass\nreread=1\n" "cam_dst=0,0,800,555\nbay_dst=0,571,445,675\n");
    ncalls = 0;
    posts(3);
    {
        struct call *s = last("set", CAM, SP_SIZE);
        check("17b mode=pass reverts live: window back to the app's 800x480",
              s && s->a == 800 && s->b == 480 && g_geo_ours == 0);
        check("17b mode=pass hides the bay and keeps the child",
              g_bay_win != 0 && count("destroy", 0) == 0 && log_has("bay hidden: mode not compose"));
    }
    ncalls = 0;
    posts(30);
    check("17c pass is silent afterwards", count("set", 0) == 0 && count("create_type", 0) == 0);
    check("17c every frame still posts", count("post", CAM) == 30);
    write_conf(CONF_COMPOSE);
    ncalls = 0;
    posts(3);
    check("17d pass -> compose applies again", count("set", CAM) == 4 && g_bay_win != 0);

    /* the app's own geometry is restored EXACTLY, whatever it is */
    reset_state();
    g_seed_geo = 0;
    write_conf(CONF_COMPOSE);
    start_camera();
    seed_geometry(CAM, 5, 50, 900, 600, 3, 10, 700, 400);
    posts(2);
    write_conf("enabled=1\nmode=pass\nreread=1\n");
    ncalls = 0;
    posts(2);
    {
        struct call *p = last("set", CAM, SP_POSITION), *s = last("set", CAM, SP_SIZE);
        struct call *sp = last("set", CAM, SP_SOURCE_POSITION), *ss = last("set", CAM, SP_SOURCE_SIZE);
        check("17e odd app geometry restored exactly (all four rects)",
              p && s && sp && ss && p->a == 5 && p->b == 50 && s->a == 900 && s->b == 600 &&
              sp->a == 3 && sp->b == 10 && ss->a == 700 && ss->b == 400);
    }

    /* the app already reset it: leaving compose must not overwrite the app's own */
    reset_state();
    write_conf(CONF_COMPOSE);
    start_camera();
    posts(3);
    seed_geometry(CAM, 0, 71, 800, 480, 0, 0, 720, 480);   /* the app re-asserts */
    write_conf("enabled=1\nmode=pass\nreread=1\n");
    ncalls = 0;
    posts(1);
    check("17f app-reset geometry is left alone on exit", count("set", CAM) == 0 && g_geo_ours == 0);

    /* geometry unreadable: the hero is never applied */
    reset_state();
    g_seed_geo = 0;
    write_conf(CONF_COMPOSE);
    start_camera();
    posts(40);
    check("17g unreadable window geometry: zero sets, zero bay", count("set", 0) == 0 && count("create_type", 0) == 0);
    check("17g unreadable window geometry: logged", log_has("window geometry unreadable"));
    check("17g unreadable window geometry: no marker written", !exists("slot-inflight"));
    check("17g real posts unaffected", count("post", CAM) == 40);

    /* ---- 18. failed real calls: the result is returned untouched ---- */
    reset_state();
    write_conf(CONF_COMPOSE);
    start_camera();
    g_post_rc = -7;
    ncalls = 0;
    check("18a failed real post returns its exact result", do_post(CAM) == -7);
    check("18a ... and nothing was touched", count("set", 0) == 0 && count("create_type", 0) == 0);
    g_post_rc = 0;
    posts(1);
    check("18b once posts succeed the hero applies", count("set", CAM) == 4);
    reset_state();
    g_create_rc = -1;
    write_conf(CONF_COMPOSE);
    {
        void *w = 0;
        yafc_init();
        check("18c failed real create returns its exact result", do_create(&w, &ctx_obj) == -1);
        check("18c ... and no context is captured", g_ctx == 0);
    }

    /* ---- 19. our own symbol handed back by dlsym: refuse, never recurse ---- */
    reset_state();
    write_conf(CONF_COMPOSE);
    g_self_post = (void *)HOOK_POST;
#ifdef YAFC_SLOT
    g_got[0] = g_self_post;
#endif
    start_camera();
    check("19 own symbol from dlsym: not ready", g_ready == 0);
#ifdef YAFC_SLOT
    check("19 slot refuses and keeps the GOT as found", g_got[0] == g_self_post && g_got[1] == (void *)f_create_ &&
          log_has("slot refused: libscreen pid 4242"));
#else
    check("19 hook returns -1 instead of calling itself", HOOK_POST(CAM, &buf_obj, 1, 0, 0) == -1);
#endif

    /* ---- 20. lazy resolve is race-free: slow dlsym, two threads ---- */
    reset_state();
    write_conf("enabled=1\nmode=pass\n");
    set_id(CAM, "RVC_app");
    seed_geometry(CAM, 0, 71, 800, 480, 0, 0, 720, 480);
    g_slow_dlsym_us = 3000;
    {
        pthread_t a, b;
        struct targ ta = { 5, 0 }, tb = { 5, 0 };
        g_resolved = 0;
        pthread_create(&a, 0, post_thread, &ta);
        usleep(15000);
        pthread_create(&b, 0, post_thread, &tb);
        pthread_join(a, 0);
        pthread_join(b, 0);
        check("20 no post is lost to a half-finished resolve", ta.bad == 0 && tb.bad == 0);
        check("20 every post reached the real function", count("post", CAM) == 10);
    }
    g_slow_dlsym_us = 0;

#ifdef YAFC_SLOT
    /* ================= slot-only: identity, DISABLE, GOT, strikes ================= */

    /* ---- S1. the replay: real result first, hero after ---- */
    reset_state();
    write_conf(CONF_COMPOSE);
    start_camera();
    ncalls = 0;
    posts(1);
    check("S1 the real post runs before any property is touched",
          ncalls > 1 && !strcmp(calls[0].fn, "post") && !strcmp(calls[1].fn, "set"));

    /* ---- S2. identity negatives: nothing patched, nothing set, reason logged ---- */
    {
        struct { const char *name; int what; } cases[] = {
            { "wrong load address", 0 }, { "text hash differs", 1 }, { "no RW LOAD", 2 },
            { "wrong text size", 3 }, { "no program headers at all", 4 }, { "RW segment wrong size", 5 },
        };
        unsigned k;
        for (k = 0; k < sizeof cases / sizeof cases[0]; k++) {
            char what[96];
            reset_state();
            write_conf(CONF_COMPOSE);
            switch (cases[k].what) {
            case 0: g_dlpi_addr += 0x1000; break;
            case 1: g_text[12345] ^= 0xff; break;
            case 2: g_ph[1].p_type = 0; break;
            case 3: g_ph[0].p_filesz -= 4; break;
            case 4: g_phdr_present = 0; break;
            case 5: g_ph[1].p_memsz += 4; break;
            }
            start_camera();
            posts(20);
            snprintf(what, sizeof what, "S2 %s: refused, GOT untouched", cases[k].name);
            check(what, log_has("slot refused: not SS_RVC pid 4242") &&
                        g_got[0] == (void *)f_post_ && g_got[1] == (void *)f_create_);
            snprintf(what, sizeof what, "S2 %s: no property set, no marker", cases[k].name);
            check(what, count("set", 0) == 0 && !exists("slot-inflight") && !log_has("slot active"));
        }
    }

    /* ---- S3. GOT mismatch (someone else patched it, or relocation not done) ---- */
    reset_state();
    write_conf(CONF_COMPOSE);
    g_got[0] = (void *)0x1234;
    start_camera();
    check("S3 foreign post slot: refused, both slots untouched",
          log_has("slot refused: GOT pid 4242") && g_got[0] == (void *)0x1234 && g_got[1] == (void *)f_create_);
    check("S3 ... no property set", count("set", 0) == 0);
    reset_state();
    g_got[1] = (void *)0x1234;
    write_conf(CONF_COMPOSE);
    start_camera();
    check("S3 foreign create slot: refused", log_has("slot refused: GOT pid 4242") && g_got[0] == (void *)f_post_);
    reset_state();
    g_nocv = 1;
    start_camera();
    check("S3 libscreen without get_window_property_cv: refused",
          log_has("slot refused: libscreen pid 4242") && g_got[0] == (void *)f_post_);

    /* ---- S4. DISABLE ---- */
    reset_state();
    write_conf(CONF_COMPOSE);
    write_file("DISABLE", "x");
    start_camera();
    posts(20);
    check("S4 DISABLE: refused and logged", log_has("slot refused: DISABLE pid 4242") && g_got[0] == (void *)f_post_);
    check("S4 DISABLE: stock behaviour, no set", count("set", 0) == 0 && count("post", CAM) == 20);
    unlink("DISABLE");
    reset_core(1);
    write_conf(CONF_COMPOSE);
    start_camera();
    posts(2);
    check("S4 removing DISABLE re-arms", log_has("slot active pid 4242") && count("set", CAM) == 4);

    /* ---- S4b. enabled=0 keeps stock; enabled=1 runs ---- */
    reset_state();
    write_file("camera.conf", "enabled=0\n" CONF_COMPOSE);
    start_camera();
    posts(20);
    check("S4b enabled=0: refused, stock", log_has("slot refused: enabled=0 pid 4242") && g_got[0] == (void *)f_post_ && count("set", 0) == 0);
    reset_core(1);
    write_conf(CONF_COMPOSE);
    start_camera();
    posts(2);
    check("S4b enabled=1 runs", log_has("slot active pid 4242"));

    /* ---- S5. wrong or missing window ID: never ours ---- */
    reset_state();
    write_conf(CONF_COMPOSE);
    start_with_id("CarPlay");
    posts(60);
    check("S5 other ID: zero sets, config never applied", count("set", 0) == 0 && !log_has("first post"));
    check("S5 other ID: gives up after a bounded number of reads", log_has("slot idle: no RVC_app window pid 4242"));
    check("S5 other ID: every frame still posts", count("post", CAM) == 60);
    reset_state();
    write_conf(CONF_COMPOSE);
    start_with_id(0);
    posts(10);
    check("S5 no ID at all: zero sets", count("set", 0) == 0 && !log_has("first post"));
    reset_state();
    write_conf(CONF_COMPOSE);
    start_camera();
    posts(3);
    ncalls = 0;
    do_post(OTHER);
    do_post(OTHER);
    check("S5 a different window after identification: passed through only",
          count("post", OTHER) == 2 && count("set", 0) == 0);

    /* ---- S6. two threads race the first-post identification ---- */
    reset_state();
    write_conf(CONF_COMPOSE);
    start_camera();
    g_slow_cv_us = 60000;
    {
        pthread_t a, b;
        struct targ ta = { 30, 0 }, tb = { 30, 0 };
        pthread_create(&a, 0, post_thread, &ta);
        usleep(10000);
        pthread_create(&b, 0, post_thread, &tb);
        pthread_join(a, 0);
        pthread_join(b, 0);
        check("S6 both threads get the real result every time", ta.bad == 0 && tb.bad == 0);
        check("S6 all 60 posts reached the real function", count("post", CAM) == 60);
        check("S6 identified once, config applied once", log_count("first post") == 1 && count("set", CAM) == 4);
        check("S6 exactly one bay", count("create_type", 0) == 1);
    }
    g_slow_cv_us = 0;

    /* ---- S7. strike counter and breaker ---- */
    reset_state();
    write_file("boot_count", "7\n");
    write_conf(CONF_COMPOSE);
    start_camera();
    check("S7 activation line carries the boot count", log_has("slot active pid 4242 7"));
    posts(5);
    {
        char b[16] = {0};
        FILE *f = fopen("slot-inflight", "r");
        if (f) { if (!fgets(b, sizeof b, f)) b[0] = 0; fclose(f); }
        check("S7 marker written before the first geometry change, with the boot count", f && !strcmp(b, "7"));
    }
    posts(40);
    check("S7 marker stays until 60 good posts", exists("slot-inflight"));
    posts(40);
    check("S7 marker and strikes cleared after 60 verified posts",
          !exists("slot-inflight") && !exists("slot-strikes") && log_has("slot verified posts"));

    /* three runs that never verify: strikes 1, 2, then the breaker */
    reset_state();
    write_file("boot_count", "8\n");
    write_conf(CONF_COMPOSE);
    start_camera(); posts(5);                                 /* crashes: marker left */
    check("S7 run 1 left a marker", exists("slot-inflight"));
    reset_core(1); write_conf(CONF_COMPOSE);
    start_camera();
    check("S7 run 2: strike 1 logged, still active", log_has("slot strike pid 4242 1") && log_has("slot active"));
    posts(5);
    reset_core(1); write_conf(CONF_COMPOSE);
    start_camera();
    check("S7 run 3: strike 2 logged, still active", log_has("slot strike pid 4242 2") && log_has("slot active"));
    posts(5);
    reset_core(1); write_conf(CONF_COMPOSE);
    start_camera();
    posts(20);
    check("S7 run 4: strike 3 -> refused, DISABLE written",
          log_has("slot refused: strikes pid 4242 3") && exists("DISABLE") && !exists("slot-strikes") && !exists("slot-inflight"));
    check("S7 run 4: GOT untouched, stock behaviour", g_got[0] == (void *)f_post_ && count("set", 0) == 0);
    reset_core(1); write_conf(CONF_COMPOSE);
    start_camera();
    check("S7 run 5: DISABLE keeps it off", log_has("slot refused: DISABLE pid 4242") && g_got[0] == (void *)f_post_);
    unlink("DISABLE");
    reset_core(1); write_conf(CONF_COMPOSE);
    start_camera();
    posts(80);
    check("S7 rm DISABLE re-arms with a fresh count; a good run clears everything",
          log_has("slot active") && !log_has("slot strike") && !exists("slot-inflight") && count("set", CAM) == 4);

    /* leaving compose cleanly before 60 posts is not a crash */
    reset_state();
    write_conf(CONF_COMPOSE);
    start_camera();
    posts(5);
    check("S7 marker present while ours", exists("slot-inflight"));
    write_conf("enabled=1\nmode=pass\nreread=1\n");
    posts(3);
    check("S7 clean exit from compose clears the marker", !exists("slot-inflight"));

    /* an unwritable marker means no hero: fail open */
    reset_state();
    write_conf(CONF_COMPOSE);
    start_camera();
    mkdir("slot-inflight", 0755);
    posts(10);
    check("S7 marker unwritable: no hero, logged", count("set", 0) == 0 && log_has("marker write failed"));
    check("S7 marker unwritable: frames still post", count("post", CAM) == 10);
    rmdir("slot-inflight");

    /* the recorded hash matches the real binary when it is available */
    {
        const char *p = getenv("SS_RVC_STOCK");
        if (p && *p) {
            static unsigned char rvc[0x43800];
            FILE *f = fopen(p, "rb");
            size_t n = f ? fread(rvc, 1, sizeof rvc, f) : 0;
            if (f) fclose(f);
            check("S8 recorded text hash == FNV-1a of the stock SS_RVC text LOAD",
                  n == sizeof rvc && fnv64(rvc, sizeof rvc) == 0xf3442ba773f7b837ULL);
        } else {
            puts("S8 skipped (set SS_RVC_STOCK to the stock SS_RVC to check the recorded hash)");
        }
    }
#endif

    /* ---- cleanup ---- */
    unlink("camera.conf");
    unlink("post.log");
    unlink("boot_count");
    unlink("DISABLE"); unlink("slot-inflight"); unlink("slot-strikes");
    if (chdir(cwd) != 0) failures++;
    rmdir(dir);

    printf("\n%s (%d failure%s)\n", failures ? "FAILED" : "ALL PASS", failures, failures == 1 ? "" : "s");
    return failures != 0;
}

/* QNX Screen constants and call shapes used by the dev tools. NOT a copy of
 * QNX's screen.h: only what we use, each with its evidence.
 *
 * Numbers: QNX 6.6 docs (qnx.com .../com.qnx.doc.screen/topic/
 * screen_8h_1Screen_Property_Types.html and the Event / Context / Usage /
 * Pixel Format pages, fetched 2026-11-16), cross-checked against binaries that
 * run on this radio family:
 *   [F] the FMods tools (socOSD, instutility, rtsp-server): their Screen constant table matched
 *   [Q] Ford's own Qt plugins in the HMI image (the Qt Screen and media plugins)
 * [R] Captured radio libscreen.so.1 (v8): context getters dispatch 108 at
 * 0x4c08 and 109 at 0x4930 and walk the same context-local list at +0x3c.
 * This establishes implementation, not whether our context sees RVC_app. */

#define SCREEN_APPLICATION_CONTEXT    0   /* QNX Screen context type */
#define SCREEN_WINDOW_MANAGER_CONTEXT 1   /* docs (1<<0); [F] passes 1. Needs root. */

#define SCREEN_PROPERTY_BUFFER_SIZE     5   /* [F] */
#define SCREEN_PROPERTY_CLASS           7
#define SCREEN_PROPERTY_FORMAT         14   /* [F] */
#define SCREEN_PROPERTY_PIPELINE       17
#define SCREEN_PROPERTY_ID_STRING      20   /* [Q] */
#define SCREEN_PROPERTY_OWNER_PID      31
#define SCREEN_PROPERTY_POINTER        34   /* [F] */
#define SCREEN_PROPERTY_POSITION       35   /* QNX property types; [F] */
#define SCREEN_PROPERTY_RENDER_BUFFERS 37   /* [F] */
#define SCREEN_PROPERTY_ROTATION       38
#define SCREEN_PROPERTY_SIZE           40   /* [F] */

/* There is NO destination-rectangle property. A window's "destination rectangle",
 * which the radio's property dump prints, is derived from POSITION + SIZE. To place
 * the camera picture in a band, set SOURCE_POSITION/SIZE to the region of the buffer
 * to show and POSITION/SIZE to where and how large to show it, then let the
 * compositor scale. Verified against the QNX 8.0 property enum ([D]), which matches
 * every value this file already carried (SOURCE_POSITION 41, SOURCE_SIZE 42,
 * ROTATION 38, ZORDER 54). */
/* [K] Kaz Wolfe's independent implementation (https://github.com/KazWolfe)
 * provides the child-window geometry rule used by `bay_apply_geometry()`: a
 * child's rectangle is in its parent's SOURCE-content
 * pixels and the compositor applies the parent's SIZE/SOURCE_SIZE scale. Divide
 * a wanted SCREEN rectangle by that scale. Property IDs in yafc-slot.c mirror
 * this header; check-screen-abi.py checks call signatures, not property IDs. */
#define SCREEN_PROPERTY_SOURCE_POSITION 41
#define SCREEN_PROPERTY_SOURCE_SIZE    42   /* [Q] */
#define SCREEN_PROPERTY_STRIDE         44   /* [F] */
#define SCREEN_PROPERTY_TRANSPARENCY   46   /* [F] */
#define SCREEN_PROPERTY_TYPE           47   /* [Q] */
#define SCREEN_PROPERTY_USAGE          48   /* [F] */
#define SCREEN_PROPERTY_VISIBLE        51   /* [F] */
#define SCREEN_PROPERTY_WINDOW         52   /* [Q] */
#define SCREEN_PROPERTY_ZORDER         54   /* QNX property types; [F][Q] */
#define SCREEN_PROPERTY_SCALE_QUALITY  56   /* [D] QNX 8.0 property enum; the radio
                                             * reports "scale quality = 0" on the camera
                                             * window, i.e. the compositor's scaler is at
                                             * its lowest setting. Settable; worth trying
                                             * higher when quality matters. */
#define SCREEN_PROPERTY_SENSITIVITY    57   /* QNX 6.5 SP1 property types */
#define SCREEN_PROPERTY_DISPLAY_COUNT  59   /* [F] */
#define SCREEN_PROPERTY_DISPLAYS       60   /* [F] */
#define SCREEN_PROPERTY_WINDOW_COUNT  108   /* [R] */
#define SCREEN_PROPERTY_WINDOWS       109   /* [R] */

#define SCREEN_USAGE_READ    2
#define SCREEN_USAGE_WRITE   4              /* [F] installer-display */
#define SCREEN_USAGE_NATIVE  8              /* [F] rtsp-server uses READ|NATIVE = 10 */
#define SCREEN_FORMAT_RGB565   6            /* [F] rtsp-server captures in this */
#define SCREEN_FORMAT_RGBA8888 8            /* [F] socOSD window format */
#define SCREEN_SENSITIVITY_NEVER       2    /* QNX 6.5 SP1 sensitivity types */

/* Event types, docs only (PROPERTY/CLOSE/POST differ from what one might guess). */
#define SCREEN_EVENT_NONE     0
#define SCREEN_EVENT_CREATE   1
#define SCREEN_EVENT_PROPERTY 2
#define SCREEN_EVENT_CLOSE    3
#define SCREEN_EVENT_POST     9

/* Call shapes, all seen in [F] or [Q] disassembly:
 *   int screen_create_context(void **ctx, int type)
 *   int screen_destroy_context(void *ctx)
 *   int screen_get_context_property_iv(void *ctx, int pname, int *out)
 *   int screen_get_context_property_pv(void *ctx, int pname, void **out)
 *   int screen_get_display_property_iv(void *dpy, int pname, int *out)
 *   int screen_create_pixmap(void **pix, void *ctx)
 *   int screen_set_pixmap_property_iv(void *pix, int pname, const int *in)
 *   int screen_create_pixmap_buffer(void *pix)
 *   int screen_get_pixmap_property_pv(void *pix, int pname, void **out)
 *   int screen_get_buffer_property_pv(void *buf, int pname, void **out)
 *   int screen_get_buffer_property_iv(void *buf, int pname, int *out)
 *   int screen_read_display(void *dpy, void *buf, int count, const int *rects, int flags)
 *   int screen_destroy_pixmap(void *pix)
 *   int screen_create_event(void **ev)
 *   int screen_get_event(void *ctx, void *ev, unsigned long long timeout_ns)
 *   int screen_get_event_property_iv(void *ev, int pname, int *out)
 *   int screen_get_event_property_pv(void *ev, int pname, void **out)
 *   int screen_get_window_property_iv(void *win, int pname, int *out)
 *   int screen_create_window(void **win, void *ctx)
 *   int screen_destroy_window(void *win)
 *   int screen_set_window_property_iv(void *win, int pname, const int *in)
 *   int screen_get_window_property_pv(void *win, int pname, void **out)
 *   int screen_create_window_buffers(void *win, int count)
 *   int screen_post_window(void *win, void *buf, int count, const int *rects, int flags)
 *   int screen_get_window_property_cv(void *win, int pname, int len, char *out)
 *   int screen_create_window_type(void **win, void *ctx, int type)
 *   int screen_create_window_group(void *win, const char *name)
 *   int screen_join_window_group(void *win, const char *name)
 *   int screen_share_window_buffers(void *win, void *share)
 *
 * The last four are the child-window route (yafc-slot.c "bay"). The radio's
 * captured libscreen.so.1 exports all four; the QNX 7.1/8.0 reference gives the
 * same shapes. screen_join_window_group takes a NAME STRING, not a window
 * handle: the 2026-11-20 bay bug passed a window handle as the name.
 */
/* QNX 6.5 SP1 documents screen_flush_context(ctx, flags): flags 0
 * submits pending commands without waiting for display idle. */
typedef int (*f_flush_context)(void *, int);
typedef int (*f_create_type)(void **, void *, int);
typedef int (*f_group)(void *, const char *);
typedef int (*f_share)(void *, void *);
typedef int (*f_create_context)(void **, int);
typedef int (*f_destroy)(void *);
typedef int (*f_get_iv)(void *, int, int *);
typedef int (*f_get_pv)(void *, int, void **);
typedef int (*f_get_cv)(void *, int, int, char *);
typedef int (*f_set_iv)(void *, int, const int *);
typedef int (*f_create_pixmap)(void **, void *);
typedef int (*f_one)(void *);
typedef int (*f_read_display)(void *, void *, int, const int *, int);
typedef int (*f_create_event)(void **);
typedef int (*f_get_event)(void *, void *, unsigned long long);

/* QNX 6.5 ARM process entry, re-implemented from the disassembly of Ford's own
 * stock binaries (apps/AudioDriver entry 0x100dd0). Sequence there:
 *   r4 = r0                      (exit hook handed over by the loader)
 *   argc=[sp] argv=sp+4 envp=argv+4*argc+4 auxv=after envp NULL
 *   _init_libc(argc, argv, envp, auxv, r4)      (5th arg on the stack)
 *   _preinit_array(start, end)
 *   atexit(_fini)
 *   _fini_array(start, end)
 *   _init()
 *   _init_array(start, end)
 *   errno = 0
 *   exit(main(argc, argv, envp))
 * Differences here: the stack is forced to 8-byte alignment before calls, and
 * errno is not touched (avoids an R_ARM_COPY against a libc we do not have).
 */
typedef void (*vfn)(void);

extern void _init_libc(int, char **, char **, void *, vfn);
extern void _preinit_array(vfn *, vfn *);
extern void _init_array(vfn *, vfn *);
extern void _fini_array(vfn *, vfn *);
extern int atexit(vfn);
extern void exit(int) __attribute__((noreturn));
extern int main(int, char **, char **);

extern vfn __preinit_array_start[], __preinit_array_end[];
extern vfn __init_array_start[], __init_array_end[];
extern vfn __fini_array_start[], __fini_array_end[];

void _init(void) {}
void _fini(void) {}

__attribute__((noreturn, used))
void _start_c(unsigned *sp, vfn exitfn)
{
    int argc = (int)sp[0];
    char **argv = (char **)(sp + 1);
    char **envp = argv + argc + 1;
    char **p = envp;
    while (*p++) {}
    _init_libc(argc, argv, envp, (void *)p, exitfn);
    _preinit_array(__preinit_array_start, __preinit_array_end);
    atexit(_fini);
    _fini_array(__fini_array_start, __fini_array_end);
    _init();
    _init_array(__init_array_start, __init_array_end);
    exit(main(argc, argv, envp));
}

__asm__(
    ".text\n"
    ".arm\n"
    ".global _start\n"
    ".type _start,%function\n"
    "_start:\n"
    "    mov r1, r0\n"          /* loader's exit hook */
    "    mov r0, sp\n"          /* original stack: argc, argv..., envp..., auxv */
    "    bic sp, sp, #7\n"
    "    mov fp, #0\n"
    "    mov lr, #0\n"
    "    bl _start_c\n"
    "1:  b 1b\n"
    ".size _start, .-_start\n"
);

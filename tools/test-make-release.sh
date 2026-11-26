#!/bin/sh
# Host test for make-release.sh. It runs the assembly with a stub payload
# (YAFC_SKIP_BUILD=1), so it needs no cross toolchain, and checks the two zips:
# one marker each and the right one, the stick layout at the zip root, no wrapper
# directory, no marker left running, no private token in the text, START-HERE.txt
# short and honest, and SHA256SUMS that verify. It builds twice and compares the
# hashes, so a change that makes the zips non-deterministic fails here.
#
# usage: sh tools/test-make-release.sh
# exit 0 all cases pass, 1 a case failed, 2 setup problem.

LC_ALL=C
export LC_ALL

here=$(cd "$(dirname "$0")" && pwd) || exit 2
MAKE=$here/make-release.sh
[ -f "$MAKE" ] || { echo "setup: $MAKE missing"; exit 2; }
command -v python3 >/dev/null || { echo "setup: python3 missing"; exit 2; }

WORK=$(mktemp -d) || { echo "setup: mktemp failed"; exit 2; }
trap 'rm -rf "$WORK"' EXIT INT TERM

mkdir -p "$WORK/bin"
printf 'stub slot library\n' > "$WORK/bin/libyafc.so"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/slotprobe"
chmod 755 "$WORK/bin/slotprobe"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
no() { fail=$((fail + 1)); echo "FAIL $1"; }

# build DIST: assemble with the stub payload, quietly
build() {
  YAFC_SKIP_BUILD=1 YAFC_LIB=$WORK/bin/libyafc.so YAFC_PROBE=$WORK/bin/slotprobe \
    YAFC_OUT=$1 sh "$MAKE" 2.3.4 > "$WORK/build.log" 2>&1
}

if build "$WORK/a"; then ok "make-release.sh assembles with a stub payload"; else
  no "make-release.sh assembles with a stub payload"; sed 's/^/     /' "$WORK/build.log"; fi
if build "$WORK/b"; then ok "make-release.sh runs twice"; else
  no "make-release.sh runs twice"; sed 's/^/     /' "$WORK/build.log"; fi

# check DIST: every assertion about the zips, in one python pass
check() {
  python3 - "$1" <<'PY'
import hashlib, os, re, sys, zipfile

dist = sys.argv[1]
fails = []
def bad(msg):
    fails.append(msg)
    print("FAIL " + msg)
def good(msg):
    print("ok   " + msg)

VARIANTS = {"install": "INSTALL", "uninstall": "REMOVE"}
FORBIDDEN = re.compile(r"\bpat\b|PAT_|pat-rvc|patcam")
HOSTPATH = re.compile(r"/home/|/Users/|/mnt/c/|[A-Za-z]:[\\/](?:Users|home|Windows)")
TEXT_MAX = 25

names = {}
blobs = {}
for variant in VARIANTS:
    z = os.path.join(dist, "YAFC-2.3.4-%s.zip" % variant)
    if not os.path.isfile(z):
        bad("missing " + z)
        continue
    with zipfile.ZipFile(z) as zf:
        names[variant] = zf.namelist()
        blobs[variant] = {n: zf.read(n) for n in zf.namelist()}
    good("%s zip opens" % variant)

for variant, entries in names.items():
    files = blobs[variant]
    want = "RUN-YAFC-" + VARIANTS[variant]
    root = [n for n in entries if "/" not in n]
    markers = [n for n in root if n.startswith("RUN-YAFC-")]
    if markers == [want]:
        good("%s zip has exactly one marker, %s" % (variant, want))
    else:
        bad("%s zip markers %s, wanted [%s]" % (variant, markers, want))
    if any(n.endswith(".running") for n in entries):
        bad("%s zip contains a .running marker" % variant)
    else:
        good("%s zip has no .running marker" % variant)

    wrappers = sorted({n.split("/")[0] for n in entries if "/" in n})
    stray = [w for w in wrappers if w not in ("SyncMyMod", "yafc-payload", "tools")]
    if stray:
        bad("%s zip has a wrapper directory: %s" % (variant, stray))
    else:
        good("%s zip root is the stick root" % variant)

    # SyncMyMod/.yafc-usb ships on purpose: it is make-usb.sh's ownership stamp, and a
    # stick without it cannot be refreshed by the script later. It is empty and hidden.
    required = ["SyncMyMod/autoinstall.sh", "SyncMyMod/.yafc-usb", "yafc-install.sh",
                "yafc-payload/libyafc.so", "yafc-payload/slotprobe",
                "yafc-payload/camera.conf", "tools/apply-hmi-fragments.sh",
                "START-HERE.txt", want]
    missing = [r for r in required if r not in entries]
    if missing:
        bad("%s zip missing %s" % (variant, missing))
    else:
        good("%s zip has the stick layout" % variant)
    if not any(n.startswith("yafc-payload/hmi/") and n.endswith(".fragment") for n in entries):
        bad("%s zip has no HMI fragment" % variant)
    else:
        good("%s zip has HMI fragments" % variant)

    start = files.get("START-HERE.txt", b"").decode("utf-8", "replace")
    lines = start.splitlines()
    if len(lines) > TEXT_MAX:
        bad("%s START-HERE.txt is %d lines: %r" % (variant, len(lines), start[-90:]))
    else:
        good("%s START-HERE.txt is %d lines" % (variant, len(lines)))
    if not start.startswith("WARNING:"):
        bad("%s START-HERE.txt does not open with the WARNING block" % variant)
    else:
        good("%s START-HERE.txt opens with the WARNING block" % variant)
    for phrase in ("not yet field-tested", "FMods", "UNKNOWN", "parked", "at your own risk",
                   "warranty", "DISCLAIMER.md"):
        if phrase not in start:
            bad("%s START-HERE.txt lacks %r" % (variant, phrase))
    if "RUN-YAFC-%s.running" % VARIANTS[variant] not in start:
        bad("%s START-HERE.txt does not name its own .running marker" % variant)
    else:
        good("%s START-HERE.txt names its own .running marker" % variant)

    dirty = False
    for name, blob in files.items():
        if name.endswith(".so") or name.endswith("slotprobe"):
            continue
        text = blob.decode("utf-8", "replace")
        hit = FORBIDDEN.search(text)
        if hit:
            dirty = True
            bad("%s zip: %s holds a private token %r" % (variant, name, hit.group(0)))
        hit = HOSTPATH.search(text)
        if hit:
            dirty = True
            bad("%s zip: %s holds a host path %r" % (variant, name, hit.group(0)))
    if not dirty:
        good("%s zip text is clean" % variant)

sums = os.path.join(dist, "SHA256SUMS")
if not os.path.isfile(sums):
    bad("missing SHA256SUMS")
else:
    listed = {}
    for line in open(sums, encoding="utf-8"):
        digest, _, name = line.rstrip("\n").partition("  ")
        listed[name] = digest
    want = {"YAFC-2.3.4-%s.zip" % v for v in VARIANTS}
    if set(listed) != want:
        bad("SHA256SUMS lists %s" % sorted(listed))
    else:
        good("SHA256SUMS lists the two zips")
    for name, digest in sorted(listed.items()):
        p = os.path.join(dist, name)
        real = hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.isfile(p) else "missing"
        if real != digest:
            bad("SHA256SUMS hash mismatch for " + name)
    if not fails:
        good("SHA256SUMS hashes verify")

sys.exit(1 if fails else 0)
PY
}

if check "$WORK/a"; then ok "zip contents, markers, tokens and hashes"; else
  no "zip contents, markers, tokens and hashes"; fi

if cmp -s "$WORK/a/SHA256SUMS" "$WORK/b/SHA256SUMS"; then
  ok "two runs give the same hashes"
else
  no "two runs give the same hashes"
  diff "$WORK/a/SHA256SUMS" "$WORK/b/SHA256SUMS" | sed 's/^/     /'
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
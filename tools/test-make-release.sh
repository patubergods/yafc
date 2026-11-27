#!/bin/sh
# Host test for make-release.sh. It runs the assembly with a stub payload
# (YAFC_SKIP_BUILD=1), so it needs no cross toolchain. The probe starts without
# an execute bit, and USB assembly must not need chmod. Check two zips, each
# with one marker, the stick layout at the root, no private tokens, concise
# instructions, all source fragments and both checksum manifests. Build twice
# with different umasks to check reproducibility.
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
printf '%s\n' /fs/tmpfs/yafc-view /fs/tmpfs/yafc-session /fs/tmpfs/yafc-ready > "$WORK/bin/libyafc.so"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/slotprobe"
chmod 644 "$WORK/bin/slotprobe" || exit 2
mkdir "$WORK/no-chmod" || exit 2
cat > "$WORK/no-chmod/chmod" <<'SH'
#!/bin/sh
echo "USB filesystem does not support chmod" >&2
exit 1
SH
chmod 755 "$WORK/no-chmod/chmod" || exit 2

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
no() { fail=$((fail + 1)); echo "FAIL $1"; }

# build DIST UMASK [LIB]: assemble with a stub payload, quietly
build() (
  umask "$2"
  PATH="$WORK/no-chmod:$PATH" \
    YAFC_SKIP_BUILD=1 YAFC_LIB=${3:-$WORK/bin/libyafc.so} YAFC_PROBE=$WORK/bin/slotprobe \
    YAFC_OUT=$1 sh "$MAKE" 2.3.4 > "$WORK/build.log" 2>&1
)

mkdir -p "$WORK/a" || exit 2
: > "$WORK/a/YAFC-2.3.4-rehearse.zip" || exit 2
if build "$WORK/a" 022; then ok "release assembles with a non-executable probe and no chmod"; else
  no "release assembles with a non-executable probe and no chmod"; sed 's/^/     /' "$WORK/build.log"; fi
if build "$WORK/b" 077; then ok "release assembles with a stricter umask"; else
  no "release assembles with a stricter umask"; sed 's/^/     /' "$WORK/build.log"; fi
for missing in session ready; do
  grep -Fvx "/fs/tmpfs/yafc-$missing" "$WORK/bin/libyafc.so" > "$WORK/stale.so" || exit 2
  if ! build "$WORK/stale-$missing" 022 "$WORK/stale.so" &&
     grep -Fq "lacks the HMI mailbox protocol (/fs/tmpfs/yafc-$missing)" "$WORK/build.log" &&
     [ ! -e "$WORK/stale-$missing/YAFC-2.3.4-install.zip" ]; then
    ok "release rejects a stale library missing yafc-$missing"
  else
    no "release rejects a stale library missing yafc-$missing"; sed 's/^/     /' "$WORK/build.log"
  fi
done

# check DIST: every assertion about the zips, in one python pass
check() {
  python3 - "$1" "$here/../payload/hmi" "$WORK/bin" <<'PY'
import hashlib, os, re, sys, zipfile
from pathlib import Path

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
DOCS = "https://github.com/patubergods/yafc/blob/main/docs/"
fragments = {"yafc-payload/hmi/" + p.name: p.read_bytes()
             for p in Path(sys.argv[2]).glob("*.fragment")}
if not fragments:
    bad("no source fragments found")
probe = "yafc-payload/slotprobe"
library = "yafc-payload/libyafc.so"
stub_payload = {name: (Path(sys.argv[3]) / Path(name).name).read_bytes()
                for name in (probe, library)}

expected_zips = {"YAFC-2.3.4-%s.zip" % v for v in VARIANTS}
actual_zips = {name for name in os.listdir(dist) if name.endswith(".zip")}
if actual_zips != expected_zips:
    bad("release zip set: %s" % sorted(actual_zips))
else:
    good("release contains only install and uninstall zips")

names = {}
blobs = {}
modes = {}
for variant in VARIANTS:
    z = os.path.join(dist, "YAFC-2.3.4-%s.zip" % variant)
    if not os.path.isfile(z):
        bad("missing " + z)
        continue
    with zipfile.ZipFile(z) as zf:
        names[variant] = zf.namelist()
        blobs[variant] = {n: zf.read(n) for n in zf.namelist()}
        modes[variant] = {info.filename: (info.external_attr >> 16) & 0o777
                          for info in zf.infolist()}
    good("%s zip opens" % variant)

for variant, entries in names.items():
    files = blobs[variant]
    if len(entries) != len(files):
        bad("%s zip repeats an entry" % variant)
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
                library, probe, "yafc-payload/README.txt", "yafc-payload/SHA256SUMS",
                "yafc-payload/camera.conf", "tools/apply-hmi-fragments.sh",
                "START-HERE.txt", "DISCLAIMER.txt", want]
    missing = [r for r in required if r not in entries]
    if missing:
        bad("%s zip missing %s" % (variant, missing))
    else:
        good("%s zip has the stick layout" % variant)
    archived_fragments = {n: files[n] for n in entries if n.startswith("yafc-payload/hmi/")}
    if archived_fragments != fragments:
        bad("%s zip fragment names or bytes differ from the source" % variant)
    else:
        good("%s zip includes every source fragment byte for byte" % variant)
    if any(files.get(name) != content for name, content in stub_payload.items()):
        bad("%s zip altered the native payload bytes" % variant)
    if modes[variant].get(probe) != 0o644:
        bad("%s zip should store slotprobe as non-executable data" % variant)
    for script in ("SyncMyMod/autoinstall.sh", "yafc-install.sh", "tools/apply-hmi-fragments.sh"):
        if modes[variant].get(script) != 0o755:
            bad("%s zip has the wrong shell script mode for %s" % (variant, script))
    payload_sums = files.get("yafc-payload/SHA256SUMS", b"").decode("utf-8").splitlines()
    payload_hashes = {path: digest for digest, path in
                      (line.split(None, 1) for line in payload_sums)}
    covered = {"SyncMyMod/autoinstall.sh", "yafc-install.sh", "tools/apply-hmi-fragments.sh",
               library, probe, "yafc-payload/camera.conf"} | fragments.keys()
    if len(payload_sums) != len(covered) or set(payload_hashes) != covered or any(
            path not in files or hashlib.sha256(files[path]).hexdigest() != digest
            for path, digest in payload_hashes.items()):
        bad("%s zip payload SHA256SUMS does not match packaged files" % variant)
    else:
        good("%s zip payload SHA256SUMS includes and verifies all HMI fragments" % variant)

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
    phrases = ("used only on a 2020 Explorer ST", "not yet field-tested", "FMods",
               "UNKNOWN", "parked", "at your own risk", "warranty", DOCS + "DISCLAIMER.md",
               DOCS + "RECOVERY.md", "request ID", "Do not retry.")
    if variant == "install":
        phrases += ("fullscreen rear video appeared early", "The 360 view",
                    "parking sensors and view-selection buttons appeared later")
    for phrase in phrases:
        if phrase not in start:
            bad("%s START-HERE.txt lacks %r" % (variant, phrase))
    if "RUN-YAFC-%s.running" % VARIANTS[variant] not in start:
        bad("%s START-HERE.txt does not name its own .running marker" % variant)
    else:
        good("%s START-HERE.txt names its own .running marker" % variant)

    readme = files.get("yafc-payload/README.txt", b"").decode("utf-8", "replace")
    for doc in ("INSTALL.md", "ARCHITECTURE.md", "CAMERA-PIPELINE.md", "RECOVERY.md",
                "HMI-PATCH.md"):
        if DOCS + doc not in readme:
            bad("%s packaged README lacks a standalone link to %s" % (variant, doc))

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
    if set(listed) != expected_zips:
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
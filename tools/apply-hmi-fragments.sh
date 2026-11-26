#!/bin/sh
# Apply the YAFC HMI edits to the owner's own copies of four HMI files.
#
# usage: sh apply-hmi-fragments.sh STAGE_DIR FRAGMENT_DIR
#
# STAGE_DIR holds the owner's copies under STAGE_DIR/fordhmi/qml/<target>.
# FRAGMENT_DIR holds *.fragment files (header, then body). No Ford text lives in
# this tool; every edit comes from a fragment file. Needs only sh, awk, sort,
# cksum, openssl, mv and rm. It runs on the radio and on a host.
#
# Fragment format. Every header line starts with "# ". The header ends at the
# line "# end-header". The body runs from the next line to the end of the file
# and must not contain a second "# end-header" line.
#   # yafc-fragment v1                  (first line, exactly)
#   # id: <name>                        fragments of one target apply in id order
#   # target: <relative path>           one of the four targets below
#   # edit: replace | append-after
#   # find: <text>                      replace: must match exactly one stock line
#   # replace: <text>                   replace: the text that takes its place
#   # anchor: <text>                    append-after: must match exactly one line
#   # end-header
#   <body>                              append-after: inserted after the anchor line
# Each header line is "key: value" (first ": " splits it). Blank find/anchor
# values and unknown or missing keys are refused.
#
# Matching works on whole lines. A stock line matches when it equals the find or
# anchor text after the trailing CR and the surrounding spaces and tabs are
# removed from both. Zero or several matches refuse the fragment.
# replace:       the matched line keeps its own leading whitespace. Everything
#                after it becomes the replace text. If nothing matches and a
#                line equal to the replace text is already present, the fragment
#                is skipped.
# append-after:  the anchor line stays untouched. The body lines follow it
#                verbatim after one blank line. If the body lines are already
#                present in a row, the fragment is skipped. A body that declares
#                Component.onCompleted is refused when the target already
#                contains one: a second handler would break the HMI. That case
#                means a firmware other than the one the fragments were written
#                for.
# Inserted and replaced lines are written with the file's own line ending.
# The HMI files are CRLF, so every line of the output ends in CRLF. A target
# without a final newline gains one when edited.
# A target without a fragment fails the run. A target whose fragments are all
# already applied is reported as "already applied" and does not fail it, so a
# rerun is a success. Each target is edited on a temporary
# copy that is renamed into place only when all its fragments succeeded, so a
# refusal never leaves a half-edited file. The tool prints per target the
# fragments applied or skipped and the cksum and SHA-1 of the input and output.
# It does not gate on Ford file hashes: a moved or reworded line makes it refuse.
# UNPROVEN on a radio: fragment text and anchors against real firmware, this
# script under the radio's own awk, and cksum on the radio.
#
# Exit status: 0 all four targets edited, 1 refusal or an unedited target, 2 usage.

LC_ALL=C
export LC_ALL

[ $# -eq 2 ] || { echo "usage: sh apply-hmi-fragments.sh STAGE_DIR FRAGMENT_DIR" >&2; exit 2; }
STAGE=$1
FDIR=$2

T1=themes/ford-10P-MY20/styles/RVCPopupStyle.qml
T2=hmirvc/+10inchP/RVCPopup.qml
T3=hmisettings/driverassistance/+10inchP/RVCSettings.qml
T4=+10inchP/Root.qml
HMI_PREFIX=fordhmi/qml

# One awk program, two modes. "list": parse one fragment file, print
# "target<TAB>id<TAB>file". "apply": the sorted fragment files of one target come
# on stdin, one path per line; edit the target file and write the result to tmp.
AWKPROG='
function fail(msg) { ERR = msg; return 0 }

function trim(s) {
  gsub(/^[ \t\r]+/, "", s); gsub(/[ \t\r]+$/, "", s)
  return s
}

# Parse fragment file path into F_*[n]. Returns 1, or 0 with ERR set.
function parse(path, n,   r, line, i, text, p, body, inbody, ended) {
  split("", H)
  i = 0; inbody = 0; ended = 0; body = ""
  if ((r = (getline line < path)) < 0) return fail(path ": cannot read")
  while (r > 0) {
    i++
    text = line; sub(/\r+$/, "", text)
    if (inbody) {
      if (text == "# end-header") { close(path); return fail(path ": body contains an end-header line") }
      body = body text "\n"
    } else if (text == "# end-header") {
      inbody = 1; ended = 1
    } else {
      if (substr(text, 1, 2) != "# ") { close(path); return fail(path ": header line " i " does not start with \"# \"") }
      text = substr(text, 3)
      if (i == 1) {
        if (text != "yafc-fragment v1") { close(path); return fail(path ": not a yafc-fragment v1 file") }
      } else {
        p = index(text, ": ")
        if (p == 0) { close(path); return fail(path ": bad header line " i) }
        H[substr(text, 1, p - 1)] = substr(text, p + 2)
      }
    }
    r = (getline line < path)
  }
  close(path)
  if (!ended) return fail(path ": no \"# end-header\" line")
  gsub(/^\n+/, "", body); gsub(/\n+$/, "", body)
  if (!("id" in H) || !("target" in H) || !("edit" in H)) return fail(path ": header lacks id, target or edit")
  if (H["edit"] == "replace") {
    if (!("find" in H) || !("replace" in H)) return fail(path ": header lacks find or replace")
    if (trim(H["find"]) == "") return fail(path ": empty find")
  } else if (H["edit"] == "append-after") {
    if (!("anchor" in H)) return fail(path ": header lacks anchor")
    if (trim(H["anchor"]) == "") return fail(path ": empty anchor")
    if (body !~ /[^ \t\n]/) return fail(path ": empty append body")
  } else return fail(path ": unknown edit " H["edit"])
  F_id[n] = H["id"]; F_target[n] = H["target"]; F_edit[n] = H["edit"]
  F_find[n] = trim(H["find"]); F_repl[n] = trim(H["replace"]); F_anchor[n] = trim(H["anchor"]); F_body[n] = body
  return 1
}

# Number of lines of the global text L[1..N] equal, trimmed, to s; first hit in HIT.
function matches(s,   i, c) {
  c = 0; HIT = 0
  for (i = 1; i <= N; i++) if (trim(L[i]) == s) { c++; if (!HIT) HIT = i }
  return c
}

function file_has(s,   i) {
  for (i = 1; i <= N; i++) if (index(L[i], s) > 0) return 1
  return 0
}

# 1 when the nb lines in BL[] appear in a row in L[], compared trimmed.
function seq_present(nb,   i, k, ok) {
  for (i = 1; i + nb - 1 <= N; i++) {
    ok = 1
    for (k = 1; k <= nb; k++) if (trim(L[i + k - 1]) != trim(BL[k])) { ok = 0; break }
    if (ok) return 1
  }
  return 0
}

# Edit the global text with fragment n. Returns "applied" or "skipped";
# on refusal returns "" with ERR set.
function apply1(n,   c, nb, i, k, p, lead) {
  if (F_edit[n] == "replace") {
    c = matches(F_find[n])
    if (c == 0) {
      if (F_repl[n] == "" || matches(F_repl[n]) > 0) return "skipped"
      ERR = F_id[n] ": line to replace not found (different firmware?)"; return ""
    }
    if (c > 1) { ERR = F_id[n] ": line to replace occurs " c " times, expected 1"; return "" }
    match(L[HIT], /^[ \t]*/)
    lead = substr(L[HIT], 1, RLENGTH)
    L[HIT] = lead F_repl[n]
    return "applied"
  }
  nb = split(F_body[n], BL, "\n")
  for (k = 1; k <= nb; k++) sub(/\r+$/, "", BL[k])
  if (F_body[n] != "" && seq_present(nb)) return "skipped"
  c = matches(F_anchor[n])
  if (c != 1) { ERR = F_id[n] ": anchor occurs " c " times, expected 1 (different firmware?)"; return "" }
  if (index(F_body[n], "Component.onCompleted") > 0 && file_has("Component.onCompleted")) {
    ERR = F_id[n] ": the file already has a Component.onCompleted handler (different firmware?)"; return ""
  }
  p = HIT
  for (i = N; i > p; i--) L[i + nb + 1] = L[i]
  L[p + 1] = ""
  for (k = 1; k <= nb; k++) L[p + 1 + k] = BL[k]
  N += nb + 1
  return "applied"
}

BEGIN { if (mode == "list") {
  if (!parse(ARGV[1], 1)) { print "REFUSED: " ERR; exit 1 }
  if (F_id[1] != id) { print "REFUSED: " ARGV[1] ": id must match the filename"; exit 1 }
  print F_target[1] "\t" F_id[1] "\t" ARGV[1]
  exit 0
} }

mode == "apply" { files[++nf] = $0 }

END {
  if (mode != "apply") exit
  if (nf == 0) { print "  REFUSED: no fragment for this target"; exit 1 }
  for (i = 1; i <= nf; i++)
    if (!parse(files[i], i)) { print "  REFUSED: " ERR; exit 1 }
  N = 0; eol = crlf ? "\r\n" : "\n"
  if ((r = (getline line < path)) < 0) { print "  REFUSED: cannot read " path; exit 1 }
  while (r > 0) { sub(/\r+$/, "", line); L[++N] = line; r = (getline line < path) }
  close(path)
  for (i = 1; i <= nf; i++) {
    how[i] = apply1(i)
    if (how[i] == "") { print "  REFUSED: " ERR " (file left unedited)"; exit 1 }
    if (how[i] == "applied") changed = 1
  }
  for (i = 1; i <= nf; i++) print "  fragment " F_id[i] ": " how[i]
  for (i = 1; i <= N; i++) printf("%s%s", L[i], eol) > tmp
  close(tmp)
  exit changed ? 0 : 3
}
'

# Parse every fragment first. LIST holds "target<TAB>id<TAB>file" lines.
[ -d "$FDIR" ] || { echo "REFUSED: no fragment directory $FDIR"; exit 1; }
LIST=
for f in "$FDIR"/*.fragment; do
  [ -f "$f" ] || continue
  name=${f##*/}
  line=$(awk -v mode=list -v id="${name%.fragment}" "$AWKPROG" "$f") || { echo "$line"; exit 1; }
  LIST="$LIST$line
"
done
printf '%s' "$LIST" | awk -F'\t' -v t1="$T1" -v t2="$T2" -v t3="$T3" -v t4="$T4" \
  '$1 != t1 && $1 != t2 && $1 != t3 && $1 != t4 { print "REFUSED: " $2 " targets unknown file " $1; bad = 1 } END { exit bad }' || exit 1

sums() {   # $1 label, $2 file: cksum and SHA-1 lines for the report
  set -- "$1" "$2" $(cksum "$2")
  echo "  cksum $1 $3 $4"
  echo "  sha1 $1  $(openssl dgst -sha1 -r "$2" | awk '{ print $1 }')"
}

status=0
CR=$(printf '\r')
for target in "$T1" "$T2" "$T3" "$T4"; do
  path=$STAGE/$HMI_PREFIX/$target
  tmp=$path.yafc-tmp
  echo "target $target"
  rm -f "$tmp"
  # The line ending is detected here: awk may hide a trailing CR when it reads.
  crlf=0
  grep -q "$CR\$" "$path" 2>/dev/null && crlf=1
  printf '%s' "$LIST" | awk -F'\t' -v t="$target" '$1 == t' | sort \
    | awk -F'\t' '{ print $3 }' \
    | awk -v mode=apply -v path="$path" -v tmp="$tmp" -v crlf="$crlf" "$AWKPROG"
  rc=$?
  if [ $rc -eq 1 ]; then status=1; rm -f "$tmp"; continue; fi
  if [ $rc -ne 0 ] && [ $rc -ne 3 ]; then echo "  REFUSED: awk failed ($rc)"; status=1; rm -f "$tmp"; continue; fi
  [ -f "$tmp" ] || { echo "  REFUSED: no output written"; status=1; continue; }
  sums in "$path"
  sums out "$tmp"
  if [ $rc -eq 3 ]; then
    # Every fragment was already applied. A rerun is a success, not a refusal:
    # keep the original file so its bytes and its final newline are untouched.
    echo "  already applied"
    rm -f "$tmp"; continue
  fi
  mv "$tmp" "$path" || { echo "  REFUSED: cannot replace $path"; status=1; rm -f "$tmp"; }
done
exit $status

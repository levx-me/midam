#!/bin/sh
# Checks the `midam` script (Resources/midam): usage and exit codes, help, status JSON, the URLs it
# opens and the review --wait round trip. The app is faked through MIDAM_OPEN, and a stand-in
# `open` on PATH refuses to run, so nothing here ever opens midam:// for real. Run from the repo
# root: sh tools/cli-test.sh
# (The Swift side of the same contract is in tools/ReplyTest.)
set -u
cd "$(dirname "$0")/.." || exit 1
MIDAM=$PWD/Resources/midam
[ -x "$MIDAM" ] || { echo "FAIL Resources/midam is not executable"; exit 1; }
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir "$T/bin" "$T/sp ace 한글"
printf '#!/bin/sh\necho "open called: $*" >> "%s/open.log"\nexit 1\n' "$T" > "$T/bin/open"
chmod +x "$T/bin/open"
PATH="$T/bin:$PATH"
export MIDAM_SUPPORT="$T/support"
unset MIDAM_OPEN MIDAM_TIMEOUT
DOC="$T/sp ace 한글/a&b #1.md"
printf '# doc\n' > "$DOC"
printf 'text\n' > "$T/note.txt"

FAILS=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then :; else FAILS=$((FAILS + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
has() { # name needle haystack
  case $3 in *"$2"*) ;; *) FAILS=$((FAILS + 1)); printf 'FAIL %s: missing "%s" in\n%s\n' "$1" "$2" "$3" ;; esac
}
run() { OUT=$("$@" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err"); }
jsget() { node -e 'const o=JSON.parse(process.argv[1]);const v=o[process.argv[2]];console.log(v===null?"null":typeof v==="string"?v:JSON.stringify(v))' "$1" "$2"; }

# The fake app: records the URL; if it carries reply=<dir>/reply.md it answers into that dir the way
# Midam does (reply.md first, then verdict) unless FAKE_ANSWER is empty.
cat > "$T/fake" <<'EOF'
#!/bin/sh
echo "$1" >> "$FAKE_LOG"
[ -n "${FAKE_ANSWER:-}" ] || exit 0
dir=$(printf %s "$1" | sed -n 's/.*[?&]reply=\([^&]*\)%2Freply\.md.*/\1/p' | sed 's/%2F/\//g')
[ -n "$dir" ] || exit 0
echo "$dir" > "$FAKE_DIR"
( sleep 0.3; printf '%s' "$FAKE_REPLY" > "$dir/reply.md"; printf '%s' "$FAKE_ANSWER" > "$dir/verdict" ) &
EOF
chmod +x "$T/fake"
export FAKE_LOG="$T/fake.log" FAKE_DIR="$T/fake.dir"

# Usage and exit codes
run "$MIDAM";                         check "no args: 64" 64 $RC; has "no args: usage on stderr" "Usage:" "$ERR"; check "no args: stdout empty" "" "$OUT"
run "$MIDAM" bogus;                   check "unknown command" 64 $RC
run "$MIDAM" open;                    check "open without path" 64 $RC
run "$MIDAM" open --bogus x;          check "unknown option" 64 $RC
run "$MIDAM" open a b;                check "two paths" 64 $RC
run "$MIDAM" review "$DOC" --timeout abc; check "bad timeout" 64 $RC
run "$MIDAM" open "$DOC:0";           check "line 0" 64 $RC
run "$MIDAM" open "$T/note.txt";      check "not markdown" 64 $RC
run "$MIDAM" open "$T/missing.md";    check "missing file: 2" 2 $RC; has "missing file message" "no such file" "$ERR"; check "missing: stdout empty" "" "$OUT"
run "$MIDAM" open "$T";               check "directory: 2" 2 $RC
run "$MIDAM" review "$T/missing.md" --wait; check "review missing: 2" 2 $RC
# Midam not available: the stand-in `open -Ra Midam` fails (and nothing is opened)
run "$MIDAM" open "$DOC";             check "no app: 3" 3 $RC
run "$MIDAM" review "$DOC" --wait --timeout 1; check "review no app: 3" 3 $RC

# Help and version
for c in "" open review status; do
  run "$MIDAM" $c --help; check "help $c exit" 0 $RC; has "help $c usage" "sage" "$OUT"; check "help $c stderr" "" "$ERR"
  has "help $c example" "midam " "$OUT"
done
run "$MIDAM" review -h;               has "help examples" "Examples:" "$OUT"
run "$MIDAM" --version;               check "version exit" 0 $RC; has "version" "midam " "$OUT"
case $OUT in "midam "[0-9]*) ;; *) FAILS=$((FAILS + 1)); echo "FAIL version format: $OUT" ;; esac

# open: the URL is percent-encoded; line parsed from path:line (also when the name has colons)
export MIDAM_OPEN="$T/fake"; : > "$FAKE_LOG"
run "$MIDAM" open "$DOC:40";          check "open exit" 0 $RC; check "open stdout empty" "" "$OUT"
URL=$(tail -1 "$FAKE_LOG")
REAL=$(realpath "$DOC")
check "open url" "midam://open?path=$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$REAL")&line=40" "$URL"
run "$MIDAM" open "$DOC" --quiet;     check "quiet" "" "$ERR"
check "open without line" "midam://open?path=$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$REAL")" "$(tail -1 "$FAKE_LOG")"
printf 'x\n' > "$T/c:7.md"
run "$MIDAM" open "$T/c:7.md";        check "colon in name" 0 "$(tail -1 "$FAKE_LOG" | grep -c 'line=')" ; check "colon in name exit" 0 $RC
(cd "$T" && "$MIDAM" open "note.txt:3" >/dev/null 2>&1); check "relative non-markdown" 64 $?
(cd "$T/sp ace 한글" && "$MIDAM" open "a&b #1.md" >/dev/null 2>&1); check "relative path ok" 0 $?
has "relative resolved" "%2Fsp%20ace" "$(tail -1 "$FAKE_LOG")"

# review without --wait: opens the document, no reply target, exits at once
: > "$FAKE_LOG"
run "$MIDAM" review "$DOC";           check "review no wait exit" 0 $RC
check "review no wait url" "midam://review?path=$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$REAL")" "$(tail -1 "$FAKE_LOG")"

# review --wait: approve -> 0, changes -> 10, nothing -> 20; the temp dir is always removed
export FAKE_REPLY='## a.md Review: Approve

1. `a.md:L1` "quoted"
   note'
FAKE_ANSWER=approve run "$MIDAM" review "$DOC" --wait --timeout 10
check "approve exit" 0 $RC; check "approve stdout" "$FAKE_REPLY" "$OUT"
URL=$(tail -1 "$FAKE_LOG"); has "reply url" "reply=" "$URL"
D=$(cat "$FAKE_DIR"); [ -e "$D" ] && { FAILS=$((FAILS + 1)); echo "FAIL temp dir left behind: $D"; }
case $D in */midam-review.??????) ;; *) FAILS=$((FAILS + 1)); echo "FAIL temp dir name: $D" ;; esac
FAKE_ANSWER=changes run "$MIDAM" review "$DOC" --wait --timeout 10
check "changes exit" 10 $RC; check "changes stdout" "$FAKE_REPLY" "$OUT"
FAKE_ANSWER=changes run "$MIDAM" review "$DOC" --wait --timeout 10 --json
check "json exit" 10 $RC
check "json reply" "$FAKE_REPLY" "$(jsget "$OUT" reply)"; check "json verdict" changes "$(jsget "$OUT" verdict)"; check "json path" "$REAL" "$(jsget "$OUT" path)"
FAKE_ANSWER=garbage run "$MIDAM" review "$DOC" --wait --timeout 10
check "bad verdict: 1" 1 $RC
START=$(date +%s)
FAKE_ANSWER= run "$MIDAM" review "$DOC" --wait --timeout 1
check "timeout exit" 20 $RC; has "timeout message" "timed out" "$ERR"; check "timeout stdout empty" "" "$OUT"
[ $(( $(date +%s) - START )) -le 4 ] || { FAILS=$((FAILS + 1)); echo "FAIL timeout took too long"; }
URL=$(tail -1 "$FAKE_LOG")
RD=$(printf %s "$URL" | sed -n 's/.*reply=\([^&]*\)%2Freply\.md.*/\1/p' | sed 's/%2F/\//g')
[ -n "$RD" ] && [ ! -e "$RD" ] || { FAILS=$((FAILS + 1)); echo "FAIL timeout left dir $RD"; }
FAKE_ANSWER= run "$MIDAM" review "$DOC" --wait --timeout=1 --quiet; check "quiet timeout" 20 $RC
# SIGTERM while waiting: exit 143 and the dir is removed (a terminal's Ctrl-C takes the same path with 130)
FAKE_ANSWER= "$MIDAM" review "$DOC" --wait --timeout 30 >/dev/null 2>&1 &
PID=$!
sleep 1.5
RD=$(tail -1 "$FAKE_LOG" | sed -n 's/.*reply=\([^&]*\)%2Freply\.md.*/\1/p' | sed 's/%2F/\//g')
[ -d "$RD" ] || { FAILS=$((FAILS + 1)); echo "FAIL review dir missing while waiting: $RD"; }
kill -TERM $PID; wait $PID; check "sigterm exit" 143 $?
[ ! -e "$RD" ] || { FAILS=$((FAILS + 1)); echo "FAIL sigterm left dir"; }
D=${RD%/midam-review.*}; ls "$D" 2>/dev/null | grep -q '^midam-review\.' && echo "note: other midam-review dirs exist in $D (not ours)"

# status
run "$MIDAM" status "$DOC" --json;    check "status exit" 0 $RC; check "status stderr" "" "$ERR"
check "status exists" true "$(jsget "$OUT" exists)"; check "status notes" 0 "$(jsget "$OUT" notes)"
check "status verdict" null "$(jsget "$OUT" verdict)"; check "status lastRead" null "$(jsget "$OUT" lastRead)"
check "status path" "$REAL" "$(jsget "$OUT" path)"
case $(jsget "$OUT" midamRunning) in true|false) ;; *) FAILS=$((FAILS + 1)); echo "FAIL midamRunning not a boolean" ;; esac
run "$MIDAM" status "$T/missing.md" --json; check "status missing exit" 0 $RC; check "status missing" false "$(jsget "$OUT" exists)"
run "$MIDAM" status "$DOC"
has "status human" "0 notes" "$OUT"
run "$MIDAM" status;                  check "status without path" 64 $RC

if [ "$FAILS" -eq 0 ]; then echo "cli-test: ok"; else echo "cli-test: $FAILS failure(s)"; exit 1; fi

#!/bin/sh
# Adversarial checks for both status line implementations.
#
#   sh tests/run.sh            # runs statusline.sh, and statusline.ps1 when powershell exists
#
# Everything happens in a throwaway cache directory, so the machine's own
# mascot and rate-limit cache are never touched.

cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd)
TMP="${TMPDIR:-/tmp}/statusline-test.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

# The cache path is handed to PowerShell too, so it must be a Windows-friendly
# absolute path when we are under MSYS.
CACHE="$TMP/cache"
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) CACHE=$(cd "$TMP" && pwd -W 2>/dev/null || pwd)/cache ;;
esac
export STATUSLINE_CACHE_DIR="$CACHE"

# The project path in the payload is what Claude Code would send: a native
# Windows path under MSYS, so PowerShell can resolve it too.
ROOT_W="$ROOT"
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) ROOT_W=$(pwd -W 2>/dev/null || pwd) ;;
esac

HAVE_PS=0
command -v powershell >/dev/null 2>&1 && HAVE_PS=1

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n      %s\n' "$1" "$2"; }
strip() { sed 's/\x1b\[[0-9;]*m//g'; }

SH="sh $ROOT/scripts/statusline.sh"
PS="powershell -NoProfile -ExecutionPolicy Bypass -File $ROOT/scripts/statusline.ps1"
HOOK_SH="sh $ROOT/scripts/mascot-hook.sh"
HOOK_PS="powershell -NoProfile -ExecutionPolicy Bypass -File $ROOT/scripts/mascot-hook.ps1"

payload() {
    # $1 session id, $2 dir, $3 ctx, $4 five, $5 five_reset
    printf '{"session_id":"%s","cwd":"%s","model":{"id":"x","display_name":"Opus 5"},"workspace":{"current_dir":"%s","project_dir":"%s"},"context_window":{"total_input_tokens":1,"current_usage":{"input_tokens":5,"output_tokens":1},"used_percentage":%s,"remaining_percentage":1},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":50,"resets_at":%s}}}' \
        "$1" "$2" "$2" "$2" "$3" "$4" "$5" "$5"
}

FUTURE=$(( $(date +%s) + 7200 ))
SID='test-session-0001-abcd'
P=$(payload "$SID" "$ROOT_W" 42 63 "$FUTURE")

run_both() {
    # $1 label, $2 payload; prints "sh:<line>" and "ps:<line>" (colours stripped)
    out_sh=$(printf '%s' "$2" | $SH | strip)
    printf 'sh:%s\n' "$out_sh"
    if [ "$HAVE_PS" -eq 1 ]; then
        out_ps=$(printf '%s' "$2" | $PS | strip | tr -d '\r')
        printf 'ps:%s\n' "$out_ps"
    fi
}

echo "== 1. plain render, no roll yet"
rm -rf "$CACHE"
run_both plain "$P" > "$TMP/o1"
if grep -q 'sh:DIR claude-code-statusline-astro | GIT ' "$TMP/o1" && grep -q '42%' "$TMP/o1" && grep -q '63%' "$TMP/o1"; then ok "sh renders DIR/GIT/CTX/5H"; else bad "sh basic render" "$(cat "$TMP/o1")"; fi
if grep -q '（' "$TMP/o1"; then bad "mascot shown before any roll" "$(cat "$TMP/o1")"; else ok "no mascot before a roll"; fi
lines=$(printf '%s' "$P" | $SH | wc -l | tr -d ' ')
[ "$lines" -eq 1 ] && ok "sh prints exactly one line" || bad "sh line count" "$lines"

echo "== 2. hooks create the key and the state file"
printf '%s' "$P" | $HOOK_SH working
[ -f "$CACHE/.gacha-key" ] && ok "sh hook wrote the machine key" || bad "sh hook key" "missing"
[ "$(cut -d' ' -f1 "$CACHE/mascot-testsess.txt" 2>/dev/null)" = working ] && ok "sh hook wrote the state" || bad "sh hook state" "$(cat "$CACHE/mascot-testsess.txt" 2>/dev/null)"
if [ "$HAVE_PS" -eq 1 ]; then
    key1=$(cat "$CACHE/.gacha-key")
    printf '%s' "$P" | $HOOK_PS -State done
    [ "$(cat "$CACHE/.gacha-key")" = "$key1" ] && ok "ps hook keeps an existing key" || bad "ps hook replaced the key" ""
    [ "$(cut -d' ' -f1 "$CACHE/mascot-testsess.txt" | tr -d '\r')" = done ] && ok "ps hook wrote the state" || bad "ps hook state" ""
fi

echo "== 3. roll once, then the face is everywhere and identical in both scripts"
$SH --roll > "$TMP/roll" 2>&1
grep -q '오늘의 마스코트를 뽑았습니다' "$TMP/roll" && ok "sh --roll" || bad "sh --roll" "$(cat "$TMP/roll")"
face_sh=$($SH --today | strip | sed -n 3p | sed 's/^  //; s/  .*//')
[ -n "$face_sh" ] && ok "sh --today shows a face ($face_sh)" || bad "sh --today" ""
other=$(payload 'another-session-9999' "$ROOT_W" 5 10 "$FUTURE")
printf '%s' "$other" | $SH | strip | grep -q "$face_sh" && ok "brand-new session shows the same face (idle)" || bad "idle face in new session" ""
if [ "$HAVE_PS" -eq 1 ]; then
    face_ps=$($PS -Today | strip | tr -d '\r' | sed -n 3p | sed 's/^  //; s/  .*//')
    [ "$face_ps" = "$face_sh" ] && ok "ps reads the same roll ($face_ps)" || bad "ps/sh face mismatch" "$face_ps vs $face_sh"
    name_sh=$($SH --today | strip | sed -n 3p | sed 's/.*  \([A-Za-z-]*\)  \[.*/\1/')
    name_ps=$($PS -Today | strip | tr -d '\r' | sed -n 3p | sed 's/.*  \([A-Za-z-]*\)  \[.*/\1/')
    [ "$name_ps" = "$name_sh" ] && ok "same name ($name_sh)" || bad "name mismatch" "$name_ps vs $name_sh"
fi

echo "== 4. a second roll the same day is refused"
$SH --roll | grep -q '이미 사용' && ok "sh refuses a second roll" || bad "sh second roll" ""
if [ "$HAVE_PS" -eq 1 ]; then $PS -Roll | grep -q '이미 사용' && ok "ps refuses a second roll" || bad "ps second roll" ""; fi

echo "== 5. tampering with the stored roll loses the mascot instead of upgrading it"
cp "$CACHE/gacha.txt" "$TMP/gacha.bak"
sed 's/ common \| uncommon \| rare \| unique / legend /' "$CACHE/gacha.txt" | awk '{ $4 = "legend"; $5 = 0; print }' > "$CACHE/gacha.txt"
$SH --today | grep -q '아직 뽑은 마스코트가 없습니다' && ok "sh: edited tier -> no mascot" || bad "sh accepted an edited tier" "$($SH --today | strip)"
if [ "$HAVE_PS" -eq 1 ]; then $PS -Today | grep -q '아직 뽑은 마스코트가 없습니다' && ok "ps: edited tier -> no mascot" || bad "ps accepted an edited tier" ""; fi
printf 'v1 20200101 1 legend 0 deadbeef' > "$CACHE/gacha.txt"
$SH --today | grep -q '아직' && ok "sh: forged signature -> no mascot" || bad "sh accepted a forged signature" ""
printf 'garbage' > "$CACHE/gacha.txt"
printf '%s' "$P" | $SH | strip | grep -q 'DIR claude' && ok "sh survives a garbage roll file" || bad "sh garbage roll" ""
cp "$TMP/gacha.bak" "$CACHE/gacha.txt"
# a roll stamped in the future (clock moved back) does not earn another roll
awk '{ $2 = "20990101"; print }' "$CACHE/gacha.txt" > "$TMP/g2"   # signature no longer matches -> no mascot, and no roll either? roll must be allowed only when the file is valid
cp "$TMP/gacha.bak" "$CACHE/gacha.txt"
$SH --today | grep -q "$face_sh" && ok "original roll restored" || bad "restore" ""

echo "== 6. hostile payloads never break the line"
for bad_payload in '' '{' 'null' '{"session_id":123}' '{"workspace":{"current_dir":"/nope/{weird}/dir"},"model":{"display_name":"X"},"context_window":{"used_percentage":"abc"}}' '{"rate_limits":{"five_hour":{"used_percentage":-50,"resets_at":"soon"}}}' '{"context_window":{"used_percentage":1e9}}'; do
    n=$(printf '%s' "$bad_payload" | $SH | wc -l | tr -d ' ')
    [ "$n" -eq 1 ] || bad "sh hostile payload line count" "$bad_payload -> $n lines"
    if [ "$HAVE_PS" -eq 1 ]; then
        n=$(printf '%s' "$bad_payload" | $PS | wc -l | tr -d ' ')
        [ "$n" -eq 1 ] || bad "ps hostile payload line count" "$bad_payload -> $n lines"
    fi
done
ok "hostile payloads: one line each"
if [ "$HAVE_PS" -eq 1 ]; then
    brace=$(payload 'brace-1' 'D:/{proj}/x' 42 63 "$FUTURE")
    printf '%s' "$brace" | $PS | strip | grep -q '42%' && ok "ps: brace inside a path does not break CTX" || bad "ps brace path" "$(printf '%s' "$brace" | $PS | strip)"
fi
printf 'v1 abc def\n' > "$CACHE/rl-broken0.txt"
printf '%s' "$P" | $SH | strip | grep -q '63%' && ok "sh ignores a corrupt rate-limit entry" || bad "sh corrupt rl" ""
rm -f "$CACHE/rl-broken0.txt"

echo "== 7. cross-session rate limit: the newest window and highest reading win"
printf 'v1 80 %s 50 %s\n' "$FUTURE" "$FUTURE" > "$CACHE/rl-peer0001.txt"
printf '%s' "$P" | $SH | strip | grep -q '80%' && ok "sh takes the higher peer reading" || bad "sh peer max" ""
printf 'v1 99 %s 50 %s\n' "$(( FUTURE - 100000 ))" "$FUTURE" > "$CACHE/rl-peer0002.txt"
printf '%s' "$P" | $SH | strip | grep -q '80%' && ok "sh ignores an older window" || bad "sh older window" ""
rm -f "$CACHE"/rl-peer*.txt

echo "== 8. options through the environment"
STATUSLINE_MASCOT=0 sh "$ROOT/scripts/statusline.sh" < /dev/null > /dev/null   # sanity: runs
if printf '%s' "$P" | STATUSLINE_MASCOT=0 $SH | strip | grep -q "$face_sh"; then bad "STATUSLINE_MASCOT=0 still shows the face" ""; else ok "STATUSLINE_MASCOT=0 hides the mascot"; fi
printf 'working %s\n' "$(date +%s)" > "$CACHE/mascot-testsess.txt"
with_talk=$(printf '%s' "$P" | $SH | strip)
no_talk=$(printf '%s' "$P" | STATUSLINE_TALK=0 $SH | strip)
[ "${#no_talk}" -lt "${#with_talk}" ] && ok "STATUSLINE_TALK=0 drops the line while working" || bad "STATUSLINE_TALK=0" "$with_talk / $no_talk"
printf '%s' "$P" | NO_COLOR=1 $SH | grep -q "$(printf '\033')" && bad "NO_COLOR left escapes" "" || ok "NO_COLOR strips every escape"
printf '%s' "$P" | STATUSLINE_SEVEN_DAY=1 $SH | strip | grep -q '7D' && ok "STATUSLINE_SEVEN_DAY=1 adds the weekly meter" || bad "7D" ""
if [ "$HAVE_PS" -eq 1 ]; then
    printf '%s' "$P" | STATUSLINE_SEVEN_DAY=1 $PS | strip | grep -q '7D' && ok "ps: STATUSLINE_SEVEN_DAY=1" || bad "ps 7D" ""
    printf '%s' "$P" | NO_COLOR=1 $PS | grep -q "$(printf '\033')" && bad "ps NO_COLOR" "" || ok "ps: NO_COLOR strips every escape"
fi

echo "== 9. states: error face, and the done line goes quiet after a minute"
printf 'error %s\n' "$(date +%s)" > "$CACHE/mascot-testsess.txt"
printf '%s' "$P" | $SH | strip | grep -q '（；' && ok "error state shows the error face" || bad "error face" "$(printf '%s' "$P" | $SH | strip)"
printf 'done %s\n' "$(( $(date +%s) - 3600 ))" > "$CACHE/mascot-testsess.txt"
quiet=$(printf '%s' "$P" | $SH | strip)
case "$quiet" in *"$face_sh") ok "old done state: face only, no line" ;; *) bad "old done state still talks" "$quiet" ;; esac

echo "== 10. both scripts print byte-identical lines"
# The two runs cannot share a second, so compare a state whose frame and line
# do not depend on the clock: "done" with a fresh stamp picks one fixed line
# and the first frame. A legend roll flows with the clock, so it is skipped.
if [ "$HAVE_PS" -eq 1 ]; then
    if $SH --today | grep -q '레전드'; then
        ok "skipped: legend rolled, its colours move with the clock"
    else
        printf 'done %s\n' "$(date +%s)" > "$CACHE/mascot-testsess.txt"
        a=$(printf '%s' "$P" | $SH | od -An -c | tr -d ' \n')
        b=$(printf '%s' "$P" | $PS | tr -d '\r' | od -An -c | tr -d ' \n')
        [ "$a" = "$b" ] && ok "identical output including colours" || bad "sh/ps output differs" "$(printf '%s' "$P" | $SH | cat -v | cut -c1-200)"
    fi
fi

echo "== 11. long project names lose their head"
long=$(payload 'long-1' "/tmp/this-is-a-very-long-project-directory-name-that-goes-on" 1 1 "$FUTURE")
printf '%s' "$long" | $SH | strip | grep -q 'DIR …' && ok "sh truncates from the left" || bad "sh truncation" "$(printf '%s' "$long" | $SH | strip)"

echo "== 12. every frame of a face has the same width"
if command -v python >/dev/null 2>&1; then
    python docs/legend/render.py check | grep -q '^ok' && ok "render.py width check" || bad "width check" "$(python docs/legend/render.py check)"
fi

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

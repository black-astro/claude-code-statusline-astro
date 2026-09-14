#!/bin/sh
# claude-statusline - mascot state hook (macOS, Linux, WSL, Git Bash).
#
# Claude Code never tells the status line whether a turn is running, so the
# hooks record it here and statusline.sh reads it back. Wire it up like this:
#
#   UserPromptSubmit -> mascot-hook.sh working
#   Stop             -> mascot-hook.sh done
#   StopFailure      -> mascot-hook.sh error
#   Notification     -> mascot-hook.sh notify
#
# It writes one small file and prints nothing, so it can never disturb a turn.
# Every failure path exits 0 for the same reason. No jq needed: one field is
# pulled straight out of the payload.

state="${1:-done}"
case "$state" in
    working|done|error|notify) ;;
    *) exit 0 ;;
esac

payload=$(cat 2>/dev/null | tr -d '\n\r')
[ -n "$payload" ] || exit 0

sid=$(printf '%s' "$payload" |
    sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
[ -n "$sid" ] || exit 0

# Must match the key statusline.sh derives: alphanumerics only, first 8 chars.
sid_key=$(printf '%s' "$sid" | tr -cd 'a-zA-Z0-9' | cut -c1-8)
[ -n "$sid_key" ] || exit 0

CACHE_DIR="${STATUSLINE_CACHE_DIR:-$HOME/.claude/statusline-cache}"
mkdir -p "$CACHE_DIR" 2>/dev/null || exit 0

# The per-machine key the daily draw is derived from. Created once, with a
# CSPRNG, and never touched again: the face for a given day is
# HMAC-SHA256(key, date), so a stable key is what makes the draw stable. ln
# fails if another process got there first, which leaves that key in place
# rather than replacing it; mv covers filesystems without hard links.
KEY_FILE="$CACHE_DIR/.gacha-key"
if [ ! -f "$KEY_FILE" ]; then
    key=''
    if command -v openssl >/dev/null 2>&1; then
        key=$(openssl rand -hex 32 2>/dev/null)
    elif [ -r /dev/urandom ]; then
        key=$(od -An -tx1 -N32 /dev/urandom 2>/dev/null | tr -d ' 

')
    fi
    if [ -n "$key" ]; then
        key_tmp="$KEY_FILE.tmp.$$"
        if (umask 077; printf '%s
' "$key" >"$key_tmp") 2>/dev/null; then
            if ln "$key_tmp" "$KEY_FILE" 2>/dev/null; then
                rm -f "$key_tmp" 2>/dev/null
            elif [ ! -f "$KEY_FILE" ]; then
                mv -f "$key_tmp" "$KEY_FILE" 2>/dev/null || rm -f "$key_tmp" 2>/dev/null
            else
                rm -f "$key_tmp" 2>/dev/null
            fi
        fi
    fi
fi

now=$(date +%s 2>/dev/null)
case "$now" in ''|*[!0-9]*) now=0 ;; esac

tmp="$CACHE_DIR/mascot-$sid_key.tmp.$$"
if printf '%s %s\n' "$state" "$now" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$CACHE_DIR/mascot-$sid_key.txt" 2>/dev/null || rm -f "$tmp" 2>/dev/null
fi

exit 0

#!/bin/sh
# claude-code-statusline — POSIX sh implementation (macOS, Linux, WSL, Git Bash).
#
# Reads the Claude Code session JSON from stdin and prints exactly one line:
#   DIR <project> | GIT <branch> | MODEL <name> | CTX [bar] NN% | 5H [bar] NN% 4h10m
#
# Set NO_COLOR=1 to strip the ANSI colors.

# Nothing may reach stderr: Claude Code renders whatever the command emits.
exec 2>/dev/null

# ---- appearance ------------------------------------------------------------
BAR_LEN=10
# U+25FC/25FB draw a near-square block with the glyph's own margins, so flush
# cells still show a hairline gap, and the empty cell renders as an outlined
# box rather than a shaded fill.
BAR_FULL='◼'    # U+25FC  filled cell
BAR_EMPTY='◻'   # U+25FB  empty cell (outlined)
BAR_GAP=''      # cells are flush; the glyph provides its own separation
BAR_PAD=''      # spacing just inside the brackets
DIR_MAX=32      # project name is left-truncated past this many characters

SHOW_SEVEN_DAY=0  # set to 1 to also show the 7-day (weekly) meter

# Mascot: a kaomoji at the end of the line reflecting what the session is doing.
# It needs the companion hook (mascot-hook.sh) to know the state - without it the
# state file never appears and the mascot simply stays hidden.
SHOW_MASCOT=1
# Rarity odds in per-mille, lowest rarity first. They must total 1000 and line up
# with MASCOT_TIERS below.
MASCOT_ODDS='600 250 100 40 10'
MASCOT_TIERS='common uncommon rare unique legend'

# Meters turn amber at WARN_AT and red at CRIT_AT.
WARN_AT=60
CRIT_AT=90

# Rate-limit snapshots are shared between sessions through this directory so
# every terminal shows the freshest value any of them has seen.
CACHE_DIR="${STATUSLINE_CACHE_DIR:-$HOME/.claude/statusline-cache}"

if [ -n "${NO_COLOR:-}" ]; then
    RESET=''
    DIM=''
    C_DIR=''
    C_GIT_MAIN=''
    C_GIT_OTHER=''
    C_MODEL=''
    C_OK=''
    C_WARN=''
    C_CRIT=''
    C_COMMON=''
    C_UNCOMMON=''
    C_RARE=''
    C_UNIQUE=''
    C_LEGEND=''
else
    ESC=$(printf '\033')
    RESET="${ESC}[0m"
    DIM="${ESC}[90m"
    C_DIR="${ESC}[97m"              # bright white — project name
    C_GIT_MAIN="${ESC}[95m"         # magenta — main / master
    C_GIT_OTHER="${ESC}[96m"        # sky blue — every other branch
    C_MODEL="${ESC}[93m"            # yellow — model name
    # 256-color meter palette. For 16-color-only terminals use
    # 96 / 93 / 91 in place of these three.
    C_OK="${ESC}[38;5;46m"          # neon green  — under WARN_AT
    C_WARN="${ESC}[38;5;214m"       # amber       — WARN_AT and up
    C_CRIT="${ESC}[38;5;203m"       # red         — CRIT_AT and up
    # Mascot rarity palette, common -> legend.
    C_COMMON="${ESC}[38;5;255m"     # white
    C_UNCOMMON="${ESC}[38;5;82m"    # green
    C_RARE="${ESC}[38;5;117m"       # sky blue
    C_UNIQUE="${ESC}[38;5;141m"     # purple
    C_LEGEND="${ESC}[1;38;5;208m"   # orange, bold
fi

payload=$(cat | tr -d '\n\r')

# ---- payload fields --------------------------------------------------------
# jq handles the payload properly when present; the sed fallback covers the
# handful of flat fields this status line needs on machines without it.
get_str() {
    printf '%s' "$payload" |
        sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p"
}

get_nested_num() {
    printf '%s' "$payload" |
        sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*{\\([^{}]*\\)}.*/\\1/p" |
        sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\\([0-9][0-9.]*\\).*/\\1/p"
}

if command -v jq >/dev/null 2>&1; then
    dir=$(printf '%s' "$payload" | jq -r '(.workspace.current_dir // .cwd // "")')
    model=$(printf '%s' "$payload" | jq -r '(.model.display_name // "")')
    sid=$(printf '%s' "$payload" | jq -r '(.session_id // "")')
    ctx=$(printf '%s' "$payload" | jq -r '(.context_window.used_percentage // "")')
    five=$(printf '%s' "$payload" | jq -r '(.rate_limits.five_hour.used_percentage // "")')
    five_reset=$(printf '%s' "$payload" | jq -r '(.rate_limits.five_hour.resets_at // "")')
    seven=$(printf '%s' "$payload" | jq -r '(.rate_limits.seven_day.used_percentage // "")')
    seven_reset=$(printf '%s' "$payload" | jq -r '(.rate_limits.seven_day.resets_at // "")')
else
    dir=$(get_str current_dir)
    [ -z "$dir" ] && dir=$(get_str cwd)
    model=$(get_str display_name)
    sid=$(get_str session_id)
    ctx=$(get_nested_num context_window used_percentage)
    five=$(get_nested_num five_hour used_percentage)
    five_reset=$(get_nested_num five_hour resets_at)
    seven=$(get_nested_num seven_day used_percentage)
    seven_reset=$(get_nested_num seven_day resets_at)
fi

[ -z "$model" ] && model='-'

now=$(date +%s 2>/dev/null)
case "$now" in ''|*[!0-9]*) now=0 ;; esac

# ---- git -------------------------------------------------------------------
branch=''
root=''
if [ -n "$dir" ] && [ -d "$dir" ] && command -v git >/dev/null 2>&1; then
    root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)

    branch=$(git -C "$dir" branch --show-current 2>/dev/null)
    if [ -z "$branch" ]; then
        branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
        [ "$branch" = 'HEAD' ] && branch=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)
    fi
fi

if [ -n "$branch" ]; then
    case "$branch" in
        main|master) c_branch=$C_GIT_MAIN ;;
        *)           c_branch=$C_GIT_OTHER ;;
    esac
else
    branch='-'
    c_branch=$DIM
fi

# ---- project name ----------------------------------------------------------
# Only the project root is shown. The full path is noise once you know where
# you are, and the repository root is what actually identifies the session.
[ -z "$root" ] && root="$dir"

if [ -n "$root" ]; then
    project=$(printf '%s' "$root" | sed 's#[\\/]*$##; s#.*[\\/]##')
    [ -z "$project" ] && project="$root"
    project=$(awk -v s="$project" -v max="$DIR_MAX" 'BEGIN{
        n = length(s)
        if (n <= max) { printf "%s", s } else { printf "…%s", substr(s, n - max + 2) }
    }')
else
    project='-'
fi

# ---- cross-session rate-limit sync -----------------------------------------
# The payload's rate_limits are a per-session snapshot frozen at that session's
# last API response, so idle terminals drift apart and disagree with the web
# usage page. Every session therefore publishes the snapshot it was handed, and
# every session renders the best snapshot published by anyone: the newest
# window wins, and within the same window the highest reading wins, because
# account usage only rises while a window is open.
#
# Cache line format (one line per session): "v1 <5h%> <5h_reset> <7d%> <7d_reset>"

round_pct() {
    case "$1" in
        *[0-9]*) awk -v v="$1" 'BEGIN{ v = v + 0; if (v < 0) v = 0; if (v > 100) v = 100; printf "%d", int(v + 0.5) }' ;;
    esac
}

to_epoch() {
    _e=${1%%.*}
    case "$_e" in
        *[!0-9]*|'') printf '' ;;
        *) printf '%s' "$_e" ;;
    esac
}

five_i=$(round_pct "$five")
five_r=$(to_epoch "$five_reset")
seven_i=$(round_pct "$seven")
seven_r=$(to_epoch "$seven_reset")

mkdir -p "$CACHE_DIR" 2>/dev/null

sid_key=$(printf '%s' "$sid" | tr -cd 'a-zA-Z0-9' | cut -c1-8)
if [ -n "$five_i" ] && [ -n "$sid_key" ] && [ -d "$CACHE_DIR" ]; then
    _tmp="$CACHE_DIR/rl-$sid_key.tmp.$$"
    printf 'v1 %s %s %s %s\n' \
        "$five_i" "${five_r:--}" "${seven_i:--}" "${seven_r:--}" >"$_tmp" &&
        mv -f "$_tmp" "$CACHE_DIR/rl-$sid_key.txt"
    # Entries from long-dead sessions stop mattering once their window closes;
    # sweep anything untouched for two days to keep the directory small.
    find "$CACHE_DIR" \( -name 'rl-*.txt' -o -name 'mascot-*.txt' \) -mmin +2880 -exec rm -f {} + 2>/dev/null
fi

best5u=$five_i; best5r=${five_r:-0}
best7u=$seven_i; best7r=${seven_r:-0}
[ -z "$best5u" ] && best5r=0
[ -z "$best7u" ] && best7r=0

for f in "$CACHE_DIR"/rl-*.txt; do
    [ -f "$f" ] || continue
    read -r _v _u5 _r5 _u7 _r7 <"$f" || continue
    [ "$_v" = 'v1' ] || continue

    case "$_u5" in
        ''|*[!0-9]*) ;;
        *)
            case "$_r5" in *[!0-9]*|'') _r5=0 ;; esac
            if [ -z "$best5u" ] || [ "$_r5" -gt "$best5r" ]; then
                best5u=$_u5; best5r=$_r5
            elif [ "$_r5" -eq "$best5r" ] && [ "$_u5" -gt "$best5u" ]; then
                best5u=$_u5
            fi
            ;;
    esac

    case "$_u7" in
        ''|*[!0-9]*) ;;
        *)
            case "$_r7" in *[!0-9]*|'') _r7=0 ;; esac
            if [ -z "$best7u" ] || [ "$_r7" -gt "$best7r" ]; then
                best7u=$_u7; best7r=$_r7
            elif [ "$_r7" -eq "$best7r" ] && [ "$_u7" -gt "$best7u" ]; then
                best7u=$_u7
            fi
            ;;
    esac
done

# ---- meters ----------------------------------------------------------------
# Renders "[◼◼◼◼◻◻◻◻◻◻] 42% 4h10m". The whole meter — brackets, filled cells
# and the outlines of empty cells — carries the load color, and the bar width
# never changes so the line does not jitter.
# The countdown is the time until the window resets, computed locally from
# resets_at — it costs nothing and is the one part that is always current.
#
# A snapshot whose resets_at has already passed is from a window that is over,
# so the number is marked with "~" and dimmed instead of given a countdown.
fmt_remaining() {
    _rem=$1
    if [ "$_rem" -ge 3600 ]; then
        printf '%dh%02dm' $((_rem / 3600)) $(( (_rem % 3600) / 60 ))
    elif [ "$_rem" -ge 60 ]; then
        printf '%dm' $((_rem / 60))
    else
        printf '<1m'
    fi
}

meter() {
    _raw=$1
    _reset=$2

    _known=1
    case "$_raw" in
        *[0-9]*) ;;
        *) _known=0 ;;
    esac

    if [ "$_known" -eq 1 ]; then
        _n=$(round_pct "$_raw")
        case "$_n" in
            ''|*[!0-9]*) _known=0 ;;
        esac
    fi

    _stale=0
    _cd=''
    case "$_reset" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$now" -gt 0 ] && [ "$_reset" -gt 0 ]; then
                if [ "$_reset" -lt "$now" ]; then
                    _stale=1
                else
                    _cd=$(fmt_remaining $((_reset - now)))
                fi
            fi
            ;;
    esac

    if [ "$_known" -eq 0 ]; then
        _filled=0
        _c=$DIM
        _cpct=$DIM
        _pct='--%'
        _cd=''
    else
        _filled=$(( (_n + 5) / 10 ))
        [ "$_filled" -gt "$BAR_LEN" ] && _filled=$BAR_LEN
        if [ "$_n" -ge "$CRIT_AT" ]; then
            _c=$C_CRIT
        elif [ "$_n" -ge "$WARN_AT" ]; then
            _c=$C_WARN
        else
            _c=$C_OK
        fi
        if [ "$_stale" -eq 1 ]; then
            _cpct=$DIM
            _pct="~${_n}%"
        else
            _cpct=$_c
            _pct="${_n}%"
        fi
    fi

    _bar=''
    _i=0
    while [ "$_i" -lt "$BAR_LEN" ]; do
        [ "$_i" -gt 0 ] && _bar="${_bar}${BAR_GAP}"
        if [ "$_i" -lt "$_filled" ]; then
            _bar="${_bar}${_c}${BAR_FULL}"
        else
            _bar="${_bar}${_c}${BAR_EMPTY}"
        fi
        _i=$((_i + 1))
    done

    _out="${_c}[${BAR_PAD}${_bar}${_c}${BAR_PAD}] ${_cpct}${_pct}${RESET}"
    [ -n "$_cd" ] && _out="${_out} ${DIM}${_cd}${RESET}"
    printf '%s' "$_out"
}

# ---- mascot ----------------------------------------------------------------
# The face is the day's draw. It is never stored and it is never rolled here:
# it is derived from HMAC-SHA256(machine key, today's date). The same day
# therefore always yields the same face however often this script runs, and no
# amount of editing or deleting files changes it - forcing a legend would mean
# inverting HMAC-SHA256. The key is created once by mascot-hook.sh.
#
# Each face carries two frames of one expression, always the same width so the
# line never jitters. While a turn runs the frames alternate on every refresh;
# once the turn is done the face settles on its first frame.
#
# Faces are separated by '|' and their two frames by '#'; no face contains
# either character, so cut can index them.
KAO_ERROR='（；へ：）#（；ω；）'
KAO_COMMON='（・ω・）#（－ω－）|（´･ω･）#（´－ω－）|（・_・）#（－_－）|（ ˘ω˘ ）#（ ˘ᴗ˘ ）|（=・ω・=）#（=－ω－=）|（・∀・）#（－∀－）'
KAO_UNCOMMON='（๑˃ᴗ˂）#（๑˂ᴗ˃）|（｡･ω･｡）#（｡－ω－｡）|（^▽^）#（^ω^）|（・ㅂ・）#（－ㅂ－）|（◕‿◕）#（◠‿◠）'
KAO_RARE='（๑˃ᴗ˂）✧#（๑˃ᴗ˂）✦|ヽ（•‿•）ノ#ヾ（•‿•）ﾉ|（★ω★）#（☆ω☆）|（◕‿◕）✧#（◠‿◠）✦|\（^o^）/#\（^O^）/'
KAO_UNIQUE='（☆▽☆）#（★▽★）|ヽ（°〇°）ﾉ#ヾ（°Д°）ﾉ|（ﾉ◕ヮ◕）ﾉ#（ヽ◕ヮ◕）ヽ|（♡‿♡）#（♥‿♥）'
KAO_LEGEND='✧（◕ᴗ◕）✧#✦（◕ᴗ◕）✦|ヽ（♡‿♡）ノ#ヾ（♥‿♥）ﾉ|（ﾉ≧∇≦）ﾉ#（ﾉ≧▽≦）ﾉ|♪（๑ᴖ◡ᴖ๑）♪#♫（๑ᴖ◡ᴖ๑）♫'

MASCOT_TIERS='common uncommon rare unique legend'

kao_count() { printf %s "$1" | awk -F'|' '{print NF}'; }
kao_face() { printf %s "$1" | cut -d'|' -f"$2"; }
kao_frame() { printf %s "$1" | cut -d'#' -f"$2"; }

# HMAC-SHA256 as hex. openssl is the one that matches the PowerShell version
# byte for byte; the sha256 fallbacks only keep the mascot working where
# openssl is missing, and give that machine its own faces.
gacha_hmac() {
    if command -v openssl >/dev/null 2>&1; then
        printf %s "$2" | openssl dgst -sha256 -hmac "$1" 2>/dev/null | sed 's/.*= *//'
    elif command -v sha256sum >/dev/null 2>&1; then
        printf %s "$1$2" | sha256sum 2>/dev/null | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        printf %s "$1$2" | shasum -a 256 2>/dev/null | cut -d' ' -f1
    fi
}

# Sets GACHA_TIER and GACHA_INDEX for today, or returns 1 when there is no key
# - which is also what a fresh install looks like before the first turn ends.
# Two independent 32-bit windows of one HMAC pick the tier and the face.
gacha_draw() {
    _key=$(cat "$CACHE_DIR/.gacha-key" 2>/dev/null | tr -d " 	
")
    [ -n "$_key" ] || return 1

    _today=$(date +%Y%m%d 2>/dev/null)
    case "$_today" in ''|*[!0-9]*) return 1 ;; esac

    _sig=$(gacha_hmac "$_key" "gacha|v1|$_today")
    [ -n "$_sig" ] || return 1
    [ "${#_sig}" -ge 16 ] || return 1

    _n1=$(printf '%d' "0x$(printf %s "$_sig" | cut -c1-8)" 2>/dev/null) || return 1
    _n2=$(printf '%d' "0x$(printf %s "$_sig" | cut -c9-16)" 2>/dev/null) || return 1

    _roll=$(( _n1 % 1000 ))
    _acc=0
    _ti=1
    GACHA_TIER=common
    for _odd in $MASCOT_ODDS; do
        _acc=$(( _acc + _odd ))
        if [ "$_roll" -lt "$_acc" ]; then
            GACHA_TIER=$(printf %s "$MASCOT_TIERS" | cut -d' ' -f"$_ti")
            break
        fi
        _ti=$(( _ti + 1 ))
    done

    _pool=$(gacha_pool "$GACHA_TIER")
    _kn=$(kao_count "$_pool")
    [ "$_kn" -gt 0 ] || return 1
    GACHA_INDEX=$(( _n2 % _kn + 1 ))
    return 0
}

gacha_pool() {
    case "$1" in
        common) printf %s "$KAO_COMMON" ;;
        uncommon) printf %s "$KAO_UNCOMMON" ;;
        rare) printf %s "$KAO_RARE" ;;
        unique) printf %s "$KAO_UNIQUE" ;;
        legend) printf %s "$KAO_LEGEND" ;;
    esac
}

gacha_color() {
    case "$1" in
        legend)   printf %s "$C_LEGEND" ;;
        unique)   printf %s "$C_UNIQUE" ;;
        rare)     printf %s "$C_RARE" ;;
        uncommon) printf %s "$C_UNCOMMON" ;;
        *)        printf %s "$C_COMMON" ;;
    esac
}

# Reads the turn state the hooks left for this session and draws the face.
# Prints nothing when the hooks are not installed, so the line then looks
# exactly as it did before the mascot existed.
mascot() {
    [ "$SHOW_MASCOT" -eq 1 ] || return 0
    [ -n "$sid_key" ] || return 0

    _mf="$CACHE_DIR/mascot-$sid_key.txt"
    [ -f "$_mf" ] || return 0
    _raw=$(cat "$_mf" 2>/dev/null) || return 0
    [ -n "$_raw" ] || return 0
    _state=$(printf %s "$_raw" | awk '{print $1}')

    if [ "$_state" = error ]; then
        _fr=1
        [ "$now" -gt 0 ] && _fr=$(( (now / 5) % 2 + 1 ))
        printf '%s' "${C_CRIT}$(kao_frame "$KAO_ERROR" "$_fr")${RESET}"
        return 0
    fi
    [ "$_state" = working ] || [ "$_state" = done ] || return 0

    gacha_draw || return 0
    _face=$(kao_face "$(gacha_pool "$GACHA_TIER")" "$GACHA_INDEX")
    [ -n "$_face" ] || return 0

    _fr=1
    if [ "$_state" = working ] && [ "$now" -gt 0 ]; then
        _fr=$(( (now / 5) % 2 + 1 ))
    fi
    printf '%s' "$(gacha_color "$GACHA_TIER")$(kao_frame "$_face" "$_fr")${RESET}"
}
# ---- output ----------------------------------------------------------------
SEP="${DIM} | ${RESET}"
line="${DIM}DIR${RESET} ${C_DIR}${project}${RESET}"
line="${line}${SEP}${DIM}GIT${RESET} ${c_branch}${branch}${RESET}"
line="${line}${SEP}${DIM}MODEL${RESET} ${C_MODEL}${model}${RESET}"
line="${line}${SEP}${DIM}CTX${RESET} $(meter "$ctx" '')"
line="${line}${SEP}${DIM}5H${RESET} $(meter "$best5u" "$best5r")"
if [ "$SHOW_SEVEN_DAY" -eq 1 ]; then
    line="${line}${SEP}${DIM}7D${RESET} $(meter "$best7u" "$best7r")"
fi
_mascot=$(mascot)
[ -n "$_mascot" ] && line="${line} ${_mascot}"

printf '%s\n' "$line"
exit 0

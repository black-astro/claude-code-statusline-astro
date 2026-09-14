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

STATUSLINE_VERSION='1.3.0'

# Run with no arguments (the way Claude Code calls it) to print the status line.
#   --version   print the version and exit
#   --today     print today's mascot draw and exit
#   --help      print a short usage summary and exit
MASCOT_ONLY=0
case "${1:-}" in
    --version|-v)
        printf 'claude-code-statusline-astro %s\n' "$STATUSLINE_VERSION"
        exit 0
        ;;
    --help|-h)
        printf 'claude-code-statusline-astro %s\n\n' "$STATUSLINE_VERSION"
        printf '  statusline.sh            Claude Code calls this with session JSON on stdin\n'
        printf '  statusline.sh --today    show the mascot drawn for today\n'
        printf '  statusline.sh --version  show the version\n'
        printf '  statusline.sh --help     this text\n\n'
        printf 'Settings live at the top of this file. Update by re-running install.sh.\n'
        exit 0
        ;;
    --today)
        MASCOT_ONLY=1
        ;;
esac

STATUSLINE_VERSION='1.4.0'

# Run with no arguments (the way Claude Code calls it) to print the status line.
#   --roll      roll today's mascot (once a day) and exit
#   --today     print the mascot you are currently wearing and exit
#   --version   print the version and exit
#   --help      print a short usage summary and exit
SUBCOMMAND=''
case "${1:-}" in
    --version|-v)
        printf 'claude-code-statusline-astro %s\n' "$STATUSLINE_VERSION"
        exit 0
        ;;
    --help|-h)
        printf 'claude-code-statusline-astro %s\n\n' "$STATUSLINE_VERSION"
        printf '  statusline.sh            Claude Code calls this with session JSON on stdin\n'
        printf '  statusline.sh --roll     오늘의 마스코트 뽑기 (하루 한 번)\n'
        printf '  statusline.sh --today    지금 쓰고 있는 마스코트 보기\n'
        printf '  statusline.sh --version  버전 보기\n'
        printf '  statusline.sh --help     이 도움말\n\n'
        printf '뽑기는 하루 한 번이고, 뽑기 전까지 지금 마스코트가 그대로 유지됩니다.\n'
        exit 0
        ;;
    --roll)
        SUBCOMMAND=roll
        ;;
    --today)
        SUBCOMMAND=today
        ;;
esac

SHOW_SEVEN_DAY=0  # set to 1 to also show the 7-day (weekly) meter

# Mascot: a kaomoji at the end of the line reflecting what the session is doing.
# It needs the companion hook (mascot-hook.sh) to know the state - without it the
# state file never appears and the mascot simply stays hidden.
SHOW_MASCOT=1
# The mascot speaks a line when a turn finishes; set 0 for the face alone.
SHOW_MASCOT_TALK=1
# Seconds per animation step. Claude Code only redraws every refreshInterval,
# so anything below that value changes nothing - keep the two in step.
ANIM_SECS=3
# How long after a turn ends the mascot keeps talking. Past this it goes quiet
# until the next turn, so an idle terminal is not left with a stale sentence.
TALK_WINDOW_SECS=60
# Rarity odds in per-mille, lowest rarity first. They must total 1000 and line up
# with MASCOT_TIERS below.
MASCOT_ODDS='400 350 180 60 10'
MASCOT_TIERS='common uncommon rare unique legend'

# Maintainer tier. A key whose SHA-256 is listed here also rolls 'dev' faces;
# every other key never sees them. Only the hash is published, so the list gives
# nothing away - matching it would mean finding a preimage of SHA-256. Add your
# own hash to claim the tier on your machine: SHA-256 of the key file's text,
# trimmed of whitespace, hashed as UTF-8. The README gives the exact command.
DEV_KEY_HASHES='837cbfd9a3f7b0c8887e1654f8bed41800fd80a4cd4a969a14b1a5095d6fa31a'
# Per-mille odds of the dev tier; the ordinary tiers share what is left, keeping
# their ratio to each other.
DEV_ODDS=100

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
    C_DEV=''
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
    C_DEV="${ESC}[1;38;5;51m"       # cyan, bold - maintainer only
fi

payload=''
[ -n "$SUBCOMMAND" ] || payload=$(cat | tr -d '\n\r')

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
# The face is whatever the last roll produced. Rolls happen once a day and only
# when asked for (statusline.sh --roll); nothing here changes the face on its
# own. The result is signed with the machine key, so the stored tier and face
# cannot be edited into something rarer.
#
# Each face carries frames of one expression, all the same width so the line
# never jitters. The frames advance while a turn runs and settle on the first
# one when it ends. Legend additionally shimmers through a flowing gradient.
#
# Faces are separated by '|' and their frames by '#'; no face contains either
# character, so cut can index them. Spoken lines use the same convention.
KAO_ERROR='（；へ：）#（；ω；）'
KAO_COMMON='（・ω・）#（－ω－）|（´･ω･）#（´－ω－）|（・_・）#（－_－）|（ ˘ω˘ ）#（ ˘ᴗ˘ ）|（=・ω・=）#（=－ω－=）|（・∀・）#（－∀－）|（＞ω＜）#（＞ᴗ＜）|（・ｖ・）#（－ｖ－）|（^_^）#（^ω^）|（・◡・）#（－◡－）|（・ツ・）#（－ツ－）|（¬ω¬）#（¬_¬）'
KAO_UNCOMMON='（๑˃ᴗ˂）#（๑˂ᴗ˃）|（｡･ω･｡）#（｡－ω－｡）|（^▽^）#（^ᴗ^）|（・ㅂ・）#（－ㅂ－）|（◕‿◕）#（◠‿◠）|（๑•ᴗ•๑）#（๑-ᴗ-๑）|（≧ω≦）#（≧ᴗ≦）|（･ω<）#（･ᴗ<）|（。◕‿◕。）#（。◠‿◠。）|（＾▽＾）#（＾ᴗ＾）|（･◡･）#（･ᴗ･）|（≖‿≖）#（≖_≖）'
KAO_RARE='（๑˃ᴗ˂）✧#（๑˃ᴗ˂）✦|ヽ（•‿•）ノ#ヾ（•‿•）ﾉ|（★ω★）#（☆ω☆）|（◕‿◕）✧#（◠‿◠）✦|\（^o^）/#\（^O^）/|（✧ω✧）#（✦ω✦）|ヽ（◕‿◕）ノ#ヾ（◠‿◠）ﾉ|（๑✧‿✧๑）#（๑✦‿✦๑）|（★‿★）#（☆‿☆）|（≧∇≦）✧#（≧▽≦）✦|ヽ（^ω^）ノ#ヾ（^ᴗ^）ﾉ|（･∀･）✧#（･∀･）✦'
KAO_UNIQUE='（☆▽☆）#（★▽★）|ヽ（°〇°）ﾉ#ヾ（°Д°）ﾉ|（ﾉ◕ヮ◕）ﾉ#（ヽ◕ヮ◕）ヽ|（♡‿♡）#（♥‿♥）|（ﾉ☆▽☆）ﾉ#（ヽ★▽★）ヽ|（๑♡‿♡๑）#（๑♥‿♥๑）|ヽ（✧∇✧）ノ#ヾ（✦▽✦）ﾉ|（＠◕ᴗ◕＠）#（＠◠ᴗ◠＠）|（ﾉ≧ڡ≦）ﾉ#（ヽ≧ڡ≦）ヽ'
KAO_LEGEND='✧（◕ᴗ◕）✧#✦（◕ᴗ◕）✦#✧（◕ᴗ◕）✦#✦（◕ᴗ◕）✧|ヽ（♡‿♡）ノ#ヾ（♥‿♥）ﾉ#ヽ（♥‿♥）ノ#ヾ（♡‿♡）ﾉ|（ﾉ≧∇≦）ﾉ#（ﾉ≧▽≦）ﾉ#（ヽ≧∇≦）ヽ#（ヽ≧▽≦）ヽ|♪（๑ᴖ◡ᴖ๑）♪#♫（๑ᴖ◡ᴖ๑）♫#♩（๑ᴖ◡ᴖ๑）♩#♬（๑ᴖ◡ᴖ๑）♬|（✧ᴗ✧）#（✦ᴗ✦）#（★ᴗ★）#（☆ᴗ☆）'
KAO_DEV='（¬‿¬）#（¬_¬）|（☞ﾟヮﾟ）☞#（☜ﾟヮﾟ）☜|（◣_◢）#（◢_◣）|ᕙ（⇀‸↼）ᕗ#ᕦ（⇀‸↼）ᕤ'

# The mascot only speaks while a turn runs, right after one ends, and when
# something is waiting on you. The rest of the time it just sits there.
TALK_ERROR='앗...|실패했어요...'
TALK_WORK_COMMON='끙...|우우|낑낑|웅...'
TALK_WORK_UNCOMMON='하는 중!|조금만!|열일 중!|가는 중!'
TALK_WORK_RARE='작업 중이에요|조금만 기다려요|거의 다 왔어요'
TALK_WORK_UNIQUE='처리하고 있어요!|조금만 기다려 주세요!|열심히 하는 중이에요!'
TALK_WORK_LEGEND='작업을 진행하고 있습니다!|곧 마무리됩니다, 잠시만요!'
TALK_WORK_DEV='빌드 도는 중.|컴파일 중.|테스트 도는 중.'
TALK_DONE_COMMON='왕!|냥!|뿌!|삐약!|꽥!|음냐'
TALK_DONE_UNCOMMON='왕왕!|다했다!|끝!|됐다!|오케이!|히히'
TALK_DONE_RARE='다 됐어요|끝났어요|완료했어요|해냈어요!|준비 끝!'
TALK_DONE_UNIQUE='작업 완료했어요!|다 끝냈습니다!|깔끔하게 끝냈어요!|확인해 보세요!'
TALK_DONE_LEGEND='요청하신 작업 모두 완료했습니다!|전부 끝냈습니다, 확인 부탁드려요!|작업을 성공적으로 마쳤습니다!'
TALK_DONE_DEV='빌드 통과.|커밋하시죠.|배포 준비 완료.|테스트 전부 초록불.'
TALK_NOTIFY_COMMON='앙?|웅?|왕?'
TALK_NOTIFY_UNCOMMON='저기요!|잠깐만요!|봐주세요!'
TALK_NOTIFY_RARE='확인해 주세요|봐주셔야 해요'
TALK_NOTIFY_UNIQUE='확인 부탁해요!|잠시 봐주세요!'
TALK_NOTIFY_LEGEND='확인 부탁드립니다!|잠시 확인해 주세요!'
TALK_NOTIFY_DEV='입력 대기 중.|확인 요망.'

MASCOT_TIERS='common uncommon rare unique legend'

# The legend gradient walks this ramp, one hue per character.
RAINBOW='196 202 208 214 220 190 118 46 48 51 45 39 63 99 129 201'

kao_count() { printf %s "$1" | awk -F'|' '{print NF}'; }
kao_at() { printf %s "$1" | cut -d'|' -f"$2"; }
kao_frames() { printf %s "$1" | awk -F'#' '{print NF}'; }
kao_frame() { printf %s "$1" | cut -d'#' -f"$2"; }

# HMAC-SHA256 as hex. openssl is the one that matches the PowerShell version
# byte for byte; the sha256 fallbacks only keep things working where openssl is
# missing, and give that machine its own results.
gacha_hmac() {
    if command -v openssl >/dev/null 2>&1; then
        printf %s "$2" | openssl dgst -sha256 -hmac "$1" 2>/dev/null | sed 's/.*= *//'
    elif command -v sha256sum >/dev/null 2>&1; then
        printf %s "$1$2" | sha256sum 2>/dev/null | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        printf %s "$1$2" | shasum -a 256 2>/dev/null | cut -d' ' -f1
    fi
}

gacha_key() { cat "$CACHE_DIR/.gacha-key" 2>/dev/null | tr -d " \t\n\r"; }

# Whether this machine's key is one of the maintainer keys. Comparing hashes
# rather than keys is what lets the list ship in the open.
is_dev_key() {
    [ -n "$DEV_KEY_HASHES" ] || return 1
    _kh=''
    if command -v sha256sum >/dev/null 2>&1; then
        _kh=$(printf %s "$1" | sha256sum 2>/dev/null | cut -d' ' -f1)
    elif command -v shasum >/dev/null 2>&1; then
        _kh=$(printf %s "$1" | shasum -a 256 2>/dev/null | cut -d' ' -f1)
    elif command -v openssl >/dev/null 2>&1; then
        _kh=$(printf %s "$1" | openssl dgst -sha256 2>/dev/null | sed 's/.*= *//')
    fi
    [ -n "$_kh" ] || return 1
    for _dh in $DEV_KEY_HASHES; do
        [ "$_kh" = "$_dh" ] && return 0
    done
    return 1
}

gacha_pool() {
    case "$1" in
        common)   printf %s "$KAO_COMMON" ;;
        uncommon) printf %s "$KAO_UNCOMMON" ;;
        rare)     printf %s "$KAO_RARE" ;;
        unique)   printf %s "$KAO_UNIQUE" ;;
        legend)   printf %s "$KAO_LEGEND" ;;
        dev)      printf %s "$KAO_DEV" ;;
    esac
}

talk_pool() {
    case "$1.$2" in
        work.common)       printf %s "$TALK_WORK_COMMON" ;;
        work.uncommon)     printf %s "$TALK_WORK_UNCOMMON" ;;
        work.rare)         printf %s "$TALK_WORK_RARE" ;;
        work.unique)       printf %s "$TALK_WORK_UNIQUE" ;;
        work.legend)       printf %s "$TALK_WORK_LEGEND" ;;
        work.dev)          printf %s "$TALK_WORK_DEV" ;;
        done.common)       printf %s "$TALK_DONE_COMMON" ;;
        done.uncommon)     printf %s "$TALK_DONE_UNCOMMON" ;;
        done.rare)         printf %s "$TALK_DONE_RARE" ;;
        done.unique)       printf %s "$TALK_DONE_UNIQUE" ;;
        done.legend)       printf %s "$TALK_DONE_LEGEND" ;;
        done.dev)          printf %s "$TALK_DONE_DEV" ;;
        notify.common)     printf %s "$TALK_NOTIFY_COMMON" ;;
        notify.uncommon)   printf %s "$TALK_NOTIFY_UNCOMMON" ;;
        notify.rare)       printf %s "$TALK_NOTIFY_RARE" ;;
        notify.unique)     printf %s "$TALK_NOTIFY_UNIQUE" ;;
        notify.legend)     printf %s "$TALK_NOTIFY_LEGEND" ;;
        notify.dev)        printf %s "$TALK_NOTIFY_DEV" ;;
    esac
}

# Sets ROLL_DATE / ROLL_EPOCH / ROLL_TIER / ROLL_INDEX from the stored roll, or
# returns 1 when there is none. A bad signature reads as no roll at all, so an
# edited file loses the mascot rather than granting a better one.
read_roll() {
    _rf="$CACHE_DIR/gacha.txt"
    [ -f "$_rf" ] || return 1
    _rr=$(cat "$_rf" 2>/dev/null) || return 1
    [ -n "$_rr" ] || return 1

    set -- $_rr
    [ "$#" -ge 6 ] || return 1
    [ "$1" = v1 ] || return 1

    _rkey=$(gacha_key)
    [ -n "$_rkey" ] || return 1
    _want=$(gacha_hmac "$_rkey" "roll|v1|$2|$3|$4|$5")
    [ -n "$_want" ] || return 1
    [ "$_want" = "$6" ] || return 1
    [ -n "$(gacha_pool "$4")" ] || return 1

    ROLL_DATE=$2
    ROLL_EPOCH=$3
    ROLL_TIER=$4
    ROLL_INDEX=$5
    case "$ROLL_EPOCH" in ''|*[!0-9]*) ROLL_EPOCH=0 ;; esac
    return 0
}

# One roll per calendar day. A stored roll stamped in the future means the clock
# moved backwards, and that does not earn another roll either.
can_roll() {
    read_roll || return 0
    _today=$(date +%Y%m%d 2>/dev/null)
    [ "$ROLL_DATE" = "$_today" ] && return 1
    if [ "$now" -gt 0 ] && [ "$ROLL_EPOCH" -gt 0 ] && [ "$now" -lt "$ROLL_EPOCH" ]; then
        return 1
    fi
    return 0
}

# Rolls once and stores the signed result. The randomness is cryptographic, so
# the outcome is not predictable from the date or from previous rolls.
do_roll() {
    _key=$(gacha_key)
    [ -n "$_key" ] || return 1

    _rand=''
    if command -v openssl >/dev/null 2>&1; then
        _rand=$(openssl rand -hex 8 2>/dev/null)
    elif [ -r /dev/urandom ]; then
        _rand=$(od -An -tx1 -N8 /dev/urandom 2>/dev/null | tr -d ' \n\r')
    fi
    [ "${#_rand}" -ge 16 ] || return 1

    _n1=$(printf '%d' "0x$(printf %s "$_rand" | cut -c1-8)" 2>/dev/null) || return 1
    _n2=$(printf '%d' "0x$(printf %s "$_rand" | cut -c9-16)" 2>/dev/null) || return 1

    _tiers=$MASCOT_TIERS
    _odds=$MASCOT_ODDS
    if is_dev_key "$_key"; then
        _scaled=''
        _used=0
        for _odd in $MASCOT_ODDS; do
            _v=$(( _odd * (1000 - DEV_ODDS) / 1000 ))
            _scaled="$_scaled $_v"
            _used=$(( _used + _v ))
        done
        _tiers="dev $MASCOT_TIERS"
        _odds="$(( 1000 - _used ))$_scaled"
    fi

    _roll=$(( _n1 % 1000 ))
    _acc=0
    _ti=1
    ROLL_TIER=common
    for _odd in $_odds; do
        _acc=$(( _acc + _odd ))
        if [ "$_roll" -lt "$_acc" ]; then
            ROLL_TIER=$(printf %s "$_tiers" | cut -d' ' -f"$_ti")
            break
        fi
        _ti=$(( _ti + 1 ))
    done

    _kn=$(kao_count "$(gacha_pool "$ROLL_TIER")")
    [ "$_kn" -gt 0 ] || return 1
    ROLL_INDEX=$(( _n2 % _kn + 1 ))

    ROLL_DATE=$(date +%Y%m%d 2>/dev/null)
    ROLL_EPOCH=$now
    [ "$ROLL_EPOCH" -gt 0 ] || ROLL_EPOCH=$(date +%s 2>/dev/null)
    _sig=$(gacha_hmac "$_key" "roll|v1|$ROLL_DATE|$ROLL_EPOCH|$ROLL_TIER|$ROLL_INDEX")
    [ -n "$_sig" ] || return 1

    mkdir -p "$CACHE_DIR" 2>/dev/null || return 1
    _tmp="$CACHE_DIR/gacha.tmp.$$"
    printf 'v1 %s %s %s %s %s' "$ROLL_DATE" "$ROLL_EPOCH" "$ROLL_TIER" "$ROLL_INDEX" "$_sig" \
        >"$_tmp" 2>/dev/null || return 1
    mv -f "$_tmp" "$CACHE_DIR/gacha.txt" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; return 1; }
    return 0
}

# Flat tier color. Legend uses this only when the gradient is unavailable.
tier_color() {
    case "$1" in
        legend)   printf %s "$C_LEGEND" ;;
        dev)      printf %s "$C_DEV" ;;
        unique)   printf %s "$C_UNIQUE" ;;
        rare)     printf %s "$C_RARE" ;;
        uncommon) printf %s "$C_UNCOMMON" ;;
        *)        printf %s "$C_COMMON" ;;
    esac
}

# The gradient walks character by character, so it needs an awk that counts
# characters rather than bytes. gawk in a UTF-8 locale does; mawk and busybox
# awk do not, and there the caller falls back to one flat color.
awk_counts_chars() {
    [ "$(printf %s "\u00ac\u203f" | awk '{print length($0)}' 2>/dev/null)" = 2 ]
}

# Paints every character its own hue along the rainbow and drifts the whole ramp
# one step per animation tick, so the color flows across the text.
grad_text() {
    printf %s "$1" | awk -v off="$2" -v esc="$ESC" -v rb="$RAINBOW" '
        BEGIN { n = split(rb, C, " ") }
        {
            for (i = 1; i <= length($0); i++) {
                printf "%s[1;38;5;%sm%s", esc, C[((off + i - 1) % n) + 1], substr($0, i, 1)
            }
        }'
}

# Picks a line from a pool, seeded with the timestamp the hook recorded, so it
# holds steady across redraws and changes with the next turn.
pick_talk() {
    [ "$SHOW_MASCOT_TALK" -eq 1 ] || return 0
    _tp="$1"
    [ -n "$_tp" ] || return 0
    _tn=$(kao_count "$_tp")
    [ "$_tn" -gt 0 ] || return 0
    _th=$(( ($2 * 1103515245 + 12345) % 2147483648 ))
    [ "$_th" -lt 0 ] && _th=$(( 0 - _th ))
    kao_at "$_tp" "$(( _th % _tn + 1 ))"
}

# Reads the turn state the hooks left for this session and draws the face.
# Prints nothing when nothing has been rolled yet or the hooks are not
# installed, so the line then looks as it did before the mascot existed.
mascot() {
    [ "$SHOW_MASCOT" -eq 1 ] || return 0
    [ -n "$sid_key" ] || return 0

    _mf="$CACHE_DIR/mascot-$sid_key.txt"
    [ -f "$_mf" ] || return 0
    _raw=$(cat "$_mf" 2>/dev/null) || return 0
    [ -n "$_raw" ] || return 0
    _state=$(printf %s "$_raw" | awk '{print $1}')
    _stamp=$(printf %s "$_raw" | awk '{print $2}')
    case "$_stamp" in ''|*[!0-9]*) _stamp=0 ;; esac

    if [ "$_state" = error ]; then
        _fn=$(kao_frames "$KAO_ERROR")
        _fr=1
        [ "$now" -gt 0 ] && _fr=$(( (now / ANIM_SECS) % _fn + 1 ))
        _line=$(pick_talk "$TALK_ERROR" "$_stamp")
        [ -n "$_line" ] && _line=" $_line"
        printf '%s' "${C_CRIT}$(kao_frame "$KAO_ERROR" "$_fr")${_line}${RESET}"
        return 0
    fi

    read_roll || return 0
    _face=$(kao_at "$(gacha_pool "$ROLL_TIER")" "$ROLL_INDEX")
    [ -n "$_face" ] || return 0

    _fn=$(kao_frames "$_face")
    _fr=1
    if [ "$_state" = working ] && [ "$now" -gt 0 ]; then
        _fr=$(( (now / ANIM_SECS) % _fn + 1 ))
    fi

    # Speaks while working, for a short while after finishing, and whenever
    # something is waiting on you. Otherwise it stays quiet.
    _line=''
    case "$_state" in
        working)
            _line=$(pick_talk "$(talk_pool work "$ROLL_TIER")" "$_stamp")
            ;;
        notify)
            _line=$(pick_talk "$(talk_pool notify "$ROLL_TIER")" "$_stamp")
            ;;
        done)
            if [ "$now" -le 0 ] || [ "$_stamp" -le 0 ] ||
               [ "$(( now - _stamp ))" -le "$TALK_WINDOW_SECS" ]; then
                _line=$(pick_talk "$(talk_pool done "$ROLL_TIER")" "$_stamp")
            fi
            ;;
    esac
    [ -n "$_line" ] && _line=" $_line"

    _text="$(kao_frame "$_face" "$_fr")${_line}"
    # Legend shimmers: every character takes its own hue and the ramp drifts.
    if [ "$ROLL_TIER" = legend ] && [ -n "$RESET" ] && awk_counts_chars; then
        _rn=0
        for _c in $RAINBOW; do _rn=$(( _rn + 1 )); done
        _off=0
        [ "$now" -gt 0 ] && _off=$(( (now / ANIM_SECS) % _rn ))
        printf '%s' "$(grad_text "$_text" "$_off")${RESET}"
        return 0
    fi
    printf '%s' "$(tier_color "$ROLL_TIER")${_text}${RESET}"
}
# ---- subcommands -----------------------------------------------------------
# Never read stdin, so they work from a plain prompt.

# Prints one roll as "（・ω・）  [커먼]", tier label included.
show_draw() {
    case "$ROLL_TIER" in
        common)   _lab='커먼' ;;
        uncommon) _lab='언커먼' ;;
        rare)     _lab='레어' ;;
        unique)   _lab='유니크' ;;
        legend)   _lab='레전드' ;;
        dev)      _lab='DEV' ;;
    esac
    _f=$(kao_at "$(gacha_pool "$ROLL_TIER")" "$ROLL_INDEX")
    printf '  %s%s%s  [%s]\n' "$(tier_color "$ROLL_TIER")" "$(kao_frame "$_f" 1)" "$RESET" "$_lab"
    printf '  표정 %s장  %s\n' "$(kao_frames "$_f")" "$(printf %s "$_f" | tr '#' ' ')"
}

if [ "$SUBCOMMAND" = roll ]; then
    if can_roll; then
        if do_roll; then
            printf '오늘의 마스코트를 뽑았습니다!\n\n'
            show_draw
            printf '  대사      %s\n' "$(talk_pool done "$ROLL_TIER" | tr '|' '/')"
            printf '\n다음 뽑기는 내일부터 가능합니다.\n'
            exit 0
        fi
        printf '뽑기에 실패했습니다. 턴을 한 번 끝내 비밀키가 만들어졌는지 확인해 주세요.\n'
        exit 1
    fi
    read_roll
    printf '오늘 뽑기는 이미 사용했습니다. 내일 다시 뽑을 수 있어요.\n\n'
    show_draw
    exit 0
fi

if [ "$SUBCOMMAND" = today ]; then
    if read_roll; then
        printf '지금 마스코트  (뽑은 날 %s)\n\n' "$ROLL_DATE"
        show_draw
        printf '  대사      %s\n' "$(talk_pool done "$ROLL_TIER" | tr '|' '/')"
        printf '\n'
        if can_roll; then
            printf '오늘 뽑기가 남아 있습니다. --roll 로 새로 뽑을 수 있어요.\n'
        else
            printf '오늘 뽑기는 사용했습니다. 내일 다시 뽑을 수 있어요.\n'
        fi
    else
        printf '아직 뽑은 마스코트가 없습니다. --roll 로 뽑아 보세요.\n'
    fi
    exit 0
fi

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

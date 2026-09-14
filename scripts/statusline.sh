#!/bin/sh
# claude-statusline — POSIX sh implementation (macOS, Linux, WSL, Git Bash).
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

STATUSLINE_VERSION='1.7.0'

# Run with no arguments (the way Claude Code calls it) to print the status line.
#   --roll      roll today's mascot (once a day) and exit
#   --today     print the mascot you are currently wearing and exit
#   --version   print the version and exit
#   --help      print a short usage summary and exit
SUBCOMMAND=''
case "${1:-}" in
    --version|-v)
        printf 'claude-statusline-astro %s\n' "$STATUSLINE_VERSION"
        exit 0
        ;;
    --help|-h)
        printf 'claude-statusline-astro %s\n\n' "$STATUSLINE_VERSION"
        printf '  statusline.sh            Claude Code calls this with session JSON on stdin\n'
        printf '  statusline.sh --roll     오늘의 마스코트 뽑기 (하루 한 번)\n'
        printf '  statusline.sh --today    지금 쓰고 있는 마스코트 보기\n'
        printf '  statusline.sh --version  버전 보기\n'
        printf '  statusline.sh --help     이 도움말\n\n'
        printf '뽑기는 하루 한 번이고, 뽑기 전까지 지금 마스코트가 그대로 유지됩니다.\n'
        printf '
  statusline.sh --roll legend         등급 지정 (메인테이너 키 전용)
'
        printf '  statusline.sh --roll legend Wrath   얼굴 지정 (메인테이너 키 전용)
'
        exit 0
        ;;
    --roll)
        SUBCOMMAND=roll
        ROLL_WANT="${2:-}"
        ROLL_FACE="${3:-}"
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
# Seconds per expression frame while a turn runs. Claude Code only redraws
# every refreshInterval (the installer sets 2), so keep the two equal.
ANIM_SECS=2
# Legend sparkle: the palette runs from its darkest colour at the edges of
# the face to its lightest in the middle, and on every redraw one character
# in SPARKLE_EVERY flashes the lightest colour (or the darkest where the text
# is already pale), picked by the clock so the twinkle wanders. 1 lights
# everything, 0 turns the twinkle off. The spoken line gets the same
# treatment on its own.
SPARKLE_EVERY=4
# 24-bit colour for the legend ramp. Set 0 on a terminal that only knows 256
# colours; the ramp then snaps to the nearest of those.
LEGEND_TRUE_COLOR=1
# How long after a turn ends the mascot keeps talking. Past this it goes quiet
# until the next turn, so an idle terminal is not left with a stale sentence.
TALK_WINDOW_SECS=60
# The switches above can also be flipped without editing this file, through
# environment variables (Claude Code passes its "env" settings through):
#   STATUSLINE_MASCOT=0      hide the mascot
#   STATUSLINE_TALK=0        face only, no lines
#   STATUSLINE_SEVEN_DAY=1   show the weekly meter
#   STATUSLINE_TRUE_COLOR=0  256-colour ramps
case "${STATUSLINE_MASCOT:-}" in 0) SHOW_MASCOT=0 ;; 1) SHOW_MASCOT=1 ;; esac
case "${STATUSLINE_TALK:-}" in 0) SHOW_MASCOT_TALK=0 ;; 1) SHOW_MASCOT_TALK=1 ;; esac
case "${STATUSLINE_SEVEN_DAY:-}" in 0) SHOW_SEVEN_DAY=0 ;; 1) SHOW_SEVEN_DAY=1 ;; esac
case "${STATUSLINE_TRUE_COLOR:-}" in 0) LEGEND_TRUE_COLOR=0 ;; 1) LEGEND_TRUE_COLOR=1 ;; esac

# Rarity odds in per-mille, lowest rarity first, totalling 1000 and lined up with
# MASCOT_TIERS below. These are fixed on purpose: everyone rolls against the same
# table, and editing them turns the roll into a choice, which is no roll at all.
MASCOT_ODDS='400 350 180 60 10'
MASCOT_TIERS='common uncommon rare unique legend'

# Maintainer tier. A key whose SHA-256 is listed here also rolls 'dev' faces;
# every other key never sees them. Only the hash is published, so the list gives
# nothing away - matching it would mean finding a preimage of SHA-256. Add your
# own hash to claim the tier on your machine: SHA-256 of the key file's text,
# trimmed of whitespace, hashed as UTF-8. The README gives the exact command.
DEV_KEY_HASHES='64528c9f19e91ed0ca521f443a672235456aa3cdf23f45787f07482759777238'
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
    C_COMMON="${ESC}[38;5;253m"     # the faintest grey
    C_UNCOMMON="${ESC}[38;5;120m"   # light green
    C_RARE="${ESC}[38;5;117m"       # sky blue
    C_UNIQUE="${ESC}[38;5;141m"     # purple - only when the gradient is off
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

# The block may hold one level of nested objects (context_window carries a
# current_usage object); those are blanked before the field is looked up.
get_nested_num() {
    printf '%s' "$payload" |
        sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*{\(\([^{}]*{[^{}]*}\)*[^{}]*\)}.*/\1/p" |
        sed 's/{[^{}]*}//g' |
        sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9][0-9.]*\).*/\1/p"
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

    # One colour code covers the whole bar; the cells are the same colour.
    _bar=''
    _i=0
    while [ "$_i" -lt "$BAR_LEN" ]; do
        [ "$_i" -gt 0 ] && _bar="${_bar}${BAR_GAP}"
        if [ "$_i" -lt "$_filled" ]; then
            _bar="${_bar}${BAR_FULL}"
        else
            _bar="${_bar}${BAR_EMPTY}"
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
KAO_ERROR='（；へ；）#（；ㅅ；）'
KAO_COMMON='（・ω・）#（－ω－）|（´ ᴗ ｀）#（´ ᴖ ｀）|（ ˘ᴗ˘ ）z#（ ˘ᴗ˘ ）Z|（=・ェ・=）#（=－ェ－=）|（・∀・）#（－∀－）|（˙◡˙）#（˙‿˙）|（￢_￢）#（￢‿￢）|（´-ι_-｀）#（´-ι.-｀）|（・_・）#（・.・）|（≖‿≖）#（≖_≖）|（◣‸◢）#（◢‸◣）|（＾ｖ＾）#（＾ｕ＾）'
KAO_UNCOMMON='（๑˃ᴗ˂）#（๑˂ᴗ˃）|（｡•ᴗ•｡）#（｡•ᴖ•｡）|（^▽^）#（^∇^）|（◕‿◕）#（◠‿◠）|（≧Д≦）#（≧∀≦）|（･ᵕ<）#（-ᵕ<）|（ㆆ_ㆆ）#（ㆆ.ㆆ）|（◔_◔）#（◔‸◔）|（｡>ㅅ<｡）#（｡>ㅁ<｡）|（・ㅂ・）#（－ㅂ－）|（＠_＠）#（＠.＠）|（⊙o⊙）#（⊙O⊙）'
KAO_RARE='（･ᴗ･）◇#（-ᴗ-）◆|ヽ（•‿•）ノ#ヾ（•‿•）ノ|（◕‿◕）✿#（◠‿◠）❀|\（^o^）/#\（^O^）/|（´▽｀）♪#（´▽｀）♬|（・ω・）ノ#（－ω－）ノ|（￣ｰ￣）ゞ#（￣ｰ￣）ゝ|（▼ω▼）b#（▼ω▼）d|（´ε｀）♡#（´ε｀）♥|（￢‿￢）☆#（￢‿￢）★|（☞°ヮ°）☞#（☜°ヮ°）☜|┐（´～｀）┌#┐（´〜｀）┌'
KAO_UNIQUE='╰（☆▽☆）╯#╰（★▽★）╯|╭（◕ヮ◕）╮#╭（◠ヮ◠）╮|┗（♡‿♡）┛#┗（♥‿♥）┛|＼（•∇•）／#＼（•▽•）／|⊂（＾ᴗ＾）⊃#⊂（＾ᴖ＾）⊃|╰（￣ヘ￣）╯#╰（￣〜￣）╯|┗（╬◣_◢）┛#┗（╬◢_◣）┛|⊂（￢_￢）⊃#⊂（￢‿￢）⊃|╭（▼ヘ▼）╮#╭（▼〜▼）╮|＼（⇀‸↼）／#＼（⇀‿↼）／'
KAO_LEGEND='彡☆（●ᴗ●）☆ミノ#ヽ彡☆（●ᴗ●）☆ミ#彡☆（●o●）☆ミノ#ヽ彡☆（●ᴗ●）☆ミ|ψ（╬◣_◢）ψ!#!ψ（◣_◢╬）ψ#ψ（╬◣o◢）ψ!#!ψ（◣_◢╬）ψ|≪（▼_▼）≫†#†≪（▼_▼）≫#≪（▼‿▼）≫†#†≪（▼_▼）≫|⊰（◕‿◕）⊱☆#☆⊰（◕‿◕）⊱#⊰（◕ᴗ◕）⊱☆#☆⊰（◕‿◕）⊱|༺（◈ω◈）༻ζ#ζ༺（◈ω◈）༻#༺（◈▽◈）༻ζ#ζ༺（◈ω◈）༻'
KAO_DEV='｛・ω・｝#｛－ω－｝|⟨◕ᴗ◕⟩#⟨◠ᴗ◠⟩|［◉_◉］#［◉‸◉］|⟨◣_◢⟩#⟨◢_◣⟩'

NAME_COMMON='Kitten|Cozy|Snooze|Whiskers|Grin|Smiley|Side-eye|Bored|Blank|Smirk|Scowl|Pleased'
NAME_UNCOMMON='Giggle|Rosy|Beam|Bright|Squee|Wink|Stare|Eyeroll|Pout|Hamster|Dizzy|Gasp'
NAME_RARE='Twinkle|Cheer|Blossom|Hooray|Melody|Wave|Smug|Cool|Kiss|Scheme|Gunslinger|Shrug'
NAME_UNIQUE='Superstar|Jubilee|Lovestruck|Dazzle|Hurrah|Boss|Fury|Skeptic|Villain|Grit'
NAME_LEGEND='Halo|Wrath|Overlord|Seraph|Wyvern'
NAME_DEV='Root|Sudo|Kernel|Daemon'

# The mascot only speaks while a turn runs, right after one ends, and when
# something is waiting on you. The rest of the time it just sits there.
TALK_ERROR='앗...|실패했어요...'

TALK_WORK_COMMON='끙...|우우|낑낑|웅...'
TALK_WORK_UNCOMMON='하는 중!|조금만!|열일 중!|가는 중!'
TALK_WORK_RARE='작업 중이에요|조금만 기다려요|거의 다 왔어요'
TALK_WORK_UNIQUE='처리하고 있어요!|조금만 기다려 주세요!|열심히 하는 중이에요!'
TALK_WORK_LEGEND='작업을 진행하고 있습니다!|곧 마무리됩니다, 잠시만요!'
TALK_WORK_DEV='빌드 도는 중.|컴파일 중.|테스트 도는 중.'
TALK_DONE_COMMON='왕!|냥!|뿌!|삐약!|꽥!|음냐|냥냥! 참치 있냥?|뿌! 배고프다뿌|삐약... 병아리는 아닌데'
TALK_DONE_UNCOMMON='왕왕!|다했다!|끝!|됐다!|오케이!|히히|다했다! 간식 줘!|끝! 나 잘했지?|됐다! 커피콩은 왜 콩일까'
TALK_DONE_RARE='다 됐어요|끝났어요|완료했어요|해냈어요!|준비 끝!|끝났어요. 제일 뜨거운 과일은 천도복숭아래요|다 됐어요. 왕이 넘어지면? 킹콩!|완료! 소가 웃는 소리는? 우하하'
TALK_DONE_UNIQUE='작업 완료했어요!|다 끝냈습니다!|깔끔하게 끝냈어요!|확인해 보세요!|다 끝냈습니다! 쉬는 날에도 코드 꿈을 꿔요|완료했어요! 버그도 잡고 웃음도 잡을게요|깔끔하게 끝냈어요! 이 정도면 승진 각이죠?'
TALK_DONE_LEGEND='요청하신 작업 모두 완료했습니다!|전부 끝냈습니다, 확인 부탁드려요!|작업을 성공적으로 마쳤습니다!|모두 마쳤습니다. 오늘의 넌센스: 물고기의 반대말은? 불고기.|완료했습니다. 세상에서 가장 빠른 새는? 눈 깜짝할 새.|끝났습니다. 가장 오래된 나무는? 갈매나무.'
TALK_DONE_DEV='빌드 통과.|커밋하시죠.|배포 준비 완료.|테스트 전부 초록불.'
TALK_NOTIFY_COMMON='앙?|웅?|왕?'
TALK_NOTIFY_UNCOMMON='저기요!|잠깐만요!|봐주세요!'
TALK_NOTIFY_RARE='확인해 주세요|봐주셔야 해요'
TALK_NOTIFY_UNIQUE='확인 부탁해요!|잠시 봐주세요!'
TALK_NOTIFY_LEGEND='확인 부탁드립니다!|잠시 확인해 주세요!'
TALK_NOTIFY_DEV='입력 대기 중.|확인 요망.'

MASCOT_TIERS='common uncommon rare unique legend'

# Legend ramps, 36 cells each, generated by docs/legend/render.py
# from the RGB keyframes there. One set in 24-bit colour, one snapped to the
# xterm cube for terminals that only know 256 colours.
RAMP_TRUE_DAWN='38;2;143;101;8 38;2;152;108;7 38;2;161;116;6 38;2;170;123;5 38;2;179;130;4 38;2;188;138;2 38;2;197;145;1 38;2;206;153;0 38;2;213;160;6 38;2;220;167;13 38;2;226;173;20 38;2;233;180;27 38;2;239;187;34 38;2;246;194;41 38;2;252;201;48 38;2;255;206;60 38;2;255;210;76 38;2;255;214;91 38;2;255;219;107 38;2;255;223;123 38;2;255;227;138 38;2;255;231;154 38;2;255;234;166 38;2;255;236;175 38;2;255;238;184 38;2;255;240;192 38;2;255;242;201 38;2;255;244;210 38;2;255;246;218 38;2;252;244;219 38;2;236;223;189 38;2;221;203;159 38;2;205;183;129 38;2;190;162;98 38;2;174;142;68 38;2;159;121;38'
RAMP_TRUE_EMBER='38;2;168;37;36 38;2;174;40;39 38;2;181;43;43 38;2;187;47;46 38;2;194;50;49 38;2;200;53;53 38;2;206;56;56 38;2;213;59;59 38;2;219;64;64 38;2;224;70;70 38;2;230;76;76 38;2;236;81;81 38;2;241;87;87 38;2;247;92;92 38;2;253;98;98 38;2;255;104;104 38;2;255;111;111 38;2;255;118;118 38;2;255;125;125 38;2;255;131;131 38;2;255;138;138 38;2;255;145;145 38;2;255;151;151 38;2;255;157;155 38;2;255;162;160 38;2;255;168;164 38;2;255;173;169 38;2;255;179;173 38;2;255;185;177 38;2;253;185;177 38;2;240;164;157 38;2;228;143;137 38;2;216;121;117 38;2;204;100;96 38;2;192;79;76 38;2;180;58;56'
RAMP_TRUE_RADIANCE='38;2;138;120;224 38;2;147;130;228 38;2;156;139;231 38;2;165;149;235 38;2;173;159;238 38;2;182;168;242 38;2;191;178;245 38;2;199;187;247 38;2;206;195;248 38;2;214;204;250 38;2;221;213;252 38;2;229;221;253 38;2;236;230;255 38;2;239;234;255 38;2;242;238;255 38;2;246;243;255 38;2;249;247;255 38;2;252;251;255 38;2;255;255;255 38;2;247;248;250 38;2;239;241;245 38;2;232;234;240 38;2;224;227;234 38;2;216;220;229 38;2;208;213;224 38;2;202;207;219 38;2;195;200;213 38;2;189;194;208 38;2;182;188;203 38;2;176;181;197 38;2;169;175;192 38;2;164;166;197 38;2;159;157;203 38;2;154;148;208 38;2;148;138;213 38;2;143;129;219'
RAMP_TRUE_SAPPHIRE='38;2;43;74;168 38;2;46;79;176 38;2;49;85;184 38;2;51;90;191 38;2;54;95;199 38;2;57;100;207 38;2;60;106;215 38;2;62;111;222 38;2;68;117;227 38;2;74;123;232 38;2;80;129;236 38;2;86;135;240 38;2;92;141;245 38;2;98;147;249 38;2;104;154;253 38;2;111;159;255 38;2;118;165;255 38;2;126;170;255 38;2;133;176;255 38;2;141;182;255 38;2;148;187;255 38;2;156;193;255 38;2;163;198;255 38;2;171;203;255 38;2;178;207;255 38;2;186;212;255 38;2;193;217;255 38;2;201;222;255 38;2;208;226;255 38;2;209;226;253 38;2;185;204;240 38;2;162;182;228 38;2;138;161;216 38;2;114;139;204 38;2;90;117;192 38;2;67;96;180'
RAMP_TRUE_EMERALD='38;2;15;122;74 38;2;16;128;78 38;2;17;135;83 38;2;18;141;87 38;2;19;148;92 38;2;21;154;96 38;2;22;160;101 38;2;23;167;105 38;2;27;173;110 38;2;33;180;115 38;2;39;186;120 38;2;44;192;126 38;2;50;199;131 38;2;55;205;136 38;2;61;211;141 38;2;70;216;147 38;2;81;220;154 38;2;92;223;161 38;2;103;227;168 38;2;114;231;174 38;2;125;234;181 38;2;136;238;188 38;2;147;241;194 38;2;156;243;200 38;2;165;245;205 38;2;174;247;211 38;2;183;249;216 38;2;192;251;222 38;2;201;253;228 38;2;203;251;228 38;2;176;233;206 38;2;149;214;184 38;2;122;196;162 38;2;95;177;140 38;2;69;159;118 38;2;42;140;96'
RAMP_TRUE_UNIQUE='38;2;210;188;255 38;2;192;158;255 38;2;174;129;255 38;2;155;103;248 38;2;135;79;237 38;2;115;58;219 38;2;95;42;188 38;2;74;26;156'
RAMP_256_DAWN='38;5;94 38;5;94 38;5;136 38;5;136 38;5;136 38;5;136 38;5;172 38;5;172 38;5;178 38;5;178 38;5;178 38;5;178 38;5;214 38;5;214 38;5;221 38;5;221 38;5;221 38;5;221 38;5;221 38;5;222 38;5;222 38;5;222 38;5;223 38;5;229 38;5;229 38;5;229 38;5;230 38;5;230 38;5;230 38;5;230 38;5;223 38;5;187 38;5;180 38;5;143 38;5;137 38;5;136'
RAMP_256_EMBER='38;5;124 38;5;124 38;5;124 38;5;124 38;5;131 38;5;167 38;5;167 38;5;167 38;5;167 38;5;167 38;5;167 38;5;203 38;5;203 38;5;203 38;5;203 38;5;203 38;5;203 38;5;210 38;5;210 38;5;210 38;5;210 38;5;210 38;5;210 38;5;217 38;5;217 38;5;217 38;5;217 38;5;217 38;5;217 38;5;217 38;5;217 38;5;174 38;5;174 38;5;167 38;5;131 38;5;131'
RAMP_256_RADIANCE='38;5;104 38;5;104 38;5;140 38;5;141 38;5;147 38;5;147 38;5;147 38;5;183 38;5;189 38;5;189 38;5;189 38;5;189 38;5;225 38;5;225 38;5;231 38;5;231 38;5;231 38;5;231 38;5;231 38;5;231 38;5;231 38;5;189 38;5;188 38;5;188 38;5;188 38;5;188 38;5;188 38;5;146 38;5;146 38;5;146 38;5;145 38;5;146 38;5;146 38;5;104 38;5;104 38;5;104'
RAMP_256_SAPPHIRE='38;5;25 38;5;25 38;5;61 38;5;61 38;5;62 38;5;62 38;5;62 38;5;62 38;5;68 38;5;68 38;5;69 38;5;69 38;5;69 38;5;69 38;5;69 38;5;75 38;5;111 38;5;111 38;5;111 38;5;111 38;5;111 38;5;147 38;5;153 38;5;153 38;5;153 38;5;153 38;5;153 38;5;189 38;5;189 38;5;189 38;5;153 38;5;146 38;5;110 38;5;68 38;5;67 38;5;61'
RAMP_256_EMERALD='38;5;29 38;5;29 38;5;29 38;5;29 38;5;29 38;5;29 38;5;35 38;5;35 38;5;35 38;5;36 38;5;36 38;5;36 38;5;78 38;5;78 38;5;78 38;5;78 38;5;78 38;5;79 38;5;79 38;5;79 38;5;115 38;5;121 38;5;121 38;5;158 38;5;158 38;5;158 38;5;158 38;5;158 38;5;194 38;5;194 38;5;152 38;5;115 38;5;115 38;5;72 38;5;72 38;5;29'
RAMP_256_UNIQUE='38;5;183 38;5;147 38;5;141 38;5;135 38;5;99 38;5;98 38;5;55 38;5;55'
LEGEND_PALETTES='dawn ember radiance sapphire emerald'

# The ramp of a palette, 24-bit or 256-colour per LEGEND_TRUE_COLOR.
legend_ramp() {
    if [ "$LEGEND_TRUE_COLOR" -eq 1 ]; then
        case "$1" in
            dawn)       printf %s "$RAMP_TRUE_DAWN" ;;
            ember)      printf %s "$RAMP_TRUE_EMBER" ;;
            radiance)   printf %s "$RAMP_TRUE_RADIANCE" ;;
            sapphire)   printf %s "$RAMP_TRUE_SAPPHIRE" ;;
            emerald)    printf %s "$RAMP_TRUE_EMERALD" ;;
            unique)     printf %s "$RAMP_TRUE_UNIQUE" ;;
            *)          printf %s "$RAMP_TRUE_RADIANCE" ;;
        esac
    else
        case "$1" in
            dawn)       printf %s "$RAMP_256_DAWN" ;;
            ember)      printf %s "$RAMP_256_EMBER" ;;
            radiance)   printf %s "$RAMP_256_RADIANCE" ;;
            sapphire)   printf %s "$RAMP_256_SAPPHIRE" ;;
            emerald)    printf %s "$RAMP_256_EMERALD" ;;
            unique)     printf %s "$RAMP_256_UNIQUE" ;;
            *)          printf %s "$RAMP_256_RADIANCE" ;;
        esac
    fi
}

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

name_pool() {
    case "$1" in
        common)   printf %s "$NAME_COMMON" ;;
        uncommon) printf %s "$NAME_UNCOMMON" ;;
        rare)     printf %s "$NAME_RARE" ;;
        unique)   printf %s "$NAME_UNIQUE" ;;
        legend)   printf %s "$NAME_LEGEND" ;;
        dev)      printf %s "$NAME_DEV" ;;
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

# Sets ROLL_DATE / ROLL_EPOCH / ROLL_TIER / ROLL_INDEX (counted from 0, like the
# PowerShell version, so one cache directory reads the same on both) from the stored roll, or
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
    case "$ROLL_INDEX" in ''|*[!0-9]*) return 1 ;; esac
    [ "$ROLL_INDEX" -lt "$(kao_count "$(gacha_pool "$4")")" ] || return 1
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
# $1 = 원하는 등급(선택), $2 = 원하는 얼굴 이름이나 번호(선택).
# 0 성공 / 1 실패 / 2 권한 없음 / 3 없는 등급 / 4 없는 얼굴.
do_roll() {
    _key=$(gacha_key)
    [ -n "$_key" ] || return 1

    # Picking a tier outright is a maintainer thing - it is how the faces get
    # looked at while working on them. Any other key is turned away here.
    _want="${1:-}"
    if [ -n "$_want" ]; then
        is_dev_key "$_key" || return 2
        [ -n "$(gacha_pool "$_want")" ] || return 3
    fi

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
    [ -n "$_want" ] && ROLL_TIER=$_want

    _kn=$(kao_count "$(gacha_pool "$ROLL_TIER")")
    [ "$_kn" -gt 0 ] || return 1
    ROLL_INDEX=$(( _n2 % _kn ))

    # A named face (or its 1-based number) goes with a chosen tier, so the
    # maintainer can wear each one in turn while working on them.
    _wantf="${2:-}"
    if [ -n "$_want" ] && [ -n "$_wantf" ]; then
        _pick=''
        case "$_wantf" in
            ''|*[!0-9]*)
                _pick=$(printf %s "$(name_pool "$ROLL_TIER")" | awk -F'|' -v w="$_wantf" '{ for (i = 1; i <= NF; i++) if ($i == w) { print i - 1; exit } }')
                ;;
            *)
                [ "$_wantf" -ge 1 ] && [ "$_wantf" -le "$_kn" ] && _pick=$(( _wantf - 1 ))
                ;;
        esac
        [ -n "$_pick" ] || return 4
        ROLL_INDEX=$_pick
    fi

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
    [ "$(printf %s "¬‿" | awk '{print length($0)}' 2>/dev/null)" = 2 ]
}

# Paints the face with the whole palette ($3, one SGR parameter per cell),
# darkest at the edges and lightest in the middle, and makes a few characters
# flash the lightest colour (or the darkest where the text is already pale). Which ones is decided by a
# small integer hash of the seed ($2) and the position, so both
# implementations agree exactly.
grad_text() {
    printf %s "$1" | awk -v seed="$2" -v esc="$ESC" -v rb="$3" -v every="$SPARKLE_EVERY" '
        BEGIN { n = split(rb, C, " "); lo = 0; hi = int(n / 2) }
        {
            L = length($0)
            for (i = 1; i <= L; i++) {
                d = 2 * (i - 1) - (L - 1); if (d < 0) d = -d
                idx = hi
                if (L > 1) idx = hi - int((hi - lo) * d / (L - 1))
                code = C[idx + 1]
                if (every > 0) {
                    x = (seed * 31 + (i - 1) * 7 + 13) % 2147483647
                    x = (x * 48271) % 2147483647
                    x = (x * 48271) % 2147483647
                    if (x % every == 0) {
                        code = C[hi + 1]
                        if (substr(C[idx + 1], 1, 5) == "38;2;") {
                            split(C[idx + 1], P, ";")
                            lum = (P[3] * 299 + P[4] * 587 + P[5] * 114) / 1000
                            if (lum > 170) code = C[1]
                        }
                    }
                }
                printf "%s[%sm%s", esc, code, substr($0, i, 1)
            }
        }'
}


# Unique wears one fixed gradient, lavender to deep purple, stretched across
# the text ($2 = the ramp). It never moves and uses few colours: a clear step
# below legend.
static_grad_text() {
    printf %s "$1" | awk -v esc="$ESC" -v rb="$2" '
        BEGIN { n = split(rb, C, " ") }
        {
            L = length($0)
            for (i = 1; i <= L; i++) {
                idx = 0
                if (L > 1) idx = int((i - 1) * (n - 1) / (L - 1))
                printf "%s[%sm%s", esc, C[idx + 1], substr($0, i, 1)
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

# Draws the face for the current roll, animated by the turn state the hooks
# left for this session. Prints nothing only when nothing has been rolled yet,
# so the line then looks as it did before the mascot existed.
mascot() {
    [ "$SHOW_MASCOT" -eq 1 ] || return 0

    # The face is the machine-wide roll, so it shows in every session from the
    # first redraw. The state file only adds what the turn is doing; until the
    # hooks write one the mascot simply sits idle.
    _state=idle
    _stamp=0
    _mf="$CACHE_DIR/mascot-$sid_key.txt"
    if [ -n "$sid_key" ] && [ -f "$_mf" ]; then
        _raw=$(cat "$_mf" 2>/dev/null)
        if [ -n "$_raw" ]; then
            _state=$(printf %s "$_raw" | awk '{print $1}')
            _stamp=$(printf %s "$_raw" | awk '{print $2}')
        fi
    fi
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
    _face=$(kao_at "$(gacha_pool "$ROLL_TIER")" "$(( ROLL_INDEX + 1 ))")
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
    _text=$(kao_frame "$_face" "$_fr")
    # Legend twinkles; the spoken line stays in one steady colour beside it.
    if [ "$ROLL_TIER" = legend ] && [ -n "$RESET" ] && awk_counts_chars; then
        _pn=$(printf %s "$LEGEND_PALETTES" | cut -d" " -f"$(( ROLL_INDEX + 1 ))")
        _ramp=$(legend_ramp "$_pn")
        _seed=0
        [ "$now" -gt 0 ] && _seed=$(( now % 1000003 ))
        printf '%s' "$(grad_text "$_text" "$_seed" "$_ramp")${RESET}"
        # The line wears its own gradient, seeded one step apart so its
        # twinkle does not mirror the face's.
        [ -n "$_line" ] && printf ' %s%s' "$(grad_text "$_line" "$(( _seed + 1 ))" "$_ramp")" "$RESET"
        return 0
    fi
    if [ "$ROLL_TIER" = unique ] && [ -n "$RESET" ] && awk_counts_chars; then
        printf '%s' "$(static_grad_text "$_text" "$(legend_ramp unique)")${RESET}"
        [ -n "$_line" ] && printf ' %s%s' "$(static_grad_text "$_line" "$(legend_ramp unique)")" "$RESET"
        return 0
    fi
    [ -n "$_line" ] && _text="${_text} ${_line}"
    printf '%s' "$(tier_color "$ROLL_TIER")${_text}${RESET}"
}
# ---- subcommands -----------------------------------------------------------
# Never read stdin, so they work from a plain prompt.

# Paints one frame the way the status line would: the legend gradient when it
# is available, the flat tier colour otherwise.
paint_face() {
    if [ "$1" = legend ] && [ -n "$RESET" ] && awk_counts_chars; then
        _pp=$(printf %s "$LEGEND_PALETTES" | cut -d" " -f"$(( $2 + 1 ))")
        printf '%s%s' "$(grad_text "$3" 0 "$(legend_ramp "$_pp")")" "$RESET"
    elif [ "$1" = unique ] && [ -n "$RESET" ] && awk_counts_chars; then
        printf '%s%s' "$(static_grad_text "$3" "$(legend_ramp unique)")" "$RESET"
    else
        printf '%s%s%s' "$(tier_color "$1")" "$3" "$RESET"
    fi
}

# What a freshly drawn mascot says, in its tier's manner of speaking.
intro_line() {
    case "$1" in
        common)   printf '"냥. 나 %s."' "$2" ;;
        uncommon) printf '"안녕! 나는 %s!"' "$2" ;;
        rare)     printf '"반가워요. 저는 %s이에요."' "$2" ;;
        unique)   printf '"처음 뵙겠습니다. %s입니다!"' "$2" ;;
        legend)   printf '"%s이라고 합니다. 함께하게 되어 영광입니다."' "$2" ;;
        dev)      printf '"%s. 로그인 완료."' "$2" ;;
    esac
}

# Prints one roll as "（・ω・）  Kitten  [커먼 1/12]", name and tier included.
show_draw() {
    case "$ROLL_TIER" in
        common)   _lab='커먼' ;;
        uncommon) _lab='언커먼' ;;
        rare)     _lab='레어' ;;
        unique)   _lab='유니크' ;;
        legend)   _lab='레전드' ;;
        dev)      _lab='DEV' ;;
    esac
    _f=$(kao_at "$(gacha_pool "$ROLL_TIER")" "$(( ROLL_INDEX + 1 ))")
    _nm=$(kao_at "$(name_pool "$ROLL_TIER")" "$(( ROLL_INDEX + 1 ))")
    _tot=$(kao_count "$(gacha_pool "$ROLL_TIER")")
    printf '  %s  %s  [%s %s/%s]\n' "$(paint_face "$ROLL_TIER" "$ROLL_INDEX" "$(kao_frame "$_f" 1)")" "$_nm" "$_lab" "$(( ROLL_INDEX + 1 ))" "$_tot"
    printf '  %s\n' "$(intro_line "$ROLL_TIER" "$_nm")"
    printf '  표정 %s장  %s\n' "$(kao_frames "$_f")" "$(printf %s "$_f" | tr '#' ' ')"
}

if [ "$SUBCOMMAND" = roll ]; then
    # 등급을 직접 고르는 건 메인테이너 키에서만 됩니다.
    if [ -n "$ROLL_WANT" ]; then
        do_roll "$ROLL_WANT" "$ROLL_FACE"
        case $? in
            0)
                printf '%s 등급으로 지정했습니다.\n\n  뿅!\n' "$ROLL_WANT"
                show_draw
                exit 0
                ;;
            2)
                printf '등급을 직접 고르는 건 메인테이너 키에서만 됩니다.\n'
                printf '일반 사용자는 --roll 로 하루 한 번 뽑습니다.\n'
                exit 1
                ;;
            3)
                printf '그런 등급이 없습니다: %s\n' "$ROLL_WANT"
                printf '고를 수 있는 값: common uncommon rare unique legend dev\n'
                exit 1
                ;;
            4)
                printf '그런 얼굴이 없습니다: %s
' "$ROLL_FACE"
                printf '고를 수 있는 값: %s
' "$(name_pool "$ROLL_WANT" | tr '|' ' ')"
                exit 1
                ;;
            *)
                printf '지정에 실패했습니다.\n'
                exit 1
                ;;
        esac
    fi

    if can_roll; then
        if do_roll; then
            printf '오늘의 마스코트를 뽑았습니다!\n\n  뿅!\n'
            show_draw
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

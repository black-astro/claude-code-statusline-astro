#!/bin/sh
# claude-code-statusline — POSIX sh implementation (macOS, Linux, WSL, Git Bash).
#
# Reads the Claude Code session JSON from stdin and prints exactly one line:
#   DIR <project> | GIT <branch> | MODEL <name> | CTX [bar] NN% | 5H [bar] NN% | 7D [bar] NN%
#
# Set NO_COLOR=1 to strip the ANSI colors.

# Nothing may reach stderr: Claude Code renders whatever the command emits.
exec 2>/dev/null

# ---- appearance ------------------------------------------------------------
BAR_LEN=10
# U+2589 fills the left 7/8 of its cell, so cells sit flush against each other
# and the leftover 1/8 reads as a hairline gap — full cell height, no padding
# needed. A true square like U+25A0 is limited by the cell width instead, which
# is why it looks small.
BAR_FULL='▉'    # U+2589  filled cell
BAR_EMPTY='░'   # U+2591  empty cell
BAR_GAP=''      # cells are flush; the glyph provides its own separation
BAR_PAD=' '     # spacing just inside the brackets
DIR_MAX=32      # project name is left-truncated past this many characters

SHOW_SEVEN_DAY=0  # set to 1 to also show the 7-day (weekly) meter

# Meters turn amber at WARN_AT and red at CRIT_AT.
WARN_AT=60
CRIT_AT=90

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
    C_OK="${ESC}[38;5;117m"         # light blue  — under WARN_AT
    C_WARN="${ESC}[38;5;214m"       # amber       — WARN_AT and up
    C_CRIT="${ESC}[38;5;203m"       # red         — CRIT_AT and up
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
    ctx=$(printf '%s' "$payload" | jq -r '(.context_window.used_percentage // "")')
    five=$(printf '%s' "$payload" | jq -r '(.rate_limits.five_hour.used_percentage // "")')
    five_reset=$(printf '%s' "$payload" | jq -r '(.rate_limits.five_hour.resets_at // "")')
    seven=$(printf '%s' "$payload" | jq -r '(.rate_limits.seven_day.used_percentage // "")')
    seven_reset=$(printf '%s' "$payload" | jq -r '(.rate_limits.seven_day.resets_at // "")')
else
    dir=$(get_str current_dir)
    [ -z "$dir" ] && dir=$(get_str cwd)
    model=$(get_str display_name)
    ctx=$(get_nested_num context_window used_percentage)
    five=$(get_nested_num five_hour used_percentage)
    five_reset=$(get_nested_num five_hour resets_at)
    seven=$(get_nested_num seven_day used_percentage)
    seven_reset=$(get_nested_num seven_day resets_at)
fi

[ -z "$model" ] && model='-'

now=$(date +%s 2>/dev/null)

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

# ---- meters ----------------------------------------------------------------
# Renders "[ ■ ■ ■ ■ □ □ □ □ □ □ ] 42%". Filled cells carry the load color,
# empty cells stay dim, and the width never changes so the line does not
# jitter as values appear.
#
# A rate-limit window whose resets_at has already passed means this session is
# holding an out-of-date snapshot, so the number is marked with "~" and dimmed.
meter() {
    _raw=$1
    _reset=$2

    _known=1
    case "$_raw" in
        *[0-9]*) ;;
        *) _known=0 ;;
    esac

    if [ "$_known" -eq 1 ]; then
        _n=$(awk -v v="$_raw" 'BEGIN{ v = v + 0; if (v < 0) v = 0; if (v > 100) v = 100; printf "%d", int(v + 0.5) }')
        case "$_n" in
            ''|*[!0-9]*) _known=0 ;;
        esac
    fi

    _stale=0
    case "$_reset" in
        *[0-9]*)
            case "$now" in
                *[0-9]*) [ "$_reset" -lt "$now" ] && _stale=1 ;;
            esac
            ;;
    esac

    if [ "$_known" -eq 0 ]; then
        _filled=0
        _c=$DIM
        _cpct=$DIM
        _pct='--%'
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
            _bar="${_bar}${DIM}${BAR_EMPTY}"
        fi
        _i=$((_i + 1))
    done

    printf '%s' "${DIM}[${BAR_PAD}${_bar}${DIM}${BAR_PAD}] ${_cpct}${_pct}${RESET}"
}

# ---- output ----------------------------------------------------------------
SEP="${DIM} | ${RESET}"
line="${DIM}DIR${RESET} ${C_DIR}${project}${RESET}"
line="${line}${SEP}${DIM}GIT${RESET} ${c_branch}${branch}${RESET}"
line="${line}${SEP}${DIM}MODEL${RESET} ${C_MODEL}${model}${RESET}"
line="${line}${SEP}${DIM}CTX${RESET} $(meter "$ctx" '')"
line="${line}${SEP}${DIM}5H${RESET} $(meter "$five" "$five_reset")"
if [ "$SHOW_SEVEN_DAY" -eq 1 ]; then
    line="${line}${SEP}${DIM}7D${RESET} $(meter "$seven" "$seven_reset")"
fi

printf '%s\n' "$line"
exit 0

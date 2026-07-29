#!/bin/sh
# claude-code-statusline — POSIX sh implementation (macOS, Linux, WSL, Git Bash).
#
# Reads the Claude Code session JSON from stdin and prints exactly one line:
#   DIR <path> | GIT <branch> | MODEL <name> | CTX [bar] NN% | 5H [bar] NN%
#
# Set NO_COLOR=1 to strip the ANSI colors.

# Nothing may reach stderr: Claude Code renders whatever the command emits.
exec 2>/dev/null

BAR_LEN=10
BAR_FULL='▰'
BAR_EMPTY='▱'

if [ -n "${NO_COLOR:-}" ]; then
    RESET=''
    DIM=''
    C_DIR=''
    C_GIT=''
    C_MODEL=''
    C_OK=''
    C_WARN=''
    C_CRIT=''
else
    ESC=$(printf '\033')
    RESET="${ESC}[0m"
    DIM="${ESC}[90m"
    C_DIR="${ESC}[96m"
    C_GIT="${ESC}[95m"
    C_MODEL="${ESC}[93m"
    C_OK="${ESC}[92m"
    C_WARN="${ESC}[93m"
    C_CRIT="${ESC}[91m"
fi

payload=$(cat | tr -d '\n\r')

# jq handles the payload properly when present; the sed fallback covers the
# handful of fields this status line needs on machines without it.
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
else
    dir=$(get_str current_dir)
    [ -z "$dir" ] && dir=$(get_str cwd)
    model=$(get_str display_name)
    ctx=$(get_nested_num context_window used_percentage)
    five=$(get_nested_num five_hour used_percentage)
fi

[ -z "$dir" ] && dir='-'
[ -z "$model" ] && model='-'

branch='-'
if [ "$dir" != '-' ] && [ -d "$dir" ] && command -v git >/dev/null 2>&1; then
    b=$(git -C "$dir" branch --show-current 2>/dev/null)
    if [ -z "$b" ]; then
        b=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
        [ "$b" = 'HEAD' ] && b=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)
    fi
    [ -n "$b" ] && branch="$b"
fi

# Renders "[▰▰▰▰▱▱▱▱▱▱] 42%", colored green/amber/red by how full it is.
meter() {
    _raw=$1
    _blank="${DIM}[----------] --%${RESET}"

    case "$_raw" in
        *[0-9]*) ;;
        *) printf '%s' "$_blank"; return ;;
    esac

    _n=$(awk -v v="$_raw" 'BEGIN{ v = v + 0; if (v < 0) v = 0; if (v > 100) v = 100; printf "%d", int(v + 0.5) }')
    case "$_n" in
        ''|*[!0-9]*) printf '%s' "$_blank"; return ;;
    esac

    _filled=$(( (_n + 5) / 10 ))
    [ "$_filled" -gt "$BAR_LEN" ] && _filled=$BAR_LEN

    if [ "$_n" -ge 85 ]; then
        _c=$C_CRIT
    elif [ "$_n" -ge 60 ]; then
        _c=$C_WARN
    else
        _c=$C_OK
    fi

    _bar=''
    _i=0
    while [ "$_i" -lt "$BAR_LEN" ]; do
        if [ "$_i" -lt "$_filled" ]; then
            _bar="${_bar}${BAR_FULL}"
        else
            _bar="${_bar}${BAR_EMPTY}"
        fi
        _i=$((_i + 1))
    done

    printf '%s[%s%s%s] %s%s%%%s' "$DIM" "$_c" "$_bar" "$DIM" "$_c" "$_n" "$RESET"
}

SEP="${DIM} | ${RESET}"
line="${DIM}DIR${RESET} ${C_DIR}${dir}${RESET}"
line="${line}${SEP}${DIM}GIT${RESET} ${C_GIT}${branch}${RESET}"
line="${line}${SEP}${DIM}MODEL${RESET} ${C_MODEL}${model}${RESET}"
line="${line}${SEP}${DIM}CTX${RESET} $(meter "$ctx")"
line="${line}${SEP}${DIM}5H${RESET} $(meter "$five")"

printf '%s\n' "$line"
exit 0
